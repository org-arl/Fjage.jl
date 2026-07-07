# Container stress test — single run. See README.md. Not part of CI.
#
#   julia -t 4 --project=test/containerstress test/containerstress/stress.jl \
#     --mode standalone|slave --rate 10 --duration 20 --warmup 3 [--out results/x.json]
#
# Exit codes: 0 = clean, 1 = message loss or duplicates, 3 = watchdog fired (stall/deadlock).

using Pkg
Pkg.activate(@__DIR__)

function parse_cli(args)
  o = Dict{String,Any}(
    "mode" => "standalone", "rate" => 1.0, "duration" => 20.0, "warmup" => 3.0,
    "njulia" => 3, "njava" => 1, "churn" => false, "version" => "",
    "port" => 5082, "fjage" => normpath(joinpath(@__DIR__, "..", "..")),
    "out" => "", "label" => "")
  i = 1
  while i ≤ length(args)
    startswith(args[i], "--") || error("unexpected argument $(args[i])")
    k = args[i][3:end]
    haskey(o, k) || error("unknown option --$k")
    i < length(args) || error("missing value for --$k")
    v = args[i+1]
    o[k] = o[k] isa Bool ? lowercase(v) ∈ ("1", "true", "yes") :
           o[k] isa Float64 ? parse(Float64, v) : o[k] isa Int ? parse(Int, v) : v
    i += 2
  end
  o["mode"] ∈ ("standalone", "slave") || error("--mode must be standalone or slave")
  o
end

const OPTS = parse_cli(ARGS)

# make sure this environment's Fjage points at the requested checkout (repo root
# by default; a git worktree of another branch for A/B comparisons); crude line
# parse instead of TOML so this works before the environment is instantiated
function manifest_fjage_path()
  mf = joinpath(@__DIR__, "Manifest.toml")
  isfile(mf) || return nothing
  insection = false
  for line ∈ eachline(mf)
    s = strip(line)
    if startswith(s, "[[")
      insection = s ∈ ("[[deps.Fjage]]", "[[Fjage]]")
    elseif insection
      m = match(r"^path\s*=\s*\"(.*)\"", s)
      m === nothing || return String(m.captures[1])
    end
  end
  nothing
end

function ensure_fjage(devpath)
  devpath = realpath(abspath(devpath))
  p = manifest_fjage_path()
  p !== nothing && !isabspath(p) && (p = normpath(joinpath(@__DIR__, p)))
  if p === nothing || !ispath(p) || realpath(p) != devpath
    Pkg.develop(path=devpath)
  end
  Pkg.instantiate()
end

ensure_fjage(OPTS["fjage"])

using Fjage, JSON, Statistics
using Sockets: connect
import Downloads   # NOT `using`: Downloads exports `request`, which clashes with Fjage.request

include("messages.jl")
include("agents.jl")

const AGENT_NAMES = ["a$i" for i ∈ 1:OPTS["njulia"]]
const JAVA_NAMES = ["j$i" for i ∈ 1:OPTS["njava"]]
const JAVA_QLEN = 4096

# ---------------------------------------------------------------- watchdog

const PHASE = Ref(:setup)

function start_watchdog(agents::Vector{StressAgent}, deadline::Float64)
  @async begin
    last_hb, last_change = -1, time()
    while PHASE[] != :done
      sleep(2)
      hb = sum(sent_total(a) + recv_total(a) for a ∈ agents)
      hb == last_hb || (last_hb = hb; last_change = time())
      stalled = PHASE[] == :run && time() - last_change > 10
      if stalled || time() > deadline
        println(stderr, "\nWATCHDOG: $(stalled ? "no message progress for 10 s during run" : "overall deadline exceeded") (phase=$(PHASE[]))")
        for a ∈ agents
          println(stderr, "  $(name(a)): sent=$(sent_total(a)) recv=$(recv_total(a)) dups=$(a.dups) qlen=$(length(a._msgqueue))")
        end
        exit(3)
      end
    end
  end
end

# ---------------------------------------------------------------- java master

