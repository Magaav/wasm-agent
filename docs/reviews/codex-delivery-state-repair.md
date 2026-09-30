# Repair status: prior-generation intent after an in-flight review change

Status file committed **first**, before the fix, on top of the refused tip
`b00f456681710b38f18a475047f8d3c31e6237fc` (tree `16874083447182f118df5794a6c70226e3ab0aae`) of
`change/codex-delivery-state`. Repair lane: a bounded subagent of the publisher, session
`child:dispatch:5b9b0560-ab23-47bb-bd88-d6ce9fa9e1dd`. Nothing is redesigned: one finding, one race,
one regression.

## What is fixed (scope)

The single blocking finding of `change/review-codex-delivery-state` (`9485f95b`):
`summary_exceeds_code:unresolved` - after an in-flight review change makes the enqueue
acknowledgement write lose its CAS, the next reconciler exits **0** with `pending_events=0` while an
older outbox intent is still **pending** next to an exact durable queued effect.

Repair, in `scripts/delivery-trigger.mjs` only: a real pass (`--emit` on) also reconciles the
intents the record already holds for other generations. For each non-acknowledged intent that is not
the generation this pass computes, the trigger **observes the exact durable effect already queued**
(the emitter is never invoked for it again) and settles it, or **reports it as unsettled**
(`pending_events`, `skipped[reason=prior_generation_pending]`, exit 4). A pass can no longer claim
zero pending events while such an intent is pending. `--no-emit` is a rehearsal that emits nothing
and claims nothing about the queue, so it is deliberately untouched.

## What is proven (at this commit)

- The reviewer's own fixture is reproduced verbatim against this tip: `intent-race-probe.mjs`
  (SHA-256 `f85de4ecfdce074dc6656769c4b1b21c150fbcba120b1b524a431a494f51dc18`, the hash in the
  review's manifest) materialized from the review's retained root and run over a `git archive` of
  `b00f456`. It fails, exit 1, with the reviewer's assertion:
  `AssertionError [ERR_ASSERTION]: unsettled old durable intent was silently omitted from the
  reconciliation result`; pass 2 exited 0 with `pending_events=0` while `oldIntentState` was
  `pending` and the queued effect existed (`emitCalls=1`).
- The reviewer's reading of the cause is confirmed in source: the pass computes and settles only the
  current generation, and `record.admission.event` is set to `null` on refusal, so an older pending
  outbox entry is never looked at again.

## What is unproven (at this commit)

- Everything below: the fix itself, the in-tree regression, the after-leg of the reviewer's fixture.
- Out of scope and still unresolved, exactly as the review left them: full workflow/installation,
  live sentinel/node receipt wiring, native Linux/macOS coverage, publisher/merged-tree smoke; and
  the gate wiring of the store/outbox fixtures (the review's `boundary_gap`). `scripts/test.sh` is
  not run by this lane.

Agent: wasm-agent node=fixture session=child:dispatch:5b9b0560-ab23-47bb-bd88-d6ce9fa9e1dd
