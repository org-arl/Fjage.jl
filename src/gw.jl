export Gateway, agent, topic, agentforservice, agentsforservice
export subscribe, unsubscribe, send, receive, request

"""
    gw = Gateway([name,] host, port)

Open a new TCP/IP gateway to communicate with fjåge agents from Julia.
"""
struct Gateway
  agentID::AgentID
  sock::Ref{TCPSocket}
  subscriptions::Set{String}
  pending::Dict{String,Channel}
  msgqueue::Vector
  tasks_waiting_for_msg::Vector{Tuple{Task,#=receive_id::=#Int}}
  msgqueue_lock::ReentrantLock # Protects both msgqueue and tasks_waiting_for_msg
  host::String
  port::Int
  reconnect::Ref{Bool}
  function Gateway(name::String, host::String, port::Int; reconnect=true)
    gw = new(
      AgentID(name, false),
      Ref(connect(host, port)),
      Set{String}(),
      Dict{String,Channel}(),
      Vector(),
      Vector{Tuple{Task,Int}}(),
      ReentrantLock(),
      host, port, Ref(reconnect)
    )
    @async _run(gw)
    gw
  end
end

Gateway(host::String, port::Int; reconnect=true) = Gateway("julia-gw-" * string(uuid1()), host, port; reconnect=reconnect)

Base.show(io::IO, gw::Gateway) = print(io, gw.agentID.name)

"""
    name(gw)

Get the name of the gateway.
"""
name(gw::Gateway) = gw.agentID.name

function _println(sock, s)
  @debug ">> $s"
  try
    println(sock, s)
  catch
    @warn "Connection lost..."
    close(sock)
  end
end

# respond to master container
function _respond(gw, rq::Dict, rsp::Dict)
  s = JSON.json(merge(Dict("id" => rq["id"], "inResponseTo" => rq["action"]), rsp))
  _println(gw.sock[], s)
end

# ask master container a question, and wait for reply
function _ask(gw, rq::Dict)
  id = string(uuid4())
  s = JSON.json(merge(rq, Dict("id" => id)))
  ch = Channel{Dict}(1)
  gw.pending[id] = ch
  try
    _println(gw.sock[], s)
    return take!(ch)
  finally
    delete!(gw.pending, id)
  end
end

_agents(gw::Gateway) = [gw.agentID.name]
_agents_types(gw::Gateway) = [(gw.agentID.name, "Gateway")]
_subscriptions(gw::Gateway) = gw.subscriptions
_services(gw::Gateway) = String[]
_agentsforservice(gw::Gateway, svc) = String[]
_onclose(gw::Gateway) = close(gw.sock[])
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
  s = JSON.json(Dict(
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
        s = readline(gw.sock[])
        @debug "<< $s"
        json = JSON.parse(s)
        if haskey(json, "id") && haskey(gw.pending, json["id"])
          put!(gw.pending[json["id"]], json)
        elseif haskey(json, "action")
          if json["action"] == "agents"
            at = _agents_types(gw)
            _respond(gw, json, Dict("agentIDs" => first.(at), "agentTypes" => last.(at)))
          elseif json["action"] == "agentForService"
            alist = _agentsforservice(gw, json["service"])
            if length(alist) > 0
              _respond(gw, json, Dict("agentID" => first(alist)))
            else
              _respond(gw, json, Dict())
            end
          elseif json["action"] == "agentsForService"
            alist = _agentsforservice(gw, json["service"])
            _respond(gw, json, Dict("agentIDs" => alist))
          elseif json["action"] == "services"
            _respond(gw, json, Dict("services" => _services(gw)))
          elseif json["action"] == "containsAgent"
            ans = (json["agentID"] ∈ _agents(gw))
            _respond(gw, json, Dict("answer" => ans))
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
        @warn ex stacktrace(catch_backtrace())
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
function agentforservice(gw::Gateway, svc::String)
  rq = Dict("action" => "agentForService", "service" => svc)
  rsp = _ask(gw, rq)
  haskey(rsp, "agentID") ? AgentID(rsp["agentID"], false, gw) : nothing
end

"Find all agents that provides a named service."
function agentsforservice(gw::Gateway, svc::String)
  rq = Dict("action" => "agentsForService", "service" => svc)
  rsp = _ask(gw, rq)
  [AgentID(a, false, gw) for a ∈ rsp["agentIDs"]]
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
  close(gw.sock[])
  nothing
end

# prepares a message to be sent to the server
function _prepare(msg::Message)
  data = Dict{Symbol,Any}()
  for k ∈ keys(msg)
    v = msg[k]
    if typeof(v) <: Array && typeof(v).parameters[1] <: Complex
      btype = typeof(v).parameters[1].parameters[1]
      data[k] = reinterpret(btype, v)
    elseif v !== nothing
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
function _inflate(json::AbstractDict)
  function inflate_recursively!(d)
    for (k, v) ∈ d
      if typeof(v) <: Dict && haskey(v, "clazz") && match(r"^\[.$", v["clazz"]) != nothing
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
      d[k] = typeof(v) <: AbstractDict ? inflate_recursively!(v) : v
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
    setproperty!(obj, Symbol(k), v)
  end
  obj
end

_inflate(json::String) = _inflate(JSON.parse(json))

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
  json = JSON.json(Dict(
    :action => :send,
    :relay => true,
    :message => Dict(
      :clazz => clazz,
      :data => data
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
