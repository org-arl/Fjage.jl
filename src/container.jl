abstract type Agent end

function init(a::Agent) end
function shutdown(a::Agent) end

container(a::Agent) = a.container
delay(a::Agent, millis) = sleep(millis/1000)
AgentID(a::Agent) = agent(container(a), a)
agent(a::Agent) = agent(container(a), a)
currenttimemillis(a::Agent) = Dates.value(now())
nanotime(a::Agent) = currenttimemillis(a) * 1000000

# TODO: state, platform, store, agentforservice, register, deregister, receive, request, send, log, stop, die, subscribe, unsubsscribe

mutable struct Container
  agents::Dict{String,Agent}
  running::Bool
end

Container() = Container(Dict{String,Agent}(), false)

function add(c::Container, name::String, a::Agent)
  canlocate(c, name) && throw(ArgumentError("Duplicate agent name"))
  c.agents[name] = a
  a.container = c
  c.running && init(a)
end

function kill(c::Container, name::String)
  containsagent(c, name) || throw(ArgumentError("No such agent"))
  a = c.agents[name]
  delete!(c.agents, name)
  foreach(b -> stop(b), a.behaviors)
  shutdown(a)
end

kill(c::Container, a::AgentID) = kill(c, a.name)

function start(c::Container)
  c.running && throw(ArgumentError("Container already running"))
  c.running = true
  foreach(kv -> init(kv[2]), c.agents)
end

function shutdown(c::Container)
  c.running || throw(ArgumentError("Container not running"))
  foreach(a -> kill(c, a), keys(c.agents))
  empty!(c.agents)
  c.running = false
end

agent(c::Container, name::String) = c.agents[name]
agent(c::Container, a::Agent) = first(AgentID(name) for (name, a1) ∈ c.agents if a1 === a)

containsagent(c::Container, a::AgentID) = a.name ∈ keys(c.agents)
containsagent(c::Container, name::String) = name ∈ keys(c.agents)
canlocate(c::Container, a) = containsagent(c, a)          # TODO: also check remote container

abstract type Behavior end

agent(b::Behavior) = b.agent
done(b::Behavior) = b.done
priority(b::Behavior) = b.priority

# TODO: block(b, millis)
function block(b::Behavior)
  b.done && return
  b.block = Condition()
end

function restart(b::Behavior)
  b.done && return
  b.block === nothing && return
  oblock = b.block
  b.block = nothing
  notify(oblock)
end

function reset(b::Behavior)
  b.agent === nothing || remove!(b.agent.behaviors, b)
  b.agent = nothing
  b.done = false
end

Base.reset(b::Behavior) = reset(b)

function stop(b::Behavior)
  b.done = true
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
  remove!(b.agent.behaviors, b)
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
  remove!(b.agent.behaviors, b)
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
    b.block === nothing || wait(b.block)
    b.action === nothing || b.action(b.agent, b)
    b.onend === nothing || b.onend(b.agent, b)
  catch ex
    @warn ex
  end
  b.done = true
  remove!(b.agent.behaviors, b)
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
  remove!(b.agent.behaviors, b)
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

# TODO: implement
# struct BackoffBehavior <: Behavior end
# struct PoissonBehavior <: Behavior end
# struct FSMBehavior <: Behavior end
# struct TestBehavior <: Behavior end

function add(a::Agent, b::Behavior)
  (b.agent === nothing && b.done == false) || throw(ArgumentError("Behavior already running"))
  b.agent = a
  push!(a.behaviors, b)
  @async action(b)
end
