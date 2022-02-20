export Platform, RealTimePlatform, add, currenttimemillis, delay, containers, isrunning, start, shutdown
export Container, StandaloneContainer, SlaveContainer, canlocateagent, containsagent, agent, agents
export register, deregister, services, add, agentforservice, agentsforservice, canlocateagent, ps
export name!, state, isidle, autoclone, autoclone!, addlistener, removelistener, buildversion
export queuesize!, platformsend, loglevel!, store
export Agent, @agent, name, platform, send, subscribe, unsubscribe, die, stop, receive, request
export Behavior, done, priority, block, restart, stop, isblocked, OneShotBehavior, CyclicBehavior
export WakerBehavior, TickerBehavior, MessageBehavior, ParameterMessageBehavior, BackoffBehavior, PoissonBehavior
export backoff, tickcount

abstract type Platform end
abstract type Container end
abstract type Agent end
abstract type Behavior end

### fallbacks

name(::Nothing) = "-"
platform(::Nothing) = nothing
currenttimemillis(::Nothing) = Dates.value(now())
nanotime(::Nothing) = Dates.value(now()) * 1000000
delay(::Nothing, millis) = sleep(millis/1000)

"""
    loglevel!(level)

Set log level. Supported levels include `:debug`, `:info`, `:warn`, `:error`, `:none`.
The equivalent Julia `Logging.Debug`, `Logging.Info`, etc levels may also be used.
"""
function loglevel!(level)
  # requires JULIA_DEBUG environment variable to be setup correctly
  (level === Logging.Debug || level === :debug) && return disable_logging(Logging.BelowMinLevel)
  (level === Logging.Info || level === :info) && return disable_logging(Logging.Debug)
  (level === Logging.Warn || level === :warn) && return disable_logging(Logging.Info)
  (level === Logging.Error || level === :error) && return disable_logging(Logging.Warn)
  (level === Logging.AboveMaxLevel || level === :none) && return disable_logging(Logging.Error)
  throw(ArgumentError("Bad loglevel (allowed values are :debug, :info, :warn, :error, :none)"))
end

### stacktrace pretty printing & auto-reconnection

function reporterror(src, ex)
  fname = basename(@__FILE__)
  bt = String[]
  for s ∈ stacktrace(catch_backtrace())
    push!(bt, "    $s")
    basename(string(s.file)) == fname && s.func == :run && break
  end
  bts = join(bt, '\n')
  if src === nothing
    @error "$(ex)\n  Stack trace:\n$(bts)"
  else
    @error "[$(src)] $(ex)\n  Stack trace:\n$(bts)"
  end
end

reporterror(ex) = reporterror(nothing, ex)

function reconnect(c, ex)
  c.reconnect[] || return false
  isopen(c.sock[]) && return false
  ex isa IOError || return false
  @warn "Connection lost..."
  close(c.sock[])
  true
end

### realtime platform

"Real-time platform."
Base.@kwdef struct RealTimePlatform <: Platform
  containers = Container[]
  running = Ref(false)
  term = Threads.Condition()
end

function Base.show(io::IO, p::RealTimePlatform)
  print(io, "RealTimePlatform[running=", p.running[], ", containers=", length(p.containers), "]")
end

"""
    currenttimemillis(platform::Platform)

Get current time in milliseconds for the platform.
"""
currenttimemillis(::RealTimePlatform) = Dates.value(now())

"""
    nanotime(platform::Platform)

Get current time in nanoseconds for the platform.
"""
nanotime(::RealTimePlatform) = Dates.value(now()) * 1000000

"""
    delay(platform::Platform, millis)

Sleep for millis ms on the platform.
"""
delay(::RealTimePlatform, millis) = sleep(millis/1000)

"""
    containers(platform::Platform)

Get list of containers running on the platform.
"""
containers(p::RealTimePlatform) = p.containers

"""
    isrunning(platform::Platform)

Check if platform is running.
"""
isrunning(p::RealTimePlatform) = p.running[]

"""
    isidle(platform::Platform)

Check if platform is idle. Unimplemented. Currently always returns true.
"""
isidle(::RealTimePlatform) = true      # FIXME

"""
    buildversion(platform::Platform)

Get build version of the platform.
"""
buildversion(::RealTimePlatform) = VERSION

"""
    add(platform::Platform, container::Container)

Run a container on a platform.
"""
function add(p::RealTimePlatform, c::Container)
  platform(c) === p || throw(ArgumentError("Container bound to another platform"))
  push!(p.containers, c)
  p.running[] && start(c)
  nothing
end

"""
    start(platform::Platform)

Start the platform and all containers running on the platform.
"""
function start(p::RealTimePlatform)
  p.running[] && return p
  @debug "Starting RealTimePlatform..."
  p.running[] = true
  foreach(start, p.containers)
  @debug "RealTimePlatform is running"
  p
end

"""
    shutdown(platform::Platform)

Stop the platform and all containers running on the platform.
"""
function shutdown(p::RealTimePlatform)
  p.running[] || return
  @debug "Stopping RealTimePlatform..."
  foreach(shutdown, p.containers)
  p.running[] = false
  @debug "Stopped RealTimePlatform"
  lock(() -> notify(p.term), p.term)
  nothing
end

"""
    wait(platform::Platform)

Wait for platform to finish running. Blocks until all containers running on
the platform have shutdown.
"""
function Base.wait(p::RealTimePlatform)
  lock(p.term) do
    while isrunning(p)
      wait(p.term)
    end
  end
end

### standalone & slave containers

"Standalone container."
struct StandaloneContainer{T <: Platform} <: Container
  name::Ref{String}
  platform::T
  agents::Dict{String,Agent}
  topics::Dict{AgentID,Set{Agent}}
  services::Dict{String,Set{AgentID}}
  running::Ref{Bool}
  initing::Ref{Bool}
end

"Slave container."
struct SlaveContainer{T <: Platform} <: Container
  name::Ref{String}
  platform::T
  agents::Dict{String,Agent}
  topics::Dict{AgentID,Set{Agent}}
  services::Dict{String,Set{AgentID}}
  running::Ref{Bool}
  initing::Ref{Bool}
  sock::Ref{TCPSocket}
  pending::Dict{String,Channel}
  host::String
  port::Int
  reconnect::Ref{Bool}
end

