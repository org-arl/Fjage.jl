export AgentID, topic, name, owner, istopic, send, request

"An identifier for an agent or a topic."
struct AgentID{T}
  name::String
  istopic::Bool
  owner::T
  AgentID(name::String, istopic::Bool, owner) = new{typeof(owner)}(name, istopic, owner)
end

"""
    aid = AgentID(name[, istopic])
    aid = AgentID(name[, owner])
    aid = AgentID(name[, istopic[, owner]])

Create an AgentID, optionally with an owner.
"""
AgentID(name::String, owner=nothing) = name[1] == '#' ? AgentID(name[2:end], true, owner) : AgentID(name, false, owner)
AgentID(name::String, istopic::Bool) = AgentID(name, istopic, nothing)

# create unowned AgentID from owned AgentID
AgentID(aid::AgentID) = AgentID(aid.name, aid.istopic, nothing)

"""
    aid = topic([owner,] name[, subtopic])

Creates an AgentID for a named topic, optionally owned by an owner. AgentIDs that are
associated with gateways/agents can be used directly in `send()` and `request()` calls.
"""
topic(name::String) = AgentID(name, true)
topic(aid::AgentID) = aid.istopic ? aid : AgentID(aid.name * "__ntf", true)
topic(aid::AgentID, topic2::String) = AgentID(aid.name * "__" * topic2 * "__ntf", true)
topic(owner, name::String) = AgentID(name, true, owner)
topic(owner, aid::AgentID) = aid.istopic ? aid : AgentID(aid.name * "__ntf", true, owner)
topic(owner, aid::AgentID, topic2::String) = AgentID(aid.name * "__" * topic2 * "__ntf", true, owner)

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
  msg.recipient = AgentID(aid)
  send(aid.owner, msg)
end

"""
    rsp = request(aid, msg[, timeout])
    rsp = request(aid, msg, T[, timeout])

Send a request to the specified agent, and wait for a response. The agentID (`aid`) specified
must be an "owned" agentID obtained from the `agent(owner, name)` function or returned by the
`agentforservice(owner, service)` function.

If `T` is specified, the response is expected to be of type `T` or `nothing` if the request times out.
The timeout is specified in milliseconds, and defaults to 1 second if unspecified. The default timeout
can be changed by calling `default_timeout(millis)`.

Since the response message may be of any type, type inference cannot proceed unless the return
type is explicitly specified. It is recommended that the caller specify the expected type of the
response message explicitly when possible.
"""
function request(aid::AgentID, msg, timeout=timeout[])
  send(aid, msg)
  receive(aid.owner, msg, timeout)
end

# applies to Gateway / Agent / owned AgentID
request(a, msg, T, timeout=timeout[]) = request(a, msg, timeout)::Union{Nothing,T}

function Base.show(io::IO, ::MIME"text/plain", aid::AgentID)
  if aid.owner !== nothing
    rsp = request(aid, ParameterReq(), ParameterRsp)
    if rsp !== nothing
      println(io, rsp)
      return
    end
  end
  print(io, aid.istopic ? "#" * aid.name : aid.name)
end

function Base.show(io::IO, aid::AgentID)
  print(io, aid.istopic ? "#" * aid.name : aid.name)
end

JSON.lower(aid::AgentID) = aid.istopic ? "#" * aid.name : aid.name

"""
    rsp = aid << msg

Send a request via the gateway to the specified agent, and wait for a response.
The default timeout is used for this request. If no response is received within
the timeout, `nothing` is returned. The agentID (`aid`) specified must be an
"owned" agentID obtained from the `agent(owner, name)` function or returned by the
`agentforservice(owner, service)` function.

Exactly equivalent to `request(aid, msg)`.

Since the response message may be of any type, type inference cannot proceed unless the return
type is explicitly specified. It is recommended that the caller specify the expected type of the
response message explicitly when possible via type assertion.

# Example:

```julia
rsp = (aid << ParameterReq())::Union{Nothing,ParameterRsp}
```
"""
Base.:<<(aid::AgentID, msg) = request(aid, msg)

