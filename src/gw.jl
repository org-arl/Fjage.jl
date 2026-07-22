export Gateway, agent, topic, agentforservice, agentsforservice
export subscribe, unsubscribe, send, receive, request

const JsonObject = JSON.Object{String,Any}

"""
    gw = Gateway([name,] host, port)

Open a new TCP/IP gateway to communicate with fjåge agents from Julia.
"""
struct Gateway
  agentID::AgentID
  sock::Ref{TCPSocket}
  subscriptions::Set{String}
  pending::Dict{String,Channel{JsonObject}}
  msgqueue::Vector{Message}
  tasks_waiting_for_msg::Vector{Tuple{Task,Int}}
  msgqueue_lock::ReentrantLock # Protects both msgqueue and tasks_waiting_for_msg
  host::String
  port::Int
  reconnect::Ref{Bool}
  function Gateway(name::String, host, port::Int; reconnect=true)
    startswith(name, "gateway-") || (name = "gateway-" * name)  # spec: gateway agent names are prefixed "gateway-"
    gw = new(
      AgentID(name, false),
      Ref(connect(host, port)),
      Set{String}(),
      Dict{String,Channel{JsonObject}}(),
      Message[],
      Tuple{Task,Int}[],
      ReentrantLock(),
      string(host), port, Ref(reconnect)
    )
    @async _run(gw)
    gw
  end
end

Gateway(host, port::Int; reconnect=true) = Gateway("gateway-" * string(uuid1()), host, port; reconnect=reconnect)

Base.show(io::IO, gw::Gateway) = print(io, gw.agentID.name)

"""
    name(gw)

Get the name of the gateway.
"""
name(gw::Gateway) = gw.agentID.name

function _println(sock, s)
  sock === nothing && return
  @debug ">> $s"
  try
    println(sock, s)
  catch
    @warn "Connection lost..."
    close(sock)
  end
end

# respond to master container
function _respond(gw, rq, rsp)
  s = JSON.json(merge!(JsonObject("id" => rq["id"], "inResponseTo" => rq["action"]), rsp))
  _println(gw.sock[], s)
end

# ask master container a question, and wait for reply
# 2-arg: blocks indefinitely; used by SlaveContainer (container.jl). Left untouched.
function _ask(gw, rq)
  id = string(uuid4())
  s = JSON.json(merge!(JsonObject("id" => id), rq))
  ch = Channel{JsonObject}(1)
  gw.pending[id] = ch
  try
    _println(gw.sock[], s)
    return take!(ch)
  finally
    delete!(gw.pending, id)
  end
end

# 3-arg: bounded/timeout variant; used only by the Gateway discovery methods below.
# timeout (ms): < 0 blocks forever, 0 is non-blocking, otherwise waits up to timeout
# and returns an empty JsonObject() on timeout (interpreted as "not found").
function _ask(gw, rq, timeout)
  timeout < 0 && return _ask(gw, rq)   # block forever (delegates to the 2-arg method)
  id = string(uuid4())
  s = JSON.json(merge!(JsonObject("id" => id), rq))
  ch = Channel{JsonObject}(1)
  gw.pending[id] = ch
  try
    _println(gw.sock[], s)
    timeout == 0 && return isready(ch) ? take!(ch) : JsonObject()
    # _run() is the sole producer into ch and this is the sole consumer, so there is
    # no producer race: we only ever read (isready) or take!, never put!/close ch. If
    # the reply lands after we give up, it harmlessly fills the (then-abandoned)
    # channel, and the finally-delete! makes _run() ignore any later reply for this id.
    timedwait(() -> isready(ch), timeout / 1e3; pollint=0.001) === :ok ? take!(ch) : JsonObject()
  finally
    delete!(gw.pending, id)
  end
end

_agents(gw::Gateway) = [gw.agentID.name]
_agents_types(gw::Gateway) = [(gw.agentID.name, "Gateway")]
_subscriptions(gw::Gateway) = gw.subscriptions
_services(gw::Gateway) = String[]
_agentsforservice(gw::Gateway, svc) = String[]
_onclose(gw::Gateway) = gw.sock[] === nothing || close(gw.sock[])
_shutdown(gw::Gateway) = close(gw)
_alive(gw::Gateway) = nothing

