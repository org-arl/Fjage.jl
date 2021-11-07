# Agents, Behaviors & Containers

`Fjage.jl` currently supports standalone containers and slave containers.
Standalone containers may be used to deploy Julia-only agent applications.
Slave containers are used to connect to Java master containers that host
multi-language agent applications.

The agents, behaviors and containers API is modeled on the Java version, and
hence the [fjåge developer's guide](https://fjage.readthedocs.io/en/latest/)
provides a good introduction to developing agents.

## Example

```julia
using Fjage

@agent struct MyAgent
  count::Int = 0
end

function Fjage.startup(a::MyAgent)
  add(a, TickerBehavior(5000) do a, b
    a.count += 1
    @info "Tick $(a.count)"
  end)
end

# start the agent in a container
c = Container()
add(c, "myagent", MyAgent())
start(c)

# when you've had enough, shutdown the container
sleep(30)
shutdown(c)
```

More examples are available in the
[examples](https://github.com/org-arl/Fjage.jl/tree/master/examples)
folder for reference.

## Agent, Behaviors & Container API

```@autodocs
Modules = [Fjage]
Pages   = ["container.jl"]
```