"""
    Container()
    Container(platform::Platform)
    Container(platform::Platform, name)

Create a standalone container running on a real-time platform (if unspecified).
If a name is not specified, a unique name is randomly generated.
"""
function Container(p=RealTimePlatform(), name=string(uuid4()))
  c = StandaloneContainer(Ref(name), p, Dict{String,Agent}(), Dict{AgentID,Set{Agent}}(),
    Dict{String,Set{AgentID}}(), Ref(false), Ref(false))
  add(p, c)
  c
end

"""
    SlaveContainer(host, port)
    SlaveContainer(host, port, name)
    SlaveContainer(platform::Platform, host, port)
    SlaveContainer(platform::Platform, host, port, name)

Create a slave container running on a real-time platform (if unspecified),
optionally with a specified name. If a name is not specified, a unique name
is randomly generated.
"""
SlaveContainer(host, port; reconnect=true) = SlaveContainer(RealTimePlatform(), host, port; reconnect=reconnect)
SlaveContainer(host, port, name; reconnect=true) = SlaveContainer(RealTimePlatform(), host, port, name; reconnect=reconnect)

function SlaveContainer(p::Platform, host, port, name=string(uuid4()); reconnect=true)
  c = SlaveContainer(Ref(name), p, Dict{String,Agent}(), Dict{AgentID,Set{Agent}}(),
    Dict{String,Set{AgentID}}(), Ref(false), Ref(false), Ref(TCPSocket()), Dict{String,Channel}(), host, port, Ref(reconnect))
  add(p, c)
  c
end

"""
    name(container::Container)

Get name of the container.
"""
name(c::Container) = c.name[]

"""
    name!(container::Container, s)

Set name of the container.
"""
name!(c::Container, s::String) = (c.name[] = s)

function Base.show(io::IO, c::Container)
  print(io, typeof(c), "[name=\"", name(c), "\", running=", c.running[], ", agents=", length(c.agents), "]")
end

"""
    platform(container::Container)

Get platform on which the container is running.
"""
platform(c::Container) = c.platform

"""
    isrunning(container::Container)

Check if the container is running.
"""
isrunning(c::Container) = c.running[]

"""
    state(container::Container)

Get a human-readable state of the container.
"""
state(c::Container) = isrunning(c) ? "Running" : "Not running"

"""
    isidle(container::Container)

Check if container is idle. Unimplemented. Currently always returns true.
"""
isidle(::Container) = true     # FIXME

"""
    autoclone(container::Container)

Check if the container is configured to automatically clone messages on send.
"""
autoclone(::Container) = false

"""
    autoclone!(container::Container, b)

Configure container to automatically clone (or not clone) messages on send. Currently
auto-cloning is unimplemented, and so `b` can only be `false`.
"""
autoclone!(::Container, b::Bool) = b && throw(ArgumentError("autoclone not supported"))

"""
    addlistener(container::Container, listener)

Add message listener to container. Unimplemented.
"""
addlistener(::Container, listener) = throw(ErrorException("Listeners not supported"))

"""
    removelistener(container::Container, listener)

Remove message listener from container.
"""
removelistener(::Container, listener) = false

"""
    containsagent(container::Container, aid::AgentID)
    containsagent(container::Container, name::String)

Check if an agent is running in the container.
"""
containsagent(c::Container, aid::AgentID) = aid.name ∈ keys(c.agents)
containsagent(c::Container, name::String) = name ∈ keys(c.agents)

"""
    canlocateagent(container::Container, aid::AgentID)
    canlocateagent(container::Container, name::String)

Check if an agent is running in the container, or in any of the remote containers.
"""
canlocateagent(c::StandaloneContainer, a) = containsagent(c, a)

function canlocateagent(c::SlaveContainer, aid)
  c.running[] || return false
  containsagent(c, aid) && return true
  rq = Dict("action" => "containsAgent", "agentID" => aid)
  rsp = _ask(c, rq)
  haskey(rsp, "answer") && return rsp["answer"]::Bool
  false
end

"""
    agent(container::Container, aid::AgentID)
    agent(container::Container, name::String)

Get the agent ID of an agent specified by name or its agent ID.
"""
agent(c::Container, name::String) = name ∈ keys(c.agents) ? c.agents[name] : nothing
agent(c::Container, aid::AgentID) = agent(c, name(aid))

"""
    agents(container::Container)

Get list of agents running in the container.
"""
agents(c::Container) = collect(values(c.agents))

"""
    services(container::Container)

Get list of services running in the container.
"""
services(c::Container) = collect(keys(c.services))

"""
    add(container::Container, agent)
    add(container::Container, name, agent)

Run an agent in a container. If the name is not specified, a unique name is randomly
generated.
"""
function add(c::Container, name::String, a::Agent)
  canlocateagent(c, name) && throw(ArgumentError("Duplicate agent name"))
  a._container = c
  a._aid = AgentID(name)
  c.agents[name] = a
  c.running[] && init(a)
  @async _msgloop(a)
  @debug "Added agent $(name)::$(typeof(a))"
  a._aid
end

add(c::Container, a::Agent) = add(c, string(typeof(a)) * "-" * string(uuid4())[1:8], a)

"""
    kill(container::Container, aid::AgentID)
    kill(container::Container, name::String)
    kill(container::Container, agent::Agent)

Stop an agent running in a container.
"""
function Base.kill(c::Container, aid::String)
  containsagent(c, aid) || return false
  a = c.agents[aid]
  if c.running[]
    foreach(stop, a._behaviors)
    lock(() -> notify(a._processmsg, false), a._processmsg)
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

"""
    start(container::Container)

Start a container.
"""
function start(c::StandaloneContainer)
  c.running[] && return c
  if !isrunning(c.platform)
    length(containers(c.platform)) > 1 && throw(ArgumentError("Platform is not running"))
    start(platform(c))
    return c
  end
  @debug "Starting StandaloneContainer..."
  c.running[] = true
  c.initing[] = true
  foreach(kv -> init(kv[2]), c.agents)
  @debug "StandaloneContainer is running"
  c.initing[] = false
  foreach(c.agents) do kv
    foreach(kv[2]._behaviors) do b
      @async action(b)
    end
  end
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
  c.initing[] = true
  foreach(kv -> init(kv[2]), c.agents)
  @debug "SlaveContainer is running"
  # behaviors to be started and c.initing[] reset on _alive()
  @async _run(c)
  c
end

function _alive(c::SlaveContainer)
  c.initing[] || return
  c.initing[] = false
  foreach(c.agents) do kv
    foreach(kv[2]._behaviors) do b
      @async action(b)
    end
  end
