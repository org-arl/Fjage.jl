# Gateway

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

For more information, see [fjåge gateway API specifications](https://github.com/org-arl/fjage/blob/master/gateways/Gateways.md).

## Gateway API documentation

```@autodocs
Modules = [Fjage]
Pages   = ["gw.jl"]
```
