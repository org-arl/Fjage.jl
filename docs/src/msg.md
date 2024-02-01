# Messages

Messages are data containers that carry information between agents. When
interacting with Java/Groovy agents, messages are mapped to Java/Groovy
message classes with fields with the same name as the keys in the message.

Message types are defined using the `@message` macro. For example:
```julia
@message "org.arl.fjage.shell.ShellExecReq" struct ShellExecReq
  cmd::Union{String,Nothing} = nothing
  script::Union{String,Nothing} = nothing
  args::Vector{String} = String[]
  ans::Bool = false
end
```
defines a `ShellExecReq` message type that maps to a Java class with the
package `org.arl.fjage.shell.ShellExecReq`.

All messages are mutable. The `@message` macro also automatically adds a few fields:

- `performative::Symbol`
- `messageID::String`
- `inReplyTo::String`
- `sender::AgentID`
- `recipient::AgentID`
- `sentAt::Int64`

Messages can subtype other messages:
```julia
julia> abstract type MyAbstractMessage <: Message end

julia> @message "org.arl.fjage.demo.MyConcreteMessage" struct MyConcreteMessage <: MyAbstractMessage
        a::Int
      end

julia> MyConcreteMessage(a=1)
MyConcreteMessage:INFORM[a:1]

julia> MyConcreteMessage(a=1) isa MyAbstractMessage
true
```

It is also possible to have a concrete message type that can also be a supertype
of another message:
```julia
julia> abstract type SomeMessage <: Message end

julia> @message "org.arl.fjage.demo.SomeMessage" struct SomeMessage <: SomeMessage
        a::Int
      end

julia> @message "org.arl.fjage.demo.SomeExtMessage" struct SomeExtMessage <: SomeMessage
        a::Int
        b::Int
      end

julia> SomeMessage(a=1) isa SomeMessage
true

julia> SomeExtMessage(a=1, b=2) isa SomeMessage
true
```

Performatives are guessed automatically based on message classname. By default,
the performative is `Performative.INFORM`. If a message classname ends with a
`Req`, the default performative changes to `Performative.REQUEST`. Performatives
may be overridden at declaration or at construction (and are mutable):
```julia
julia> @message "org.arl.fjage.demo.SomeReq" struct SomeReq end;
julia> @message "org.arl.fjage.demo.SomeRsp" Performative.AGREE struct SomeRsp end;

julia> SomeReq().performative
:REQUEST

julia> SomeRsp().performative
:AGREE

julia> SomeRsp(performative=Performative.INFORM).performative
:INFORM
```

When strict typing is not required, one can use the dictionary-like
`GenericMessage` message type:
```julia
julia> msg = GenericMessage("org.arl.fjage.demo.DynamicMessage")
DynamicMessage:INFORM

julia> msg.a = 1
1

julia> msg.b = "xyz"
"xyz"

julia> msg
DynamicMessage:INFORM[a:1 b:"xyz"]

julia> classname(msg)
"org.arl.fjage.demo.DynamicMessage"

julia> msg isa GenericMessage
true
```

## API

```@autodocs
Modules = [Fjage]
Pages   = ["msg.jl"]
```
