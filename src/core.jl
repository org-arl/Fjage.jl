# global variables
const _messageclasses = Dict{String,DataType}()

"An action represented by a message."
module Performative
  const REQUEST = "REQUEST"
  const AGREE = "AGREE"
  const REFUSE = "REFUSE"
  const FAILURE = "FAILURE"
  const INFORM = "INFORM"
  const CONFIRM = "CONFIRM"
  const DISCONFIRM = "DISCONFIRM"
  const QUERY_IF = "QUERY_IF"
  const NOT_UNDERSTOOD = "NOT_UNDERSTOOD"
  const CFP = "CFP"
  const PROPOSE = "PROPOSE"
  const CANCEL = "CANCEL"
end

"Base class for messages transmitted by one agent to another."
abstract type Message end

"An identifier for an agent or a topic."
struct AgentID
  name::String
  istopic::Bool
  owner::Any
end

"""
    aid = AgentID(name[, istopic])

Create an unowned AgentID.

See also: [`agent`](@ref), [`topic`](@ref)
"""
AgentID(name::String) = name[1] == '#' ? AgentID(name[2:end], true, nothing) : AgentID(name, false, nothing)
AgentID(name::String, istopic::Bool) = AgentID(name, istopic, nothing)

Base.show(io::IO, aid::AgentID) = print(io, aid.istopic ? "#"*aid.name : aid.name)
JSON.lower(aid::AgentID) = aid.istopic ? "#"*aid.name : aid.name

"""
    aid = agent([owner,] name)

Creates an AgentID for a named agent, optionally owned by a gateway/agent. AgentIDs that are
associated with gateways/agents can be used directly in `send()` and `request()` calls.
"""
agent(name::String) = AgentID(name, false)
agent(owner, name::String) = AgentID(name, false, owner)

"""
    aid = topic([owner,] name[, subtopic])

Creates an AgentID for a named topic, optionally owned by an owner. AgentIDs that are
associated with gateways/agents can be used directly in `send()` and `request()` calls.
"""
topic(name::String) = AgentID(name, true)
topic(aid::AgentID) = aid.istopic ? aid : AgentID(aid.name*"__ntf", true)
topic(aid::AgentID, topic2::String) = AgentID(aid.name*"__"*topic2*"__ntf", true)

"""
    mtype = MessageClass(context, clazz[, superclass[, performative]])

Create a message class from a fully qualified class name. If a performative is not
specified, it is guessed based on the class name. For class names ending with "Req",
the performative is assumed to be REQUEST, and for all other messages, INFORM.

# Examples

```julia-repl
julia> using Fjage
julia> MyShellExecReq = MessageClass(@__MODULE__, "org.arl.fjage.shell.ShellExecReq");
julia> req = MyShellExecReq(cmd="ps")
ShellExecReq: REQUEST [cmd:"ps"]
```
"""
function MessageClass(context, clazz::String, superclass=nothing, performative=nothing)
  sname = replace(string(clazz), "." => "_")
  tname = sname
  if performative === nothing
    performative = match(r"Req$",string(clazz))==nothing ? Performative.INFORM : Performative.REQUEST
  end
  if superclass === nothing
    superclass = "$(@__MODULE__).Message"
  else
    scname = string(superclass)
    ndx = findlast(isequal('.'), scname)
    if ndx !== nothing
      scname = scname[ndx+1:end]
    end
    if scname == tname
      tname = "$(scname)_"
    end
  end
  expr = Expr(:toplevel)
  expr.args = [Meta.parse("""
      struct $(tname) <: $(superclass)
        clazz::String
        data::Dict{String,Any}
        $(tname)(c::String, d::Dict{String,Any}) = new(c, d)
      end
    """),
    Meta.parse("""
      function $(sname)(; kwargs...)
        dict = Dict{String,Any}(
          "msgID" => string($(@__MODULE__).uuid4()),
          "perf" => "$(performative)"
        )
        for k in keys(kwargs)
          dict[string(k)] = kwargs[k]
        end
        return $(tname)("$(clazz)", dict)
      end
    """),
    Meta.parse("""
      $(@__MODULE__)._messageclasses["$(clazz)"] = $(tname)
    """)]
  if sname != tname
    push!(expr.args, Meta.parse("$(tname)(; kwargs...) = $(sname)(; kwargs...)"))
  end
  return context.eval(expr)
