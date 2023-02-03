export TaskBehavior

mutable struct TaskBehavior <: Behavior
    agent::Union{Nothing,Agent}
    block::Union{Nothing,Threads.Condition}
    timer::Union{Nothing,Timer}
    done::Bool
    priority::Int

    action::Any
    control_task::Union{Nothing, Task}
    action_task::Union{Nothing, Task}
end

"""
    TaskBehavior(action)

Create a behavior which allows for explicit interruptions.

The given function `action(a::Agent, b::Behavior)` is called exactly once at the
earliest available opportunity. The behavior may explicitly interrupt itself by
calling `Fjage.sleep(b, millis)`, which blocks the behavior for `millis`
milliseconds.

# Examples:
```julia
@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  add(a, TaskBehavior() do a, b
    for ith = ("first", "second", "third")
      println("Going to sleep for the \$ith time")
      Fjage.sleep(b, 500)
    end
  end)
end
```
"""
function TaskBehavior(action)
    return TaskBehavior(
        nothing, # agent
        nothing, # block
        nothing, # timer
        false,   # done
        0,       # priority
        action,  # action
        nothing, # control_task
        nothing, # action_task
    )
end

function action(b::TaskBehavior)
    b.control_task = current_task()
    b.action_task = Task() do
        try
            b.action(b.agent, b)
        catch e
            reporterror(b.agent, e)
        end
        b.done = true
        yieldto(b.main_task)
    end
    try
        while !b.done
            if !isnothing(b.block)
                lock(() -> wait(b.block), b.block)
            end
            _mutex_call(b.agent) do agent
                yieldto(b.action_task)
            end
        end
    catch ex
        reporterror(b.agent, ex)
    end
    b.done = true
    b.control_task = nothing
    b.action_task = nothing
    delete!(b.agent._behaviors, b)
    b.agent = nothing
end

"""
    Fjage.sleep(b::TaskBehavior, millis)

Block the behavior for `millis` milliseconds.

Unlike `block()`, this function blocks immediately and only resumes once the
block has expired. Unlike `Base.sleep()`, this function releases the lock on the
behavior's agent.
"""
    if current_task() != b.action_task
        @error "Fjage.pause() has been called outside of an action context!"
    end
    block(b, millis)
    yieldto(b.control_task)
end