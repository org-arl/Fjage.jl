"""
Julia-fjåge gateway, standalone container, and slave container.

Notes:
- The `Gateway` is not thread-safe, and should only be used from a single task/thread.
- Containers and agents are designed to be safe to use from multiple threads.
"""
module Fjage

using Sockets, Base64, UUIDs, Dates, Logging, Random
using JSON, MacroTools, PkgVersion
using InteractiveUtils: subtypes

export BLOCKING

const BLOCKING = -1
const MAX_QUEUE_LEN = 256
const _dropped_msgs = Threads.Atomic{Int}(0)
const VERSION = @PkgVersion.Version

const timeout = Ref(1000)

"""
    default_timeout(millis)

Set default timeout for requests. This timeout is used when not explicitly
specified. The timeout is given in milliseconds.
"""
default_timeout(t) = (timeout[] = t)

include("aid.jl")
include("msg.jl")
include("const.jl")
include("gw.jl")
include("container.jl")
include("fsm.jl")
include("coroutine_behavior.jl")

function __init__()
  registermessages()
end

end