end

"""
    shutdown(container::Container)

Stop a container and all agents running in it.
"""
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
  c.reconnect[] = false
  c.running[] = false
  try
    println(c.sock[], "{\"alive\": false}")
  catch ex
    # ignore
  end
  close(c.sock[])
  @debug "Stopped SlaveContainer"
  nothing
end

_onclose(c::SlaveContainer) = shutdown(c)
_shutdown(c::SlaveContainer) = shutdown(platform(c))

"""
    subscribe(c::Container, topic::AgentID, agent::Agent)

Subscribe `agent` running in container `c` to `topic`.
"""
function subscribe(c::StandaloneContainer, t::AgentID, a::Agent)
  t ∈ keys(c.topics) || (c.topics[t] = Set{Agent}())
  push!(c.topics[t], a)
  true
end

"""
    unsubscribe(c::Container, topic::AgentID, agent::Agent)

Unsubscribe `agent` running in container `c` from `topic`.
"""
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

"""
    unsubscribe(c::Container, agent::Agent)

Unsubscribe `agent` running in container `c` from all topics.
"""
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

"""
    register(c::Container, aid::AgentID, svc::String)

Register agent `aid` as providing service `svc`.
"""
function register(c::Container, aid::AgentID, svc::String)
  svc ∈ keys(c.services) || (c.services[svc] = Set{AgentID}())
  push!(c.services[svc], aid)
  true
end

"""
    deregister(c::Container, aid::AgentID)

Deregister agent `aid` from providing any services.
"""
function deregister(c::Container, aid::AgentID)
  foreach(svc -> delete!(c.services[svc], aid), keys(c.services))
  nothing
end

"""
    deregister(c::Container, aid::AgentID, svc::String)

Deregister agent `aid` from providing service `svc`.
"""
function deregister(c::Container, aid::AgentID, svc::String)
  svc ∈ keys(c.services) || return false
  delete!(c.services[svc], aid)
  true
end

"""
    agentforservice(c::Container, svc::String, owner::AgentID)

Lookup any agent providing the service `svc`, and return an `AgentID` owned
by `owner`. Returns `nothing` if no agent providing specified service found.
"""
function agentforservice(c::StandaloneContainer, svc::String, owner::AgentID)
  svc ∈ keys(c.services) || return nothing
  AgentID(first(c.services[svc]).name, false, owner)
end

"""
    agentsforservice(c::Container, svc::String, owner::AgentID)

Lookup all agents providing the service `svc`, and return list of `AgentID` owned
by `owner`. Returns an empty list if no agent providing specified service found.
"""
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

"""
    send(c::Container, msg)

Send message `msg` to recipient specified in the message. Return `true` if the
message is accepted for delivery, `false` otherwise.
"""
send(c::Container, msg) = _deliver(c, msg, true)
send(c::Container, msg, relay) = _deliver(c, msg, relay)

"""
    ps(c::Container)

Get a list of agents running in a container. The list contains tuples of agent
name and agent type. The agent type may be an empty string for agents running in
remote containers, if the containers do not support type query.
"""
ps(c::StandaloneContainer) = collect((kv[1], string(typeof(kv[2]))) for kv ∈ c.agents)

function ps(c::SlaveContainer)
  rq = Dict("action" => "agents")
  rsp = _ask(c, rq)
  if "agentTypes" ∈ keys(rsp) && length(rsp["agentIDs"]) == length(rsp["agentTypes"])
    return collect(zip(rsp["agentIDs"], rsp["agentTypes"]))
  end
  [(a, "") for a in rsp["agentIDs"]]
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
_agents_types(c::SlaveContainer) = [(k, string(typeof(v))) for (k, v) ∈ c.agents]
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
    json = JSON.json(Dict(
      "action" => "send",
      "relay" => true,
      "message" => Dict(
        "clazz" => msg.__clazz__,
        "data" => msg.__data__
      )
    ))
    try
      println(c.sock[], json)
    catch ex
      @debug "Message $(msg) delivery failed: $(ex)"
      return false
    end
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

"""
The `@agent` macro is used to define a Fjage agent. The macro takes in a `struct`
definition and converts it into an agent definition. The fields in the struct are
treated as agent attributes. Fjage agent types are subtypes of `Fjage.Agent`
and are mutable.

The `struct` definition may include initialization, as supported by the
`Base.@kwdef` macro.

# Examples:
```julia
using Fjage

@agent struct MyAgent
  field1::Int = 1
  field2::String = "hello"
end

abstract type SpecialAgent <: Fjage.Agent end

@agent struct MySpecialAgent <: SpecialAgent
  agentnumber::Int = 007
  licensedtokill::Bool = true
end
```
"""
macro agent(sdef)
  if @capture(sdef, struct T_ <: P_ fields__ end)
    push!(fields, :(_aid::Union{AgentID,Nothing} = nothing))
    push!(fields, :(_container::Union{Container,Nothing} = nothing))
    push!(fields, :(_behaviors::Set{Behavior} = Set{Behavior}()))
    push!(fields, :(_listeners::Vector{Tuple{Any,Channel,Int}} = Tuple{Any,Channel,Int}[]))
    push!(fields, :(_msgqueue::Vector{Message} = Message[]))
    push!(fields, :(_processmsg::Threads.Condition = Threads.Condition()))
    push!(fields, :(_lock::ReentrantLock = ReentrantLock()))
    :( Base.@kwdef mutable struct $T <: $P; $(fields...); end ) |> esc
  elseif @capture(sdef, struct T_ fields__ end)
    push!(fields, :(_aid::Union{AgentID,Nothing} = nothing))
    push!(fields, :(_container::Union{Container,Nothing} = nothing))
    push!(fields, :(_behaviors::Set{Behavior} = Set{Behavior}()))
    push!(fields, :(_listeners::Vector{Tuple{Any,Channel,Int}} = Tuple{Any,Channel,Int}[]))
    push!(fields, :(_msgqueue::Vector{Message} = Message[]))
    push!(fields, :(_processmsg::Threads.Condition = Threads.Condition()))
    push!(fields, :(_lock::ReentrantLock = ReentrantLock()))
    :( Base.@kwdef mutable struct $T <: Agent; $(fields...); end ) |> esc
  else
    @error "Bad agent definition"
  end
end

Base.show(io::IO, a::Agent) = print(io, typeof(a), "(", something(AgentID(a), "-"), ")")