function _deliver(gw::Gateway, msg::Message, relay::Bool)
  lock(gw.msgqueue_lock) do
    for (idx, (task, _)) ∈ pairs(gw.tasks_waiting_for_msg)
      # Check if message matches the filter. This has to happen on the receiver
      # task because this task may run in a different world age.
      schedule(task, (current_task(), msg))
      if wait()
        deleteat!(gw.tasks_waiting_for_msg, idx)
        return
      end
    end
    push!(gw.msgqueue, msg)
    deleteat!(gw.msgqueue, 1:(length(gw.msgqueue) - MAX_QUEUE_LEN))
  end
end

# update master container about changes to recipient watch list
function _update_watch(gw)
  watch = _agents(gw)
  append!(watch, _subscriptions(gw))
  s = JSON.json(JsonObject(
    "action" => "wantsMessagesFor",
    "agentIDs" => watch
  ))
  _println(gw.sock[], s)
end

# task monitoring incoming JSON messages from master container
function _run(gw)
  while true
    try
      _println(gw.sock[], "{\"alive\": true}")
      _println(gw.sock[], "{\"action\": \"auth\", \"name\": \"$(name(gw))\"}")
      _update_watch(gw)
      while isopen(gw.sock[])
        s = strip(readline(gw.sock[]))
        @debug "<< $s"
        json = try
          JSON.parse(s)
        catch
          length(s) == 0 || @warn "Failed to parse JSON: $s"
          continue
        end
        if haskey(json, "id") && haskey(gw.pending, json["id"])
          put!(gw.pending[json["id"]], json)
        elseif haskey(json, "action")
          if json["action"] == "agents"
            at = _agents_types(gw)
            _respond(gw, json, JsonObject("agentIDs" => first.(at), "agentTypes" => last.(at)))
          elseif json["action"] == "agentForService"
            alist = _agentsforservice(gw, json["service"])
            if length(alist) > 0
              _respond(gw, json, JsonObject("agentID" => first(alist)))
            else
              _respond(gw, json, JsonObject())
            end
          elseif json["action"] == "agentsForService"
            alist = _agentsforservice(gw, json["service"])
            _respond(gw, json, JsonObject("agentIDs" => alist))
          elseif json["action"] == "services"
            _respond(gw, json, JsonObject("services" => _services(gw)))
          elseif json["action"] == "containsAgent"
            ans = (json["agentID"] ∈ _agents(gw))
            _respond(gw, json, JsonObject("answer" => ans))
          elseif json["action"] == "send"
            rcpt = json["message"]["data"]["recipient"]
            if rcpt ∈ _agents(gw) || rcpt ∈ _subscriptions(gw)
              try
                msg = _inflate(json["message"])
                _deliver(gw, msg, json["relay"])
              catch ex
                @warn ex
              end
            end
          elseif json["action"] == "shutdown"
            _shutdown(gw)
          end
        elseif haskey(json, "alive") && json["alive"]
          _println(gw.sock[], "{\"alive\": true}")
          _alive(gw)
        end
      end
    catch ex
      if !(ex isa ErrorException && startswith(ex.msg, "Unexpected end of input"))
        showerror(stderr, ex, catch_backtrace())
      end
    end
    gw.reconnect[] || break
    while gw.reconnect[] && !isopen(gw.sock[])
      @info "Reconnecting..."
      try
        gw.sock[] = connect(gw.host, gw.port)
        @info "Reconnected"
      catch
        sleep(1.0)
      end
    end
  end
  _onclose(gw)
end

AgentID(gw::Gateway) = gw.agentID
agent(gw::Gateway, name::String) = AgentID(name, false, gw)

"Find an agent that provides a named service."
function agentforservice(gw::Gateway, svc::AbstractString, timeout=6000)
  rq = JsonObject("action" => "agentForService", "service" => svc)
  rsp = _ask(gw, rq, timeout)
  haskey(rsp, "agentID") ? AgentID(rsp["agentID"], false, gw) : nothing
end

"Find all agents that provide a named service."
function agentsforservice(gw::Gateway, svc::AbstractString, timeout=6000)
  rq = JsonObject("action" => "agentsForService", "service" => svc)
  rsp = _ask(gw, rq, timeout)
  haskey(rsp, "agentIDs") ? [AgentID(a, false, gw) for a ∈ rsp["agentIDs"]] : AgentID[]
end

"Find all agents running on the master container."
function agents(gw::Gateway, timeout=6000)
  rq = JsonObject("action" => "agents")
  rsp = _ask(gw, rq, timeout)
  haskey(rsp, "agentIDs") ? [AgentID(a, false, gw) for a ∈ rsp["agentIDs"]] : AgentID[]
