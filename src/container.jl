export Platform, add, currenttimemillis, delay, containers, isrunning, start, shutdown
export Container, StandaloneContainer, SlaveContainer, canlocateagent, containsagent, agent, agents
export register, deregister, services, add, agentforservice, agentsforservice, canlocateagent, ps
export Agent, @agent, name, platform, send, subscribe, unsubscribe, die, stop, receive, request
export Behavior, done, priority, block, restart, stop, isblocked, OneShotBehavior, CyclicBehavior
export WakerBehavior, TickerBehavior, MessageBehavior, ParameterMessageBehavior

abstract type Platform end
abstract type Container end
abstract type Agent end
abstract type Behavior end

### realtime platform

Base.@kwdef struct RealTimePlatform <: Platform
  containers = Container[]
  running = Ref(false)
end

function Base.show(io::IO, p::RealTimePlatform)
  print(io, "RealTimePlatform[running=", p.running[], ", containers=", length(p.containers), "]")
end

currenttimemillis(::RealTimePlatform) = Dates.value(now())
nanotime(::RealTimePlatform) = Dates.value(now()) * 1000000
delay(::RealTimePlatform, millis) = sleep(millis/1000)

containers(p::RealTimePlatform) = p.containers
isrunning(p::RealTimePlatform) = p.running[]

function add(p::RealTimePlatform, c::Container)
  platform(c) === p || throw(ArgumentError("Container bound to another platform"))
  push!(p.containers, c)
  p.running[] && start(c)
  nothing
end

function start(p::RealTimePlatform)
  p.running[] && return p
  @debug "Starting RealTimePlatform..."
  p.running[] = true
  foreach(start, p.containers)
  @debug "RealTimePlatform is running"
  p
end

function shutdown(p::RealTimePlatform)
  p.running[] || return
  @debug "Stopping RealTimePlatform..."
  foreach(shutdown, p.containers)
  p.running[] = false
  @debug "Stopped RealTimePlatform"
  nothing
end

### standalone & slave containers

struct StandaloneContainer{T <: Platform} <: Container
  platform::T
  agents::Dict{String,Agent}
  topics::Dict{AgentID,Set{Agent}}
  services::Dict{String,Set{AgentID}}
  running::Ref{Bool}
end

struct SlaveContainer{T <: Platform} <: Container
  platform::T
  agents::Dict{String,Agent}
  topics::Dict{AgentID,Set{Agent}}
  services::Dict{String,Set{AgentID}}
  running::Ref{Bool}
  sock::Ref{TCPSocket}
  pending::Dict{String,Channel}
  host::String
  port::Int
end

Container() = Container(RealTimePlatform())

function Container(p)
  c = StandaloneContainer(p, Dict{String,Agent}(), Dict{AgentID,Set{Agent}}(),
    Dict{String,Set{AgentID}}(), Ref(false))
  add(p, c)
  c
end

SlaveContainer(host, port) = SlaveContainer(RealTimePlatform(), host, port)

function SlaveContainer(p, host, port)
  c = SlaveContainer(p, Dict{String,Agent}(), Dict{AgentID,Set{Agent}}(),
    Dict{String,Set{AgentID}}(), Ref(false), Ref(TCPSocket()), Dict{String,Channel}(), host, port)
  add(p, c)
  c
end

function Base.show(io::IO, c::Container)
  print(io, typeof(c), "[running=", c.running[], ", platform=", typeof(c.platform),
    ", agents=", length(c.agents), "]")
end

platform(c::Container) = c.platform
isrunning(c::Container) = c.running[]

containsagent(c::Container, aid::AgentID) = aid.name ∈ keys(c.agents)
containsagent(c::Container, name::String) = name ∈ keys(c.agents)

canlocateagent(c::StandaloneContainer, a) = containsagent(c, a)

function canlocateagent(c::SlaveContainer, aid)
  containsagent(c, aid) && return true
  rq = Dict("action" => "containsAgent", "agentID" => aid)
  rsp = _ask(c, rq)
  haskey(rsp, "answer") && return rsp["answer"]::Bool
  false
end

agent(c::Container, name::String) = name ∈ keys(c.agents) ? c.agents[name] : nothing
agent(c::Container, aid::AgentID) = agent(c, name(aid))