"""
    init(a::Agent)

Initialization function for an agent. The default implementation calls `setup(a)`,
and adds a `ParameterMessageBehavior` to support agent parameters, a
`MessageBehavior` that calls `processrequest(a, msg)` for REQUEST messages or
`processmessage(a, msg)` for all other messages, and a `OneShotBehavior` that
calls `startup(a)` once the agent is running. An agent may provide a method
if these default behaviors are desired.

# Examples:
```julia
using Fjage

@agent struct MyBareAgent end

function Fjage.init(a::MyBareAgent)
  @info "MyBareAgent init"
end
```
"""
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


@doc """
    setup(a::Agent)

Unless an agent overrides its `init(a)` function, the default behavior for an agent
is to call `setup(a)` during initialization, and `startup(a)` once the agent
is running. Typically, the `setup(a)` function is used to register services, and
the `startup(a)` function is used to lookup services from other agents. Behaviors
may be added in either of the functions.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.setup(a::MyAgent)
  @info "MyAgent setting up"
end

function Fjage.startup(a::MyAgent)
  @info "MyAgent started"
end
```
""" setup
@doc (@doc setup) startup

setup(a::Agent) = nothing
startup(a::Agent) = nothing

"""
    processrequest(a::Agent, req)

Unless an agent overrides its `init(a)` function, the default behavior for an agent
is to add a `MessageBehavior` that calls `processrequest(a, req)` when it
receives any message with a performative `REQUEST`. The return value of the
function must be either `nothing` or a response message. If a response message
is returned, it is sent. If `nothing` is returned, a default response with
performative `NOT_UNDERSTOOD` is sent back. An agent may provide methods to
handle specific messages. For unhandled requests, the default implementation
just returns a `nothing`.

# Examples:
```julia
using Fjage

const MySpecialReq = MessageClass(@__MODULE__, "MySpecialReq", nothing, Performative.REQUEST)

@agent struct MyAgent end

function Fjage.processrequest(a::MyAgent, req::MySpecialReq)
  # do something useful with the request here...
  # and return an AGREE response
  Message(req, Performative.AGREE)
end
```
"""
processrequest(a::Agent, req) = nothing

"""
    processmessage(a::Agent, msg)

Unless an agent overrides its `init(a)` function, the default behavior for an agent
is to add a `MessageBehavior` that calls `processmessage(a, msg)` when it
receives any message (with the exception of messages with performative `REQUEST`,
for which `processrequest(a, msg)` is called instead). An agent may provide methods to
handle specific messages.

# Examples:
```julia
using Fjage

const MySpecialNtf = MessageClass(@__MODULE__, "MySpecialNtf")

@agent struct MyAgent end

function Fjage.processmessage(a::MyAgent, msg::MySpecialNtf)
  # do something useful with the message here...
end
```
"""
processmessage(a::Agent, msg) = nothing

"""
    shutdown(a::Agent)

This function is called when an agent terminates. An agent may provide a
method to handle termination, if desired.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.shutdown(a::MyAgent)
  @info "MyAgent shutting down"
end
```
"""
function shutdown(a::Agent)
  @debug "MyAgent terminated"
end

"""
    stop(a::Agent)
    stop(a::Agent, msg)

Terminates an agent, optionally with an error message to be logged, explaining
the reason for termination.

  # Examples:
```julia
using Fjage

@agent struct MyAgent
  criticalagent::Union{AgentID,Nothing} = nothing
end

function Fjage.startup(a::MyAgent)
  a.criticalagent = agentforservice("CriticalService")
  a.criticalagent === nothing && return stop(a, "Could not find an agent providing CriticalService")
  @info "MyAgent up and running"
end
```
"""
function stop(a::Agent)
  kill(container(a), a)
  nothing
end

function stop(a::Agent, msg)
  @error "Agent $(AgentID(a)) died: $(msg)"
  stop(a)
end

"""
    platform(a::Agent)

Get platform on which the agent's container is running.
"""
platform(a::Agent) = platform(container(a))

"""
    container(a::Agent)

Get container in which the agent is running.
"""
container(a::Agent) = a._container

"""
    AgentID(a::Agent)

Get the `AgentID` of the agent.
"""
AgentID(a::Agent) = a._aid

"""
    name(a::Agent)

Get the name of the agent.
"""
name(a::Agent) = name(a._aid)

"""
    agent(a::Agent, name::String)

Generate an owned `AgentID` for an agent with the given name.
"""
agent(a::Agent, name::String) = AgentID(name, false, a)

"""
    currenttimemillis(a::Agent)

Get current time in milliseconds for the agent.
"""
currenttimemillis(a::Agent) = currenttimemillis(platform(a))

"""
    nanotime(a::Agent)

Get current time in nanoseconds for the agent.
"""
nanotime(a::Agent) = nanotime(platform(a))

"""
    delay(a::Agent, millis)

Delay the execution of the agent by `millis` milliseconds.
"""
delay(a::Agent, millis) = delay(platform(a), millis)

# FIXME: support agent-specific log levels
loglevel!(::Agent, level) = loglevel!(level)

# FIXME: improve agent state tracking
function state(a::Agent)
  # states in fjåge: IDLE/INIT/NONE/RUNNING/FINISHED/FINISHING
  c = container(a)
  c !== nothing && isrunning(c) && return :idle
  :none
end

"""
    subscribe(a::Agent, topic::AgentID)

Subscribe agent to specified topic.
"""
subscribe(a::Agent, t::AgentID) = subscribe(container(a), t, a)

"""
    unsubscribe(a::Agent, topic::AgentID)

Unsubscribe agent from specified topic.
"""
unsubscribe(a::Agent, t::AgentID) = unsubscribe(container(a), t, a)

"""
    register(a::Agent, svc::String)

Register agent as providing a specied service.
"""
register(a::Agent, svc::String) = register(container(a), AgentID(a), svc)

"""
    deregister(a::Agent, svc::String)

Deregister agent from providing a specied service.
"""
deregister(a::Agent, svc::String) = deregister(container(a), AgentID(a), svc)

"""
    agentforservice(a::Agent, svc::String)

Find an agent providing a specified service. Returns an owned `AgentID` for the
service provider, if one is found, `nothing` otherwise.
"""
agentforservice(a::Agent, svc::String) = agentforservice(container(a), svc, a)

