"""
Julia-fjåge gateway, standalone container, and slave container.

Notes:
- This implementation is not thread-safe.
"""
module Fjage

using Sockets, Distributed, Base64, UUIDs, Dates, Logging, Random
using JSON, MacroTools, PkgVersion
using InteractiveUtils: subtypes

export BLOCKING

const BLOCKING = -1
const MAX_QUEUE_LEN = 256
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

end