end

"Check if an agent is running on the master container."
containsagent(gw::Gateway, aid::AgentID, timeout=6000) = containsagent(gw, aid.name, timeout)
function containsagent(gw::Gateway, aid::AbstractString, timeout=6000)
  rq = JsonObject("action" => "containsAgent", "agentID" => aid)
  rsp = _ask(gw, rq, timeout)
  haskey(rsp, "answer") ? rsp["answer"]::Bool : false
end

"Find all services available on the master container."
function services(gw::Gateway, timeout=6000)
  rq = JsonObject("action" => "services")
  rsp = _ask(gw, rq, timeout)
  haskey(rsp, "services") ? Vector{String}(rsp["services"]) : String[]
end

"Subscribe to receive all messages sent to the given topic."
function subscribe(gw::Gateway, aid::AgentID)
  push!(gw.subscriptions, string(topic(gw, aid)))
  _update_watch(gw)
  true
end

"Unsubscribe from receiving messages sent to the given topic."
function unsubscribe(gw::Gateway, aid::AgentID)
  k = string(topic(gw, aid))
  if k ∈ gw.subscriptions
    delete!(gw.subscriptions, k)
    _update_watch(gw)
    return true
  end
  false
end

"Close a gateway connection to the master container."
function Base.close(gw::Gateway)
  gw.reconnect[] = false
  _println(gw.sock[], "{\"alive\": false}")
  gw.sock[] === nothing || close(gw.sock[])
  nothing
end

# encodes Julia arrays as Base64 representation
_array(v::AbstractArray{T}) where {T <: Union{Int8,UInt8}} = JsonObject(
  "clazz" => "[B",
  "data" => base64encode(reinterpret(UInt8, v))
)
_array(v::AbstractArray{T}) where {T <: Union{Int16,UInt16}} = JsonObject(
  "clazz" => "[S",
  "data" => base64encode(reinterpret(UInt8, v))
)
_array(v::AbstractArray{T}) where {T <: Union{Int32,UInt32}} = JsonObject(
  "clazz" => "[I",
  "data" => base64encode(reinterpret(UInt8, v))
)
_array(v::AbstractArray{T}) where {T <: Union{Int64,UInt64}} = JsonObject(
  "clazz" => "[J",
  "data" => base64encode(reinterpret(UInt8, v))
)
_array(v::AbstractArray{Float32}) = JsonObject(
  "clazz" => "[F",
  "data" => base64encode(reinterpret(UInt8, v))
)
_array(v::AbstractArray{Float64}) = JsonObject(
  "clazz" => "[D",
  "data" => base64encode(reinterpret(UInt8, v))
)

# fallback for other types
_array(v) = v

# prepares a message to be sent to the server
function _prepare(msg::Message)
  data = JSON.Object{Symbol,Any}()
  for k ∈ keys(msg)
    v = msg[k]
    # multidimensional arrays are serialized in Fortran memory order
    if v isa AbstractArray{<:Complex}
      data[k] = _array(reinterpret(real(eltype(v)), vec(transpose(v))))
      data[Symbol(string(k) * "__isComplex")] = true
    elseif v isa AbstractArray
      data[k] = _array(vec(transpose(v)))
    elseif v !== nothing && !(v isa AbstractFloat && isnan(v))
      k === :performative && (k = :perf)
      k === :messageID && (k = :msgID)
      data[k] = v
    end
  end
  classname(msg), data
end

# converts Base64 encoded arrays to Julia arrays
function _b64toarray(v)
  try
    dtype = v["clazz"]
    if dtype == "[B"  # byte array
      dtype = Int8
    elseif dtype == "[S"  # short array
      dtype = Int16
    elseif dtype == "[I"  # integer array
      dtype = Int32
    elseif dtype == "[J"  # long array
      dtype = Int64
    elseif dtype == "[F"  # float array
      dtype = Float32
    elseif dtype == "[D"  # double array
      dtype = Float64
    else
      return v
    end
    return Array{dtype}(reinterpret(dtype, base64decode(v["data"])))
  catch ex
    return v
  end
end