const GH_MAVEN = "https://maven.pkg.github.com/org-arl/fjage/com/github/org-arl/fjage"
const MAVEN_CENTRAL = "https://repo1.maven.org/maven2"
const GSON_VERSION = "2.10.1"

# GitHub Packages requires a token (scope read:packages) even for public downloads
function _github_token()
  for k ∈ ("GITHUB_TOKEN", "GH_TOKEN")
    isempty(get(ENV, k, "")) || return ENV[k]
  end
  try
    tok = strip(read(`gh auth token`, String))
    isempty(tok) || return tok
  catch
  end
  error("a GitHub token is needed to download fjage from GitHub Packages — " *
        "set GITHUB_TOKEN (scope read:packages) or run `gh auth refresh -h github.com -s read:packages`")
end

function _gh_get(url, tok, dest=IOBuffer())
  try
    Downloads.download(url, dest; headers=["Authorization" => "Bearer $tok"])
  catch e
    error("download failed for $url — if this is a 401/403, your GitHub token " *
          "lacks the read:packages scope (`gh auth refresh -h github.com -s read:packages`); ($e)")
  end
  dest
end

# fetch the current fjage release jar from the org-arl GitHub Packages registry
# (and gson, needed by its JSON protocol, from Maven Central) into lib/;
# --version pins a specific release
function ensure_jars(version)
  lib = joinpath(@__DIR__, "lib")
  mkpath(lib)
  tok = _github_token()
  if isempty(version)
    meta = String(take!(_gh_get("$GH_MAVEN/maven-metadata.xml", tok)))
    m = something(match(r"<release>([^<]+)</release>", meta),
                  match(r"<latest>([^<]+)</latest>", meta), Some(nothing))
    m === nothing && error("cannot determine current fjage release from GitHub Packages metadata")
    version = m.captures[1]
    @info "Current fjage release" version
  end
  fjage = joinpath(lib, "fjage-$version.jar")
  isfile(fjage) || _gh_get("$GH_MAVEN/$version/fjage-$version.jar", tok, fjage)
  gson = joinpath(lib, "gson-$GSON_VERSION.jar")
  isfile(gson) || Downloads.download("$MAVEN_CENTRAL/com/google/code/gson/gson/$GSON_VERSION/gson-$GSON_VERSION.jar", gson)
  fjage, gson
end

function build_java(version)
  jar, gson = ensure_jars(version)
  srcdir = joinpath(@__DIR__, "java", "org", "arl", "fjage", "stress")
  srcs = filter(endswith(".java"), readdir(srcdir; join=true))
  classes = joinpath(@__DIR__, "classes")
  clsfiles = isdir(classes) ? [joinpath(r, f) for (r, _, fs) ∈ walkdir(classes) for f ∈ fs] : String[]
  if isempty(clsfiles) || max(maximum(mtime.(srcs)), mtime(jar)) > maximum(mtime.(clsfiles))
    @info "Compiling Java sources against $(basename(jar))"
    mkpath(classes)
    run(`javac -cp $jar -d $classes $srcs`)
  end
  join([jar, gson, classes], ":")
end

function launch_master(cp, port, njava)
  mkpath(joinpath(@__DIR__, "logs"))
  log = open(joinpath(@__DIR__, "logs", "master-$port.log"), "w")
  proc = run(pipeline(`java -Xmx2g -cp $cp org.arl.fjage.stress.StressBoot $port $njava $JAVA_QLEN`; stdout=log, stderr=log); wait=false)
  atexit(() -> process_running(proc) && kill(proc))
  t0 = time()
  while time() - t0 < 15
    process_running(proc) || error("java master died on startup — see logs/master-$port.log")
    try
      close(connect("localhost", port))
      return proc
    catch
      sleep(0.5)
    end
  end
  error("java master did not open port $port within 15 s")
end

function ctl_request(ctl, msg; tries=10, timeout=2000)
  for _ ∈ 1:tries
    rsp = request(ctl, clone(msg), timeout)
    rsp === nothing || return rsp
  end
  nothing