agents(c::Container) = collect(values(c.agents))
services(c::Container) = collect(keys(c.services))

function add(c::Container, name::String, a::Agent)
  canlocateagent(c, name) && throw(ArgumentError("Duplicate agent name"))
  a._container = c
  a._aid = AgentID(name)
  c.agents[name] = a
  c.running[] && init(a)
  @debug "Added agent $(name)::$(typeof(a))"
  a._aid
end

add(c::Container, a::Agent) = add(c, string(typeof(a)) * "-" * string(uuid4())[1:8], a)

function Base.kill(c::Container, aid::String)
  containsagent(c, aid) || return false
  a = c.agents[aid]
  if c.running[]
    foreach(stop, a._behaviors)
    shutdown(a)
  end
  a._container = nothing
  a._aid = nothing
  empty!(a._behaviors)
  foreach(kv -> delete!(kv[2], a), c.topics)
  foreach(kv -> delete!(kv[2], AgentID(aid)), c.services)
  delete!(c.agents, aid)
  @debug "Killed agent $(aid)"
  true
end

Base.kill(c::Container, aid::AgentID) = kill(c, aid.name)
Base.kill(c::Container, a::Agent) = kill(c, AgentID(a))

function start(c::StandaloneContainer)
  c.running[] && return c
  if !isrunning(c.platform)
    length(containers(c.platform)) > 1 && throw(ArgumentError("Platform is not running"))
    start(platform(c))
    return c
  end
  @debug "Starting StandaloneContainer..."
  c.running[] = true
  foreach(kv -> init(kv[2]), c.agents)
  @debug "StandaloneContainer is running"
  c
end

function start(c::SlaveContainer)
  c.running[] && return c
  if !isrunning(c.platform)
    length(containers(c.platform)) > 1 && throw(ArgumentError("Platform is not running"))
    start(platform(c))
    return c
  end
  @debug "Starting SlaveContainer..."
  @debug "SlaveContainer connecting to $(c.host):$(c.port)..."
  c.sock[] = connect(c.host, c.port)
  @debug "SlaveContainer connected"
  c.running[] = true
  foreach(kv -> init(kv[2]), c.agents)
  @debug "SlaveContainer is running"
  @async _run(c)
  c
end

function shutdown(c::StandaloneContainer)
  c.running[] || return
  @debug "Stopping StandaloneContainer..."
  foreach(name -> kill(c, name), keys(c.agents))
  empty!(c.agents)
  empty!(c.topics)
  empty!(c.services)
  c.running[] = false
  @debug "Stopped StandaloneContainer"
  nothing
end

function shutdown(c::SlaveContainer)
  c.running[] || return
  @debug "Stopping SlaveContainer..."
  foreach(name -> kill(c, name), keys(c.agents))
  empty!(c.agents)
  empty!(c.topics)
  empty!(c.services)
  c.running[] = false
  try
    println(c.sock[], "{\"alive\": false}")
  catch ex
    # ignore
  end
  Base.close(c.sock[])
  @debug "Stopped SlaveContainer"
  nothing
end

function subscribe(c::StandaloneContainer, t::AgentID, a::Agent)
  t ∈ keys(c.topics) || (c.topics[t] = Set{Agent}())
  push!(c.topics[t], a)
  true
end

function unsubscribe(c::StandaloneContainer, a::Agent)
  foreach(t -> delete!(c.topics[t], a), keys(c.topics))
  nothing
end

function unsubscribe(c::StandaloneContainer, t::AgentID, a::Agent)
  t ∈ keys(c.topics) || return false
  delete!(c.topics[t], a)
  true
end

function subscribe(c::SlaveContainer, t::AgentID, a::Agent)
  t.istopic || (t = topic(t))
  t ∈ keys(c.topics) || (c.topics[t] = Set{Agent}())
  push!(c.topics[t], a)
  _update_watch(c)
  true
end

function unsubscribe(c::SlaveContainer, a::Agent)
  foreach(t -> delete!(c.topics[t], a), keys(c.topics))
  _update_watch(c)
  nothing
end

function unsubscribe(c::SlaveContainer, t::AgentID, a::Agent)
  t.istopic || (t = topic(t))
  t ∈ keys(c.topics) || return false
  delete!(c.topics[t], a)
  _update_watch(c)
  true
end

