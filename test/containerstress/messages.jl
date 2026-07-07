# Typed wire messages shared by the Julia agents and the Java jagent.
# Class names must match the Java classes in java/org/arl/fjage/stress/ exactly.

@message "org.arl.fjage.stress.StressMsg" struct StressMsg
  stream::String = "b"    # "b" = broadcast, "d" = directed
  seq::Int64 = 0          # 1-based, contiguous per (sender, stream[, recipient])
  t0::Int64 = 0           # sender wall-clock ms, for latency measurement
end

@message "org.arl.fjage.stress.StressCtl" Performative.REQUEST struct StressCtl
  cmd::String = ""        # "start" | "stop" | "stats"
  rate::Float64 = 1.0     # msgs/agent/s (mean), for "start"
  warmup::Int64 = 0       # ms before latency collection begins, for "start"
  churn::Bool = false     # secondary-behavior churn mode, for "start"
  peers::Vector{String} = String[]
end

@message "org.arl.fjage.stress.StressStats" struct StressStats
  bcastSent::Int64 = 0
  dmPeers::Vector{String} = String[]
  dmSent::Vector{Int64} = Int64[]
  senders::Vector{String} = String[]
  recvBcast::Vector{Int64} = Int64[]
  recvDm::Vector{Int64} = Int64[]
  dups::Int64 = 0
  latN::Int64 = 0
  latSum::Int64 = 0
  latMin::Int64 = 0
  latMax::Int64 = 0
end