end

# ---------------------------------------------------------------- stats & tally

function latsummary(v::Vector{Int64})
  isempty(v) && return Dict("n" => 0)
  s = sort(v)
  Dict("n" => length(s), "min" => s[1], "mean" => round(mean(s); digits=2),
       "median" => median(s), "p95" => s[max(1, ceil(Int, 0.95length(s)))], "max" => s[end])
end

function snapshot(a::StressAgent)
  recv = Dict("$s/$st" => length(bs) for ((s, st), bs) ∈ a.seen)
  # a secondary whose task never terminated after stop() keeps its agent field
  # set — the signature of a frozen (lost-wakeup) behavior
  churn = Dict("adds" => a.churn_adds, "removes" => a.churn_removes,
               "stuck" => count(sb -> sb.agent !== nothing, a.spawned))
  Dict("sent_b" => a.bcast_sent, "sent_d" => copy(a.dm_sent), "recv" => recv,
       "dups" => a.dups, "send_fail" => a.send_fail, "lat" => latsummary(a.latencies),
       "churn" => churn)
end

function snapshot(s::StressStats)
  recv = Dict{String,Int64}()
  for (i, sn) ∈ enumerate(s.senders)
    recv["$sn/b"] = s.recvBcast[i]
    recv["$sn/d"] = s.recvDm[i]
  end
  lat = s.latN == 0 ? Dict("n" => 0) :
    Dict("n" => s.latN, "min" => s.latMin, "mean" => round(s.latSum / s.latN; digits=2), "max" => s.latMax)
  Dict("sent_b" => s.bcastSent, "sent_d" => Dict{String,Int64}(zip(s.dmPeers, s.dmSent)),
       "recv" => recv, "dups" => s.dups, "send_fail" => 0, "lat" => lat)
end

function tally(stats)
  rows, tot_exp, tot_got = [], 0, 0
  for r ∈ sort(collect(keys(stats))), s ∈ sort(collect(keys(stats)))
    r == s && continue
    for (stream, expected) ∈ (("b", stats[s]["sent_b"]), ("d", get(stats[s]["sent_d"], r, 0)))
      got = get(stats[r]["recv"], "$s/$stream", 0)
      expected == 0 && got == 0 && continue
      push!(rows, Dict("receiver" => r, "sender" => s, "stream" => stream,
                       "expected" => expected, "got" => got, "missing" => expected - got))
      tot_exp += expected
      tot_got += got
    end
  end
  dups = sum(st["dups"] for st ∈ values(stats))
  send_fail = sum(st["send_fail"] for st ∈ values(stats))
  loss_pct = tot_exp == 0 ? 0.0 : round(100 * (tot_exp - tot_got) / tot_exp; digits=3)
  # inbox-overflow drop counter, present only when src is instrumented
  drops = isdefined(Fjage, :_dropped_msgs) ? Fjage._dropped_msgs[] : -1
  sent_total = sum(st["sent_b"] + sum(values(st["sent_d"]); init=0) for st ∈ values(stats))
  stuck = sum(get(get(st, "churn", Dict()), "stuck", 0) for st ∈ values(stats))
  rows, Dict("expected" => tot_exp, "got" => tot_got, "missing" => tot_exp - tot_got,
             "dups" => dups, "send_fail" => send_fail, "loss_pct" => loss_pct,
             "inbox_drops" => drops, "sent_total" => sent_total,
             "stuck_behaviors" => stuck)
end