function register(c::Container, aid::AgentID, svc::String)
  svc ∈ keys(c.services) || (c.services[svc] = Set{AgentID}())
  push!(c.services[svc], aid)
  true
end

function deregister(c::Container, aid::AgentID)
  foreach(svc -> delete!(c.services[svc], aid), keys(c.services))
  nothing
end

function deregister(c::Container, aid::AgentID, svc::String)
  svc ∈ keys(c.services) || return false
  delete!(c.services[svc], aid)
  true
end

function agentforservice(c::StandaloneContainer, svc::String, owner::AgentID)
  svc ∈ keys(c.services) || return nothing
  AgentID(first(c.services[svc]).name, false, owner)
end

function agentsforservice(c::StandaloneContainer, svc::String, owner::AgentID)
  svc ∈ keys(c.services) || return AgentID[]
  [AgentID(s.name, false, owner) for s ∈ c.services[svc]]
end

function agentforservice(c::SlaveContainer, svc::String, owner::Agent)
  rq = Dict("action" => "agentForService", "service" => svc)
  rsp = _ask(c, rq)
  haskey(rsp, "agentID") ? AgentID(rsp["agentID"], false, owner) : nothing
end

function agentsforservice(c::SlaveContainer, svc::String, owner::Agent)
  rq = Dict("action" => "agentsForService", "service" => svc)
  rsp = _ask(c, rq)
  [AgentID(a, false, owner) for a in rsp["agentIDs"]]
end

send(c::Container, msg) = _deliver(c, msg, true)
send(c::Container, msg, relay) = _deliver(c, msg, relay)

ps(c::StandaloneContainer) = collect((kv[1], typeof(kv[2])) for kv ∈ c.agents)

function ps(c::SlaveContainer)
  rq = Dict("action" => "agents")
  rsp = _ask(c, rq)
  [(a, nothing) for a in rsp["agentIDs"]]
end

function _deliver(c::StandaloneContainer, msg::Message)
  c.running[] || return false
  if msg.recipient.name ∈ keys(c.agents)
    _deliver(c.agents[msg.recipient.name], msg)
  elseif msg.recipient ∈ keys(c.topics)
    foreach(a -> _deliver(a, msg), c.topics[msg.recipient])
  else
    @debug "Message $(msg) undeliverable"
    return false
  end
  true
end

_deliver(c::StandaloneContainer, msg::Message, relay::Bool) = _deliver(c, msg)

function _deliver(::Nothing, msg::Message)
  @debug "Delivered message $(msg) to nowhere"
  false
end

_agents(c::SlaveContainer) = collect(keys(c.agents))
_subscriptions(c::SlaveContainer) = collect(string.(keys(c.topics)))
_services(c::SlaveContainer) = collect(keys(c.services))

function _agentsforservice(c::SlaveContainer, svc::String)
  svc ∈ keys(c.services) || return AgentID[]
  collect(c.services[svc])
end

function _deliver(c::SlaveContainer, msg::Message, relay::Bool)
  c.running[] || return false
  if msg.recipient.name ∈ keys(c.agents)
    _deliver(c.agents[msg.recipient.name], msg)
  elseif relay
    _prepare!(msg)
    json = JSON.json(Dict("action" => "send", "relay" => true, "message" => msg))
    println(c.sock[], json)
  elseif msg.recipient ∈ keys(c.topics)
    foreach(a -> _deliver(a, msg), c.topics[msg.recipient])
  else
    @debug "Message $(msg) undeliverable"
    return false
  end
  true
end

_deliver(c::SlaveContainer, msg::Message) = _deliver(c, msg, true)

### agent

macro agent(sdef)
  @capture(sdef, struct T_ fields__ end)
  push!(fields, :(_aid::Union{AgentID,Nothing} = nothing))
  push!(fields, :(_container::Union{Container,Nothing} = nothing))
  push!(fields, :(_behaviors::Set{Behavior} = Set{Behavior}()))
  push!(fields, :(_listeners::Vector{Tuple{Any,Channel,Int}} = Tuple{Any,Channel,Int}[]))
  push!(fields, :(_msgqueue::Vector{Message} = Message[]))
  :( Base.@kwdef mutable struct $T <: Agent; $(fields...); end ) |> esc
end

Base.show(io::IO, a::Agent) = print(io, typeof(a), "(", something(AgentID(a), "-"), ")")

