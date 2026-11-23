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
| `scripts/test-deploy-wait.sh` step 2e (new) | the door's two scopes across processes: an unauthenticated `POST /chat` gets 503 with no commit, no `target`, no `request`, no `source`, while the authenticated turns of the same step do carry the commit | `scripts/test.sh:1350`, `scripts/fast.sh:869` |
| `scripts/test-completion-deploy-wait.lua` (new, 10 checks) | a child settlement is held while a deploy waits and delivered exactly once after it, and a run the node refused returns the row to `ready` with the reason instead of `delivered` | globbed by `scripts/fast.sh` (not in `scripts/fast-path.exclude`) |
| `scripts/test-peer-deploy-wait.lua` (new, 14 checks) | a peer's `503 deploy_waiting` is a named, retryable answer carrying `retry_after_seconds`; a 200, a 500, a 503 that is not the door and no answer keep their old meaning | globbed by `scripts/fast.sh` |
| `rust/wa-capabilities` `deploy_door_tests` (new, 2 rows) | the anonymous refusal body carries no commit, no request id and no lane; the authenticated one carries them | `scripts/fast.sh:733` |
| `rust/wa-sentinel` `stamp_seconds` row (new, row 11) | a request name that is not a stamp is not a time | `scripts/test.sh:220` |

The three Lua rows that read the same deploy state as the new gate are green against this tree's binary:
`scripts/test-deploy-wait.lua` (59 checks), `scripts/test-deploy-pause.lua` (23), `scripts/test-deploy-resume.lua`
(25).

**The whole fast path, run three times (`f1326d6c`)**, each under `flock -o ~/Work/missions/.suite.lock`, waiting
its turn in the lock queue (two runs waited ~20-30 minutes behind other missions' suites and were not cancelled):

| run | result line |
| --- | --- |
| 1 (`61b489d3`) | `fast path FAILED (5 of 416 checks, 0 skipped, 1176s)` |
| 2 (`61b489d3`) | `fast path FAILED (4 of 416 checks, 0 skipped, 592s)` |
| 3 (`f1326d6c`) | `fast path FAILED (4 of 416 checks, 0 skipped, 618s)` |

**Two of run 1's failures were mine, and are fixed in `f1326d6c`:** `scripts/test-refusal-contract.lua` and
`scripts/test-regenerate.sh` both failed because `lua/core/nodes.lua` now names two refusal codes
(`deploy_waiting`, `remote_deploy_waiting`) and the generated map `lua/core/refusal_codes.lua` was stale - fixed
with the repo's own generator (`lua5.4 scripts/gen-refusal-codes.lua --write`: 593 codes from 106 modules), and
both rows are green in runs 2 and 3.

**The rest is load, named rather than smoothed over.** The failing set differs between runs - run 2 had
`subagents::tests::health_shape_is_strict_and_a_cancelling_task_stays_active`, run 3 had
`test-graph-quarantine-evidence.lua`, which passed in runs 1 and 2 - and every row that failed passes when run
alone on this tree: `test-land-quick.lua` (176 checks), `test-graph-quarantine-evidence.lua`,
`test-undo-pty.mjs` (17 ok, 0 failed; the same for `--remote`), and the subagents row 3/3 in a row. What they have
in common is the machine: `test-land-quick.lua` runs 20 `git` commands against the shared canonical checkout and
the pty rows are timing-bound, while this box was running other missions' suites and worktrees at load 5-7 (16
cores) throughout. **Not proven green as a whole**: I did not get a clean 416-check line, and I did not exclude a
row to manufacture one.

The peer row was rewritten after run 3 (it now measures through `remote_chat` instead of pinning a helper, so it
discriminates); it passes standalone on this tree and fails on the base, and the next full run is the first that
measures it inside the suite.

Green in all three runs: the two rows this branch changes - `fast: deploy-wait ok (27279ms)` and
`fast: deploy-bound ok (589ms)` - plus the Rust rows of both crates this branch touches
(`fast: rust wa-capabilities ok`, `fast: rust wa-sentinel ok`).