"""
    get(aid, [ndx,] param[, timeout])
    get(aid, [ndx,] param, T[, timeout])

Get the value of a parameter from the specified agent. The agentID (`aid`) specified
must be an "owned" agentID obtained from the `agent(owner, name)` function or returned by the
`agentforservice(owner, service)` function. If the request times out, `nothing` is returned.
The timeout may be specified in milliseconds, and defaults to 1 second or the value
set by `default_timeout(millis)`. If `ndx` is specified, an indexed parameter is
returned.

If `T` is specified, the parameter value is expected to be of type `T`. Specifying
`T` allows for type inference and is recommended when the expected type of the
parameter value is known.

An alternative syntax for getting a parameter value is to use the `aid.param` or
`aid[ndx].param` notation, which is equivalent to `get(aid, :param)` or `get(aid, ndx, :param)`.
With this notation, timeout cannot be specified and the default timeout is always used.
To aid type inference, one may use type assertion with this notation.

# Example:

```julia
x = get(aid, :title)                  # no type and default timeout
x = get(aid, :title, String)          # with expected type and default timeout
x = get(aid, :title, 2000)            # no type and custom timeout
x = get(aid, :title, String, 2000)    # with expected type and custom timeout
x = get(aid, 1, :MTU)                 # indexed parameter
x = aid.title                         # alternative notation with no type
x = aid.title::String                 # alternative notation with expected type
x = aid[1].MTU                        # alternative notation for indexed parameter
```
"""
function Base.get(aid::AgentID, ndx::Int, p::Symbol, T, timeout)::Union{Nothing,T}
  req = ParameterReq(param=string(p), index=ndx)
  rsp = request(aid, req, ParameterRsp, timeout)
  rsp === nothing && return nothing
  T === Any && return rsp.value
  convert(T, rsp.value)
end

Base.get(aid::AgentID, p::Symbol) = get(aid, -1, p, Any, timeout[])
Base.get(aid::AgentID, p::Symbol, T::Type) = get(aid, -1, p, T, timeout[])
Base.get(aid::AgentID, p::Symbol, timeout::Int) = get(aid, -1, p, Any, timeout)
Base.get(aid::AgentID, p::Symbol, T::Type, timeout::Int) = get(aid, -1, p, T, timeout)
Base.get(aid::AgentID, ndx::Int, p::Symbol) = get(aid, ndx, p, Any, timeout[])
Base.get(aid::AgentID, ndx::Int, p::Symbol, T) = get(aid, ndx, p, T, timeout[])
Base.get(aid::AgentID, ndx::Int, p::Symbol, timeout::Int) = get(aid, ndx, p, Any, timeout)

"""
    set!(aid, [ndx,] param, value[, timeout])

Set the value of a parameter on the specified agent. The agentID (`aid`) specified
must be an "owned" agentID obtained from the `agent(owner, name)` function or
returned by the `agentforservice(owner, service)` function. If the request times out,
`nothing` is returned. The timeout may be specified in milliseconds, and defaults to
1 second or the value set by `default_timeout(millis)`. If `ndx` is specified, an
indexed parameter is set.

The actual value set on the agent may differ from the value specified by the caller,
and the value that is actually set is returned. For type inference, it is assumed
that the value specified by the caller is the expected type of the parameter value.

An alternative syntax for setting a parameter value is to use the `aid.param = value`
or `aid[ndx].param = value` notation, which is equivalent to `set!(aid, :param, value)` or
`set!(aid, ndx, :param, value)`. With this notation, timeout cannot be specified and
the default timeout is always used.
"""
function set!(aid::AgentID, ndx::Int, p::Symbol, v, timeout)
  req = ParameterReq(param=string(p), value=v, index=ndx)
  rsp = request(aid, req, ParameterRsp, timeout)
  if rsp === nothing
    @warn "Unable to set $(name).$(p): no response"
    return
  end
  convert(typeof(v), rsp.value)
end

set!(aid::AgentID, p::Symbol, v) = set!(aid, -1, p, v, timeout[])
set!(aid::AgentID, p::Symbol, v, timeout::Int) = set!(aid, -1, p, v, timeout)
set!(aid::AgentID, ndx::Int, p::Symbol, v) = set!(aid, ndx, p, v, timeout[])

# add notation AgentID.property

function Base.getproperty(aid::AgentID, p::Symbol; ndx=-1)
  hasfield(AgentID, p) && return getfield(aid, p)
  if getfield(aid, :owner) === nothing
    @warn "Unable to get $(name).$(p): unowned agent"
    return nothing
  end
  get(aid, ndx, p)
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
  rv = set!(aid, ndx, p, value)
  rv == value || @warn "$(name).$(p) set to $(rv) instead of $(value)"
  nothing
end

struct _IndexedAgentID{T}
  aid::AgentID{T}
  ndx::Int64
end

Base.getindex(aid::AgentID{T}, ndx::Int64) where T = _IndexedAgentID{T}(aid, ndx)
Base.getproperty(iaid::_IndexedAgentID, p::Symbol) = Base.getproperty(getfield(iaid, :aid), p, ndx=getfield(iaid, :ndx))
Base.setproperty!(iaid::_IndexedAgentID, p::Symbol, v) = Base.setproperty!(getfield(iaid, :aid), p, v, ndx=getfield(iaid, :ndx))

function Base.show(io::IO, iaid::_IndexedAgentID)
  aid = getfield(iaid, :aid)
  if aid.owner !== nothing
    req = ParameterReq(index=getfield(iaid, :ndx))
    rsp = request(iaid, req, ParameterRsp, timeout)
    if rsp !== nothing
      println(io, rsp)
      return
    end
  end
  print(io, "$(getfield(getfield(iaid, :aid), :name))[$(getfield(iaid, :ndx))]")
end
