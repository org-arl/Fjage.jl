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

using Sockets, Distributed, Base64, UUIDs, Dates, Logging, Random
using JSON, MacroTools, PkgVersion
using InteractiveUtils: subtypes

export BLOCKING

const BLOCKING = -1
const MAX_QUEUE_LEN = 256
const VERSION = @PkgVersion.Version

include("aid.jl")
include("msg.jl")
include("const.jl")
include("gw.jl")
include("container.jl")

end
