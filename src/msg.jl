export Performative, Message, GenericMessage, @message, classname, clone, ParameterReq, ParameterRsp, set!

# global variables
const _messageclasses = Dict{String,DataType}()

"An action represented by a message."
module Performative
  const REQUEST = :REQUEST
  const AGREE = :AGREE
  const REFUSE = :REFUSE
  const FAILURE = :FAILURE
  const INFORM = :INFORM
  const CONFIRM = :CONFIRM
  const DISCONFIRM = :DISCONFIRM
  const QUERY_IF = :QUERY_IF
  const NOT_UNDERSTOOD = :NOT_UNDERSTOOD
  const CFP = :CFP
  const PROPOSE = :PROPOSE
  const CANCEL = :CANCEL
end

"Base class for messages transmitted by one agent to another."
abstract type Message end

"""
    classname(msg::Message)

Return the fully qualified class name of a message.
"""
function classname end

function _message(classname, perf, sdef)
  if @capture(sdef, struct T_ <: P_ fields__ end)
    if T == P
      T = Symbol("_" * string(T))
      extra = :( $(P)(; kwargs...) = $(T)(; kwargs...) )
    else
      extra = :()
    end
    push!(fields, :(messageID::String = string(Fjage.uuid4())))
    push!(fields, :(performative::Symbol = $perf))
    push!(fields, :(sender::Union{Fjage.AgentID,Nothing} = nothing))
    push!(fields, :(recipient::Union{Fjage.AgentID,Nothing} = nothing))
    push!(fields, :(inReplyTo::Union{String,Nothing} = nothing))
    push!(fields, :(sentAt::Int64 = 0))
    quote
      Base.@kwdef mutable struct $(T) <: $(P); $(fields...); end
      Fjage.classname(::Type{$(T)}) = $(classname)
      Fjage.classname(::$(T)) = $(classname)
      Fjage._messageclasses[$(classname)] = $(T)
      $extra
    end |> esc
  elseif @capture(sdef, struct T_ fields__ end)
    push!(fields, :(messageID::String = string(Fjage.uuid4())))
    push!(fields, :(performative::Symbol = $perf))
    push!(fields, :(sender::Union{Fjage.AgentID,Nothing} = nothing))
    push!(fields, :(recipient::Union{Fjage.AgentID,Nothing} = nothing))
    push!(fields, :(inReplyTo::Union{String,Nothing} = nothing))
    push!(fields, :(sentAt::Int64 = 0))
    quote
      Base.@kwdef mutable struct $(T) <: Fjage.Message; $(fields...); end
      Fjage.classname(::Type{$(T)}) = $(classname)
      Fjage.classname(::$(T)) = $(classname)
      Fjage._messageclasses[$(classname)] = $(T)
    end |> esc
  else
    @error "Bad message definition"
  end
end

"""
    @message classname [performative] struct mtype [<: supertype]
      fields...
    end

Create a message class from a fully qualified class name. If a performative is not
specified, it is guessed based on the class name. For class names ending with "Req",
the performative is assumed to be REQUEST, and for all other messages, INFORM.

# Examples

```julia-repl
julia> @message "org.arl.fjage.shell.MyShellExecReq" struct MyShellExecReq
         cmd::String
       end
julia> req = MyShellExecReq(cmd="ps")
MyShellExecReq:REQUEST[cmd:"ps"]
```
"""
macro message(classname, perf, sdef)
  _message(classname, perf, sdef)
end

macro message(classname, sdef)
  perf = endswith(classname, "Req") ? :(:REQUEST) : :(:INFORM)
  _message(classname, perf, sdef)
end

function clone(original::Message)
  cloned = deepcopy(original)
  cloned.messageID = string(uuid4())
  return cloned
end

"""
    registermessages()
    registermessages(messageclasses)

Register message classes with Fjage. Usually message classes are automatically registered on
creation with `@message`. However, when developing packages, if `@message` is used at the module level,
the types may be precompiled and the code to register the classes may not get executed at runtime.
In such cases, you may need to explicitly call `registermessages()` in the `__init()__` function
for the module.
"""
function registermessages(msg=subtypes(Message))
  for T ∈ msg
    T <: GenericMessage && continue
    s = classname(T)
    _messageclasses[s] = T
    registermessages(subtypes(T))
  end
end

function _messageclass_lookup(classname::String)
  haskey(_messageclasses, classname) && return _messageclasses[classname]
  GenericMessage{Symbol(classname)}
end

# helper function to see if a message matches a filter
function _matches(filt, msg)
  (msg === nothing || filt === nothing) && return true
  if typeof(filt) == DataType
    return typeof(msg) <: filt
  elseif typeof(filt) <: Message
    return msg.inReplyTo == filt.messageID
  elseif typeof(filt) <: Function
    return filt(msg)
  end
  false
