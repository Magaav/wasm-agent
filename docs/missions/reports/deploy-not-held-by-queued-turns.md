# deploy-not-held-by-queued-turns - a deploy waits behind turns that were admitted and never started

Worktree `/home/victor/Work/missions/deploy-not-held-by-queued-turns/wt`, branch
`change/deploy-not-held-by-queued-turns`, base `ae3cbb37`. Committed locally, never pushed.

## Premises of the brief, re-measured at `ae3cbb37`

1. **"the advertised 900 s bound" - wrong number, and two bounds were in play.** This sentinel has two:
   `deploy_idle_bound_secs()` (`WA_DEPLOY_IDLE_BOUND`, default **1800 s**, `rust/wa-sentinel/src/main.rs`)
   is what every hold line advertises - the incident's own line says `bound 1800s` - and `hold_bound_secs()`
   (`WA_DEPLOY_HOLD_BOUND`, default **180 s**, same file) is the bound past which it may pass over paused
   holders, which is what `wa-sentinel status` prints. 900 s is neither: it is the *installer's* marker bound
   (`lua/core/deploy_pause.lua`, `DEFAULT_BOUND`) and the wait's own reader bound
   (`lua/core/deploy_wait.lua`, `DEFAULT_BOUND`). So the incident was held 25 minutes with an advertised
   1800 s and a real pass-over bound of 180 s, and the bound it did reach could not be satisfied.
2. **"N rising 2, 6, 8, 10 ... the count never falls" - it falls, and never reaches zero.** The log has
   `7` at `1795402843`, then `2 -> 6 -> 8 -> 10` within five seconds at `1795403448-53`. The true statement is
   that during the whole wait `queue` was above zero whenever the sentinel looked, which is all a holder has to
   be to block it.
3. **"names no session" - true, and it was by construction.** `rust/wa-sentinel/src/holders.rs` pushed
   `Holder::new("", format!("{queue} turn(s) admitted and not started"), 0)` from `/health`'s `queue`, and
   `queue` was a bare `AtomicUsize` count (`rust/wa-capabilities/src/serve.rs`, `QUEUED`).
