abstract type Platform end
abstract type Container end
abstract type Agent end
abstract type Behavior end

### realtime platform

Base.@kwdef struct RealTimePlatform <: Platform
  containers = Container[]
  running = Ref(false)
end

Base.show(io::IO, p::RealTimePlatform) = print(io, "RealTimePlatform[running=", p.running[], ", containers=", length(p.containers), "]")

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
  p.running[] && return
  @debug "Starting RealTimePlatform..."
  foreach(start, p.containers)
  p.running[] = true
  @debug "RealTimePlatform is running"
  nothing
end

function shutdown(p::RealTimePlatform)
  p.running[] || return
  @debug "Stopping RealTimePlatform..."
  foreach(shutdown, p.containers)
  p.running[] = false
  @debug "Stopped RealTimePlatform"
  nothing
end

### standalone container

struct StandaloneContainer{T <: Platform} <: Container
  platform::T
  agents::Dict{String,Agent}
  topics::Dict{AgentID,Vector{Agent}}
  running::Ref{Bool}
end

function Container(p)
  c = StandaloneContainer(p, Dict{String,Agent}(), Dict{AgentID,Vector{Agent}}(), Ref(false))
  add(p, c)
  c
end

Base.show(io::IO, c::StandaloneContainer) = print(io, "StandaloneContainer[running=", c.running[], ", platform=", typeof(c.platform), ", agents=", length(c.agents), "]")

platform(c::StandaloneContainer) = c.platform
isrunning(c::StandaloneContainer) = c.running[]

containsagent(c::StandaloneContainer, aid::AgentID) = aid.name ∈ keys(c.agents)
containsagent(c::StandaloneContainer, name::String) = name ∈ keys(c.agents)
canlocate(c::StandaloneContainer, a) = containsagent(c, a)

agent(c::StandaloneContainer, name::String) = c.agents[name]
agent(c::StandaloneContainer, aid::AgentID) = agent(c, aid.name)

function add(c::StandaloneContainer, name::String, a::Agent)
  canlocate(c, name) && throw(ArgumentError("Duplicate agent name"))
  a._container = c
  a._aid = AgentID(name)
  c.agents[name] = a
  c.running[] && init(a)
  @debug "Added agent $(name)::$(typeof(a))"
  nothing
end

add(c::StandaloneContainer, a::Agent) = add(c, string(typeof(a)) * "-" * string(uuid4())[1:8], a)

function kill(c::StandaloneContainer, name::String)
  containsagent(c, name) || return false
  a = c.agents[name]
  if c.running[]
    foreach(stop, a._behaviors)
    shutdown(a)
  end
  a._container = nothing
  a._aid = nothing
  empty!(a._behaviors)
  foreach(kv -> delete!(kv[2], a), c.topics)
  delete!(c.agents, name)
  @debug "Killed agent $(name)"
  true
end

kill(c::StandaloneContainer, aid::AgentID) = kill(c, aid.name)
kill(c::StandaloneContainer, a::Agent) = kill(c, AgentID(a))

function start(c::StandaloneContainer)
  c.running[] && return
  @debug "Starting StandaloneContainer..."
  c.running[] = true
  foreach(kv -> init(kv[2]), c.agents)
  @debug "StandaloneContainer is running"
  nothing
end

function shutdown(c::StandaloneContainer)
  c.running[] || return
  @debug "Stopping StandaloneContainer..."
  foreach(name -> kill(c, name), keys(c.agents))
  empty!(c.agents)
  c.running[] = false
  @debug "Stopped StandaloneContainer"
  nothing
end

ps(c::StandaloneContainer) = collect((kv[1], typeof(kv[2])) for kv ∈ c.agents)

function subscribe(c::StandaloneContainer, t::AgentID, a::Agent)
  t ∈ keys(c.topics) || (c.topics[t] = Agent[])
  push!(c.topics[t], a)
  nothing
end

function unsubscribe(c::StandaloneContainer, t::AgentID, a::Agent)
  t ∈ keys(c.topics) || return
  delete!(c.topics[t], a)
  nothing
end

### agent

macro agent(sdef)
  @capture(sdef, struct T_ fields__ end)
  push!(fields, :(_aid::Union{AgentID,Nothing} = nothing))
  push!(fields, :(_container::Union{Container,Nothing} = nothing))
  push!(fields, :(_behaviors::Vector{Behavior} = Behavior[]))
  :( Base.@kwdef mutable struct $T <: Agent; $(fields...); end ) |> esc
end

Base.show(io::IO, a::Agent) = print(io, typeof(a), "(", something(AgentID(a), "-"), ")")

function init(a::Agent)
  @debug "Agent $(AgentID(a)) initialized"
end

function shutdown(a::Agent)
  @debug "Agent $(AgentID(a)) terminated"
end

platform(a::Agent) = platform(container(a))
container(a::Agent) = a._container
AgentID(a::Agent) = a._aid

currenttimemillis(a::Agent) = currenttimemillis(platform(a))
nanotime(a::Agent) = nanotime(platform(a))
delay(a::Agent, millis) = delay(platform(a), millis)

subscribe(a::Agent, t::AgentID) = subscribe(container(a), t, a)
unsubscribe(a::Agent, t::AgentID) = unsubscribe(container(a), t, a)

function add(a::Agent, b::Behavior)
  (b.agent === nothing && b.done == false) || throw(ArgumentError("Behavior already running"))
  (container(a) === nothing || !isrunning(container(a))) && throw(ArgumentError("Agent not running"))
  b.agent = a
  @debug "Add $(typeof(b)) to agent $(a._aid)"
  push!(a._behaviors, b)
  @async action(b)
  nothing
end

### behaviors

agent(b::Behavior) = b.agent
done(b::Behavior) = b.done
priority(b::Behavior) = b.priority

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
  b.agent === nothing || remove!(b.agent._behaviors, b)
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
    @warn ex
  end
  b.done = true
  remove!(b.agent._behaviors, b)
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
    @warn ex
  end
  b.done = true
  remove!(b.agent._behaviors, b)
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

WakerBehavior(millis::Int64, action) = WakerBehavior(nothing, millis, nothing, false, 0, nothing, action, nothing)

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
    @warn ex
  end
  b.done = true
  remove!(b.agent._behaviors, b)
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

TickerBehavior(millis::Int64, action) = TickerBehavior(nothing, millis, nothing, false, 0, nothing, action, nothing)

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
    @warn ex
  end
  b.done = true
  remove!(b.agent._behaviors, b)
  b.agent = nothing
end

# mutable struct MessageBehavior <: Behavior
#   agent::Union{Nothing,Agent}
#   filter
#   bUnion{Nothing,lock::Condition}
#   done::Bool
#   priority::Int
#   onstart::Union{Nothing,Function}
#   action::Union{Nothing,Function}
#   onend::Union{Nothing,Function}
# end

# MessageBehavior(filter, action) = MessageBehavior(nothing, filter, nothing, false, 0, nothing, action, nothing)