end

# like Base.setproperty!, but does not throw an error if the property does not exist
function trysetproperty!(s::Message, p::Symbol, v)
  hasfield(typeof(s), p) || return s
  ftype = fieldtype(typeof(s), p)
  setfield!(s, p, convert(ftype, v))
end

# immutable dictionary interface for Messages

function Base.get(s::Message, p::Symbol, default)
  v = getproperty(s, p)
  v === nothing && return default
  v
end

Base.getindex(s::Message, p::Symbol) = getproperty(s, p)
Base.keys(s::Message) = fieldnames(typeof(s))
Base.values(s::Message) = getfield.(Ref(s), fieldnames(typeof(s)))
Base.eltype(s::Message) = Pair{Symbol,Any}
Base.length(s::Message) = fieldcount(typeof(s))

function Base.iterate(s::Message)
  f = fieldnames(typeof(s))
  isempty(f) && return nothing
  v = getfield.(Ref(s), f)
  (f[1] => v[1], (f[2:end], v[2:end]))
end

function Base.iterate(s::Message, state)
  isempty(state[1]) && return nothing
  (state[1][1] => state[2][1], (state[1][2:end], state[2][2:end]))
end

# pretty prints arrays without type names
function _repr(x)
  x = repr(x)
  m = match(r"[A-Za-z0-9]+(\[.+\])", x)
  m !== nothing && (x = m[1])
  m = match(r"^\w+(\[.*)$", x)
  m !== nothing && (x = m[1])
  x
end

# pretty printing of messages
function Base.show(io::IO, msg::Message)
  s = classname(msg)
  ndx = findlast(".", s)
  ndx === nothing || (s = s[ndx[1]+1:end])
  p = ""
  data_suffix = ""
  signal_suffix = ""
  suffix = ""
  for k in keys(msg)
    x = msg[k]
    if k == :performative
      s *= ":" * string(x)
    elseif k == :data
      if typeof(x) <: Array
        data_suffix *= "($(length(x)) bytes)"
      elseif msg[k] !== nothing
        p *= " $k:" * _repr(msg[k])
      end
    elseif k == :signal
      if typeof(x) <: Array
        signal_suffix *= "($(length(x)) samples)"
      elseif msg[k] !== nothing
        p *= " $k:" * _repr(msg[k])
      end
    elseif k != :sender && k != :recipient && k != :messageID && k != :inReplyTo && k != :sentAt
      if typeof(x) <: Number
        isnan(x) || (p *= " $k:" * _repr(x))
      elseif typeof(x) == String || typeof(x) <: Array || typeof(x) == Bool
        p *= " $k:" * _repr(x)
      elseif x !== nothing && x !== missing
        suffix = "..."
      end
    end
  end
  length(suffix) > 0 && (p *= " " * suffix)
  length(signal_suffix) > 0 && (p *= " " * signal_suffix)
  length(data_suffix) > 0 && (p *= " " * data_suffix)
  p = strip(p)
  length(p) > 0 && (s *= "[$p]")
  print(io, s)
end

# concrete message without data
@message "org.arl.fjage.Message" struct _Message end

"Generic message type that can carry arbitrary name-value pairs as data."
Base.@kwdef mutable struct GenericMessage{T} <: Message
  __data__::Dict{Symbol,Any} = Dict{Symbol,Any}()
  messageID::String = string(Fjage.uuid4())
  performative::Symbol = Performative.INFORM
  sender::Union{AgentID,Nothing} = nothing
  recipient::Union{AgentID,Nothing} = nothing
  inReplyTo::Union{String,Nothing} = nothing
  sentAt::Int64 = 0
end

Fjage.classname(::Type{GenericMessage{T}}) where T = string(T)
Fjage.classname(::GenericMessage{T}) where T = string(T)

GenericMessage(args...) = GenericMessage{Symbol("org.arl.fjage.GenericMessage")}(args...)
GenericMessage(clazz::String, perf::Symbol=Performative.INFORM; kwargs...) = GenericMessage{Symbol(clazz)}(; performative=perf, kwargs...)

# adds notation message.field

function Base.getproperty(s::GenericMessage, p::Symbol)
  hasfield(typeof(s), p) && return getfield(s, p)
  haskey(s.__data__, p) && return s.__data__[p]
  clazz = classname(s)
  ndx = findlast(".", clazz)
  ndx === nothing || (clazz = clazz[ndx[1]+1:end])
  error("message $(clazz) has no field $(p)")
end

function Base.setproperty!(s::GenericMessage, p::Symbol, v)
  if hasfield(typeof(s), p)
    setfield!(s, p, v)
  else
    s.__data__[p] = v
  end
end

trysetproperty!(s::GenericMessage, p::Symbol, v) = setproperty!(s, p, v)

