"""
    gw = Gateway([name,] host, port)

Open a new TCP/IP gateway to communicate with fjåge agents from Julia.

See also: [`Fjage`](@ref)
"""
struct Gateway
  agentID::AgentID
  sock::TCPSocket
  subscriptions::Dict{String,Bool}
  pending::Dict{String,Channel}
  queue::Channel
  function Gateway(name::String, host::String, port::Int)
    gw = new(
      AgentID(name, false),
      connect(host, port),
      Dict{String,Bool}(),
      Dict{String,Channel}(),
      Channel(MAX_QUEUE_LEN)
    )
    @async _run(gw)
    gw
  end
end

Gateway(host::String, port::Int) = Gateway("julia-gw-" * string(uuid1()), host, port)

Base.show(io::IO, gw::Gateway) = print(io, gw.agentID.name)

# respond to master container
function _respond(gw, rq::Dict, rsp::Dict)
  s = JSON.json(merge(Dict("id" => rq["id"], "inResponseTo" => rq["action"]), rsp))
  println(gw.sock, s)
end

# ask master container a question, and wait for reply
function _ask(gw, rq::Dict)
  id = string(uuid4())
  s = JSON.json(merge(rq, Dict("id" => id)))
  ch = Channel{Dict}(1)
  gw.pending[id] = ch
  try
    println(gw.sock, s)
    return take!(ch)
  finally
    delete!(gw.pending, id)
  end
end

# update master container about changes to recipient watch list
function _update_watch(gw)
  watch = [gw.agentID.name]
  for s in keys(gw.subscriptions)
    push!(watch, s)
  end
  s = JSON.json(Dict(
    "action" => "wantsMessagesFor",
    "agentIDs" => watch
  ))
  println(gw.sock, s)
end

# task monitoring incoming JSON messages from master container
function _run(gw)
  println(gw.sock, "{\"alive\": true}")
  _update_watch(gw)
  while isopen(gw.sock)
    s = readline(gw.sock)
    json = JSON.parse(s)
    if haskey(json, "id") && haskey(gw.pending, json["id"])
      put!(gw.pending[json["id"]], json)
    elseif haskey(json, "action")
      if json["action"] == "agents"
        _respond(gw, json, Dict("agentIDs" => [gw.agentID.name]))
      elseif json["action"] == "agentForService"
        _respond(gw, json, Dict())
      elseif json["action"] == "agentsForService"
        _respond(gw, json, Dict("agentIDs" => []))
      elseif json["action"] == "services"
        _respond(gw, json, Dict("services" => []))
      elseif json["action"] == "containsAgent"
        ans = (json["agentID"] == gw.agentID.name)
        _respond(gw, json, Dict("answer" => ans))
      elseif json["action"] == "send"
        rcpt = json["message"]["data"]["recipient"]
        if rcpt == gw.agentID.name || get(gw.subscriptions, rcpt, false)
          try
            msg = _inflate(json["message"])
            while length(gw.queue.data) >= MAX_QUEUE_LEN
              take!(gw.queue)
            end
            put!(gw.queue, msg)
          catch ex
            # silently ignore bad messages
          end
        end
      end
    elseif haskey(json, "alive") && json["alive"]
      println(gw.sock, "{\"alive\": true}")
    end
  end
end

topic(gw::Gateway, name::String) = AgentID(name, true, gw)
topic(gw::Gateway, aid::AgentID) = aid.istopic ? aid : AgentID(aid.name*"__ntf", true, gw)
topic(gw::Gateway, aid::AgentID, topic2::String) = AgentID(aid.name*"__"*topic2*"__ntf", true, gw)

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
  [AgentID(a, false, gw) for a in rsp["agentIDs"]]
end

"Subscribe to receive all messages sent to the given topic."
function subscribe(gw::Gateway, aid::AgentID)
  gw.subscriptions[string(topic(gw, aid))] = true
  _update_watch(gw)
  true
end

"Unsubscribe from receiving messages sent to the given topic."
function unsubscribe(gw::Gateway, aid::AgentID)
  k = string(topic(gw, aid))
  if haskey(gw.subscriptions, k)
    delete!(gw.subscriptions, k)
    _update_watch(gw)
    return true
  end
  false
end

"Close a gateway connection to the master container."
function close(gw::Gateway)
  println(gw.sock, "{\"alive\": false}")
  Base.close(gw.sock)
end

# prepares a message to be sent to the server
function _prepare!(gw::Gateway, msg::Message)
  msg.sender = gw.agentID
  for k in keys(msg.__data__)
    v = msg.__data__[k]
    if typeof(v) <: Array && typeof(v).parameters[1] <: Complex
      btype = typeof(v).parameters[1].parameters[1]
      msg.__data__[k] = reinterpret(btype, v)
    end
  end
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
  if typeof(json) == String
    json = JSON.parse(json)
  end
  clazz = json["clazz"]
  data = json["data"]
  stype = _messageclass_lookup(clazz)
  obj = @eval $stype()
  for k in keys(data)
    v = data[k]
    if endswith(k, "__isComplex")
      continue
    end
    if k == "sender" || k == "recipient"
      v = AgentID(v)
    end
    if typeof(v) <: Dict && haskey(v, "clazz") && match(r"^\[.$", v["clazz"]) != nothing
      v = _b64toarray(v)
    end
    if typeof(v) <: Array && length(v) > 0
      t = typeof(v[1])
      v = Array{t}(v)
      kcplx = k*"__isComplex"
      if haskey(data, kcplx) && data[kcplx]
        v = Array{Complex{t}}(reinterpret(Complex{t}, v))
      end
    end
    obj.__data__[k] = v
  end
  obj
end

"""
    send(gw, msg)

Send a message via the gateway to the specified agent. The `recipient` field of the message must be
populated with an agentID.
"""
function send(gw::Gateway, msg::Message)
  _prepare!(gw, msg)
  json = JSON.json(Dict("action" => "send", "relay" => true, "message" => msg))
  println(gw.sock, json)
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
function receive(gw::Gateway, timeout::Int=0)
  isready(gw.queue) && return take!(gw.queue)
  timeout == 0 && return nothing
  waiting = true
  if timeout > 0
    @async begin
      sleep(timeout/1000.0)
      waiting && push!(gw.queue, nothing)
    end
  end
  rv = take!(gw.queue)
  waiting = false
  rv
end

function receive(gw::Gateway, filt, timeout::Int=0)
  t1 = now() + Millisecond(timeout)
  cache = []
  while true
    msg = receive(gw, (t1-now()).value)
    if _matches(filt, msg)
      if length(cache) > 0
        while isready(gw.queue)
          push!(cache, take!(gw.queue))
        end
        for m in cache
          push!(gw.queue, m)
        end
      end
      return msg
    end
    push!(cache, msg)
  end
end

"""
    rsp = request(gw, msg[, timeout])

Send a request via the gateway to the specified agent, and wait for a response. The response is returned.
The `recipient` field of the request message (`msg`) must be populated with an agentID. The timeout
is specified in milliseconds, and defaults to 1 second if unspecified.
"""
function request(gw::Gateway, msg::Message, timeout::Int=1000)
  send(gw, msg)
  receive(gw, msg, timeout)
end

"Flush the incoming message queue."
function flush(gw::Gateway)
  while isready(gw.queue)
    take!(gw.queue)
  end
end

# Base functions to add local methods
Base.close(gw::Gateway) = close(gw)
Base.flush(gw::Gateway) = flush(gw)
