export AgentID, topic, name, owner, istopic, send, request

"An identifier for an agent or a topic."
struct AgentID
  name::String
  istopic::Bool
  owner::Any
end

"""
    aid = AgentID(name[, istopic])
    aid = AgentID(name[, owner])
    aid = AgentID(name[, istopic[, owner]])

Create an AgentID, optionally with an owner.
"""
AgentID(name::String, owner=nothing) = name[1] == '#' ? AgentID(name[2:end], true, owner) : AgentID(name, false, owner)
AgentID(name::String, istopic::Bool) = AgentID(name, istopic, nothing)

"""
    aid = topic([owner,] name[, subtopic])

Creates an AgentID for a named topic, optionally owned by an owner. AgentIDs that are
associated with gateways/agents can be used directly in `send()` and `request()` calls.
"""
topic(name::String) = AgentID(name, true)
topic(aid::AgentID) = aid.istopic ? aid : AgentID(aid.name*"__ntf", true)
topic(aid::AgentID, topic2::String) = AgentID(aid.name*"__"*topic2*"__ntf", true)
topic(owner, name::String) = AgentID(name, true, owner)
topic(owner, aid::AgentID) = aid.istopic ? aid : AgentID(aid.name*"__ntf", true, owner)
topic(owner, aid::AgentID, topic2::String) = AgentID(aid.name*"__"*topic2*"__ntf", true, owner)

name(aid::AgentID) = aid.name
owner(aid::AgentID) = aid.owner
istopic(aid::AgentID) = aid.istopic

"""
    send(aid, msg)

Send a message via the gateway to the specified agent. The agentID (`aid`) specified
must be an "owned" agentID obtained from the `agent(gw, name)` function or returned by the
`agentforservice(gw, service)` function.
"""
function send(aid::AgentID, msg)
  aid.owner === nothing && throw(ArgumentError("cannot send message to an unowned agentID"))
  msg.recipient = aid
  send(aid.owner, msg)
end

"""
    rsp = request(aid, msg[, timeout])

Send a request via the gateway to the specified agent, and wait for a response. The response is returned.
The agentID (`aid`) specified must be an "owned" agentID obtained from the `agent(gw, name)` function
or returned by the `agentforservice(gw, service)` function. The timeout is specified in milliseconds,
and defaults to 1 second if unspecified.
"""
function request(aid::AgentID, msg, timeout=timeout[])
  send(aid, msg)
  receive(aid.owner, msg, timeout)
end

function Base.show(io::IO, ::MIME"text/plain", aid::AgentID)
  if aid.owner !== nothing
    rsp = aid << ParameterReq()
    if rsp !== nothing
      println(io, rsp)
      return
    end
  end
  print(io, aid.istopic ? "#"*aid.name : aid.name)
end

function Base.show(io::IO, aid::AgentID)
  print(io, aid.istopic ? "#"*aid.name : aid.name)
end

JSON.lower(aid::AgentID) = aid.istopic ? "#"*aid.name : aid.name

"""
    rsp = aid << msg

Send a request via the gateway to the specified agent, and wait for a response.
"""
Base.:<<(aid::AgentID, msg) = request(aid, msg)

# add notation AgentID.property

function Base.getproperty(aid::AgentID, p::Symbol; ndx=-1)
  hasfield(AgentID, p) && return getfield(aid, p)
  getfield(aid, :owner) === nothing && return nothing
  rsp = aid << ParameterReq(param=string(p), index=ndx)
  rsp === nothing && return nothing
  rsp.value
end

function Base.setproperty!(aid::AgentID, p::Symbol, value; ndx=-1)
  if hasfield(AgentID, p)
    setfield!(aid, p, v)
    return
  end
  name = getfield(aid, :name)
  if getfield(aid, :owner) === nothing
    @warn "Unable to set $(name).$(p): unowned agent"
    return
  end
  rsp = aid << ParameterReq(param=string(p), value=value, index=ndx)
  if rsp === nothing
    @warn "Unable to set $(name).$(p): no response"
    return
  end
  rsp.value != value && @warn "$(name).$(p) set to $(rsp.value)"
  nothing
end

struct _IndexedAgentID
  aid::AgentID
  ndx::Int64
end

Base.getindex(aid::AgentID, ndx::Int64) = _IndexedAgentID(aid, ndx)
Base.getproperty(iaid::_IndexedAgentID, p::Symbol) = Base.getproperty(getfield(iaid, :aid), p, ndx=getfield(iaid, :ndx))
Base.setproperty!(iaid::_IndexedAgentID, p::Symbol, v) = Base.setproperty!(getfield(iaid, :aid), p, v, ndx=getfield(iaid, :ndx))

function Base.show(io::IO, iaid::_IndexedAgentID)
  aid = getfield(iaid, :aid)
  if aid.owner !== nothing
    rsp = aid << ParameterReq(index=getfield(iaid, :ndx))
    if rsp !== nothing
      println(io, rsp)
      return
    end
  end
  print(io, "$(getfield(getfield(iaid, :aid), :name))[$(getfield(iaid, :ndx))]")
end