"""
    agentsforservice(a::Agent, svc::String)

Get a list of agents providing a specified service. Returns a list of owned
`AgentID` for the service providers. The list may be empty if no service providers
are found.
"""
agentsforservice(a::Agent, svc::String) = agentsforservice(container(a), svc, a)

"""
    store(a::Agent)

Return the persistent data store for agent. Currently unimplemented.
"""
store(::Agent) = throw(ErrorException("Persistent store not supported"))

"""
    queuesize!(a::Agent, n)

Set the incoming message queue size for an agent. Currently unimplemented.
"""
function queuesize!(::Agent, n)
  n == MAX_QUEUE_LEN && return nothing
  throw(ArgumentError("Changing queuesize is not supported (queuesize = $MAX_QUEUE_LEN)"))
end

"""
    send(a::Agent, msg::Message)

Send a message from agent `a`.
"""
function send(a::Agent, msg::Message)
  @debug "sending $(msg)"
  msg.sender = AgentID(a)
  msg.sentAt = currenttimemillis(a)
  _deliver(container(a), msg)
end

"""
    platformsend(a::Agent, msg::Message)

Send a message to agents running on all containers on a platform. Currently
unimplemented.
"""
platformsend(::Agent, msg::Message) = throw(ErrorException("platformsend() not supported"))

"""
    receive(a::Agent, timeout::Int=0; priority)
    receive(a::Agent, filt, timeout::Int=0; priority)

Receive a message, optionally matching the specified filter. The call blocks for
at most `timeout` milliseconds, if a message is not available. If multiple
`receive()` calls are concurrently active, the `priority` determines which call
gets the message. Only one of the active `receive()` calls will receive the message.
Returns a message or `nothing`.

If a filter `filt` is specified, only messages matching the filter trigger
this behavior. A filter may be a message class or a function that takes the
message as an argument and returns `true` to accept, `false` to reject.

Lower priority numbers indicate a higher priority.
"""
function receive(a::Agent, filt, timeout::Int=0; priority=(filt===nothing ? 0 : -100))
  (container(a) === nothing || !isrunning(container(a))) && return nothing
  m = lock(a._processmsg) do
    for (n, msg) ∈ enumerate(a._msgqueue)
      if _matches(filt, msg) && !_listener_waiting(a, msg, priority)
        deleteat!(a._msgqueue, n)
        return msg
      end
    end
    nothing
  end
  m === nothing || return m
  timeout == 0 && return nothing
  ch = Channel{Union{Message,Nothing}}(1)
  _listen(a, ch, filt, priority)
  if timeout > 0
    @async begin
      delay(a, timeout)
      put!(ch, nothing)
    end
  end
  lock(() -> notify(a._processmsg, true), a._processmsg)
  msg = take!(ch)
  _dont_listen(a, ch)
  close(ch)
  msg
end

receive(a::Agent, timeout::Int=0) = receive(a, nothing, timeout)

"""
    request(a::Agent, msg::Message)
    request(a::Agent, msg::Message, timeout::Int)

Send a request and wait for a response. If a timeout is specified, the call blocks
for at most `timeout` milliseconds. If no timeout is specified, a system default
is used. Returns the response message or `nothing` if no response received.
"""
function request(a::Agent, msg::Message, timeout::Int=timeout[])
  timeout == 0 && throw(ArgumentError("request must use a non-zero timeout"))
  (container(a) === nothing || !isrunning(container(a))) && return nothing
  ch = Channel{Union{Message,Nothing}}(1)
  _listen(a, ch, msg, -100)
  send(a, msg)
  if timeout > 0
    @async begin
      delay(a, timeout)
      put!(ch, nothing)
    end
  end
  msg = take!(ch)
  _dont_listen(a, ch)
  close(ch)
  msg
end

"""
    flush(a::Agent)

Flush agent's incoming message queue.
"""
Base.flush(a::Agent) = lock(() -> empty!(a._msgqueue), a._processmsg)

function _listen(a::Agent, ch::Channel, filt, priority::Int)
  for (n, (filt1, ch1, p)) ∈ enumerate(a._listeners)
    if p ≥ priority
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

function _listener_waiting(a::Agent, msg::Message, priority::Int)
  for (filt, ch, p) ∈ a._listeners
    priority ≤ p && return false
    _matches(filt, msg) && return true
  end
  false
end

function _deliver(a::Agent, msg::Message)
  @debug "$(a) <<< $(msg)"
  lock(a._processmsg) do
    push!(a._msgqueue, msg)
    while length(a._msgqueue) > MAX_QUEUE_LEN
      popfirst!(a._msgqueue)
    end
    notify(a._processmsg, true)
  end
end

function _msgloop(a::Agent)
  @debug "Start $(a) message loop"
  try
    lock(a._processmsg) do
      while wait(a._processmsg)
        @debug "Deliver messages in $(a) [qlen=$(length(a._msgqueue))]"
        filter!(a._msgqueue) do msg
          for (filt, ch, p) ∈ a._listeners
            if _matches(filt, msg)
              isready(ch) && return true
              put!(ch, msg)
              return false
            end
          end
          true
        end
      end
    end
  catch ex
    reporterror(a, ex)
  end
  @debug "Stop $(a) message loop"
end

### behaviors

Base.show(io::IO, b::Behavior) = print(io, typeof(b), "/", name(b.agent))

"""
    add(a::Agent, b::Behavior)

Add a behavior to an agent.
"""
function add(a::Agent, b::Behavior)
  (b.agent === nothing && b.done == false) || throw(ArgumentError("Behavior already running"))
  c = container(a)
  (c === nothing || !isrunning(c)) && throw(ArgumentError("Agent not running"))
  b.agent = a
  @debug "Add $(typeof(b)) to agent $(a._aid)"
  push!(a._behaviors, b)
  c.initing[] || @async action(b)
  b
end

"""
    agent(b::Behavior)

Get the agent owning the behavior.
"""
agent(b::Behavior) = b.agent

"""
    done(b::Behavior)

Check if a behavior is completed.
"""
done(b::Behavior) = b.done

"""
    priority(b::Behavior)

Get the priority associated with a behavior.
"""
priority(b::Behavior) = b.priority

"""
    isblocked(b::Behavior)

Check if a behavior is currently blocked.
"""
isblocked(b::Behavior) = b.block !== nothing

"""
    block(b::Behavior)
    block(b::Behavior, millis)

Marks a behavior as blocked, and prevents it from running until it is restarted
using `restart(b)`. If `millis` is specified, the behavior is automatically
restarted after `millis` milliseconds.
"""
function block(b::Behavior)
  b.done && return
  b.block = Threads.Condition()
  nothing
