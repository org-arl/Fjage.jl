"""
Julia-fjåge Gateway.

Notes:
- This implementation is not thread-safe.
- Gateway does not automatically reconnect if connection to server is lost.

# Examples

Assuming fjåge master container is running on `localhost` at port 1100:

```julia-repl
julia> using Fjage
julia> gw = Gateway("localhost", 1100);
julia> shell = agentforservice(gw, "org.arl.fjage.shell.Services.SHELL")
shell
julia> shell.language
"Groovy"
julia> request(gw, ShellExecReq(recipient=shell, cmd="ps"))
AGREE
julia> request(shell, ShellExecReq(cmd="ps"))
AGREE
julia> shell << ShellExecReq(cmd="ps")
AGREE
julia> close(gw)
```
"""
module Fjage

using Sockets, Distributed, Base64, UUIDs, Dates, JSON, MacroTools

export Performative, AgentID, Gateway, Message, GenericMessage, MessageClass, AbstractMessageClass, ParameterReq, ParameterRsp, ShellExecReq
export agent, topic, send, receive, request, agentforservice, agentsforservice, subscribe, unsubscribe, BLOCKING

export RealTimePlatform, currenttimemillis, nanotime, delay, containers, isrunning, add, start, shutdown
export Container, containsagent, canlocate, agent, platform, ps
export Agent, @agent, init, container
export Behavior, done, priority, block, restart, stop
export OneShotBehavior, CyclicBehavior, WakerBehavior, TickerBehavior, MessageBehavior

const MAX_QUEUE_LEN = 256
const BLOCKING = -1

include("core.jl")
include("gw.jl")
include("container.jl")

end
