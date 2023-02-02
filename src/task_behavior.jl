export TaskBehavior

mutable struct TaskBehavior <: Behavior
    agent::Union{Nothing,Agent}
    block::Union{Nothing,Threads.Condition}
    timer::Union{Nothing,Timer}
    done::Bool
    priority::Int

    action::Any
    main_task::Union{Nothing, Task}
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
        nothing, # main_task
    )
end

function action(b::TaskBehavior)
    b.main_task = current_task()
    secondary_task = Task() do
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
                yieldto(secondary_task)
            end
        end
    catch ex
        reporterror(b.agent, ex)
    end
    b.done = true
    b.main_task = nothing
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
function sleep(b::TaskBehavior, millis)
    block(b, millis)
    yieldto(b.main_task)
end