end

function block(b::Behavior, millis)
  b.done && return
  b.block = Threads.Condition()
  b.timer = Timer(millis/1000)
  @async begin
    try
      wait(b.timer)
    finally
      b.timer = nothing
      restart(b)
    end
  end
  nothing
end

"""
    restart(b::Behavior)

Restart a blocked behavior, previous blocked by `block(b)`.
"""
function restart(b::Behavior)
  b.block === nothing && return
  if b.timer !== nothing
    close(b.timer)
    return nothing
  end
  oblock = b.block
  b.block = nothing
  lock(() -> notify(oblock), oblock)
  nothing
end

"""
    reset(b::Behavior)

Resets a behavior, removing it from an agent running it. Once a behavior is
reset, it may be reused later by adding it to an agent.
"""
function reset(b::Behavior)
  b.agent === nothing || delete!(b.agent._behaviors, b)
  b.agent = nothing
  b.done = false
  nothing
end

Base.reset(b::Behavior) = reset(b)

"""
    stop(b::Behavior)

Terminates a behavior.
"""
function stop(b::Behavior)
  b.done = true
  restart(b)
  nothing
end

"""
    action(b::Behavior)

The action function for a behavior is repeatedly called when a behavior runs.
Typically, each type of `Behavior` provides an `action` method that implements
its intended behavior.
"""
function action end

# wrapper to ensure that behavior callbacks are atomic for the agent
function _mutex_call(f, a, b...)
  lock(a._lock) do
    f(a, b...)
  end
end

mutable struct OneShotBehavior <: Behavior
  agent::Union{Nothing,Agent}
  block::Union{Nothing,Threads.Condition}
  timer::Union{Nothing,Timer}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

"""
    OneShotBehavior(action)

Create a one-shot behavior that runs exactly once at the earliest available
opportunity. The `action(a::Agent, b::Behavior)` function is called when the
behavior runs. The `onstart` and `onend` fields in the behavior may be set
to functions that are called when the behavior is initialized and terminates.
Both functions are called with similar parameters as `action`.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  add(a, OneShotBehavior() do a, b
    @info "OneShotBehavior just ran"
  end)
end
```
"""
OneShotBehavior(action) = OneShotBehavior(nothing, nothing, nothing, false, 0, nothing, action, nothing)

function action(b::OneShotBehavior)
  try
    b.onstart === nothing || _mutex_call(b.onstart, b.agent, b)
    b.block === nothing || lock(() -> wait(b.block), b.block)
    b.action === nothing || _mutex_call(b.action, b.agent, b)
    b.onend === nothing || _mutex_call(b.onend, b.agent, b)
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct CyclicBehavior <: Behavior
  agent::Union{Nothing,Agent}
  block::Union{Nothing,Threads.Condition}
  timer::Union{Nothing,Timer}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

"""
    CyclicBehavior(action)

Create a cyclic behavior that runs repeatedly at the earliest available
opportunity. The `action(a::Agent, b::Behavior)` function is called when the
behavior runs. The `onstart` and `onend` fields in the behavior may be set
to functions that are called when the behavior is initialized and terminates.
Both functions are called with similar parameters as `action`.

The running of cyclic behaviors may be controlled using `block(b)`, `restart(b)`
and `stop(b)`.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  add(a, CyclicBehavior() do a, b
    @info "CyclicBehavior running..."
  end)
end
```
"""
CyclicBehavior(action) = CyclicBehavior(nothing, nothing, nothing, false, 0, nothing, action, nothing)

function action(b::CyclicBehavior)
  try
    b.onstart === nothing || _mutex_call(b.onstart, b.agent, b)
    while !b.done
      if b.block === nothing
        try
          b.action === nothing || _mutex_call(b.action, b.agent, b)
        catch ex
          reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
        end
        yield()
      else
        lock(() -> wait(b.block), b.block)
      end
    end
    b.onend === nothing || _mutex_call(b.onend, b.agent, b)
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct WakerBehavior <: Behavior
  agent::Union{Nothing,Agent}
  millis::Int64
  block::Union{Nothing,Threads.Condition}
  timer::Union{Nothing,Timer}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

"""
    WakerBehavior(action, millis)

Create a behavior that runs exactly once after `millis` milliseconds.
The `action(a::Agent, b::Behavior)` function is called when the
behavior runs. The `onstart` and `onend` fields in the behavior may be set
to functions that are called when the behavior is initialized and terminates.
Both functions are called with similar parameters as `action`.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  add(a, WakerBehavior(5000) do a, b
    @info "Awake after 5 seconds!"
  end)
end
```
"""
WakerBehavior(action, millis::Int64) = WakerBehavior(nothing, millis, nothing, nothing, false, 0, nothing, action, nothing)

"""
    BackoffBehavior(action, millis)

Create a behavior that runs after `millis` milliseconds. The
`action(a::Agent, b::Behavior)` function is called when the
behavior runs. The behavior may be scheduled to re-run in `t` milliseconds
by calling `backoff(b, t)`.

The `onstart` and `onend` fields in the behavior may be set to functions that
are called when the behavior is initialized and terminates. Both functions are
called with similar parameters as `action`.

The `BackoffBehavior` constructor is simply syntactic sugar for a `WakerBehavior`
that is intended to be rescheduled often using `backoff()`.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  # a behavior that will run for the first time in 5 seconds, and subsequently
  # every 2 seconds
  add(a, BackoffBehavior(5000) do a, b
    @info "Backoff!"
    backoff(b, 2000)
  end)
end
```
"""
BackoffBehavior(action, millis::Int64) = WakerBehavior(nothing, millis, nothing, nothing, false, 0, nothing, action, nothing)

function action(b::WakerBehavior)
  try
    b.onstart === nothing || _mutex_call(b.onstart, b.agent, b)
    while !b.done
      block(b, b.millis)
      b.block === nothing || lock(() -> wait(b.block), b.block)
      if !b.done
        b.done = true
        b.action === nothing || _mutex_call(b.action, b.agent, b)
      end
    end
    b.onend === nothing || _mutex_call(b.onend, b.agent, b)
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

"""
    backoff(b::WakerBehavior, millis)

Schedule the behavior to re-run in `millis` milliseconds.
"""
function backoff(b::WakerBehavior, millis::Int64)
  b.done = false
  b.millis = millis
end

