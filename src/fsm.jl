export @states, @fsm, trigger!, nextstate!, reenterstate, FSMBehavior, after

"""
A `FSMBehavior` is a behavior that implements a finite state machine. Typically, an FSM
is defined using the `@fsm` helper macro. See the documentation for `@fsm` for more
details.
"""
abstract type FSMBehavior <: Behavior end

abstract type FSMState end
struct SymbolicState{T} <: FSMState where T <: Symbol end

"""
    FSMState(s::Symbol)

Create a symbolic FSM state.
"""
FSMState(s::Symbol) = SymbolicState{s}()

const INIT = FSMState(:INIT)
const FINAL = FSMState(:FINAL)
const REENTER = FSMState(:REENTER)

"""
The `@states` macro is used to define a set of FSM states. The macro takes in a list of
state names and defines a singleton constant for each state. This is useful when defining
simple symbolic states for an FSM.
"""
macro states(states...)
  local expr = Expr(:block)
  for s ∈ states
    push!(expr.args, esc(:(const $s = Fjage.FSMState(Symbol($(string(s)))))))
  end
  expr
end

"""
The `@fsm` macro is used to define a FSM behavior. The macro takes in a `struct`
definition and converts it into an FSM behavior definition. The fields in the struct are
treated as behavior attributes. The `initialstate` field is used to specify the initial
state of the FSM, and must always be defined. FSM behaviors are mutable subtypes of the
`FSMBehavior` abstract type.

The `struct` definition may include initialization, as supported by the
`Base.@kwdef` macro.

# Example:
```julia
using Fjage

@states TICK TOCK

@fsm struct GrandfatherClock
  initialstate = TICK
  ticks::Int = 0
end

function Fjage.onenter(a::Agent, b::GrandfatherClock, state::typeof(TICK))
  b.ticks += 1
  @info "TICK \$(b.ticks)"
  after(b, 0.5) do
    nextstate!(b, TOCK)
  end
end

function Fjage.onenter(a::Agent, b::GrandfatherClock, state::typeof(TOCK))
  @info "TOCK \$(b.ticks)"
  after(b, 0.5) do
    nextstate!(b, TICK)
  end
end

function Fjage.onevent(a::Agent, b::GrandfatherClock, state, event)
  if event === :reset
    b.ticks = 0
    reenterstate(b)
  elseif event === :stop
    stop(b)
  end
end
```
"""
macro fsm(sdef)
  if @capture(sdef, struct T_ fields__ end)
    push!(fields, :(agent::Union{Fjage.Agent,Nothing} = nothing))
    push!(fields, :(block::Union{Nothing,Threads.Condition} = nothing))
    push!(fields, :(timer::Union{Nothing,Timer} = nothing))
    push!(fields, :(priority::Int = 0))
    push!(fields, :(state::Fjage.FSMState = Fjage.INIT))
    push!(fields, :(prevstate::Fjage.FSMState = Fjage.INIT))
    push!(fields, :(nextstate::Fjage.FSMState = Fjage.INIT))
    push!(fields, :(wakers::Vector{Fjage.WakerBehavior} = Fjage.WakerBehavior[]))
    :( Base.@kwdef mutable struct $T <: Fjage.FSMBehavior; $(fields...); end ) |> esc
  else
    @error "Bad FSM definition"
  end
end

# standard behavior methods
done(b::FSMBehavior) = b.state == FINAL
stop(b::FSMBehavior) = nextstate!(b, FINAL)

function reset(b::FSMBehavior)
  for waker ∈ b.wakers
    stop(waker)
  end
  empty!(b.wakers)
  b.agent === nothing || delete!(b.agent._behaviors, b)
  b.timer === nothing || close(b.timer)
  b.agent = nothing
  b.block = nothing
  b.timer = nothing
  b.state = INIT
  b.prevstate = INIT
  b.nextstate = INIT
  nothing
end

"""
    state(b::FSMBehavior)

Get the current state of the FSM.
"""
state(b::FSMBehavior) = b.state

"""
    reenterstate(b::FSMBehavior)

Reenter the current state of the FSM.
"""
reenterstate(b::FSMBehavior) = nextstate!(b, REENTER)

"""
    nextstate!(b::FSMBehavior, state::FSMState)

Set the next state of the FSM. Transition occurs after the current action
is completed, if called from the action method for a state.
"""
function nextstate!(b::FSMBehavior, state::FSMState)
  b.nextstate = state
  restart(b)
end

"""
    trigger!(b::FSMBehavior, event)

Trigger an event in the FSM.
"""
trigger!(b::FSMBehavior, event) = _mutex_call(onevent, b.agent, b, b.state, event)

"""
    after(action, b::FSMBehavior, delay)

Schedule an action to be executed after a delay (in seconds). The scheduled action
is automatically canceled when the FSM exits the current state.
"""
function after(action, b::FSMBehavior, delay)
  waker = WakerBehavior((_, _) -> action(), round(Int, delay*1000))
  push!(b.wakers, waker)
  add(b.agent, waker)
  nothing
end

"""
    onenter(a::Agent, b::FSMBehavior, state::FSMState)

Callback method invoked when the FSM enters a state.
"""
onenter(a::Agent, b::FSMBehavior, state::FSMState) = nothing

"""
    action(a::Agent, b::FSMBehavior, state::FSMState)

Callback method invoked cyclically during a state. The default implementation
calls `block(b)` to block the behavior until an event occurs.
"""
action(a::Agent, b::FSMBehavior, state::FSMState) = block(b)

"""
    onexit(a::Agent, b::FSMBehavior, state::FSMState)

Callback method invoked when the FSM exits a state.
"""
onexit(a::Agent, b::FSMBehavior, state::FSMState) = nothing

"""
    onevent(a::Agent, b::FSMBehavior, state::FSMState, event)

Callback method invoked when an event is triggered in the FSM.
"""
onevent(a::Agent, b::FSMBehavior, state, event) = nothing

# FSM behavior main loop
function action(b::FSMBehavior)
  try
    while !done(b)
      if b.block === nothing
        try
          b.state == b.prevstate && _mutex_call(action, b.agent, b, b.state)
          b.state == INIT && (b.nextstate = b.initialstate)
          b.prevstate = b.state
          if b.nextstate != b.state
            restart(b)
            _mutex_call(onexit, b.agent, b, b.state)
            for waker ∈ b.wakers
              stop(waker)
            end
            empty!(b.wakers)
            if b.nextstate == REENTER
              b.nextstate = b.state
            else
              b.state = b.nextstate
            end
            _mutex_call(onenter, b.agent, b, b.state)
          end
        catch ex
          reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
        end
        yield()
      else
        lock(() -> wait(b.block), b.block)
      end
    end
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  end
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end
