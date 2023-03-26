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
        @assert !isnothing(receive($gw))
    end
end

mutable struct CountFilter <: Function
    target::Int
    counter::Int
end

CountFilter(target) = CountFilter(target, 0)
(filter::CountFilter)(_) = (filter.counter += 1) == filter.target

function benchmark_gateway_send_receive_full_queue()
    gw = dead_gateway()
    for _ in 1:256
        Fjage._deliver(gw, GenericMessage(), false)
    end
    @benchmark begin
        Fjage._deliver($gw, $(GenericMessage()), false)
        @assert !isnothing(receive(
            $gw,
            CountFilter(256)
        ))
    end
end

function benchmark_gateway_receive_send(n_receivers::Integer = 1)
    @assert n_receivers > 0
    gw = dead_gateway()
    done = Threads.Atomic{Bool}(false)
    @sync try
        cond = Threads.Event(true)
        for _ = 1:n_receivers-1
            @async receive(gw, msg->false, BLOCKING)
        end
        @async begin
            while !done[]
                @assert !isnothing(receive(gw, BLOCKING)) || done[]
                notify(cond)
            end
        end
        @benchmark begin
            Fjage._deliver($gw, $(GenericMessage()), false)
            wait($cond)
        end
    finally
        done[] = true
        # One more message to make sure the active receiver shuts down
        Fjage._deliver(gw, GenericMessage(), false)
        # Close all the passive receivers
        for (task,_) in gw.tasks_waiting_for_msg
            schedule(task, nothing)
        end
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
        events = (
            Threads.Event(true),
            Threads.Event(true),
        )
        @async begin
            while !done[]
                notify(events[1])
                wait(events[2])
            end
        end
        @benchmark begin
            wait($events[1])
            notify($events[2])
        end
    finally
        done[] = true
    end
end

function report_send_receive()
    for (label, bench) in (
        ("Gateway, send -> receive",                  benchmark_gateway_send_receive),
        ("Channel, send -> receive (for comparison)", benchmark_channel_send_receive),
        ("Gateway, send -> receive, full queue",      benchmark_gateway_send_receive_full_queue),
        ("Gateway, receive -> send",                  benchmark_gateway_receive_send),
        ("Channel, receive -> send (for comparison)", benchmark_channel_receive_send),
        ("Event ping pong (for comparison)",          benchmark_event_ping_pong),
        ("Gateway, receive -> send with 3 receivers", ()->benchmark_gateway_receive_send(3)),
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