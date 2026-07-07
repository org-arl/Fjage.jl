# Collate results/*.json from stress.jl runs into a comparison table
# (rows: mode × rate; columns: one group per label/branch).

using Pkg
Pkg.activate(@__DIR__)
using JSON

dir = joinpath(@__DIR__, "results")
isdir(dir) || error("no results/ directory — run campaign.jl first")
runs = [JSON.parsefile(f) for f ∈ readdir(dir; join=true) if endswith(f, ".json")]
isempty(runs) && error("no results found in $dir")

labels = sort(unique(r["label"] for r ∈ runs))
keyof(r) = (r["mode"], r["rate"])
combos = sort(unique(keyof.(runs)))

function latfield(r, f)
  lats = [a["lat"][f] for a ∈ values(r["agents"]) if haskey(a["lat"], f)]
  isempty(lats) ? "-" : string(round(sum(lats) / length(lats); digits=1))
end

cols = ["loss%", "miss", "dups", "lat-mean", "lat-max", "status"]
header = "| mode | rate |" * join((" $l $c |" for l ∈ labels for c ∈ cols))
println(header)
println("|" * join(("---|" for _ ∈ 1:(2 + length(labels) * length(cols)))))
for (mode, rate) ∈ combos
  row = "| $mode | $rate |"
  for l ∈ labels
    sel = [r for r ∈ runs if r["label"] == l && keyof(r) == (mode, rate)]
    if isempty(sel)
      row *= join((" - |" for _ ∈ cols))
    else
      r = last(sel)
      t = r["totals"]
      status = r["status"] * (get(r, "shutdown_clean", true) ? "" : "+shutdown-deadlock")
      row *= " $(t["loss_pct"]) | $(t["missing"]) | $(t["dups"]) | $(latfield(r, "mean")) | $(latfield(r, "max")) | $status |"
    end
  end
  println(row)
end