function init(a::Agent)
  @debug "Agent $(AgentID(a)) init"
  setup(a)
  add(a, OneShotBehavior((a, b) -> startup(a)))
  add(a, ParameterMessageBehavior())
  add(a, MessageBehavior() do a, b, msg
    if msg.performative == Performative.REQUEST
      rsp = processrequest(a, msg)
      if rsp === nothing
        send(a, Message(msg, Performative.NOT_UNDERSTOOD))
      else
        send(a, rsp)
      end
    else
      processmessage(a, msg)
    end
  end)
end

setup(a::Agent) = nothing
startup(a::Agent) = nothing
processrequest(a::Agent, req) = nothing
processmessage(a::Agent, msg) = nothing

function shutdown(a::Agent)
  @debug "Agent $(AgentID(a)) terminated"
end

function stop(a::Agent)
  kill(container(a), a)
  nothing
end

function die(a::Agent, msg)
  @error msg
  stop(a)
end

platform(a::Agent) = platform(container(a))
container(a::Agent) = a._container
AgentID(a::Agent) = a._aid
name(a::Agent) = name(a._aid)

agent(a::Agent, name::String) = AgentID(name, false, a)

currenttimemillis(a::Agent) = currenttimemillis(platform(a))
nanotime(a::Agent) = nanotime(platform(a))
delay(a::Agent, millis) = delay(platform(a), millis)

subscribe(a::Agent, t::AgentID) = subscribe(container(a), t, a)
unsubscribe(a::Agent, t::AgentID) = unsubscribe(container(a), t, a)

register(a::Agent, svc::String) = register(container(a), AgentID(a), svc)
deregister(a::Agent, svc::String) = deregister(container(a), AgentID(a), svc)
agentforservice(a::Agent, svc::String) = agentforservice(container(a), svc, a)
agentsforservice(a::Agent, svc::String) = agentsforservice(container(a), svc, a)

function send(a::Agent, msg::Message)
  @debug "sending $(msg)"
  msg.sender = AgentID(a)
  msg.sentAt = currenttimemillis(a)
  _deliver(container(a), msg)
end

function receive(a::Agent, filt, timeout::Int=0; priority=(filt===nothing ? 0 : -100))
  (container(a) === nothing || !isrunning(container(a))) && return nothing
  for (n, msg) ∈ enumerate(a._msgqueue)
    if _matches(filt, msg)
      deleteat!(a._msgqueue, n)
      return msg
    end
  end
  timeout == 0 && return nothing
  ch = Channel{Union{Message,Nothing}}(1)
  _listen(a, ch, filt, priority)
  if timeout > 0
    @async begin
      delay(a, timeout)
      put!(ch, nothing)
    end
  end
  msg = take!(ch)
  _dont_listen(a, ch)
  Base.close(ch)
  msg
end

receive(a::Agent, timeout::Int=0) = receive(a, nothing, timeout)

function request(a::Agent, msg::Message, timeout::Int=1000)
  send(a, msg)
  receive(a, msg, timeout)
end

Base.flush(a::Agent) = empty!(a._msgqueue)

function _listen(a::Agent, ch::Channel, filt, priority::Int)
  for (n, (filt1, ch1, p)) ∈ enumerate(a._listeners)
    if p > priority
      insert!(a._listeners, n, (filt, ch, priority))
      return
    end
  end
  push!(a._listeners, (filt, ch, priority))
end

function _dont_listen(a::Agent, ch::Channel)
  for (n, (filt, ch1, p)) ∈ enumerate(a._listeners)
    if ch === ch1
      deleteat!(a._listeners, n)
      return
    end
  end
end

function _listener_notify(a::Agent)
  for (filt, ch, p) ∈ a._listeners
    put!(ch, nothing)
  end
end

function _deliver(a::Agent, msg::Message)
  @debug "$(a) <<< $(msg)"
  for (filt, ch, p) ∈ a._listeners
    if _matches(filt, msg)
      put!(ch, msg)
      return
    end
  end
  push!(a._msgqueue, msg)
  while length(a._msgqueue) > MAX_QUEUE_LEN
    popfirst!(a._msgqueue)
  end
end

### behaviors

