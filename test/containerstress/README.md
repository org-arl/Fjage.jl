# Container stress test

Stress test for `StandaloneContainer` and `SlaveContainer` message delivery.
**Not part of CI** — nothing in `test/runtests.jl` references this folder.

## What it does

N Julia agents (default 3) generate traffic at a configurable Poisson rate; every
send is a 50/50 mix of a broadcast to the shared topic `stress` and a directed
message to a random peer. In `slave` mode the Julia agents live in a
`SlaveContainer` attached to a Java fjåge master hosting M additional Java
participants (default 1). Every agent keeps an exact ledger of what it sent and
received — contiguous sequence numbers per (sender, stream) — and at the end
everything is tallied: any missing message, duplicate, failed send, or stuck
behavior makes the run FAIL (exit 1).

- **Latency**: per-message delivery time (wall-clock ms, common Unix-epoch clock
  across Julia and Java), collected only after a warmup period so Julia JIT
  compilation does not skew the statistics; reported as min/mean/median/p95/max.
- **Loss attribution**: `Fjage._dropped_msgs` counts messages silently dropped on
  inbox overflow (`MAX_QUEUE_LEN`), so overflow loss is distinguishable from
  delivery bugs (`inbox_drops` in the tally should equal `missing`).
- **Watchdog**: terminates the run (exit 3) if message counters stall mid-run or
  the overall deadline is exceeded, so deadlocks do not hang forever. Results are
  tallied and written *before* container shutdown is attempted, and shutdown is
  bounded (10 s), so a shutdown deadlock cannot destroy the run's data.
- **Churn mode** (`--churn true`): targets the behavior lifecycle — each agent's
  primary behavior only *adds/removes* secondary sender behaviors at random
  (~2 events/s, 0–6 live), and the secondaries generate the traffic (each at
  rate/3). Stopping behaviors that are mid-`block()` exercises the
  block/restart/stop protocol continuously; secondaries whose task never
  terminates after `stop()` are reported as `stuck_behaviors`.
- The Java side is plain Java (`java/org/arl/fjage/stress/`), compiled on the fly
  with `javac` against the **latest released fjage jar**, which is downloaded
  automatically from Maven Central into `lib/` on first run (pin a version with
  `--version x.y.z`). The Java agents are message-controlled (`StressCtl`
  start/stop/stats), so one binary serves all configurations.

## Requirements

- Julia (run with several threads, e.g. `-t 8` — the races this hunts are
  thread-sensitive).
- JDK 8+ (`javac`, `java`) and internet access on first run, for slave mode.

## Single run

```sh
julia -t 8 --project=test/containerstress test/containerstress/stress.jl \
  --mode standalone --rate 10 --duration 20 --warmup 3
julia -t 8 --project=test/containerstress test/containerstress/stress.jl \
  --mode slave --njulia 20 --njava 20 --rate 10 --duration 120 --churn true
```

| option | default | meaning |
|---|---|---|
| `--mode` | standalone | `standalone` (Julia only) or `slave` (+ Java master) |
| `--rate` | 1 | msgs/agent/s, Poisson mean (practical ceiling ~1000/s: integer-ms ticks) |
| `--duration` | 20 | seconds of measured traffic, after warmup |
| `--warmup` | 3 | seconds before latency collection starts |
| `--njulia` / `--njava` | 3 / 1 | number of Julia / Java agents |
| `--churn` | false | behavior add/remove churn mode (see above) |
| `--version` | latest | fjage release to test against |
| `--fjage` | this repo | path to the Fjage.jl checkout to test (point at a git worktree to compare branches) |
| `--port` | 5082 | master port (distinct from the 5081 used by `make test`) |
| `--out` / `--label` | — | JSON results file and tag stored in it |

Exit codes: 0 = clean; 1 = loss/dups/send-failures/stuck behaviors; 3 = watchdog.

## Load ladder & branch comparison

```sh
julia --project=test/containerstress test/containerstress/campaign.jl \
  --mode slave --label mybranch --rates 1,10,100,1000 --duration 120

git worktree add /tmp/fjage-master master
julia --project=test/containerstress test/containerstress/campaign.jl \
  --mode slave --label master --fjage /tmp/fjage-master

julia --project=test/containerstress test/containerstress/collate.jl
```

The ladder runs the rates ascending and stops escalating after >20% loss or a
watchdog abort. `collate.jl` prints a markdown table comparing all labels found
in `results/`.

## Interpreting results

- Agents ignore their own topic broadcasts (a fjåge topic subscriber receives its
  own messages), so "everyone got everything" means everything *from the others*.
- Loss with `inbox_drops == missing` is queue overflow (offered load exceeds
  sustainable throughput), not a delivery bug. Longer queues only absorb bursts;
  under sustained overload they *increase* latency and loss (the message loop
  sweeps the whole queue under a lock on every wake).
- Achieved send rate (`sent_total / duration / agents`) can be well below the
  nominal `--rate` under CPU contention; the ledger is always exact regardless.

See `FINDINGS.md` for results collected with this harness.
