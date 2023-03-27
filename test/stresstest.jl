print("Loading packages")
using Fjage
using GLMakie
using Dates
using Sockets
print("\r\033[K")

#########################################
# Utilities

function dead_gateway()
    # Dirty hack to create a Gateway object without starting a master container
    server = listen(2001)
    @async begin
        try
            socket = accept($server)
            try
                println(socket, "{\"action\":\"shutdown\"}")
                for _ in 1:4
                    readline(socket)
                end
            finally
                close(socket)
            end
        finally
            close($server)
        end
    end
    return Gateway("127.0.0.1", 2001, reconnect=false)
end



mutable struct CountFilter <: Function
    target::Int
    counter::Int
end

CountFilter(target) = CountFilter(target, 0)
(filter::CountFilter)(_) = (filter.counter += 1) == filter.target



#########################################
# Test

test_duration = Second(10)
n_receivers = 5
queue_numbers = [Vector{Int}() for _ in 1:n_receivers]
receive_durations = [Vector{Float64}() for _ in 1:n_receivers]
requested_timeouts = [Vector{Float64}() for _ in 1:n_receivers]
actual_timeouts = [Vector{Float64}() for _ in 1:n_receivers]

timer = Timer(test_duration)
end_time = now() + test_duration

@sync begin
    gw = dead_gateway()

    # Time monitor
    @async begin
        while isopen(timer)
            print("\rStress test running. ", ceil(end_time - now(), Second), " remaining.\033[K")
            sleep(0.1)
        end
        print("\r\033[K")
    end

    # Receivers
    for receiver in 1:n_receivers
        @async begin
            while isopen(timer)
                if rand() < 0.8
                    n = rand(1:2*Fjage.MAX_QUEUE_LEN)
                    msg, t = @timed receive(gw, CountFilter(n), BLOCKING)
                    if !isopen(timer); break; end
                    push!(queue_numbers[receiver], n)
                    push!(receive_durations[receiver], t)
                else
                    timeout = rand(1:20)
                    t = @elapsed @assert isnothing(receive(gw, msg->false, timeout))
                    push!(requested_timeouts[receiver], timeout*1e-3)
                    push!(actual_timeouts[receiver], t)
                end
            end
        end
    end

    # Sender
    msg = GenericMessage()
    while isopen(timer)
        Fjage._deliver(gw, msg, false)
        yield()
    end

    # Close pending receivers
    lock(gw.msgqueue_lock) do
        for (task,_) in gw.tasks_waiting_for_msg
            schedule(task, nothing)
        end
    end
end

print("Plotting the results")
figure = Figure()
axis = Axis(figure[1,1];
    title = "Receive duration",
    xlabel = "queue number",
    ylabel = "receive duration [sec]",
)
for receiver in 1:n_receivers
    scatter!(
        axis,
        queue_numbers[receiver],
        receive_durations[receiver],
    )
end

axis = Axis(figure[2,1];
    title = "Timeout accuracy",
    xlabel = "requested timeout [sec]",
    ylabel = "timeout accuracy[sec]",
)
for receiver in 1:n_receivers
    scatter!(
        axis,
        requested_timeouts[receiver],
        actual_timeouts[receiver] .- requested_timeouts[receiver],
    )
end
display(figure)
print("\r\033[K")
