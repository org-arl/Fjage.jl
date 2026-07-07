# Stress-test findings (2026-07-07)

Comparison of `master` before PR #51 ("pre-#51") against the PR #51 branch
(`fix-block-race`, "post-#51") using this harness. Machine: macOS arm64, JDK 8,
Julia with 4–8 threads. All loss numbers come from the exact per-(receiver,
sender, stream) sequence-number ledger; `inbox_drops` is the overflow counter at
the `MAX_QUEUE_LEN` drop site. Java side: fjåge 2.4.2 (local build; the harness
now defaults to the latest Maven Central release).

## Headline

| | pre-#51 (master) | post-#51 |
|---|---|---|
| steady-state delivery (all scales/rates tested) | 0 loss, 0 dups | 0 loss, 0 dups |
| container shutdown under load | **deadlocks** (14/15 runs, even at 1 msg/agent/s) | clean, every run |
| filtered `MessageBehavior(action, filt)` | **broken** (`MethodError`: 8 args to 9-field struct) | works |
| behavior churn (10k stop/add cycles under load) | no mid-run failure observed; shutdown deadlock | fully clean |
| saturation behavior (overload) | overflow loss, statistically identical to post-#51 at equal queue length | overflow loss, `drops == missing` |

**Conclusion: PR #51's fixes eliminate the shutdown deadlock and the broken
filtered-behavior constructor with no measurable performance cost.** The mid-run
block/restart races that PR #51 also fixes have µs-wide windows per event; they
were not caught in ~10k churn events per 2-minute run (the deterministic
regression tests added in PR #51 cover them instead).

## 3 Julia agents (+1 Java in slave mode), rate ladder, 20 s, queue 256

| mode | rate | post-#51 loss | post-#51 lat med/p95/max (ms) | pre-#51 loss | pre-#51 status |
|---|---|---|---|---|---|
| standalone | 1–100 | 0% | 0 / 1 / 1 | 0% | shutdown deadlock (except rate 1) |
| standalone | 1000 (~550/s ach.) | 0% | 0 / 1 / 8 | 0% | shutdown deadlock |
| slave | 1–100 | 0% | 1 / 2 / 20 | 0% | shutdown deadlock |
| slave | 1000 (~600/s ach.) | 0.02% = proven overflow¹ | 1 / 2 / 24 | 0% | shutdown deadlock |

¹ Intermittent (≈1 in 4 runs): `inbox_drops` matched the missing count exactly and
the loss disappeared with a longer queue — burst overflow, not a delivery bug.

## 40 agents (40 Julia standalone; 20 Julia + 20 Java slave), 120 s

Clean through ~1M pair-deliveries per run at 10 msg/agent/s on both branches
(post-#51 shown; latency med/p95 ≈ 1.4–1.9 / 3–4 ms). At 100 msg/agent/s the
offered load (~78–156k deliveries/s) exceeds the machine's sustainable throughput
(~21k/s) and overflow loss appears — 49% (slave) / 84% (standalone) — with
`drops == missing`, zero dups, and clean post-#51 shutdowns throughout. The
higher standalone loss is expected: slave mode offloads half the agents and all
their receive fan-out to the JVM.

## Behavior churn (secondaries generate traffic; primaries add/remove them)

10 msg/agent/s, 120 s, `-t 8`, ~2 lifecycle events/s/agent (0–6 live secondaries):

| config | branch | deliveries | loss | stuck behaviors | shutdown |
|---|---|---|---|---|---|
| standalone 40 | post-#51 | 956,043 | 0 | 0 | clean |
| slave 20+20 | post-#51 | 913,371 | 0 | 0 | clean |
| standalone 40 | pre-#51 | 938,458 | 0 | 0 | **deadlock** |
| slave 20+20 | pre-#51 | 965,881 | 0 | 0 | **deadlock** |

At 5× load (50 msg/agent/s, saturated), correctness still held on both branches
(all loss = overflow, 0 dups, 0 stuck), and a control run showed the branches are
statistically identical at equal queue length: post-#51 44.5% loss / 44.8 msg/s
achieved / 268 ms median latency vs pre-#51 47.2% / 45.0 / 276 ms.

## Queue-length insight

Running the saturated standalone-40 case with `MAX_QUEUE_LEN` 4096 instead of 256
made things much worse: 81% vs 44% loss, 27% lower achieved send rate, ~20×
latency (median 6.1 s vs 268 ms). Mechanism: `_msgloop` sweeps the entire
`_msgqueue` under the `_processmsg` lock on every wake, so a 16×-deeper standing
backlog costs ~16× per message, and the same lock throttles senders. Long queues
help absorb *bursts* (a 4096 queue eliminated the 0.02% burst loss at small
scale) but hurt under sustained overload. The default 256 is a sensible operating
point.

## Defects found in pre-#51 master (all fixed by PR #51)

1. **Shutdown deadlock**: `shutdown(platform)` hangs while behaviors are blocked —
   reproduced in 14 of 15 runs across all modes/scales/rates down to 1 msg/s.
   Root cause: `reset(b)` nulled `b.block` without notifying waiters, and
   listener-channel teardown (`_dont_listen` before `close`) could deadlock the
   agent's message loop against a full listener channel (issue #36).
2. **`MessageBehavior(action, filt)` constructor broken**: passes 8 positional
   args to the 9-field struct (missing `timer`) — any filtered MessageBehavior
   throws. (This harness constructs via the 1-arg form + field assignment so it
   can run on pre-#51 checkouts.)
