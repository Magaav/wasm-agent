# Repair status: prior-generation intent after an in-flight review change

Status file committed **first**, before the fix, on top of the refused tip
`b00f456681710b38f18a475047f8d3c31e6237fc` (tree `16874083447182f118df5794a6c70226e3ab0aae`) of
`change/codex-delivery-state`. Repair lane: a bounded subagent of the publisher, session
`child:dispatch:5b9b0560-ab23-47bb-bd88-d6ce9fa9e1dd`. Nothing is redesigned: one finding, one race,
one regression.

## What is fixed

The single blocking finding of `change/review-codex-delivery-state` (`9485f95b`):
`summary_exceeds_code:unresolved` - after an in-flight review change makes the enqueue
acknowledgement write lose its CAS, the next reconciler exits **0** with `pending_events=0` while an
older outbox intent is still **pending** next to an exact durable queued effect.

`scripts/delivery-trigger.mjs`: a real pass also reconciles the intents the record already holds for
other generations. For each non-acknowledged intent that is not the generation this pass computed,
the trigger **observes the exact durable queue effect** (the emitter is never invoked for it again)
and settles it, or **reports it as unsettled** (`counts.pending_events`,
`skipped[reason=prior_generation_pending]`, exit 4). A settled pass reports no pending event because
none is pending. `--no-emit` is deliberately untouched: a rehearsal emits nothing and claims nothing
about the queue, so it neither observes nor settles.

New output fields: `counts.prior_generations_settled` (integer) and `settled_prior` (array of
`{delivery, event, receipt, effect_id}`). `scripts/delivery-admission.md` documents the rule.

## What is proven

**1. The reviewer's own fixture, verbatim, before and after.** The review's `intent-race-probe.mjs`
(SHA-256 `f85de4ecfdce074dc6656769c4b1b21c150fbcba120b1b524a431a494f51dc18`, the hash in the review's
schema-1 manifest) was copied unmodified from its retained root and run over `git archive` copies of
the tip. Trigger SHA-256 `eba781d9a63a982ca160e1a933a46ddfd7e07943ceea4a89f873bf8a392e064c` is the
hash the review recorded, so the "before" leg is the reviewed artifact.

- **Before** (tip `b00f456`, unmodified trigger) - exit **1**:
  `reconcile after changed review: exit=0, reported pending=0, old intent=pending, queued exact effect exists=true, emitter calls=1`
  then
  `AssertionError [ERR_ASSERTION]: unsettled old durable intent was silently omitted from the reconciliation result`
  (`intent-race-probe.mjs:66:8`). Second pass: `pending_events=0`, `write_errors=0`, `refused=1`,
  `oldIntent.state=pending`, `effect.state=queued`, `emitCalls=1`.
- **After** (same probe, same tip, trigger replaced by this repair) - exit **0**:
  `reconcile after changed review: exit=0, reported pending=0, old intent=acknowledged, queued exact effect exists=true, emitter calls=1`
  then `in-flight intent reconciliation ok`. Second pass: `prior_generations_settled=1`,
  `pending_events=0`, `write_errors=0`, `refused=1`, `oldIntent.state=acknowledged`, `emitCalls=1`.
- **Emitter calls: 1 in both legs.** The repair never re-enqueues an existing exact effect.

**2. The in-tree regression, falsified by name.** `scripts/test-delivery-intent-race.mjs`
(14 checks; private scratch store, Git repository, job database and emitter; the emitter verifies the
intent was durable *before* it enqueues, then rewrites the review through the real revisioned
`writeRecord` while the trigger still holds its pre-emission copy).

- Fixed tree: `delivery intent race ok (14 checks, 0 skipped; isolated store, repository, database and emitter)`, exit 0.
- Same file in a scratch copy of the tip with only the fix reverted
  (`scripts/delivery-trigger.mjs` = `eba781d9...`): exit 1
  `AssertionError [ERR_ASSERTION]: unsettled prior-generation intent is settled from its durable effect or reported, never silently omitted`.
- Its third pass is the negative leg: an older intent with **no** durable effect is reported
  (`pending_events>=1`, exit 4, `prior_generation_pending`), never invented into acknowledgement.

**3. Credited behaviours re-checked (spot-check, not re-derived).** All on this tree, all exit 0:

| Suite | Result |
| --- | --- |
| `node scripts/test-delivery-admission.mjs` (gate-wired; strict single `session=` footer) | `delivery admission ok (58 checks)` |
| `node scripts/test-delivery-store.mjs` (concurrent stale writers, named CAS refusal) | `delivery store ok (9 checks, 0 skipped; private store, real concurrent writers)` |
| `node scripts/test-delivery-outbox.mjs` (durable intent before emission, failed emitter, queued zero, receipt recovery without re-emitting, new subscriber revision) | `delivery outbox ok (8 checks, 0 skipped; isolated store and emitter)` |
| `node scripts/test-delivery-intent-race.mjs` (this repair) | `delivery intent race ok (14 checks, 0 skipped)` |

The read-only receipt connection is untouched: `scripts/lib/delivery-outbox.mjs` still opens
`new DatabaseSync(receiptDb,{readOnly:true})` and never creates or migrates `jobs.db`.

## What is unproven, and what was not done

- `scripts/test.sh` was **not run** by this lane (focused suites only, as instructed). The gate is
  still the merge lane's check on the merged tree.
- The new fixture is **not wired into `scripts/test.sh`**. The suite-adjacent fixtures
  (`test-delivery-store.mjs`, `test-delivery-outbox.mjs`) are not wired either - that is the review's
  open `boundary_gap`, not this finding, and wiring it was out of scope for a one-finding repair.
- Still unresolved exactly as the review left them: full workflow/installation, **live sentinel/node
  receipt wiring**, native Linux/macOS coverage, publisher/merged-tree smoke, and deployment of the
  receipt API. The repair was exercised only through the explicit `--receipt-db` read-only seam
  against a private mock sentinel; nothing here exercises a real `job receipt` on a live node.
- The repair covers a **real pass**. A `--no-emit` rehearsal still reports `pending_events: 0` while
  a prior intent is pending, by design: it emits nothing and makes no acknowledgement claim.
- Branch state at this commit: 3 commits on top of `b00f456`, `git merge-tree --write-tree
  origin/main HEAD` clean (107 behind `origin/main`, which the landing merges).

Agent: wasm-agent node=fixture session=child:dispatch:5b9b0560-ab23-47bb-bd88-d6ce9fa9e1dd
