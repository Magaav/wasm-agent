# The landing queue: what was built, what it costs, what is left

Mission `landing-is-a-queue-service` (Fable + Victor 27/11). Plan: `ready-queue-plan.md`. This is the
account of the six hunks.

## What a landing is now

A worker puts a branch and a sha in a queue (`submit`) and is told a request id and a position. The verdict
comes back as a value or a wake, never as prose a model has to carry. One runner takes one request at a time,
from its own clone, and the journal is the whole truth about what happened.

```
submit(branch, sha) -> queued -> merging -> rows -> pushing -> landed | rejected
                        ^                                          |
                        +---- needs_review <- policy ---- + (approve) +
```

## The pieces, and where they live

| piece | file | what it owns |
| --- | --- | --- |
| journal | `scripts/lib/queue/journal.mjs` | append-only transitions, idempotent submit, position, the v0 import |
| door | `scripts/queue.mjs`, `scripts/landing-queue.mjs submit` | the only way in |
| policy | `policies/landing-policy.json`, `scripts/lib/queue/policy.mjs` | which paths wait for a person |
| review lane | `scripts/lib/queue/lane.mjs` | the token at `~/.wasm-agent/lane/review.token` |
| runner | `scripts/q-runner.mjs`, `scripts/lib/queue/steps.mjs` | one at a time, restart-safe, every wait capped |
| rework | `scripts/lib/queue/rework.mjs` | the rejection as something a worker acts on |
| wake | `scripts/lib/queue/wake.mjs` | one carrier, swappable |
| seam | `wit/landing-queue/landing-queue.wit` | the fixed interface, not yet served |

## What it costs, measured

`node scripts/queue-bench.mjs --n 20` on this node:

```
  n=20  min=38.3 ms  p50=44.3 ms  p95=57.3 ms  max=57.3 ms
  journal 4096 bytes for 20 requests
```

That is the part the queue adds to a landing's *paper trail*: 44 ms at the median for a submit, one process
per call. The landing itself is not changed at all - the runner calls the same `land-quick.sh` the
train calls today, and `_orch/landing-times.tsv` is still the baseline (lua branches 2-3 s, compiled ones
279-492 s). What the queue changes is who waits: before, a model held a turn open while a landing ran; now
a session holds a request id.

## Rows

| row | checks | what it can fail on |
| --- | --- | --- |
| `test-queue-journal.mjs` | 31 | an update to a transition, a duplicate submit, a migration that restamps times |
| `test-queue-submit.mjs` | 18 | a wait that does not end, a verdict to the wrong request |
| `test-queue-policy.mjs` | 23 | a glob that over-matches, a hash that ignores a policy edit |
| `test-queue-approval.mjs` | 33 | an approval that survives a new sha or a new policy, a token check that can be pointed elsewhere |
| `test-queue-resume.mjs` | 23 | a half state after a crash, a step that fails without closing the request |
| `test-queue-order.mjs` | 21 | an order that depends on timing, a revert that queues behind a train |
| `test-queue-door.mjs` | 16 | a submit that merges or pushes, a policy skipped at the door |
| `test-queue-rework.mjs` | 29 | a rejection that loses what to fix, a wake with the wrong arguments |

All eight are wired into `scripts/fast.sh` and run in seconds; none pushes to a repository.

## What is NOT done, and why it is named here

1. **The lane token is not retired.** Retiring it means making `land` refuse and `submit` the only door,
   which rewrites `scripts/test-landing-queue.mjs` section 10 (~40 assertions about who may land) in the
   same change. Half-retiring a door - a token that is checked but nothing behind it - is worse than the
   token. It is the next step, with that row's rewrite as its content.
2. **The WIT is not served.** It is written and lint-clean (`scripts/wit-lint.sh`, 0 new findings);
   `wasm-tools` is not on this node, so it is not compile-checked here.
3. **`orch-q-runner.service` still runs v0.** The swap is the orchestrator's, between requests; the exact
   moment is in `ready-queue-hunk3.md`.
4. **`_orch/q.sh`, `_orch/q-runner.sh` and `journal.db` are untouched.** They are the orchestrator's state,
   not this branch's, and the migration reads them without writing.