**Discrimination, measured here** (re-run for `bb0b78f4`): `scripts/test-discriminates.sh ae3cbb37` says
`discriminates scripts/test-deploy-wait.sh`, `skipped scripts/test-deploy-bound.sh` (its own scratch build) and
`unrevertable` for the two new Lua rows - the gate's rule is that a branch which changes `rust/` has Lua rows it
cannot judge against the base binary. For the two new rows that judgment is made by hand here instead, in a
`git worktree` of `ae3cbb37` with the branch's row copied in and the BASE Lua loaded by this tree's binary (the row
is about Lua, which is what a deploy's revert would change):

| row | on the base Lua at `ae3cbb37` |
| --- | --- |
| `scripts/test-completion-deploy-wait.lua` | **fails** at `no child-return wake is admitted while a deploy waits (enqueued 1)` - the base dispatched the settlement |
| `scripts/test-peer-deploy-wait.lua` | **fails** at `a door refusal is named as a deploy wait, not as unreachable: remote_unreachable` - the base threw the body away |

Earlier gate run (before those rows existed):
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
10. `lua/core/deploy_wait.lua` `refusal_redacted`, the anonymous door sentence verbatim: `deploy_waiting: this node
    is waiting for or installing a new build. This node starts no new turn while a build is waiting for it or being
    installed - a turn in flight is exactly what keeps the node from going idle - and this turn did not start.
    Nothing was lost: this is a wait, not a failure, and the work starts again once the swap is done.`
11. The anonymous 503 body: `{"error":"deploy_waiting","hint":<the sentence above>,"not_started":true,"retry_after_seconds":30}`
    (`wa_deploy_admission`'s answer also carries the `redacted` key for it).
12. A peer's answer, in the caller: `remote_deploy_waiting`, with `not_started`, `retryable`, `retry_after_seconds`,
    `peer_error: deploy_waiting`, `detail` (the peer's hint) and the message: `<peer> is waiting for or installing a
    new build, so it started no turn and nothing ran there. This is not a lost peer and nothing was lost: ask again
    in <N> seconds (the peer says when; it pauses running turns at their next step).`
13. The failed request's record ends with: `re-request with: wa-sentinel request deploy --expected-sha <sha>
    --reason '<the original reason>'` (no `--expected-sha` when the request carried no target).
14. A child settlement held by the outbox carries `wake not started: <the deploy_waiting sentence>` as its detail,
    and `wa_completion_run` answers a refused turn with `{not_started: true, deploy_waiting: <sentence>}`.
15. `lua/core/completions.lua` writes a held child settlement's detail as `deploy_waiting: waiting for the install
    of <sha> (deploy request <id>, asked <n>s ago). ...` - the existing words, reused, not a new sentence.

## Fable's review of `710c1567` - four points, answered (commit `c83e553c`)

### 1a. A message a PERSON sent through a channel (WhatsApp / Telegram / mail)

**Measured: in this tree no inbound channel message starts a turn by itself.** The channels are capabilities, not
pumps: `wa:channel/messages` is a WIT seam with no host implementation (`docs/KERNEL.md:70`), WhatsApp/Telegram/mail
arrive as tools a turn *calls* (`mcp_whatsapp_read`/`_search`/`_send`, `whatsapp_query.rs`, the `wa-whatsapp`
component), so the message waits in the channel's own store until a turn reads it. A turn is started by exactly
four things: `wa chat` at a terminal (`operator_present = true`, `lua/core/chat.lua:407` and `:1120`), the window's
`POST /chat` with `operator: true` (`lua/core/server.lua:155`), a wake/resume (in-node, `lua/core/selfloop.lua`),
and a peer's `/node/chat` (`lua/core/server.lua`, `wa_reply`). Only the last two are automatic, and both are
covered below.

So there is **no path in this tree where the door can drop a person's channel message** - and the two paths a
person is actually on are exempt and asserted: a window turn is served while a deploy waits
(`scripts/test-deploy-wait.sh` step 2), and a window turn already in flight is neither cut nor refused (step 4b).
The honest gap: **a channel pump, when one is added, must say which of the two it is.** A pump that starts a turn
for a person must send `operator: true` (and then it is exempt); a pump that cannot must leave the message in its
store and start the turn after the deploy. Proposed for `FACTORY.md` below, and this is the one thing here that is
not enforced by code, because the code it would guard does not exist yet.

### 1b. A wake / scheduled turn, and a child's completion

* **Wake: already refused durably, and tested.** `selfloop.tick` returns before dispatching any due wake while a
deploy waits (or installs), writes the sentence into each due row's `last_error` and keeps its time; when the
deploy ends, `deploy_pause.release_due` makes the paused sessions' resumes due in the same tick and each row fires
once. Held by `scripts/test-deploy-wait.sh` steps 5 and 6, on a real node: a due wake does not run, and after the
deploy "the held wakes run once" and "exactly once: a second tick dispatches nothing".
* **Child completion: it WAS lost, and that is fixed here.** MEASURED at `710c1567`: `completions.tick` had no
deploy gate, so a `ready` settlement was admitted as a run while a deploy waited (one more turn the deploy cannot
pass over); the run's own gate then refused it at its first step, `pcall(bot.run, ...)` succeeded, and
`wa_completion_run` recorded the row as `delivered` with the refusal as a note - so the summary a coordinator had
earned was gone. Fixed in `c83e553c`: the outbox tick holds the whole outbox while a deploy waits (rows keep their
state, and any row already `ready` gains the sentence as its detail), and a run that comes back refused returns
the row to `ready` with the reason instead of `delivered`. Held by the new row
`scripts/test-completion-deploy-wait.lua` (10 checks): held while a deploy waits, delivered exactly once after it,
and a refused run is not a delivery.

**Who retries, when, how many times:** the node does, on its own tick, once. There is no attempt counter for the
deploy case and none is needed - the row is not consumed until it is delivered, so a deploy that takes ten minutes
costs one delivery when it ends, not ten refusals. A send that is refused a second time after the deploy (capacity)
keeps today's bounded retry (the row returns to `ready`, `deferred_detail` records it).

### 1c. A peer's `/node/chat`

**Measured at `710c1567`:** `nodes.remote_chat` turned every non-200 into `remote_unreachable` with the status as
`detail` and **threw the body away**, so a peer that was alive, installing a build and had run nothing was reported
to the caller's model as a lost peer, with `retry_after_seconds` discarded. Fixed in `c83e553c`: `nodes.chat_answer`
maps a `503 deploy_waiting` to `remote_deploy_waiting`, `not_started`, `retryable`, `retry_after_seconds` and a
sentence that says the peer started nothing and when to ask again; `server.lua` passes those fields through to the
caller's turn. **It does not retry by itself**: the caller's model gets a named, numbered, retryable answer and
decides, which is the same shape as every other peer refusal in this tree. A 500, a 503 that is not the door, a 200
and no answer at all keep their old meaning. Held by the new row `scripts/test-peer-deploy-wait.lua` (14 checks).
**Not verified with two live scratch nodes**: the mapping is pinned as a pure function and the route that uses it
(`remote_chat` -> `chat_answer`) is the only caller; a two-node rendezvous fixture was judged not worth the risk of
a relay storm on this machine (rule 13), and that gap is named rather than hidden.

### 2. The 503 body before the credential is resolved

Fixed in `c83e553c`. The order is: ask the gate (one Lua call, no session created), and only if it answers
`waiting` resolve identity with `wa_identity` - which answers identity and **creates nothing** - and answer with
one of two bodies:

* unauthenticated: `error: deploy_waiting`, `hint` (`deploy_wait.lua refusal_redacted`: the same sentence with no
  commit, no request id and no lane), `not_started: true`, `retry_after_seconds` - nothing else;
* credential resolved: the same, plus `target`, `request`, `source` and `effect: none`.

A resolver that cannot answer is treated as unauthenticated (fail closed). Held by two Rust rows
(`serve::deploy_door_tests`) and, across processes, by `scripts/test-deploy-wait.sh` step 2e: an unauthenticated
`POST /chat` is refused with 503 and its body contains no `8082b42e1111`, no `"target"`, no `"request"` and no
`"source"`, while the authenticated turns of the same step do carry the commit - the two scopes are asserted
against each other.

### 3. What a deploy that fails at the wall leaves behind

Measured (`~/Work/missions/install-local.sh`, `~/Work/missions/status.sh`):

* `install-local.sh` waits for `wa-sentinel status`' `requests: N waiting` to reach 0, then compares
  `~/.local/bin/lua-core/lua/core` with the checkout's and exits 1 with "the installed lua/core differs from
  main's - the deploy did not take" if they differ. Before this branch a held request never left the box, so that
  landing instead ended at its own 40-minute bound; **now the box empties at the 180 s wall** and the comparison is
  what reports it.
* `status.sh` compares `main` with `installed.txt`'s `commit=` and prints `DIFFERENT - local is behind main or ahead
  of it`, and raises "this laptop does not run main's Lua" after 20 minutes. So it already shows main != installed.

What was missing was the *reason* and the way back, and that is in the repo's own surface, `wa-sentinel status`
(`fail_held_request`, `c83e553c`): the failure record now reads

`hold-bound: the node is busy: ...; session 9b28c30d has a turn admitted and not started (admitted, not started);
re-request with: wa-sentinel request deploy --expected-sha 8082b42e1111... --reason '<the original reason>'`

and the box shows `0 waiting, ... , N failed`. Held by `scripts/test-deploy-bound.sh` (the failed request is
counted, the phase is named, the blocking holder is named, and the re-request line is there).
`install-local.sh` and `status.sh` live outside this branch, so their one-line form of the same sentence is
proposed below rather than written.

## What is not done, and what remains unknown

* The exact growth path of the incident's `2 -> 6 -> 8 -> 10` was **not** reproduced from the live node's own
  history: this mission read the log and the code, and reproduced the *state* (a real queue behind a real turn
  in one conversation) on a scratch node, not the incident's process timeline. What is proven is the mechanism
  the hold line depends on (`queue` counts items in node-thread channels and names nobody) and that the door
  removes it.
* The door's answer is scoped by the credential (`c83e553c`, Fable review 2), so an anonymous caller learns the
  reason and when to retry and nothing that identifies the install.
* `wa-sentinel`'s two bounds (180 s pass-over, 1800 s advertised) are still two numbers; this change makes the
  pass-over bound real rather than merging them. Merging them is an operator decision, not this brief's.
* No release, no fleet update, no key retirement, nothing on a live peer; every test above ran on this node with
  its own scratch `WASM_AGENT_HOME`, and `~/.wasm-agent/graph.db.malformed-20261122T144358Z` was not touched.

## Proposed text (not written): `FACTORY.md`

Fable asked for proposals, never writes. Two lines:

> A turn that a PERSON is waiting on says so (`operator: true`) and is never refused for a waiting deploy. A channel
> adapter that cannot say it must leave the message in its own store and start the turn after the deploy - a
> person's message is never dropped, and a refusal that spends it is a failure.

> A refused turn must leave its work durable: the message, wake or settlement keeps its place and the reason, and is
> delivered once when the deploy ends. A reminder that silently never fires is worse than a slow deploy.

And one line for `~/Work/missions/install-local.sh` (outside this branch), so a landing ends with the reason rather
than only the symptom:

> `install-local: the deploy did not install <sha> - wa-sentinel status says why (failed at its bound behind
> <session>; re-request with `wa-sentinel request deploy --expected-sha <sha> --reason ...`); the installed commit
> is still <old>`


