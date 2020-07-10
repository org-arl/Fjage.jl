![](https://github.com/org-arl/Fjage.jl/workflows/CI/badge.svg)<br>
_fjåge v1.7.0_

# Fjåge Julia gateway

Julia gateway that can connect to the [fjåge](https://github.com/org-arl/fjage) agent framework.

## Installation

In Julia REPL:
```julia
julia> # press "]" to enter package manager
pkg> add https://github.com/org-arl/Fjage.jl
```

## Example usage

In Julia REPL:
```julia
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

For more details, see help (press "?" in Julia REPL) for `Fjage`, and the [fjåge gateway API specifications](https://github.com/org-arl/fjage/blob/master/gateways/Gateways.md).