mutable struct TickerBehavior <: Behavior
  agent::Union{Nothing,Agent}
  millis::Int64
  block::Union{Nothing,Threads.Condition}
  timer::Union{Nothing,Timer}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
  ticks::Int64
end

"""
    TickerBehavior(action, millis)

Create a behavior that runs periodically every `millis` milliseconds.
The `action(a::Agent, b::Behavior)` function is called when the
behavior runs. The `onstart` and `onend` fields in the behavior may be set
to functions that are called when the behavior is initialized and terminates.
Both functions are called with similar parameters as `action`.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  add(a, TickerBehavior(5000) do a, b
    @info "Tick!"
  end)
end
```
"""
TickerBehavior(action, millis::Int64) = TickerBehavior(nothing, millis, nothing, nothing, false, 0, nothing, action, nothing, 0)

"""
    tickcount(b::TickerBehavior)

Get the number of times a `TickerBehavior` has ticked (its `action()` has been
called).
"""
tickcount(b::TickerBehavior) = b.ticks

function action(b::TickerBehavior)
  try
    b.onstart === nothing || _mutex_call(b.onstart, b.agent, b)
    while !b.done
      block(b, b.millis)
      b.block === nothing || lock(() -> wait(b.block), b.block)
      b.ticks += 1
      try
        b.done || b.action === nothing || _mutex_call(b.action, b.agent, b)
      catch ex
        reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
      end
    end
    b.onend === nothing || _mutex_call(b.onend, b.agent, b)
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct PoissonBehavior <: Behavior
  agent::Union{Nothing,Agent}
  millis::Int64
  block::Union{Nothing,Threads.Condition}
  timer::Union{Nothing,Timer}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
  ticks::Int64
end

"""
    PoissonBehavior(action, millis)

Create a behavior that runs randomly, on an averge once every `millis` milliseconds.
The `action(a::Agent, b::Behavior)` function is called when the
behavior runs. The `onstart` and `onend` fields in the behavior may be set
to functions that are called when the behavior is initialized and terminates.
Both functions are called with similar parameters as `action`.

# Examples:
```julia
using Fjage

@agent struct MyAgent end

function Fjage.startup(a::MyAgent)
  add(a, PoissonBehavior(5000) do a, b
    @info "PoissonBehavior ran!"
  end)
end
```
"""
PoissonBehavior(action, millis::Int64) = PoissonBehavior(nothing, millis, nothing, nothing, false, 0, nothing, action, nothing, 0)

"""
    tickcount(b::PoissonBehavior)

Get the number of times a `PoissonBehavior` has ticked (its `action()` has been
called).
"""
tickcount(b::PoissonBehavior) = b.ticks

function action(b::PoissonBehavior)
  try
    b.onstart === nothing || _mutex_call(b.onstart, b.agent, b)
    while !b.done
      block(b, round(Int64, b.millis * randexp()))
      b.block === nothing || lock(() -> wait(b.block), b.block)
      b.ticks += 1
      try
        b.done || b.action === nothing || _mutex_call(b.action, b.agent, b)
      catch ex
        reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
      end
    end
    b.onend === nothing || _mutex_call(b.onend, b.agent, b)
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  end
  b.done = true
  delete!(b.agent._behaviors, b)
  b.agent = nothing
end

mutable struct MessageBehavior <: Behavior
  agent::Union{Nothing,Agent}
  filt::Any
  block::Union{Nothing,Threads.Condition}
  timer::Union{Nothing,Timer}
  done::Bool
  priority::Int
  onstart::Union{Nothing,Function}
  action::Union{Nothing,Function}
  onend::Union{Nothing,Function}
end

"""
    MessageBehavior(action, millis)
    MessageBehavior(action, filt, millis)

Create a behavior that runs every time a message arrives.
The `action(a::Agent, b::Behavior, msg)` function is called when a
message arrives. The `onstart` and `onend` fields in the behavior may be set
to functions that are called when the behavior is initialized and terminates.
Both functions are called with similar parameters as `action`.

If a filter `filt` is specified, only messages matching the filter trigger
this behavior. A filter may be a message class or a function that takes the
message as an argument and returns `true` to accept, `false` to reject.

If multiple `MessageBehavior` that match a message are active, only one of them
will receive the message. The behavior to receive is the message is chosen based
on its `priority` field. Messages with filters are given higher default priority
than ones without filters.

The default `init()` for an agent automatically adds a `MessageBehavior` to
dispatch messages to a `processrequest()` or `processmessage()` method. An
agent may therefore process messages by providing methods for those functions.
However, if an agent provides its own `init()` method, it should use
`MessageBehavior` to handle incoming messages.

# Examples:
```julia
using Fjage

const MySpecialNtf = MessageClass(@__MODULE__, "MySpecialNtf")

@agent struct MyAgent end

function Fjage.init(a::MyAgent)
  add(a, MessageBehavior(MySpecialNtf) do a, b, msg
    @info "Got a special message: \$msg"
  end)
  add(a, MessageBehavior() do a, b, msg
    @info "Got a not-so-special message: \$msg"
  end)
end
```
"""
MessageBehavior(action) = MessageBehavior(nothing, nothing, nothing, nothing, false, 0, nothing, action, nothing)
MessageBehavior(action, filt) = MessageBehavior(nothing, filt, nothing, false, (filt===nothing ? 0 : -100), nothing, action, nothing)

function action(b::MessageBehavior)
  ch = Channel{Union{Message,Nothing}}(1)
  try
    b.onstart === nothing || _mutex_call(b.onstart, b.agent, b)
    _listen(b.agent, ch, b.filt, b.priority)
    while !b.done
      try
        lock(() -> notify(b.agent._processmsg, true), b.agent._processmsg)
        msg = take!(ch)
        msg === nothing || b.action === nothing ||  _mutex_call(b.action, b.agent, b, msg)
      catch ex
        reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
      end
    end
    b.onend === nothing || _mutex_call(b.onend, b.agent, b)
  catch ex
    reconnect(container(b.agent), ex) || reporterror(b.agent, ex)
  finally
    _dont_listen(b.agent, ch)
    close(ch)
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

