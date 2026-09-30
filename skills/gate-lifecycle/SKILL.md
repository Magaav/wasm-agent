---
name: gate-lifecycle
description: >-
  Inspect a queued, stuck, cancelled or nested test gate; recover only after
  proving process/lease ownership and drain. Use before a gate reservation,
  when a cancelled worker leaves gate work alive, or when gate reports disagree.
---

# Source and ownership

Use the repository's absolute `skills/parallel-evolution/scripts/finish.mjs`
and native own-repository path. Its receipt identifies runner/hash/platform.
On Windows, it selects native Git Bash by absolute path; System32 bash starts
WSL and cannot consume native `C:/` paths. Missing shell/reservation is a refusal.
An installed snapshot must converge through the existing gated sentinel deploy
procedure before claiming the node uses a new runner.

Inspect without reconciliation:

```
node <source-repo>/scripts/gate-lane.mjs inspect --json
```

`status` reconciles; it is not read-only. A running row's prior wait reason is
cleared on grant. `history` retains that waiting evidence. Queue wait and gate
execution are separate: the acquisition defaults to 7200 seconds, execution
to 3500 seconds, and the regenerated closing spell budgets 10800 seconds.
Waiting is not an execution failure or permission to start a replacement.

Nested execution inherits only when the marker AND `GATE_LANE_ORIGIN` identify
a running lease held by a live ancestor. A bare marker or copied sibling lease
refuses. Standalone `test-parallel-finish.mjs` always owns a private queue and
uses stand-in commands; it never reserves the production gate.

# Cancellation and recovery

Cancellation of an agent is not process drain. A surviving gate remains work.
Only the `acquire` holder's process tree releases its live lease. A timed-out
shell retains the reservation for reconciliation because children may survive.
The uncertainty is durable (`drain_required`); disappeared roots never prove
detached grandchildren stopped. A cancelled running/acquired reservation needs
explicit owner drain evidence even when its recorded roots are gone.
After owner death, inspect exact PIDs, ancestry, lease and owned effect logs.
Never stop by image name, free on a timer, or discard an unlanded candidate.

If the owned process tree is proven stopped, use the documented evidence path:

```
node <source-repo>/scripts/gate-lane.mjs reconcile --id <id> --evidence <observed-drain>
```

Read back the row and queue. A refusal naming surviving work is real. POSIX
reparenting can erase ancestry; unknown requires explicit owner drain evidence.
Do not infer drain from an empty agent roster or missing conversation.

# Verified scope

Run `test-parallel-finish.mjs`, `test-gate-lane.cjs` and
`test-gate-lane-wiring.cjs` against source in scratch fixtures. They verify queue
isolation, real leases, surviving work after cancellation, validated inheritance,
foreign-release refusal, and missing-store refusal. They stand in gate commands;
they do not establish a full smoke pass or platform coverage of a delivery.
The required merged-tree smoke receipt belongs to the sole merge publisher.
Keep failed fixtures and report failures/skips as such.