end

function AbstractMessageClass(context, clazz::String, performative=nothing)
  sname = replace(string(clazz), "." => "_")
  expr = Expr(:toplevel)
  expr.args = [Meta.parse("abstract type $sname <: $(@__MODULE__).Message end"), Meta.parse("$sname")]
  rv = context.eval(expr)
  MessageClass(context, clazz, rv, performative)
  return rv
end

function _messageclass_lookup(clazz::String)
  haskey(_messageclasses, clazz) && return _messageclasses[clazz]
  Message
end

"""
    send(aid, msg)

Send a message via the gateway to the specified agent. The agentID (`aid`) specified
must be an "owned" agentID obtained from the `agent(gw, name)` function or returned by the
`agentforservice(gw, service)` function.
"""
function send(aid::AgentID, msg::Message)
  aid.owner === nothing && throw(ArgumentError("cannot send message to an unowned agentID"))
  msg.recipient = aid
  send(aid.owner, msg)
end

# helper function to see if a message matches a filter
function _matches(filt, msg)
  (msg === nothing || filt === nothing) && return true
  if typeof(filt) == DataType
    return typeof(msg) <: filt
  elseif typeof(filt) <: Message
    return msg.inReplyTo == filt.msgID
  elseif typeof(filt) <: Function
    return filt(msg)
  end
  false
end

"""
    rsp = request(aid, msg[, timeout])

Send a request via the gateway to the specified agent, and wait for a response. The response is returned.
The agentID (`aid`) specified must be an "owned" agentID obtained from the `agent(gw, name)` function
or returned by the `agentforservice(gw, service)` function. The timeout is specified in milliseconds,
and defaults to 1 second if unspecified.
"""
function request(aid::AgentID, msg::Message, timeout::Int=1000)
  send(aid, msg)
  receive(aid.owner, msg, timeout)
end

"""
    rsp = aid << msg

Send a request via the gateway to the specified agent, and wait for a response.

See also: [`request`](@ref), [`Fjage`](@ref)
"""
Base.:<<(aid::AgentID, msg::Message) = request(aid, msg)

# adds notation message.field
function Base.getproperty(s::Message, p::Symbol)
  if p == :__clazz__
    return getfield(s, :clazz)
  elseif p == :__data__
    return getfield(s, :data)
  else
    p1 = string(p)
    if p1 == "performative"
      p1 = "perf"
    elseif p1 == "messageID"
      p1 = "msgID"
    end
    v = getfield(s, :data)
    if !haskey(v, p1)
      return nothing
    end
    v = v[p1]
    return v
  end
end

# adds notation message.field
function Base.setproperty!(s::Message, p::Symbol, v)
  (p == :__clazz__ || p == :__data__) && throw(ArgumentError("read-only property cannot be set"))
  p1 = string(p)
  if p1 == "performative"
    p1 = "perf"
  elseif p1 == "messageID"
    p1 = "msgID"
  end
  getfield(s, :data)[p1] = v
  nothing
end

# pretty prints arrays without type names
function _repr(x)
  x = repr(x)
  m = match(r"[A-Za-z0-9]+(\[.+\])", x)
  m !== nothing && (x = m[1])
  x
end

# pretty printing of messages
function Base.show(io::IO, msg::Message)
  ndx = findlast(".", msg.__clazz__)
  s = ndx === nothing ? msg.__clazz__ : msg.__clazz__[ndx[1]+1:end]
  p = ""
  data_suffix = ""
  signal_suffix = ""
  suffix = ""
  data = msg.__data__
  for k in keys(data)
    x = data[k]
    if k == "perf"
      s *= ": " * x
    elseif k == "data"
      if typeof(x) <: Array
        data_suffix *= "($(length(x)) bytes)"
      else
        p *= " $k:" * _repr(data[k])
      end
    elseif k == "signal"
      if typeof(x) <: Array
        signal_suffix *= "($(length(x)) samples)"
      else
        p *= " $k:" * _repr(data[k])
      end
    elseif k != "sender" && k != "recipient" && k != "msgID" && k != "inReplyTo" && k != "sentAt"
      if typeof(x) <: Number || typeof(x) == String || typeof(x) <: Array || typeof(x) == Bool
        p *= " $k:" * _repr(x)
      else
        suffix = "..."
      end
    end
  end
  length(suffix) > 0 && (p *= " " * suffix)
  length(signal_suffix) > 0 && (p *= " " * signal_suffix)
  length(data_suffix) > 0 && (p *= " " * data_suffix)
  p = strip(p)
  length(p) > 0 && (s *= " [$p]")
  if msg.__clazz__ == "org.arl.fjage.GenericMessage"
    m = match(r"^GenericMessage: (.*)$", s)
    m === nothing || (s = m[1])
  end
  print(io, s)
