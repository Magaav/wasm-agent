# handle-wake-busy (24/11): a busy session still hears that its call settled, exactly once

Branch `change/handle-wake-busy` from `origin/main` (`e832e152`). G blocker, Fable 24/11, after the read-only
answer that found the notice was lost.

## The defect, in order (what the measured rows meant)

Measured on the live node: eight handle wakes between 02:18Z and 03:50Z ended `status='failed'` with
`lua/core/agent.lua:2072: run_resource_refused ... resource_busy`, no `due_at`, because the session's own turn
held the run claim. The chain was:

1. `lua/core/codemode_pending.lua` `wake_settled`: when the wake was only **scheduled**, the handle got
   `woke_at` AND `reported = true`.
2. `reported` is what silences the in-turn notice: `M.announce` (`lua/core/codemode_pending.lua`, filter
   `record.reported == false`), whose answer is what code-mode's `pending_settled` carries.
3. `lua/core/agent.lua:2110-2121`: the run takes the session claim; held by a live run, the agent **raises**
   `run_resource_refused` (`:2121`).
4. `lua/core/selfloop.lua:1349` deferred only the refusal the agent *returned* (`bot.turn_refused`); a raise makes
   `ok == false` at the `pcall` on `:1341`, so control fell to `M.finish(row, false, result, ...)` (`:1355`),
   which writes `status = "failed"` (`:1225`), and `lua/core/run_failure.lua:88-90` calls that code
   `retryable = false`.

So both routes to the model were closed by the same event: the in-turn notice by `reported`, the wake by its own
refusal. The record itself survived (`M.retained`, `wait(op)`, `pending()`), so nothing was lost for a model that
polled - only for one that did not.

## The three parts

1. **A raised resource refusal is a WAIT, not a delivered wake** (`lua/core/selfloop.lua`): new
   `M.resource_refused(text)`, an allow-list of the two codes `run_failure.lua` also names
   (`run_resource_refused`, `resource_busy`), and a branch in `run_wake` that calls `M.defer_refused` (`:1245`,
   which puts the row back to `pending` with a backoff `due_at`) instead of `M.finish(row, false, ...)`. Same
   treatment, and the same reasoning, as the deploy-waiting deferral that already sat one line above it.
2. **Scheduling is not delivery** (`lua/core/codemode_pending.lua`, `wake_settled`): the `woke_at` mark stays
   (exactly-once *scheduling*, across a second sweep, a restart and a second process); `reported` is no longer
   set there. It flips only where a model is actually reached: `M.announce` (in-turn) or, by construction,
   nothing else - a wake's delivered turn needs no further mark, because the script order is checked against the
   wake row itself (`M.handle_wake_state`).
3. **A failed wake leaves `reported` false**, so the next script in that scope announces the settlement - which
   is (2) plus nothing else setting the flag. `grep -n 'reported = true' lua/core/codemode_pending.lua` shows
   only: a waiter that observed the handle, a cancellation, and `M.announce`.

### The one-notice contract, and where it is enforced

| order | who tells the model | what stops the second telling |
| --- | --- | --- |
| the op settles while a script is running (wake scheduled, not yet claimed) | `M.announce` (in-turn, `pending_settled`) | the same call **withdraws** the pending wake: `M.withdraw_wake` -> `selfloop.withdraw_handle_wake`, one `UPDATE ... WHERE status='pending'` |
| the op settles while the session is idle | the wake's own turn | `M.announce` sees `M.handle_wake_state == 'delivered'` (or `'claimed'`) and marks the handle reported without saying it again |
| the wake's turn was refused (busy session) | the wake, later, after the deferral | the row is `pending` again with a future `due_at`; until it is delivered the in-turn notice is still available |

## Tests

`scripts/test-handle-wake-busy.lua` (new, 28 checks), hermetic (own scratch `HOME`/`WASM_AGENT_HOME`, refuses a real
`~/.wasm-agent`), through the product's own stores - `codemode_pending.invoke`, the `self_wakes` table via
`host.sql_query`, the run claim via `lua/core/resources.lua` - and one clock:

* **A, mid-turn:** the call settles while the session is in a turn; the sweep schedules its wake; the running turn's
  next `announce` returns it (that is what `pending_settled` is built from), a second `announce` says nothing, and
  the wake row is `cancelled` with `last_error='announced in turn'` - **zero extra turns**;
* **B, idle:** exactly one wake row, carrying the answer itself; a second sweep creates no second row; delivered
  once (`selfloop.finish`), and the store answers `delivered`;
* **C, refused:** the real claim is taken through `resources.claim` (`session:<id>`), `selfloop.resource_refused`
  recognises the exact text the live node recorded and rejects an unrelated `provider_error: 500` (allow-list, not
  block-list), and `selfloop.defer_refused` puts the row back to `pending` with a **future** `due_at` and the
  refusal on it; after `resources.finish` the claim is free and the row delivers once;
* **D:** a handle whose wake was delivered is never announced again in a later script.

**Discrimination (rule 16):** on a base worktree of `origin/main` (`git worktree add /tmp/base-wake origin/main`,
same binary, `WASM_AGENT_LUA_ROOT=/tmp/base-wake`) the row fails with
`the running turn is TOLD, in the turn: []` - it fails on the defect itself, not on a missing helper.

### A shared row changed, for Fable's eyes

`scripts/test-handle-wake.lua` asserted the OLD preference (the wake wins, the next script says nothing). Under
the one-notice contract the script is the notice when it gets there first, and the wake is withdrawn; both halves
have to be true, so that row now:

* keeps every existing assertion (the wake row, its wording, its still-pending list, "a second sweep keeps the one
  row", "a restart between settle and wake does not schedule it twice", the retained answer);
* REPLACES `"and the next script does not announce it a second time"` with the new contract: the script DOES
  announce it, the wake is withdrawn, and a second script says nothing - strictly stronger (it pins both routes
  and the withdrawal);
* moves the claim-the-wake assertions (`selfloop.claim_due`, `handle:'..op`) onto their own settled handle, so the
  wake route is still proven end to end, with a delivery that closes the row and is not announced afterwards.

No assertion was deleted or loosened; one was restated because the behaviour it described changed on purpose.

## Model-facing texts

**None new.** The wake's prompt text is unchanged (`lua/core/handle_wake.lua`, `M.prompt_for`), `pending_settled`'s
shape is unchanged, and no tool description or refusal code was added - which is why no cache cost applies and the
refusal inventory did not need regenerating. Two strings an OPERATOR reads are new or now reachable:

1. `last_error='announced in turn'` on a wake row withdrawn because the script told the model first (CLI wake row).
2. A deferred wake's row now keeps the refusal text as its `last_error` and a future `due_at` instead of
   `status='failed'` - the same sentence the failure used to carry, on a row that will try again.

## Verification

Run singly (hermetic rows, no suite lock needed):

| row | verdict |
| --- | --- |
| `scripts/test-handle-wake-busy.lua` (new) | 28 checks; fails on `origin/main` |
| `scripts/test-handle-wake.lua` | 21 checks |
| `scripts/test-codemode-pending.lua` | 108 checks |
| `scripts/test-codemode-wait-shape.lua` | 25 checks |
| `scripts/test-operation-survives-turn.lua` | 16 checks, 0 failed |
| `scripts/test-cli-wake-row.lua` | 30 checks |
| `scripts/test-deploy-pause.lua` | 100 checks |
| `scripts/test-selfloop-pause.lua` | 129 checks |
