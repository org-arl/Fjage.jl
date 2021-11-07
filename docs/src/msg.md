# Messages

Messages are dictionary-like containers that carry information between agents.
Keys can be accessed on messages using the property notation (`msg.key`), and
keys that are absent yield `nothing`. When interacting with Java/Groovy agents,
messages are mapped to Java/Groovy message classes with fields with the same
name as the keys in the message.

Message types are defined using the `MessageClass` function. For example:
```julia
const ShellExecReq = MessageClass(@__MODULE__, "org.arl.fjage.shell.ShellExecReq")
```
defines a `ShellExecReq` message type that maps to a Java class with the
package `org.arl.fjage.shell.ShellExecReq`.

## API

```@autodocs
Modules = [Fjage]
Pages   = ["msg.jl"]
```