function add(a::Agent, b::Behavior)
  (b.agent === nothing && b.done == false) || throw(ArgumentError("Behavior already running"))
  (container(a) === nothing || !isrunning(container(a))) && throw(ArgumentError("Agent not running"))
  b.agent = a
  @debug "Add $(typeof(b)) to agent $(a._aid)"
  push!(a._behaviors, b)
  @async action(b)
  b
end

agent(b::Behavior) = b.agent
done(b::Behavior) = b.done
priority(b::Behavior) = b.priority
isblocked(b::Behavior) = b.block !== nothing

function block(b::Behavior)
  b.done && return
  b.block = Condition()
  nothing
end

function restart(b::Behavior)
  b.done && return
  b.block === nothing && return
  oblock = b.block
  b.block = nothing
  notify(oblock)
  nothing
end

function reset(b::Behavior)
  b.agent === nothing || delete!(b.agent._behaviors, b)
  b.agent = nothing
  b.done = false
  nothing
end

Base.reset(b::Behavior) = reset(b)

function stop(b::Behavior)
  b.done = true
  nothing
end

mutable struct OneShotBehavior <: Behavior
  agent::Union{Nothing,Agent}
  block::Union{Nothing,Condition}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

OneShotBehavior(action) = OneShotBehavior(nothing, nothing, false, 0, nothing, action, nothing)

function action(b::OneShotBehavior)
  try
    b.onstart === nothing || b.onstart(b.agent, b)
    b.block === nothing || wait(b.block)
    b.action === nothing || b.action(b.agent, b)
    b.onend === nothing || b.onend(b.agent, b)
  catch ex
    @warn ex stacktrace(catch_backtrace())
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct CyclicBehavior <: Behavior
  agent::Union{Nothing,Agent}
  block::Union{Nothing,Condition}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

CyclicBehavior(action) = CyclicBehavior(nothing, nothing, false, 0, nothing, action, nothing)

function action(b::CyclicBehavior)
  try
    b.onstart === nothing || b.onstart(b.agent, b)
    while !b.done
      if b.block === nothing
        b.action === nothing || b.action(b.agent, b)
        yield()
      else
        wait(b.block)
      end
    end
    b.onend === nothing || b.onend(b.agent, b)
  catch ex
    @warn ex stacktrace(catch_backtrace())
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct WakerBehavior <: Behavior
  agent::Union{Nothing,Agent}
  millis::Int64
  block::Union{Nothing,Condition}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

WakerBehavior(action, millis::Int64) = WakerBehavior(nothing, millis, nothing, false, 0, nothing, action, nothing)

function action(b::WakerBehavior)
  try
    b.onstart === nothing || b.onstart(b.agent, b)
    sleep(b.millis/1000)
    if !b.done
      b.block === nothing || wait(b.block)
      b.action === nothing || b.action(b.agent, b)
    end
    b.onend === nothing || b.onend(b.agent, b)
  catch ex
    @warn ex stacktrace(catch_backtrace())
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct TickerBehavior <: Behavior
  agent::Union{Nothing,Agent}
  millis::Int64
  block::Union{Nothing,Condition}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

TickerBehavior(action, millis::Int64) = TickerBehavior(nothing, millis, nothing, false, 0, nothing, action, nothing)

function action(b::TickerBehavior)
  try
    b.onstart === nothing || b.onstart(b.agent, b)
    while !b.done
      sleep(b.millis/1000)    # TODO: improve tick timing
      b.done && break
      if b.block === nothing
        b.action === nothing || b.action(b.agent, b)
      else
        wait(b.block)
      end
    end
    b.onend === nothing || b.onend(b.agent, b)
  catch ex
    @warn ex stacktrace(catch_backtrace())
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct MessageBehavior <: Behavior
  agent::Union{Nothing,Agent}
  filt::Any
  block::Union{Nothing,Condition}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

MessageBehavior(action) = MessageBehavior(nothing, nothing, nothing, false, 0, nothing, action, nothing)
MessageBehavior(action, filt) = MessageBehavior(nothing, filt, nothing, false, (filt===nothing ? 0 : -100), nothing, action, nothing)

function action(b::MessageBehavior)
  try
    b.onstart === nothing || b.onstart(b.agent, b)
    while !b.done
      msg = receive(b.agent, b.filt, BLOCKING; priority=b.priority)
      msg === nothing || b.action === nothing || b.action(b.agent, b, msg)
    end
    b.onend === nothing || b.onend(b.agent, b)
  catch ex
    @warn ex stacktrace(catch_backtrace())
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