"""
    ParameterMessageBehavior()

`ParameterMessageBehavior` simplifies the task of an agent wishing to support
parameters via `ParameterReq` and `ParameterRsp` messages. An agent providing
parameters can advertise its parameters by providing an implementation for the
`params(a)` method (or `params(a, ndx)` method for indexed parameters). The
method returns a list of name-symbol pairs. Each entry represents a parameter
with the specified name, and dispatched using the specified symbol. Get and set
requests for the parameter are dispatched to `get(a, Val(symbol))` and
`set(a, Val(symbol), value)` methods (or `get(a, Val(symbol), ndx)` and
`set(a, Val(symbol), ndx, value)` for indexed parameters). If the method isn't
defined, and an agent struct field with the same name is present, it is used to
back the parameter.

Setters should return the value that is set, so that it can be sent back to the
requesting agent. If a setter returns `nothing`, the actual value is fetched using
the getter and then sent to the requesting agent.

An agent may choose to avoid advertising specific parameters by defining
`isunlisted(Val(symbol))` method for the parameter to return `true`.
Similarly, an agent may choose to mark a parameter as read-only by defining the
`isreadonly(Val(symbol))` method for the parameter to return `true`.

Parameter change events may be captured by defining a
`onparamchange(a::Agent, b::Behavior, param, ndx, value)` method for the parameter.

The default `init()` for an agent automatically adds a `ParameterMessageBehavior` to
dispatch handle parameters for an agent, and so an agent can benefit from this
behavior without explicitly adding it. If an agent provides its own `init()`
method and wishes to support parameters, it should add this behavior during `init()`.

# Examples:
```julia
using Fjage

@agent struct MyAgent
  param1::Int = 1
  param2::Float64 = 0.0
  secret::String = "top secret message"
  x::Int = 2
end

Fjage.param(a::MyAgent) = [
  "MyAgent.param1" => :param1,    # backed by a.param1
  "MyAgent.param2" => :param2,    # backed by a.param2, but readonly
  "MyAgent.X" => :X,              # backed by getter and setter
  "MyAgent.Y" => :Y,              # backed by getter only, so readonly
  "MyAgent.secret" => :secret     # backed by a.secret, but unlisted
]

Fjage.isreadonly(a::MyAgent, ::Val{:param2}) = true
Fjage.isunlisted(a::MyAgent, ::Val{:secret}) = true

Fjage.get(a::MyAgent, ::Val{:X}) = a.x
Fjage.set(a::MyAgent, ::Val{:X}, value) = (a.x = clamp(value, 0, 10))
Fjage.get(a::MyAgent, ::Val{:Y}) = a.x + 27
```
"""
ParameterMessageBehavior() = MessageBehavior(nothing, ParameterReq, nothing, nothing, false, -100, nothing, _paramreq_action, nothing)

params(a::Agent) = Pair{String,Symbol}[]
params(a::Agent, ndx) = Pair{String,Symbol}[]

Fjage.get(a::Agent, ::Val{:type}) = string(typeof(a))
Fjage.get(a::Agent, ::Val{:title}) = string(AgentID(a))
Fjage.get(a::Agent, ::Val{:description}) = ""

onparamchange(a::Agent, b::Behavior, p, ndx, v) = nothing

function set end
function isreadonly end
function isunlisted end

function _isunlisted(a::Agent, p, ndx)
  try
    return ndx < 0 ? isunlisted(a, Val(p)) : isunlisted(a, Val(p), ndx)
  catch end
  try
    return ndx < 0 ? isunlisted(a, p) : isunlisted(a, p, ndx)
  catch end
  false
end

function _get(a::Agent, p)
  x = missing
  isro = missing
  try
    x = Fjage.get(a, Val(p))
  catch end
  try
    x === missing && (x = Fjage.get(a, p))
  catch end
  try
    if x === missing
      x = getfield(a, p)
      isro = false
    end
  catch end
  try
    isro === missing && (isro = isreadonly(a, Val(p)))
  catch end
  try
    isro === missing && (isro = isreadonly(a, p))
  catch end
  isro === missing && (isro = isempty(methods(set, [typeof(a), Val{p}, Any])))
  x, isro
end

function _get(a::Agent, p, ndx::Int)
  x = missing
  isro = missing
  try
    x = Fjage.get(a, Val(p), ndx)
  catch end
  try
    x === missing && (x = Fjage.get(a, p, ndx))
  catch end
  try
    isro = isreadonly(a, Val(p), ndx)
  catch end
  try
    isro === missing && (isro = isreadonly(a, p, ndx))
  catch end
  isro === missing && (isro = isempty(methods(set, [typeof(a), Val{p}, Int, Any])))
  x, isro
end

function _set(a::Agent, p, v)
  try
    return set(a, Val(p), v)
  catch end
  try
    return set(a, p, v)
  catch end
  try
    return setfield!(a, p, v)
  catch end
  missing
end

function _set(a::Agent, p, ndx::Int, v)
  try
    return set(a, Val(p), ndx, v)
  catch end
  try
    return set(a, p, ndx, v)
  catch end
  missing
end

function _paramreq_action(a::Agent, b::MessageBehavior, msg::ParameterReq)
  # resolve requests
  ndx = something(msg.index, -1)
  plist = ndx < 0 ? params(a) : params(a, ndx)
  req = Tuple{String,Symbol,Any}[]
  if msg.param === nothing
    push!(req, ("title", :title, nothing))
    push!(req, ("description", :description, nothing))
    for kv ∈ plist
      _isunlisted(a, kv[2], ndx) || push!(req, (kv..., nothing))
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
          x, isro = _get(a, p)
          if x !== missing && x !== nothing
            push!(rsp, q => x)
            isro && push!(ro, q)
          end
        else
          x, isro = _get(a, p, ndx)
          if x !== missing && x !== nothing
            push!(rsp, q => x)
            isro && push!(ro, q)
          end
        end
      else # set
        if ndx < 0
          isro = false
          x = _set(a, p, v)
          if x === missing || x === nothing
            x, isro = _get(a, p)
          end
          if x !== missing && x !== nothing
            push!(rsp, q => x)
            isro && push!(ro, q)
            onparamchange(a, b, q, ndx, x)
          end
        else
          isro = false
          x = _set(a, p, ndx, v)
          if x === missing || x === nothing
            x, isro = _get(a, p, ndx)
          end
          if x !== missing && x !== nothing
            push!(rsp, q => x)
            isro && push!(ro, q)
            onparamchange(a, b, q, ndx, x)
          end
        end
      end
    catch ex
      reconnect(container(a), ex) || reporterror(a, ex)
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
  for (k, v) ∈ plist
    k == p && return (k, v)
    v === psym && return (k, v)
  end
  nothing
end