# creates a message object from a JSON representation of the object
function _inflate(json)
  function inflate_recursively!(d)
    for (k, v) ∈ d
      if typeof(v) <: JSON.Object && haskey(v, "clazz") && startswith(v["clazz"], "[")
        v = _b64toarray(v)
      end
      if typeof(v) <: Array && length(v) > 0
        t = typeof(v[1])
        v = Array{t}(v)
        kcplx = k * "__isComplex"
        if haskey(d, kcplx) && d[kcplx]
          v = Array{Complex{t}}(reinterpret(Complex{t}, v))
          delete!(d, kcplx)
        end
      end
      d[k] = typeof(v) <: JSON.Object ? inflate_recursively!(v) : v
    end
    d
  end
  clazz = json["clazz"]
  data = inflate_recursively!(json["data"])
  obj = _messageclass_lookup(clazz)()
  for (k, v) ∈ data
    if k == "sender" || k == "recipient"
      v = AgentID(v)
    elseif k == "perf"
      k = "performative"
      v = Symbol(v)
    elseif k == "msgID"
      k = "messageID"
    end
    trysetproperty!(obj, Symbol(k), v)
  end
  obj
end

"""
    send(gw, msg)

Send a message via the gateway to the specified agent. The `recipient` field of the message must be
populated with an agentID.
"""
function send(gw::Gateway, msg)
  isopen(gw.sock[]) || return false
  msg.sender = gw.agentID
  msg.sentAt = Dates.value(now())
  clazz, data = _prepare(msg)
  json = JSON.json(JsonObject(
    "action" => "send",
    "relay" => true,
    "message" => JsonObject(
      "clazz" => clazz,
      "data" => data
    )
  ))
  _println(gw.sock[], json)
  true
end

"""
    msg = receive(gw[, filter][, timeout])

Receive an incoming message from other agents or topics. Timeout is specified in
milliseconds. If no timeout is specified, the call is non-blocking. If a negative timeout
is specified, the call is blocking until a message is available.

If a `filter` is specified, only messages matching the filter are retrieved. A filter
may be a message type, a message or a function. If it is a message type, only messages
of that type or a subtype are retrieved. If it is a message, any message whose `inReplyTo`
field is set to the `msgID` of the specified message is retrieved. If it is a function,
it must take in a message and return `true` or `false`. A message for which it returns
`true` is retrieved.
"""
receive(gw::Gateway, timeout::Int=0) = receive(gw, msg->true, timeout)

const receive_counter = Threads.Atomic{Int}(0)

function receive(gw::Gateway, filt, timeout=0)
  receive_id = (receive_counter[] += 1)
  maybe_msg = lock(gw.msgqueue_lock) do
    for (idx, msg) ∈ pairs(gw.msgqueue)
      if _matches(filt, msg)
        return Some(popat!(gw.msgqueue, idx))
      end
    end
    if timeout == 0
      return Some(nothing)
    end
    if timeout > 0
      @async begin
        sleep(timeout/1e3)
        lock(gw.msgqueue_lock) do
          for (idx, (_, id)) ∈ pairs(gw.tasks_waiting_for_msg)
            # We must identify the receive to remove from the waiting list
            # based on the receive ID and not the task because the task which
            # started this one may have had its previous receive satisfied and
            # is waiting for a new receive.
            if id == receive_id
              deleteat!(gw.tasks_waiting_for_msg, idx)
              schedule($(current_task()), nothing)
              break
            end
          end
        end
      end
    end
    push!(gw.tasks_waiting_for_msg, (current_task(), receive_id))
    return nothing
  end
  isnothing(maybe_msg) || return something(maybe_msg)
  while true
    maybe_task_and_msg = wait()
    isnothing(maybe_task_and_msg) && return nothing
    delivery_task, msg = maybe_task_and_msg
    if _matches(filt, msg)
      schedule(delivery_task, true)
      return msg
    else
      schedule(delivery_task, false)
    end
  end
end

"""
    rsp = request(gw, msg[, timeout])

Send a request via the gateway to the specified agent, and wait for a response. The response is returned.
The `recipient` field of the request message (`msg`) must be populated with an agentID. The timeout
is specified in milliseconds, and defaults to 1 second if unspecified.
"""
function request(gw::Gateway, msg, timeout=1000)
  send(gw, msg) || return nothing
  receive(gw, msg, timeout)
end

"Flush the incoming message queue."
function Base.flush(gw::Gateway)
  lock(gw.msgqueue_lock) do
    empty!(gw.msgqueue)
  end
  nothing
end