function report(stats, rows, totals)
  bad = [row for row ∈ rows if row["missing"] != 0]
  println("\n─ per-pair ledger (rows with discrepancies; $(length(rows) - length(bad)) clean pairs suppressed) " * "─"^10)
  println(rpad("receiver", 10), rpad("sender", 10), rpad("stream", 8),
          lpad("expected", 10), lpad("got", 10), lpad("missing", 10))
  for row ∈ first(bad, 100)
    println(rpad(row["receiver"], 10), rpad(row["sender"], 10), rpad(row["stream"], 8),
            lpad(row["expected"], 10), lpad(row["got"], 10), lpad(row["missing"], 10))
  end
  length(bad) > 100 && println("… $(length(bad) - 100) more rows with discrepancies")
  println("\n─ latency (ms, post-warmup) " * "─"^45)
  for n ∈ sort(collect(keys(stats)))
    lat = stats[n]["lat"]
    print(rpad(n, 10))
    if lat["n"] == 0
      println("no samples")
    else
      for k ∈ ("n", "min", "mean", "median", "p95", "max")
        haskey(lat, k) && print("$k=$(lat[k])  ")
      end
      println()
    end
  end
  println("\n─ totals " * "─"^64)
  println("expected=$(totals["expected"]) got=$(totals["got"]) missing=$(totals["missing"]) " *
          "dups=$(totals["dups"]) send_fail=$(totals["send_fail"]) loss=$(totals["loss_pct"])%" *
          (totals["inbox_drops"] < 0 ? "" : " inbox_drops=$(totals["inbox_drops"])") *
          " stuck_behaviors=$(totals["stuck_behaviors"])")
end

# ---------------------------------------------------------------- runs

# in churn mode, stop all live secondaries and give their tasks a moment to
# terminate, so the stuck-behavior count in the snapshots is meaningful
function settle_churn!(agents::Vector{StressAgent}, churn)
  churn || return
  foreach(a -> foreach(stop, a.secondaries), agents)
  sleep(2)
end

# senders must not start before every agent has subscribed (and, in slave mode,
# the watch list has propagated to the master), else head-of-stream messages are
# legitimately undeliverable and would show up as false loss
function waitready(agents::Vector{StressAgent}; timeout=10.0)
  t0 = time()
  while !all(a -> a.ready, agents)
    time() - t0 > timeout && error("agents not ready within $(timeout) s")
    sleep(0.1)
  end
end

function run_traffic!(agents::Vector{StressAgent}, warmup, duration)
  latfrom = unixms() + round(Int64, 1000warmup)
  for a ∈ agents
    a.lat_from = latfrom
    a.active = true
  end
  PHASE[] = :run
  sleep(warmup + duration)
  foreach(a -> a.active = false, agents)
  PHASE[] = :drain
end

function drain!(agents::Vector{StressAgent}; cap=60.0)
  t0, last, stable = time(), -1, time()
  while time() - t0 < cap
    tot = sum(recv_total(a) for a ∈ agents)
    tot == last || (last = tot; stable = time())
    time() - stable ≥ 3 && time() - t0 ≥ 3 && return
    sleep(0.5)
  end
end

# Java agents drain on their own schedule; poll stats until their receive totals
# stop moving so the final snapshot is quiescent
function collect_java_stats(ctl, names)
  cur, prevtot = Dict{String,StressStats}(), -1
  for _ ∈ 1:10
    for j ∈ names
      s = ctl_request(ctl, StressCtl(recipient=AgentID(j), cmd="stats"); timeout=5000)
      s isa StressStats || error("no stats from $j (got $(s))")
      cur[j] = s
    end
    tot = sum(s.dups + sum(s.recvBcast) + sum(s.recvDm) for s ∈ values(cur))
    tot == prevtot && return cur
    prevtot = tot
    sleep(2)
  end
  @warn "Java-side receive counts still moving after 10 stats sweeps — using last snapshot"
  cur
end

function run_standalone(o)
  p = RealTimePlatform()
  c = Container(p, "stress")
  agents = [StressAgent(rate=o["rate"], peers=setdiff(AGENT_NAMES, [n]), churn=o["churn"]) for n ∈ AGENT_NAMES]
  foreach((n, a) -> add(c, n, a), AGENT_NAMES, agents)
  start_watchdog(agents, time() + o["warmup"] + o["duration"] + 60)
  start(p)
  waitready(agents)
  run_traffic!(agents, o["warmup"], o["duration"])
  drain!(agents)
  settle_churn!(agents, o["churn"])
  PHASE[] = :tally
  stats = Dict(n => snapshot(a) for (n, a) ∈ zip(AGENT_NAMES, agents))
  stats, () -> shutdown(p)