4. **What admits a turn while a deploy waits: the node's admission, unconditionally.** The two refusals that
   existed are both downstream of admission - `lua/core/chat.lua` refuses a *scripted* CLI turn before it posts
   anything, and `lua/core/agent.lua` refuses at the top of an already-admitted run. A served turn (a wake, a
   resume dispatch, a peer's `/node/chat`, any SSE client) was therefore admitted by
   `rust/wa-capabilities/src/serve/scheduler.rs` and handed to a node-thread's queue first, and only then
   refused - which is exactly a turn "admitted and not started".
5. **Why it never fell to zero:** `QUEUED` counts the items sitting in a node-thread channel and is decremented
   when that node-thread dequeues one, so any long turn in flight keeps the count above zero while automatic
   turns keep arriving; a holder with no session can neither be checked for a pause nor passed over, so the
   deploy's bound could not be met.
6. **Found while fixing (5): a request name that is not a stamp was read as a time.**
   `stamp_seconds("100-deploy")` took `100` as epoch *nanoseconds*, so a hand-written request read as "queued
   for fifty-six years" and was past every bound on arrival. Harmless while the bound only chose between two
   announcements; fatal once the bound is a wall. Also `WA_DEPLOY_HOLD_BOUND=0` was documented as "unbounded"
   but compared `waited >= 0`, so it passed over paused holders immediately.

## What is built, and where

| item | commit | what the diff does |
| --- | --- | --- |
| the node names the turns it admitted and has not started | `89de8506` | `rust/wa-capabilities/src/serve.rs`: `PENDING`/`PendingRun` registry, `pending_admitted` before the hand-off and `pending_started` at the dequeue (both node-thread arms, the completion arm, and every refusal that gives the place back); `/health` gains `queue_sessions {count, named, truncated, entries[{run_id, session, node_thread, kind, waited_ms}]}` and a per-node-thread `queued`; `queue` keeps its meaning and every existing reader. |
| the hold line names the sessions it waits on | `89de8506` | `rust/wa-sentinel/src/holders.rs`: `Holder.queued`, one holder per `queue_sessions` entry (session, `admitted, not started`, waited), the unnamed remainder still counted as before, and `holder_lines` says `not started yet` instead of `working`. `bound_verdict` never passes over a queued holder, even with a pause record. |
| the bound is real | `89de8506` | `rust/wa-sentinel/src/main.rs`: `fail_held_request` - past the bound, a request that cannot be passed over is recorded `failed` in the protocol state, in the queue as `hold-bound`, and in `failed/`, then leaves the box, with a `hold-bound-failed` audit line. `bound == 0` is now really unbounded. `stamp_seconds` requires a stamp. |
| a waiting deploy refuses a turn at the door | `89de8506` | `lua/core/server.lua` `wa_deploy_admission(body)` answers `{waiting, code, refusal, to, id, since, source}` from `deploy_pause.refuse` - the same reader the run's own gate uses - with `operator: true` exempt; `rust/wa-capabilities/src/serve.rs` `deploy_admission_refusal` asks it for every run route before `scheduler::admit` and answers `503` with `error: deploy_waiting`, `not_started: true`, `effect: none`, `target`, `request`, `source`, `retry_after_seconds`, and leaves the run to its own gate when the gate cannot be asked (`gate: unavailable`, logged). |
| tests | `1d1bd9f4` | `scripts/test-deploy-wait.sh` steps 2c/2d and `scripts/test-deploy-bound.sh` (naming, fail-at-bound, unbounded zero), plus the unit rows in `rust/wa-capabilities/src/serve.rs` (`pending_queue_tests`) and `rust/wa-sentinel/src/holders_tests.rs` (9, 10, 11). |

## The job, item by item

1. **Re-measured** - above; two premises were wrong (the 900 s bound, "the count never falls") and one more
   defect was found on the way (`stamp_seconds`).
2. **A turn admitted but not started is refused back to its caller, by name.** The door is the fix: while a
   build is waiting for this node or being installed, a run is refused *before* the scheduler admits it
   (`503`, `deploy_waiting`, `not_started`, `retry_after_seconds: 30`), so it never enters a queue and the node
   reaches idle in one step. A turn that was already admitted is named in `/health` and refused by the run's
   own gate the moment its node-thread starts it (unchanged, `lua/core/agent.lua`). Nothing can hold the node
   with no name on it any more.
3. **The hold line names the sessions**: `wa-sentinel status` prints one line per queued turn, e.g.
   `busy     session 9b28c30d  admitted, not started 45s  not started yet`, and the hold detail names the
   session that blocks the bound (`session 9b28c30d has a turn admitted and not started (admitted, not started)`).
   A turn the node cannot name is still counted, unchanged.
4. **The advertised bound is real**: past `WA_DEPLOY_HOLD_BOUND` (default 180 s) the request either proceeds
   (every holder paused) or FAILS by name - `failed/` record, `hold-bound-failed` audit line, out of the box -
   and is not re-announced on the next tick. `WA_DEPLOY_HOLD_BOUND=0` is the operator's unbounded wait and now
   really is one.
5. **"wa must always be available" - what each caller sees, all of it an answer and none of it a hang:**
   * a person at a terminal or in the window (`operator: true`, `lua/core/chat.lua`'s `scripted` test) is exempt
     from the door *and* from the pause while a request merely waits - their turn runs, and `scripts/test-deploy-wait.sh`
     step 4b holds that;
   * a scripted CLI turn (`wa chat --once`, a mission runner) exits 2 with the sentence and writes nothing
     (`lua/core/chat.lua`, step 3);
   * an automatic served caller now gets a `503` with `deploy_waiting`, `not_started: true` and
     `retry_after_seconds` in the same round trip (step 2d), where before it was admitted and answered later;
   * `/health` already publishes the sentinel's own queue under `sentinel`, so "a build is waiting" is visible
     without asking anyone.
6. **The pile-up test**: `scripts/test-deploy-wait.sh` step 2c builds a real queue on a scratch node (one
   conversation, an operator turn in flight) and requires `/health` to name both queued conversations and the
   per-node-thread counts to add up; step 2d then fires three automatic turns while a deploy waits and requires
   `503`/`not_started` for each, `queue` at zero throughout, and no model call for any of them.

## Tests, and where they are wired

| row | what it holds | wired |
| --- | --- | --- |
| `scripts/test-deploy-wait.sh` steps 2c, 2d (extended) | the queue is named on a real node; a waiting deploy refuses three automatic turns at the door with `503 deploy_waiting not_started`, no queue, no completion | `scripts/test.sh:1350` and `scripts/fast.sh:869` (already wired; the new steps ride the row) |
| `scripts/test-deploy-wait.sh` steps 3, 4, 4b (timing hardened) | unchanged assertions; the request is now written once the turn is provably inside its first model call instead of after a 0.8 s sleep | same two |
| `scripts/test-deploy-bound.sh` (extended) | a queued turn is named and is not "working"; past the bound with only a queued turn the request fails by name (record, audit line, out of the box) and is not retried; `WA_DEPLOY_HOLD_BOUND=0` waits unbounded | `scripts/test.sh:1351` and `scripts/fast.sh:870` (already wired; the new steps ride the row) |
| `rust/wa-capabilities` `pending_queue_tests` (2 rows) | the registry names a run until it starts, one entry per run, never run_id 0; `queue_sessions` publishes count/named/entries and an empty queue is an empty answer | `scripts/fast.sh:733` (`cargo test -p wa-capabilities`, already wired; the rows ride it) |
| `rust/wa-sentinel` `holders_tests` 9, 10, 11 | a queued turn is named and never called working, the unnamed remainder is still counted, the bound never passes over a turn that has not started, and a request name that is not a stamp is not a time | `scripts/test.sh:220` (`cargo test --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1`, already wired; the rows ride it) |

**Discrimination, measured here** (`scripts/test-discriminates.sh ae3cbb37`):
`discriminates scripts/test-deploy-wait.sh`. The same gate reported `scripts/test-deploy-bound.sh` as *skipped*
("this tree's wa-sentinel did not build" inside its scratch worktree), so it was judged by hand instead: a
`git worktree add /tmp/base-db ae3cbb37` with the branch's script copied in and its own target directory fails
**7** assertions on the base code - `a request past its bound left no failure line`, `a request that failed at
its bound left no record in failed/`, `both queued turns are holders`, `the session the node named says it has
NOT started`, `and the turn the node could not name is still counted`, `the request is still in the box: past
its bound it must proceed or fail, never wait on`, `and the failure record names the blocker` - i.e. the row
catches this change.

Green here: `cargo test --manifest-path rust/wa-sentinel/Cargo.toml` (145 passed); `cargo test -p wa-capabilities`
386 passed / 2 failed, and both failures are those rows' OWN guard, not this change - they refuse to run under the
operator's `HOME` (`refusing to run: this test starts real operations, so HOME must be a scratch or temp directory
and never the node own ~/.wasm-agent (got /home/victor)`) and pass with `HOME=<scratch>` (49 passed, 0 failed);
`bash scripts/test-deploy-wait.sh` (`deploy wait ok`); `bash scripts/test-deploy-bound.sh` (`deploy bound ok`).

## Texts to approve (new or changed, verbatim)

1. `/health` key `queue_sessions` = `{count, named, truncated, entries:[{run_id, session, node_thread, kind,
   waited_ms}]}`, and the per-node-thread key `queued`.
2. Holder labels `admitted, not started` and `child completion, admitted, not started`.
3. Holder state word `not started yet` (instead of `working`) for a queued turn.
4. Bound refusal for a queued turn: `session {short} has a turn admitted and not started ({label})`.
5. Audit verb `hold-bound-failed` with the line `the request failed at its bound: {detail}`, and the queue
   phase `hold-bound` beside `state: failed`.
6. The `failed/` record for a bound failure carries `phase: failed`, `bound_failed: true` and the `detail`.
7. Door refusal body (HTTP 503):
   `{"error":"deploy_waiting","hint":"<the one deploy_waiting sentence>","not_started":true,"effect":"none","target":<sha|null>,"request":<id|null>,"source":"request"|"claimed"|null,"retry_after_seconds":30}`.
8. Node log lines: `[serve] the deploy admission gate could not be asked ({code}: {hint}); the run's own gate
   judges it` and `[serve] the deploy admission gate is unavailable ({detail}); the run's own gate judges it`.
9. `lua/core/server.lua` `wa_deploy_admission` answer keys: `waiting`, `code`, `refusal`, `to`, `id`, `since`,
   `source`, `gate: unavailable`, `operator: true`.

## What is not done, and what remains unknown

* The exact growth path of the incident's `2 -> 6 -> 8 -> 10` was **not** reproduced from the live node's own
  history: this mission read the log and the code, and reproduced the *state* (a real queue behind a real turn
  in one conversation) on a scratch node, not the incident's process timeline. What is proven is the mechanism
  the hold line depends on (`queue` counts items in node-thread channels and names nobody) and that the door
  removes it.
* The door refuses a run before the credential is resolved, so the refusal is answered to any local caller with
  the same facts `/health` already publishes; the request id and target commit are in the existing `sentinel`
  section of `/health`, so nothing new is disclosed. Named here so a reviewer can disagree.
* `wa-sentinel`'s two bounds (180 s pass-over, 1800 s advertised) are still two numbers; this change makes the
  pass-over bound real rather than merging them. Merging them is an operator decision, not this brief's.
* No release, no fleet update, no key retirement, nothing on a live peer; every test above ran on this node with
  its own scratch `WASM_AGENT_HOME`, and `~/.wasm-agent/graph.db.malformed-20261122T144358Z` was not touched.