end

"Generic message type that can carry arbitrary name-value pairs as data."
GenericMessage = MessageClass(@__MODULE__, "org.arl.fjage.GenericMessage")

"Shell command execution request message."
ShellExecReq = MessageClass(@__MODULE__, "org.arl.fjage.shell.ShellExecReq")

"Parameter request message."
ParameterReq = MessageClass(@__MODULE__, "org.arl.fjage.param.ParameterReq")

"Parameter response message."
ParameterRsp = MessageClass(@__MODULE__, "org.arl.fjage.param.ParameterRsp")

"""
    msg = Message([perf])
    msg = Message(inreplyto[, perf])

Create a message with just a performative (`perf`) and no data. If the performative
is not specified, it defaults to INFORM. If the inreplyto is specified, the message
`inReplyTo` and `recipient` fields are set accordingly.
"""
Message(perf::String=Performative.INFORM) = GenericMessage(perf=perf)
Message(inreplyto::Message, perf::String=Performative.INFORM) = GenericMessage(perf=perf, inReplyTo=inreplyto.msgID, recipient=inreplyto.sender)

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
Base.show(io::IO, iaid::_IndexedAgentID) = print(io, "$(getfield(getfield(iaid, :aid), :name))[$(getfield(iaid, :ndx))]")

# convenience methods and pretty printing for parameters

function org_arl_fjage_param_ParameterReq(vals...; index=-1)
  req = ParameterReq(index=index)
  qlist = Pair{String,Any}[]
  for v ∈ vals
    if v isa String
      push!(qlist, Pair{String,Any}(v, nothing))
    elseif v isa Symbol
      push!(qlist, Pair{String,Any}(string(v), nothing))
    elseif v isa Pair
      push!(qlist, Pair{String,Any}(string(v[1]), v[2]))
    end
  end
  if length(qlist) > 0
    q = popfirst!(qlist)
    req.param = q[1]
    req.value = q[2]
    if length(qlist) > 0
      req.requests = Dict{String,Any}[]
      for q ∈ qlist
        push!(req.requests, Dict{String,Any}("param" => q[1], "value" => q[2]))
      end
    end
  end
  req
end

function Base.show(io::IO, p::ParameterRsp)
  plist = Pair{String,Any}[]
  if p.param !== nothing
    x = p.param
    occursin(".", x) || (x = "." * x)
    push!(plist, x => p.value)
    vs = p.values
    if vs !== nothing
      for v ∈ vs
        x = v[1]
        occursin(".", x) || (x = "." * x)
        push!(plist, x => v[2])
      end
    end
  end
  sort!(plist; by=(x -> x[1]))
  let n = findfirst(x -> x[1] == ".title", plist)
    n === nothing || println(io, "« ", plist[n][2], " »\n")
  end
  let n = findfirst(x -> x[1] == ".description", plist)
    n === nothing || plist[n][2] == "" || println(io, plist[n][2], "\n")
  end
  prefix = ""
  ro = p.readonly === nothing ? String[] : p.readonly
  for (k, v) ∈ plist
    k === ".type" && continue
    k === ".title" && continue
    k === ".description" && continue
    ks = split(k, '.')
    cprefix = join(ks[1:end-1], '.')
    if cprefix != prefix
      prefix != "" && println(io)
      prefix = cprefix
      println(io, '[', cprefix, ']')
    end
    println(io, "  ", ks[end], k ∈ ro ? " ⤇ " : " = ", v)
  end
end