function stop(b::MessageBehavior)
  b.done = true
  _listener_notify(b.agent)
  nothing
end

### parameters

ParameterMessageBehavior() = MessageBehavior(nothing, ParameterReq, nothing, false, -100, nothing, _paramreq_action, nothing)

function _paramreq_action(a::Agent, b::MessageBehavior, msg::ParameterReq)
  # resolve requests
  ndx = something(msg.index, -1)
  plist = ndx < 0 ? params(a) : params(a, ndx)
  req = Tuple{String,Symbol,Any}[]
  if msg.param === nothing
    push!(req, ("title", :title, nothing))
    push!(req, ("description", :description, nothing))
    for kv ∈ plist
      push!(req, (kv..., nothing))
    end
  else
    rr = _resolve(plist, msg.param, ndx)
    rr === nothing || push!(req, (rr[1], rr[2], msg.value))
    let preqs = msg.requests
      if preqs !== nothing
        for r ∈ preqs
          rr = _resolve(plist, r["param"], ndx)
          rr === nothing || push!(req, (rr[1], rr[2], "value" ∈ keys(r) ? r["value"] : nothing))
        end
      end
    end
  end
  # perform requests
  rsp = Pair{String,Any}[]
  ro = String[]
  for (q, p, v) ∈ req
    try
      if v === nothing   # get
        if ndx < 0
          if hasmethod(get, Tuple{typeof(a),Val{p}})
            x = get(a, Val(p))
            if x !== missing && x !== nothing
              push!(rsp, q => x)
              hasmethod(set, Tuple{typeof(a),Val{p}}) || push!(ro, q)
            end
          elseif hasfield(typeof(a), p)
            x = getfield(a, p)
            x === missing || x === nothing || push!(rsp, q => x)
          end
        else
          if hasmethod(get, Tuple{typeof(a),Val{p},Int})
            x = get(a, Val(p), ndx)
            if x !== missing && x !== nothing
              push!(rsp, q => x)
              hasmethod(set, Tuple{typeof(a),Val{p},Int}) || push!(ro, q)
            end
          end
        end
      else # set
        if ndx < 0
          if hasmethod(set, Tuple{typeof(a),Val{p},typeof(v)})
            x = set(a, Val(p), v)
            if x === missing || x === nothing
              if hasmethod(get, Tuple{typeof(a),Val{p}})
                x = get(a, Val(p))
              elseif hasfield(typeof(a), p)
                x = getfield(a, p)
              end
            end
            x === missing || x === nothing || push!(rsp, q => x)
          elseif hasfield(typeof(a), p)
            x = setfield!(a, p, v)
            push!(rsp, q => x)
          end
        else
          if hasmethod(set, Tuple{typeof(a),Val{p},Int,typeof(v)})
            x = set(a, Val(p), ndx, v)
            if x === missing || x === nothing
              hasmethod(get, Tuple{typeof(a),Val{p},Int}) && (x = get(a, Val(p), ndx))
            end
            x === missing || x === nothing || push!(rsp, q => x)
          end
        end
      end
    catch ex
      @warn ex stacktrace(catch_backtrace())
    end
  end
  rmsg = ParameterRsp(perf=Performative.INFORM, inReplyTo=msg.messageID, recipient=msg.sender, readonly=ro, index=ndx)
  length(rsp) > 0 && ((rmsg.param, rmsg.value) = popfirst!(rsp))
  length(rsp) > 0 && (rmsg.values = Dict(rsp))
  send(a, rmsg)
end

function _resolve(plist, p, ndx)
  psym = Symbol(p)
  psym === :type && return p, psym
  psym === :title && return p, psym
  psym === :description && return p, psym
  for kv ∈ plist
    kv[1] == p && return kv
    kv[2] === psym && return kv
  end
  nothing
end

params(a::Agent) = Pair{String,Symbol}[]
params(a::Agent, ndx) = Pair{String,Symbol}[]

get(a::Agent, ::Val{:type}) = string(typeof(a))
get(a::Agent, ::Val{:title}) = string(AgentID(a))
get(a::Agent, ::Val{:description}) = ""

function set end