# dictionary interface for GenericMessages

function Base.get(s::GenericMessage, p::Symbol, default)
  hasfield(typeof(s), p) && return getfield(s, p)
  haskey(s.__data__, p) && return s.__data__[p]
  default
end

function Base.keys(s::GenericMessage)
  k = Set(keys(s.__data__))
  for f ∈ fieldnames(typeof(s))
    f == :__data__ && continue
    push!(k, f)
  end
  k
end

function Base.values(s::GenericMessage)
  v = Any[]
  for k ∈ keys(s)
    push!(v, s[k])
  end
  v
end

Base.length(s::GenericMessage) = fieldcount(typeof(s)) - 1 + length(s.__data__)

function Base.iterate(s::GenericMessage)
  f = keys(s)
  v = values(s)
  (f[1] => v[1], (f[2:end], v[2:end]))
end

"""
    msg = Message([perf])
    msg = Message(inreplyto[, perf])

Create a message with just a performative (`perf`) and no data. If the performative
is not specified, it defaults to INFORM. If the inreplyto is specified, the message
`inReplyTo` and `recipient` fields are set accordingly.
"""
Message(perf::Symbol=Performative.INFORM) = _Message(performative=perf)
Message(inreplyto::Message, perf::Symbol=Performative.INFORM) = _Message(performative=perf, inReplyTo=inreplyto.messageID, recipient=inreplyto.sender)

"Parameter request message."
@message "org.arl.fjage.param.ParameterReq" struct ParameterReq
  index::Int = -1
  param::Union{String,Nothing} = nothing
  value::Union{Any,Nothing} = nothing
  requests::Union{Vector{Dict{String,Any}},Nothing} = nothing
end

"Parameter response message."
@message "org.arl.fjage.param.ParameterRsp" struct ParameterRsp
  index::Int = -1
  param::Union{String,Nothing} = nothing
  value::Union{Any,Nothing} = nothing
  values::Union{Dict{String,Any},Nothing} = nothing
end

# convenience methods and pretty printing for parameters

function ParameterReq(vals...; index=-1)
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

"""
    get!(p::ParameterReq, param)

Request parameter `param` to be fetched.

# Examples

```julia-repl
julia> p = ParameterReq(index=1)
ParameterReq[index=1]
julia> get!(p, "modulation")
ParameterReq[index=1 modulation=?]
julia> get!(p, "fec")
ParameterReq[index=1 modulation=? ...]
```
"""
function Base.get!(p::ParameterReq, param)
  param = string(param)
  if p.param === nothing
    p.param = param
  else
    p.requests === nothing && (p.requests = Dict{String,Any}[])
    push!(p.requests, Dict{String,Any}("param" => param))
  end
  p
end

"""
    set!(p::ParameterReq, param, value)

Request parameter `param` to be set to `value`.

# Examples

```julia-repl
julia> p = ParameterReq(index=1)
ParameterReq[index=1]
julia> set!(p, "modulation", "ofdm")
ParameterReq[index=1 modulation=ofdm]
julia> set!(p, "fec", 1)
ParameterReq[index=1 modulation=ofdm ...]
```
"""
function set!(p::ParameterReq, param, value)
  param = string(param)
  if p.param === nothing
    p.param = param
    p.value = value
  else
    p.requests === nothing && (p.requests = Dict{String,Any}[])
    push!(p.requests, Dict{String,Any}("param" => param, "value" => value))
  end
  p
end

"""
    get(p::ParameterRsp, param)

Extract parameter `param` from a parameter response message.
"""
function Base.get(p::ParameterRsp, key)
  skey = string(key)
  dskey = "." * skey
  (!isnothing(p.param) && (p.param == skey || endswith(p.param, dskey))) && return p.value
  vals = p.values
  if vals !== nothing
    for (k, v) ∈ vals
      (k == skey || endswith(k, dskey)) && return v
    end
  end
  nothing
end

function Base.show(io::IO, p::ParameterReq)
  print(io, "ParameterReq[")
  if p.index !== nothing && p.index ≥ 0
    print(io, "index=", p.index)
    p.param === nothing || print(io, ' ')
  end
  p.param === nothing || print(io, p.param, '=', (p.value === nothing ? "?" : string(p.value)))
  p.requests === nothing || print(io, " ...")
  print(io, ']')
end

function Base.show(io::IO, p::ParameterRsp)
  print(io, "ParameterRsp[")
  if p.index !== nothing && p.index ≥ 0
    print(io, "index=", p.index)
    p.param === nothing || print(io, ' ')
  end
  p.param === nothing || print(io, p.param, '=', p.value)
  p.values === nothing || print(io, " ...")
  print(io, ']')
end

function Base.println(io::IO, p::ParameterRsp)
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