end

function run_slave(o)
  cp = build_java(o["version"])
  proc = launch_master(cp, o["port"], o["njava"])
  p = RealTimePlatform()
  c = SlaveContainer(p, "localhost", o["port"], "jslave"; reconnect=false)
  agents = [StressAgent(rate=o["rate"], peers=[setdiff(AGENT_NAMES, [n]); JAVA_NAMES], churn=o["churn"]) for n ∈ AGENT_NAMES]
  foreach((n, a) -> add(c, n, a), AGENT_NAMES, agents)
  ctl = CtlAgent()
  add(c, "ctl", ctl)
  start_watchdog(agents, time() + o["warmup"] + o["duration"] + 180)
  start(p)
  try
    waitready(agents)
    for j ∈ JAVA_NAMES
      rsp = ctl_request(ctl, StressCtl(recipient=AgentID(j), cmd="start", rate=o["rate"],
                                       warmup=round(Int64, 1000o["warmup"]), churn=o["churn"],
                                       peers=[AGENT_NAMES; setdiff(JAVA_NAMES, [j])]))
      (rsp !== nothing && rsp.performative == Performative.AGREE) ||
        error("$j did not acknowledge start (got $(rsp))")
    end
    run_traffic!(agents, o["warmup"], o["duration"])
    for j ∈ JAVA_NAMES
      rsp = ctl_request(ctl, StressCtl(recipient=AgentID(j), cmd="stop"))
      rsp === nothing && @warn "$j did not acknowledge stop"
    end
    drain!(agents)
    settle_churn!(agents, o["churn"])
    PHASE[] = :tally
    jstats = collect_java_stats(ctl, JAVA_NAMES)
    stats = Dict{String,Any}(n => snapshot(a) for (n, a) ∈ zip(AGENT_NAMES, agents))
    for (j, s) ∈ jstats
      stats[j] = snapshot(s)
    end
    return stats, () -> (shutdown(p); process_running(proc) && kill(proc))
  catch
    process_running(proc) && kill(proc)
    rethrow()
  end
end

function main(o)
  @info "Container stress test" mode=o["mode"] rate=o["rate"] duration=o["duration"] warmup=o["warmup"] fjage=o["fjage"] threads=Threads.nthreads()
  stats, cleanup = o["mode"] == "standalone" ? run_standalone(o) : run_slave(o)
  PHASE[] = :done
  rows, totals = tally(stats)
  report(stats, rows, totals)
  clean = totals["missing"] == 0 && totals["dups"] == 0 && totals["send_fail"] == 0
  println(clean ? "\nPASS: everyone got everything." : "\nFAIL: discrepancies found.")
  # best-effort shutdown AFTER results are safe in memory: on master, shutdown can
  # deadlock (the bug fixed by #36) and must not take the run's data down with it
  ct = @async try
    cleanup()
  catch
  end
  for _ ∈ 1:20
    istaskdone(ct) && break
    sleep(0.5)
  end
  shutdown_clean = istaskdone(ct)
  shutdown_clean || println("WARNING: container shutdown did not complete within 10 s (shutdown deadlock?) — exiting anyway")
  if !isempty(o["out"])
    branch = try
      strip(read(`git -C $(o["fjage"]) rev-parse --abbrev-ref HEAD`, String))
    catch
      "?"
    end
    mkpath(dirname(abspath(o["out"])))
    result = Dict("mode" => o["mode"], "rate" => o["rate"], "duration" => o["duration"],
                  "warmup" => o["warmup"], "label" => o["label"], "branch" => branch,
                  "threads" => Threads.nthreads(), "agents" => stats, "pairs" => rows,
                  "totals" => totals, "shutdown_clean" => shutdown_clean,
                  "status" => clean ? "ok" : "loss")
    open(f -> JSON.print(f, result, 2), o["out"], "w")
    @info "Results written" out=o["out"]
  end
  exit(clean ? 0 : 1)
end

main(OPTS)
