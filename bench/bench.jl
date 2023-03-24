using Fjage
using Sockets
using BenchmarkTools

function dead_gateway()
    # Dirty hack to create a Gateway object without starting a master container
    t = @async begin
        server = listen(2001)
        try
            socket = accept(server)
            try
                println(socket, "{\"action\":\"shutdown\"}")
                for _ in 1:4
                    readline(socket)
                end
            finally
                close(socket)
            end
        finally
            close(server)
        end
    end
    return Gateway("127.0.0.1", 2001, reconnect=false)
end

function benchmark_gateway_send_receive()
    gw = dead_gateway()
    @benchmark begin
        Fjage._deliver($gw, $(GenericMessage()), false)
        receive($gw)
    end
end

function benchmark_gateway_receive_send()
    gw = dead_gateway()
    done = Threads.Atomic{Bool}(false)
    try
        cond = Threads.Event(true)
        @async begin
            while !done[]
                receive(gw, BLOCKING)
                notify(cond)
            end
        end
        @benchmark begin
            Fjage._deliver($gw, $(GenericMessage()), false)
            wait($cond)
        end
    finally
        done[] = true
    end
end

function benchmark_channel_send_receive()
    ch = Channel{Any}(Inf)
    @benchmark begin
        put!($ch, $(GenericMessage()))
        take!($ch)
    end
end

function benchmark_channel_receive_send()
    ch = Channel{Any}(Inf)
    done = Threads.Atomic{Bool}(false)
    try
        cond = Threads.Event(true)
        @async begin
            while !done[]
                take!(ch)
                notify(cond)
            end
        end
        @benchmark begin
            put!($ch, $(GenericMessage()))
            wait($cond)
        end
    finally
        done[] = true
    end
end

function benchmark_event_ping_pong()
    done = Threads.Atomic{Bool}(false)
    try
        cond = Threads.Event(true)
        @async begin
            while !done[]
                notify(cond)
                wait(cond)
            end
        end
        @benchmark begin
            wait($cond)
            notify($cond)
        end
    finally
        done[] = true
    end
end

function report_send_receive()
    for (label, bench) in (
        ("Gateway, send -> receive",                  benchmark_gateway_send_receive),
        ("Channel, send -> receive (for comparison)", benchmark_channel_send_receive),
        ("Gateway, receive -> send",                  benchmark_gateway_receive_send),
        ("Channel, receive -> send (for comparison)", benchmark_channel_receive_send),
        ("Event ping pong (for comparison)",          benchmark_event_ping_pong),
    )
        println()
        printstyled("-"^length(label), "\n"; bold = true)
        printstyled(label, "\n"; bold = true)
        printstyled("-"^length(label), "\n"; bold = true)
        println()
        display(bench())
        println()
    end
end