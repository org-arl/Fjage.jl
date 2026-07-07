# Load-ladder runner: runs stress.jl at increasing rates in fresh Julia processes,
# stopping the ladder if loss exceeds 20% (per INSTRUCTIONS.md). Not part of CI.
#
#   julia --project=test/containerstress test/containerstress/campaign.jl \
#     --mode standalone --label fix-block-race [--fjage <path>] [--rates 1,10,100,1000]

using Pkg
Pkg.activate(@__DIR__)
using JSON

function parse_cli(args)
  o = Dict{String,Any}(
    "mode" => "standalone", "label" => "unlabeled", "rates" => "1,10,100,1000",
    "duration" => 20.0, "warmup" => 3.0, "port" => 5082, "njulia" => 3, "njava" => 1,
    "fjage" => normpath(joinpath(@__DIR__, "..", "..")))
  i = 1
  while i ≤ length(args)
    startswith(args[i], "--") || error("unexpected argument $(args[i])")
    k = args[i][3:end]
    haskey(o, k) || error("unknown option --$k")
    o[k] = o[k] isa Float64 ? parse(Float64, args[i+1]) : o[k] isa Int ? parse(Int, args[i+1]) : args[i+1]
    i += 2
  end
  o
end

o = parse_cli(ARGS)
rates = parse.(Float64, split(o["rates"], ","))
mkpath(joinpath(@__DIR__, "results"))

for rate ∈ sort(rates)
  rlabel = rate == round(rate) ? string(round(Int, rate)) : string(rate)
  out = joinpath(@__DIR__, "results", "$(o["label"])-$(o["mode"])-$(rlabel).json")
  @info "Running" mode=o["mode"] rate=rate label=o["label"]
  cmd = `$(Base.julia_cmd()) -t 4 --project=$(@__DIR__) $(joinpath(@__DIR__, "stress.jl"))
         --mode $(o["mode"]) --rate $rate --duration $(o["duration"]) --warmup $(o["warmup"])
         --njulia $(o["njulia"]) --njava $(o["njava"])
         --port $(o["port"]) --fjage $(o["fjage"]) --label $(o["label"]) --out $out`
  proc = run(ignorestatus(cmd))
  if proc.exitcode == 3
    @error "Watchdog fired (stall/deadlock) at rate $rate — stopping ladder"
    break
  end
  if !isfile(out)
    @error "No results written at rate $rate (exit $(proc.exitcode)) — stopping ladder"
    break
  end
  loss = JSON.parsefile(out)["totals"]["loss_pct"]
  @info "Completed" rate=rate loss_pct=loss exitcode=proc.exitcode
  if loss > 20
    @warn "Loss $(loss)% > 20% at rate $rate — not escalating further"
    break
  end
end
