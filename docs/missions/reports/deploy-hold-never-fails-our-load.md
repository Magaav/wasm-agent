# deploy-hold-never-fails-our-load

An install under the factory's own load waits or proceeds - it never fails at the bound. Two deadlock shapes and
the promise a pause makes to the worker that paused.

Branch `change/deploy-hold-never-fails-our-load`, base `41d6420c`, rebased onto `c1337903` (origin/main, 23/11 ~16:20Z) before the last run. Commit list at the end; every claim below
cites the commit that implements it.

## What was re-measured before writing code (the brief's premises)

| premise | re-measured | note |
| --- | --- | --- |
| `WA_DEPLOY_HOLD_BOUND` default 180 s, `WA_DEPLOY_HOLD_BOUND=0` unbounded, `rust/wa-sentinel/src/main.rs` | `hold_bound_secs()` at `rust/wa-sentinel/src/main.rs:2504` (base) — 180, and `0` really is unbounded (the `bound > 0 &&` test) | correct |
| past the bound "it passes only over holders that said they paused, and otherwise FAILS" | base `holders::bound_verdict` returned `Result<(), String>`: `Ok` = proceed, `Err` = `fail_held_request` | correct — and the reason both futures were wrong is that the answer had only two values |
| the two records in `~/.wasm-agent/sentinel/failed/*.json` with `bound_failed: true` | present; the two detail strings in the brief match the code paths that produced them (`names no holder`, `has a turn admitted and not started`) | correct |
| "a holder whose only activity is the child completion of a session the node itself paused" | `/health` names these under `queue_sessions.entries[].kind = "completion"` (`rust/wa-capabilities/src/serve.rs`), which `holders_from` read only as "admitted, not started" | the kind was there and was thrown away |
| the worker failure `run_resource_refused ... resource_busy` at `lua/core/agent.lua:1984` | the line is `local claimed=resources.begin(resource_ctx)` (base `lua/core/agent.lua:1984`); the measured record is `release-linux-reads-the-receipt/out.log:11904`: claim `session:0b8c9d78-...`, `run ebf3d007`, `uncertain:false` | correct; the claim's owner cannot be proven dead from the record, so the fix does not guess it is |
| "3 minutes" for the bound | `180` | correct |

Two premises were incomplete, and the code says so where it matters:

* **a child completion is not a turn.** The brief's item 1 was "a completion of a session the node itself paused
  counts as PAUSED". The live measurement in the 15:19Z amendment (07308add, 40 minutes) shows the session need
  not have paused at all: an admitted completion waits for the install *because* a waiting request stops the node
  starting turns (`lua/core/server.lua` `wa_deploy_admission`). So the rule in the code is the wider one the
  amendment asks for;
* **"the node is busy" can name nobody for two reasons the reader itself created.** `activity_of` counts
  `operation_overdue` as busy and `holders_from` pushed no holder for it; and `current` was dropped when it had
  no label. Both are named now (`holders::holders_from`, **ae815084**).

## What changed

### 1. A child completion never holds the install (job 1 + the amendment)

`rust/wa-sentinel/src/holders.rs` (**ae815084**): `Holder` carries `completion`, set from
`queue_sessions.entries[].kind == "completion"`; `bound_verdict` skips such a holder whether or not its session
paused. A completion the node counted but could not name is skipped too when *every* unnamed entry is a
completion (`unnamed_other == 0 && unlisted == 0`), and the count-only label stays byte for byte what it was.
`holder_lines` says `not started yet, and does not hold the deploy` for one.

Both measured shapes are in `rust/wa-sentinel/src/holders_tests.rs` (**ae815084**):
`a_child_completion_never_holds_the_install` (the 5-holder, three-session shape of the amendment) and
`a_named_turn_and_a_nameless_completion_are_read_differently` (a named turn still fails, an unnamed turn still
waits).

### 2. A holder that names nobody is never a failure (job 2)

`bound_verdict` returns a three-valued `Verdict` (**ae815084**):

* `Proceed` — every holder is a paused session or a child completion;
* `Fail(reason)` — every blocker is NAMED (a working session, a named turn admitted and not started). The
  request fails by name, as before;
* `Wait(reason)` — a blocker names no session, or the node names no holder at all. The request keeps waiting,
  past its bound, and the reason is announced and recorded. `unknown is not yes` no longer implies
  `therefore fail`.

The reporter is fixed with it (`holders_from`, **ae815084**): `current` with no label but with a session is a
holder named `a run, with no label`; `operation_overdue` is a holder named `an operation is overdue`.

### 3. A request that does fail at the bound is re-queued once (job 3)

`rust/wa-sentinel/src/main.rs` (**c4420837**): `fail_held_request` writes the same `failed/` record and then
parks the request in `<sentinel>/requeue/<id>.json`; `replay_requeues()` runs at the top of every
`process_requests` tick (so `once` does it too) and puts it back in `requests/` with `queued_at = now` and
`requeued: true` on the first tick `hold_for` says the node is quiet enough to run it — the same predicate the
dispatcher uses. A request that already carries `requeued` is not parked again: once is the bound. The reason
in `failed/` and in `status` names the landing that asked (`the request's reason: ...`), and
`wa-sentinel status` prints `requeue:   N request(s) that failed at their bound run when the node is quiet
enough`.

### 4. A paused worker is not killed by its own pause (the ADDED item, and the 16:40Z amendment)

`lua/core/deploy_pause.lua` (**f4fdb170**, `is_refusal` in **20b538cf**): `M.claim_wait(claimed, now, opts)` — a session claim that is busy
**while a build waits or is being installed** is the wait, not the run's failure. Only `resource_busy` qualifies;
every other claim failure stays the caller's error.

`lua/core/agent.lua` (**f4fdb170**) uses it at the claim: a non-operator run whose session claim is held while
a build waits emits the deploy sentence, sets `turn_refused` and returns — nothing ran, nothing was claimed,
the same request runs again when the node is back. A person's turn is exempt, which is the existing rule for a
merely waiting request (`deploy_pause.at_boundary`).

`lua/core/chat.lua` (**f4fdb170**, `is_refusal` in **20b538cf**): `M.deploy_refused(agent)` recognises both sentences (`deploy_waiting:`
from `deploy_wait.lua`, `deploy waiting:` from the pause), the scripted branch exits **2** for one (this tree's
documented "refused before it started, nothing ran", `docs/SCRIPTED-RUNS.md`, which
`scripts/worker-gate.sh` and `scripts/mission.sh` already wait out without spending a round), and the line on
stderr says `not started` instead of `failed`.

## The tests, and the number

`scripts/test-deploy-bound.sh` (one row, already wired at `scripts/test.sh:1351` and `scripts/fast.sh:870` —
no new row file was added, so there is nothing new to wire) gained six steps (**4daff95a**). The two the brief
asks for:

* `three workers mid-turn, each with a child completion, one session paused: it installs (23/11)` — the
  amendment's own 5-holder shape on the real sentinel binary. **It installs in 15 ms; the row asserts < 10 s
  (N = 10 s).**
* `three child completions whose sessions have ENDED hold nothing either (14:37Z-15:20Z, 07308add)` — the
  40-minute wait. **It installs in 17 ms; the same N = 10 s.**

The others: the unnamed-holder and busy-with-nobody shapes must keep the request in the box **and** leave no
`failed/` record; an overdue operation is named; a bound failure is parked, re-queued once on the first quiet
tick, and the `done/` record shows `"requeued":true`; a second failure at the bound is not parked again.

Unit level: `rust/wa-sentinel/src/holders_tests.rs` tests 12–14 (**c4420837**),
`scripts/test-deploy-pause.lua` (5 new checks, **f4fdb170**) and `scripts/test-thinking-block.lua`
(5 new checks, **f4fdb170**) — all three files are existing rows.

### They fail on the base (measured, not asserted)

A worktree of `41d6420c` with only this mission's test files copied over:

* `cargo test --manifest-path rust/wa-sentinel/Cargo.toml holders` → `error[E0433]: cannot find \`Verdict\` in
  \`holders\`` (8 sites): the new unit tests cannot pass on the base;
* `scripts/test-deploy-bound.sh` → **18 failures**, every one of them a new step, and the old steps still pass.
  The base binary's own words for the two deadlocks, from that run:
  `the request failed at its bound: ... session da212b83 has a turn admitted and not started (child completion,
  admitted, not started)` — i.e. the base fails at the bound on exactly the shape the amendment measured;
* `scripts/test-deploy-pause.lua` → `attempt to call a nil value (field 'claim_wait')`;
  `scripts/test-thinking-block.lua` → `attempt to call a nil value (field 'deploy_refused')`.

## Texts to approve (job 5)

Nothing the model reads changes. What an operator, a landing or a worker sees, verbatim:

1. `hold-bound-passed` audit line (was: "...and all N holder(s) of the node have paused for it"):
   `{verb} proceeding: held {waited}s, past the {bound}s bound, and none of the {} holder(s) of the node can be
   hurt by it (each has paused for this request, or is a child completion that starts after the install)`
2. `wa-sentinel status`, a child completion holder:
   `  busy     session da212b83  child completion, admitted, not started 25m  not started yet, and does not hold
   the deploy`
3. `wa-sentinel status`, a run the snapshot gave no label: `  busy     session 8082b42e  a run, with no label 42s
   working`
4. `wa-sentinel status`, an overdue operation: `  busy     (no session named)  an operation is overdue for an
   unrecorded time`
5. `wa-sentinel status`, a parked request: `requeue:   1 request(s) that failed at their bound run when the node
   is quiet enough`
6. `failed/` record detail, appended: `; it is re-queued automatically once, when this node is next quiet`
   (or, for the copy that already came back: `; this request was already re-queued once, so it is not re-queued
   again`)
7. the re-queue's audit line `hold-bound-requeued` and console line: `{verb} re-queued: the node is quiet again:
   a request that failed at its bound went back into the box (the request's reason: {reason})`
8. the tick's console line: `re-queued {n} request(s) that failed at their bound: the node is quiet enough now`
9. a held request past its bound with an unnamed holder (the announcement, every time the reason changes):
   `{verb} held: {why}; the holder \`an operation is overdue\` names no session, so nothing proves it paused
   (waiting for idle; running turns pause at their next step, bound {bound}s)`
10. **what the paused worker sees** (agent.lua → the claim held by the pause; the same sentence the pre-run gate
    already gives): `deploy_waiting: waiting for the install of <sha> (deploy request <id>, asked <age>). This
    node starts no new turn while a build is waiting for it or being installed - a turn in flight is exactly what
    keeps the node from going idle - and this turn did not start. Nothing was lost: this is a wait, not a
    failure, and the work starts again once the swap is done. A running turn pauses after its current step
    instead (lua/core/deploy_pause.lua). To stop waiting, withdraw the request: wa-sentinel request withdraw <id>`
11. `wa chat` stderr, third word: `wa: session <id> not started` (was `failed`), and the process exits **2**
    (was 1).

## What I did not verify, and what is not mine

* **The exact race the agent deferral covers is not reproduced end to end.** The worker failure needs the deploy
  state to become visible *after* the run's pre-claim gate and *before* `resources.begin`; with a request in the
  box the gate refuses first and answers 2 (the planted case, `scripts/test-deploy-wait.sh` step 3, unchanged).
  The deferral is therefore covered by a unit test of the decision (`claim_wait`) and of the exit-code rule
  (`deploy_refused`), not by a live reproduction. Which of the two possible claim owners (a live paused run, or
  a killed one whose claim lingers) produced `ebf3d007` on 23/11 cannot be decided from the record, and the fix
  does not need to decide it.
* **No live check on the fleet.** Nothing in this mission called the live fleet; all builds and rows ran on this
  node against scratch homes (`$TMPDIR`), and `scripts/test-deploy-bound.sh` / `test-deploy-wait.sh` use their
  own ports, stub model and stub `/health`.
* The `WA_DEPLOY_HOLD_BOUND=0` drop-in on avell
  (`~/.config/systemd/user/wa-sentinel.service.d/orch-hold-bound.conf`) is the orchestrator's to remove after
  this lands; I did not touch it.
* A `Wait` has no second bound: a node that never names its holder keeps the request waiting for ever (the
  brief's rule 2). The landing's own timeout and `wa-sentinel request withdraw` are the ways out, and both are
  named in the line the operator reads.

## Proposals (not written) — FACTORY.md

```markdown
- **A bound is a wall on WAITING, and it has three answers, not two.** Past its bound a held request PROCEEDS
  (over holders the install cannot hurt: sessions that paused for it, and child completions, which start after
  it), FAILS BY NAME (only when every blocker is named) and is then RE-QUEUED ONCE on the first quiet tick, or
  KEEPS WAITING (when a holder names nobody). "The node is busy and names nobody" is never a failure: unknown is
  not yes, and it is not proof of a turn either. Evidence: 23/11, four landings failed at a 180 s bound against
  holders that were the deploy's own paused workers, their child completions, or nothing at all.
- **A pause is a promise.** A worker that paused for an install must be able to resume after it: a session
  claim held while a build waits is a WAIT (exit 2 with `deploy_waiting`, which the runners already wait out),
  never `run_resource_refused` and rc=1. Evidence: 23/11, components-calls-cheap (d2d69ff3) and
  release-linux-reads-the-receipt (0b8c9d78) both died rc=1 `resource_busy` while the node held them after the
  pause.
```

## Proposals (not written) — HANDOVER.md

```markdown
- Sentinel: a held request past `WA_DEPLOY_HOLD_BOUND` has three outcomes (`holders::Verdict`):
  `Proceed`/`Fail`/`Wait` — a child completion (`queue_sessions[].kind == "completion"`) and a holder with no
  session never block, a NAMED working session or named queued turn fails by name and is re-queued once from
  `<sentinel>/requeue/` on the first tick `hold_for` says the node is quiet. `wa-sentinel status` prints the
  parked count as `requeue:`.
- `wa chat` exits 2 (not 1) for a run refused by a waiting/installing build, including a run refused at its
  session claim (`deploy_pause.claim_wait`), and says `wa: session <id> not started`. Runners must keep waiting
  on `2` + `deploy_waiting` rather than charging a round.
```

## Commits

| commit | what |
| --- | --- |
| `c4420837` | holders: `Verdict` (Proceed/Wait/Fail), a child completion never holds the install, an unnamed holder is never a failure, the reporter names `current`-without-a-label and an overdue operation; the bound failure is re-queued once; unit tests 12–14 |
| `f4fdb170` | `deploy_pause.claim_wait` + `agent.lua` defers instead of failing a run whose claim the pause holds; `chat.deploy_refused` and exit 2 and `not started`; the six new steps in `scripts/test-deploy-bound.sh` and the new checks in `test-deploy-pause.lua` / `test-thinking-block.lua` |

## The 16:40Z amendment: a worker mid-turn must PAUSE, never end rc=2

MEASURED (orchestrator, 23/11 ~16:40Z): four workers - project-instructions-once, release-linux-reads-the-
receipt, graph-one-store-per-root and this mission - ended rc=2 in half an hour because their turn did NOT
start while a deploy waited (`deploy_waiting ... This node starts no new turn while a build is waiting`), and
every resume message sent while a deploy waited ended the same way.

That is the answer for a turn that has NOT started, and it is the documented one (`docs/SCRIPTED-RUNS.md`:
`2` = "refused before it started and nothing ran"; `scripts/worker-gate.sh` and `scripts/mission.sh` wait it
out without spending a round). A turn that is ALREADY RUNNING is a different path and must end differently:
it pauses at its own step boundary, writes its checkpoint and one resume wake, and ends CLEANLY - `0`. That
was never asserted, and a regression there would have read exactly like the four above. It is asserted now:

* `scripts/test-deploy-wait.sh` step 4 (**975df366**): the real turn of `scripts/lib/deploy-wait-e2e.lua`,
  mid-flight when the request lands, now asserts
  `[ "$TURN_RC" = "0" ] ... else fail "a turn that paused for the deploy ended rc=$TURN_RC: it must end
  cleanly, never as a refusal"`. Step 5 of the same row (unchanged) then proves the node's own tick performs
  the held resume after the deploy ends, which is the "resumes after the install" half.
* The claim-race half (the run refuses at its own session claim rather than at the gate) is the
  `deploy_pause.claim_wait` + `chat.deploy_refused` work above; a wake that hits it goes back with a new time
  instead of being consumed (`selfloop.defer_refused`, **20b538cf**, 13 assertions in
  `scripts/test-selfloop-pause.lua`).

## Rows run after the rebase (narrowed, singly where the lock was busy)

| row | result |
| --- | --- |
| `scripts/test-deploy-bound.sh` (rebuilt this tree's sentinel) | `deploy bound ok` |
| `scripts/test-deploy-wait.sh` (real node, real worker, real pause) | `deploy wait ok` (59 checks + the new rc assertion) |
| `scripts/test-deploy-wait.lua` | `deploy wait ok (59 checks)` |
| `scripts/test-deploy-pause.lua` | `deploy claim wait ok (28 checks)` |
| `scripts/test-thinking-block.lua` | `thinking block ok (104 checks)` |
| `scripts/test-selfloop-pause.lua` | `self-loop pause: 113 checks passed` |
| `scripts/test-completion-deploy-wait.lua` | `completion deploy wait ok (16 checks)` |
| `rust/wa-sentinel` unit tests (post-rebase) | `test result: ok. 148 passed; 0 failed` |

`scripts/fast.sh` narrowed (`WA_FAST_ROWS`) was **not** run to completion: the suite lock
(`~/Work/missions/.suite.lock`) was held by other missions' full suites for the whole window (measured with
`pgrep -af flock`: release-linux-reads-the-receipt with `--jobs 12`, project-instructions-once, main-health),
so the narrowed run queued behind them and was cancelled rather than waited out. The same rows were run one
by one, which is what the narrowed run would have selected, and single rows do not need the lock
(FACTORY rule 15). The always-on rows inside `fast.sh` (the land row's ten parts, prompt-docs, the
component checks) are therefore NOT covered by this report.

## One flake, named

`scripts/test-deploy-wait.sh` step 6 ("the held wakes run once the deploy ends") failed ONCE on this branch
(`dispatched=0` after `marker_down` + `clear_request`) and passed on an immediate re-run with nothing changed
between them; the two later runs (both after the rebase) also passed. It is timing under load (this node was
running three other suites), not a behaviour this mission changed: nothing in the diff touches
`selfloop.tick`'s dispatch or `deploy_pause.release_due`'s predicate. Not investigated further, and not
claimed as fixed.

## The last commit

| commit | what |
| --- | --- |
| `975df366` | `scripts/test-deploy-wait.sh`: a turn that paused for a deploy ends rc=0, never as a refusal |
| `20b538cf` | `deploy_pause.is_refusal` (one home for the two sentences), `chat.deploy_refused` asks it, `selfloop.defer_refused` puts a refused wake back; `test-selfloop-pause.lua` 13 assertions |
| `c4420837`, `f4fdb170`, `81ab7d49` | the sentinel, Lua and doc/report commits above, rebased onto `c1337903` |

## Follow-up review (Fable, 23/11 ~17:10Z): `7e5ff9b1`

### (a) rc=2 can never reach a turn that is already running

The two places a run is refused, both BEFORE anything is asked:

1. **the pre-run gate** — `lua/core/chat.lua` (the `--once`/`--resume` gate, `deploy_pause.refuse`) returns 2
   before `agent.run` is called. Only a NEW scripted run reaches it.
2. **the run's own session claim** — `lua/core/agent.lua`, `resources.begin` → `deploy_pause.claim_wait`
   (**f4fdb170**): the claim was taken by a turn the deploy paused, the run did not start, `turn_refused` is
   set and the CLI answers 2.

A turn that is mid-flight takes a different path: `deploy_pause.at_boundary` sets `reply` and `completed` and
leaves `turn_refused` nil, so the turn ANSWERED. That is now one function instead of an inline condition —
`chat.exit_code(ok, agent)` (**7e5ff9b1**): `0` answered, `2` refused-with-nothing-run, `1` failed — and the
`wa: session <id> ...` word follows it. Tests: `scripts/test-thinking-block.lua` asserts all four combinations
including **`exit_code(true, {turn_refused = 'deploy waiting: paused after this step'}) == 0`**, and
`scripts/test-deploy-wait.sh` step 4 asserts the paused turn end to end (`rc=0` with a deploy waiting).

**"retry when idle"**: `deploy_wait.RETRY` ends every refusal (`refusal`, `refusal_redacted`, and the pause's
own fallback in `deploy_pause.refuse`), so a script tells a wait from a failure with one substring instead of
judging prose. Asserted in `scripts/test-thinking-block.lua` and `scripts/test-deploy-pause.lua`.

### (b) a `Wait` with no end is noticed once

`Verdict::Wait` is deliberately endless, so after `WA_DEPLOY_HOLD_NOTICE` seconds (default **900**, `0` = off)
on the SAME reason the sentinel writes ONE `hold-wait-notice` line naming the holder — not a failure, and not
silence. The clock is a file (`<sentinel>/held/<request>.json`: reason, since, noticed), so a `once` and a
long-running watcher agree, and a restart does not restart the fifteen minutes; a **different** reason resets
it (it is a different holder, which is the fact the operator reads), and the record is removed when the request
stops waiting. Unit-tested with a **fake clock** (`holders_tests.rs`, `a_wait_that_never_ends_is_noticed_once`,
`wait_notice(key, why, now, 900)` with `now` 899 s and 900 s later and 100 000 s later), and end to end in
`scripts/test-deploy-bound.sh` (`WA_DEPLOY_HOLD_NOTICE=1`: no notice on the first tick, one after the window,
none on a later tick, the request still in the box).

### Base check for these follow-up tests (measured, not asserted)

A worktree of `origin/main` `b79da519` with only these test files: `test-deploy-pause.lua` fails on
`a refusal ends in retry-when-idle`; `test-thinking-block.lua` fails on `exit_code` (`attempt to call a nil
value`); the Rust tests do not compile (`cannot find function wait_notice` / `waiting_since`).

### Rows run for this follow-up

`scripts/test-deploy-bound.sh` → `deploy bound ok` (with the notice step);
`scripts/test-deploy-wait.lua` → `deploy wait ok (59 checks)`; `scripts/test-deploy-pause.lua` →
`deploy claim wait ok (30 checks)`; `scripts/test-thinking-block.lua` → `thinking block ok (111 checks)`;
`rust/wa-sentinel` → `test result: ok. 149 passed; 0 failed`.

### Texts to approve (follow-up), verbatim

12. `deploy_waiting: ... To stop waiting, withdraw the request: wa-sentinel request withdraw <id>. retry when idle:
    nothing was asked and nothing ran, so ask again once the node is back` (appended to both
    `deploy_wait.refusal` and `deploy_wait.refusal_redacted`, and to `deploy_pause.refuse`'s fallback)
13. `still waiting after <N>s on the same holder, unchanged: <the reason>. The request stays in the box; this is a
    notice, not a failure (wa-sentinel request withdraw <id> stops it)` — console and audit `hold-wait-notice`
14. `WA_DEPLOY_HOLD_NOTICE` — the new knob (default 900 s, `0` turns the notice off)

## Addendum (Fable, 23/11 ~20:50Z): 18 completions "admitted, not started" for finished workers

**Short answer.** The entry `wa-sentinel status` printed is not the `child_completions` row: it is a `PendingRun`
in the node's own scheduler queue (`rust/wa-capabilities/src/serve.rs`), pushed when a run is admitted to a
node-thread and removed when that thread STARTS it. Its age (`waited_ms`, which status prints as `13m`) is how
long it has been in a node thread's channel. So "the worker finished" is not the question: the completion is a
turn of its SESSION, and the session's node thread had a turn in front of it (the worker's own last turn, or the
deploy's pause). It is cleared by the node thread that dequeues it, and by nothing else.

**Who admits them.** `scheduler::admit(session, owner, RunClass::Background, pick_run_node_thread)` →
`Decision::Run`/`Decision::Behind` → `pending_admitted(run_id, session, node_thread, "completion")` —
`rust/wa-capabilities/src/serve.rs:3789` for a completion (the `"run"` sibling is line 2724). The DB-side
admission is a different lifecycle: `child_completions.state` (`ready` → `dispatching` → `running`) in
`lua/core/completions.lua`, dispatched by the node's tick (`lua/core/selfloop.lua`).

**Who releases them.** `pending_started(run_id)` — called by the node-thread loop when it takes the item
(`serve.rs:2857` for a completion work item, `:2904` for an HTTP run), and by the give-back paths at `:2747`,
`:2763`, `:2778`, `:2789`, `:2806` when an admission is returned (each paired with `scheduler::complete_run`).
There is no timeout in `pending_registry`: an entry lives exactly as long as its turn waits. That is the right
shape while the turn ahead is real work, and it is why 18 of them can be 13 minutes old without anything leaking.

**Measured on a scratch node** (`wa serve`, a stub model, ONE conversation, one 4 s turn ahead of three others;
the fixture is the one `scripts/test-deploy-wait.sh` uses):

```
-- sample 1  queue=3 named=3 entries=[{T1,kind=run,ms=1196},{T1,run,1190},{T1,run,1186}]
-- sample 2  queue=3 named=3 entries=[{T1,run,ms=2489},{T1,run,2486},{T1,run,2483}]
-- sample 3  queue=3 named=3 entries=[{T1,run,ms=3779},{T1,run,3776},{T1,run,3773}]
```

Three runs admitted behind one turn, each entry's `waited_ms` growing by exactly the clock, `named` counting all
three because `/health` names the session of each. (In that scratch run my stub turn never finished, so the queue
did not drain — a fixture fault, not the node's; the release is the code path above, and the drain is measured by
`scripts/test-deploy-wait.sh` step 2c, which builds a real queue and then sees it empty.)

**Whether they can ever hold a deploy: no.** Three independent reasons, all in this branch:

1. `holders::bound_verdict` SKIPS `completion` holders (`c4420837`): a completion is admitted, not started, and
   starts after the install — so a deploy proceeds over it. The measured shape is in
   `scripts/test-deploy-bound.sh` (five holders, three sessions: installs in 15 ms), and the field's 18 entries
   are the same shape with more of them;
2. while a request waits, a NEW completion never gets admitted at all: `wa_deploy_admission`
   (`lua/core/server.lua`) refuses the run at the door, and the node's tick defers it before dispatch
   (`lua/core/selfloop.lua:1262`);
3. what those entries wait for is a node thread, not the deploy: the deploy no longer waits on them, so the queue
   they are in is served as soon as the thread ahead finishes.

**Not a defect, and not fixable by a timeout.** Cancelling a queued completion after N minutes would delete a
child's report; the honest lever is the one this branch added — the deploy stops waiting for it. If a queued
completion's session is gone by the time it runs, `wa_completion_run` refuses it by name
(`completion_forbidden`, `lua/core/completions.lua`) and the queue entry is released at dequeue, as above.

## Addendum 2 (Fable, 23/11 ~21:40Z - G BLOCKER): a paused session is ALWAYS resumed by the node

A session paused for a deploy must be resumed by the node after the install, or after the request is withdrawn.
It was not, and a fleet node - or a person's own chat on `work` - has no factory watchdog to cover it.

### 1. Measured, read-only, on this laptop

| what | the record |
| --- | --- |
| the pause | `~/.wasm-agent/deploy-paused/603425eb-...json`: `{"since":1795465178,"source":"request","request":"1795465166243274647-...","to":"7e38abe976a0"}`; `66c0d5c1-...json`: `since:1795465172`, same request |
| the resume it armed | both mission logs say `paused after its step and scheduled a resume` with **no** `the resume wake could NOT be scheduled` (`esc-stops-now/out.log:36080`, `worker-write-guard/out.log:19`) |
| the deploy it waited for | `sentinel.log:903` `1795465166 maintenance-deferred deploy 1795465166243274647 ...`; `:906` `return-observation-problem ... missing binding.json`; `:912` `return-observation-retired ...` - and the request is in `~/.wasm-agent/sentinel/done/` |
| the state today | `wa session status` for both: `0 wakes pending` |
| the mission's own clock | `worker-write-guard/out.log`: `the node owns session 603425eb after a deploy pause: waiting for it to go quiet 2026-11-23T19:29:43Z`, then `still paused for a deploy after 2 h: no done written ... the orchestrator resumes it` |
| a third case, live | this mission's own session, paused at ~22:0xZ for the install of `dd76f874`, was resumed by the orchestrator and by no node (`paused-evidence.log`: `rows-that-render session 93cf1a67 ... sat 901s`) |

**Why `release_due` did not fire.** It fired nothing because there was nothing for it to fire: `release_due`
(`lua/core/deploy_pause.lua`) only ever touches rows that are still `pending`
(`SELECT ... WHERE status='pending' AND reason=? AND due_at>?`). The resume row of each session had already left
`pending` without a turn: its dispatch was cut by the very install it paused for, and the reconcile then wrote
`unknown` with `dispatch interrupted; not replayed` - which is by design never replayed. So the promise was
armed once and then lost, and the ledger had no owner for it.

### 2. The fix (`94c66c5b`)

`deploy_pause.ensure_resumes(now, opts)`, called by the node's own tick (`lua/core/selfloop.lua`, right after
`release_due`, once nothing waits or installs): every resume row that ended `unknown`, `failed` or `cancelled`
is a DEBT - the node arms a fresh resume for that session, marks the lost row `superseded` (so it is re-armed
exactly once) and says so on the log it keeps (`deploy pause: re-armed the LOST resume of session ...`). A
session that already has a `pending`/`dispatching` resume is left alone, and while a build waits or installs
nothing is re-armed at all. The new wake carries `deploy_pause.resume_prompt()`: the deploy is over, the resume
that was armed was lost, re-establish the real state and continue (text listed below).

### 3. Tests: every session kind, both endings

`scripts/test-deploy-wait.sh` step **7b** (real node, real ledger, real scheduler stub; `deploy wait ok`, six
cases green): for `served`, `worker` and `selfwake`, and for `install` and `withdraw`:

1. a paused session whose resume row is `unknown` is written by the fixture (the record, the armed wake, the cut);
2. while the deploy waits (request in the box; marker up for `install`): `dispatched=0`, `rearmed=0`;
3. the deploy ends (marker down for `install`, request withdrawn for `withdraw`): `rearmed=1`, and the resumed
   turn is dispatched on that tick or the next one (measured: `rearmed=1 dispatched=0`, then `dispatched=1`,
   because `selfloop.schedule` never arms a past time);
4. and once only: `rearmed=0` on every later tick.

Unit level, with a **fake ledger, scheduler and clock** (`scripts/test-deploy-pause.lua`, 37 checks): a waiting
deploy re-arms nothing; two lost resumes are re-armed and one that already owes a newer pending row is not; the
lost rows are marked `superseded`; the prompt is the new sentence; a later tick re-arms nothing.

### 4. The health line

`wa-sentinel status` prints it always, so "none" is a fact an operator can check rather than an absence they
have to notice:

```
paused sessions: 2, oldest 2h
paused sessions: 0, oldest none
```

Asserted in `scripts/test-deploy-bound.sh` (two records, one two hours old: `paused sessions: 2, oldest 2h`), and
built from the same `<data>/deploy-paused/*.json` records the sentinel already read for `paused_since`
(`paused_summary`, **94c66c5b**). An undated record is counted, so it never reads as "none".

### 5. Texts to approve (23/11, G blocker)

15. the re-armed wake's prompt (it goes to a model): `[deploy pending] The deploy this session paused for is OVER,
    and the resume that was armed for it was lost (a dispatch cut by the install it was waiting for). Nothing was
    replayed and nothing was cut mid-call. Re-establish the real state from the machine first (files, `git status`,
    processes, and this session's own notes checkpoint under "Deploy pause"), then continue the request you were
    already working on and say plainly what had already been done before the pause.`
16. the log line of a re-arm: `deploy pause: re-armed the LOST resume of session <id> (wake <lost> had no outcome,
    new wake <new>)` — `host.log`, once per re-arm
17. `wa-sentinel status`: `paused sessions: <n>, oldest <age>` (or `oldest none`)

### 6. Scope (G blocker)

The guarantee is the node's, not the runner's: it is the same `selfloop.tick` for every session kind, and it
holds with no watchdog present - which is what makes it safe for a fleet node and for a person's chat, neither of
which has the orchestrator's paused-marker watchdog. That watchdog can stay until this is rolled out.

## Addendum 3 (Fable, 23/11 ~22:35Z): the resume repair, bounded

Fable accepted the root cause of `94c66c5b` and found three defects in it, plus one question. All four are fixed
on this branch; the texts 15-17 he approved are unchanged.

### 1. No age bound -> a 6 h window, and a one-time migration

`ensure_resumes` now reads only rows whose own `created_at` is inside `M.RESUME_WINDOW_SECONDS` (**6 h**), and
only for a session that still exists and is not parked. Without the bound, the first tick after an install on
every node at G would wake every session that ever lost a resume - paid model turns, days later, on stale
requests. Rows older than the window are retired ONCE, by a migration that says how many it retired
(`deploy pause: migration: N lost resume row(s) older than 21600s marked superseded (too old to resume)`), keyed
by `<data>/resume-migration-1` so it runs once per node.

Tested with a fake ledger: an `unknown` row created 7 h ago and one created 1 min ago -> exactly one wake, for
the recent one; and with the marker absent, the migration reports `changes` and writes it with that count, while
still waking nothing old.

### 2. "Exactly once" was false -> a chain of 2, with backoff, then abandoned

The re-armed wake is itself a resume row, so a session that can never run would be re-armed every tick for ever.
The chain is carried on the new row's own `attempts` (`+1` per re-arm), the wait grows
(`M.RESUME_BACKOFF_SECONDS * chain`: 30 s, then 60 s), and past `M.RESUME_MAX_REARMS` (**2**) the row becomes
`resume_abandoned`, the session's pause record is marked `abandoned` (so the health line can count it) and ONE
log line says so. So a resume that always fails is tried **3 times in total** (the original turn, one re-arm, a
second re-arm) and then stops.

Tested: a row at the cap is abandoned, not re-armed (`rearmed=0, abandoned=1`), no wake is scheduled, its row
says `resume_abandoned` and the pause record is marked; and in the same pass both under-cap rows are re-armed
with 1x and 2x backoff and carry their place in the chain.

### 3. An operator's cancel is final

`cancelled` is re-armed ONLY when the NODE cancelled the dispatch - `last_error = 'cancelled before execution'`
(`lua/core/selfloop.lua:1262`, the run's own cancellation before it started) - and never a bare `cancelled`,
which is what `wa wake cancel` writes (`lua/core/selfloop.lua:612`) and what the due-cancel writes (`:822`).
Tested: one row of each; only the node's is re-armed, and the person's stands.

### 4. An interactive chat whose window was CLOSED during the pause

**It is resumed, and it is not a new policy: it is the existing behaviour of every wake in this tree.** Closing
the window ends the SSE stream and nothing else - no code parks a session when a reader goes away (the only
writer of a hold is `wa session park`, `lua/core/session_park.lua`, whose state is a `self_wake_pauses` row of
kind `park`; `lua/core/server.lua:782-792` is a ­reader of that state, not a writer). `selfloop.tick` dispatches
the rows of every session that is not parked, exactly as it does for a `--once` worker and a self-wake, so the
resume runs with nobody attached and its answer is written into the transcript - which is what the person finds
when they reopen the conversation, and what the ledger's `unfinished` state already assumes.

The two mechanisms that DO stop a session are honoured by `ensure_resumes`: a session row that no longer exists
is not woken, and a parked one (`self_wake_pauses`) is not woken - the same rule the tick uses. If the product
ever wants "no turn without a reader", that is a park, and `wa session park` already exists for it; this mission
does not invent a second rule.

### Rows run for this review

| row | result |
| --- | --- |
| `scripts/test-deploy-pause.lua` (window, migration, chain, backoff, operator cancel, gone/parked, waiting) | `deploy claim wait ok (49 checks)` |
| `scripts/test-deploy-wait.sh` (incl. 7b: served/worker/selfwake x install/withdraw) | `deploy wait ok` |
| `scripts/test-deploy-bound.sh` (incl. the health line with `abandoned:`) | `deploy bound ok` |
| `scripts/test-selfloop-pause.lua` | `self-loop pause: 113 checks passed` |
| `scripts/test-cli-wake-row.lua` | `cli wake row ok (30 checks)` |
| `scripts/test-handle-wake.lua` | `handle wake: 17 checks` |

### Texts to approve (added by this review)

18. `deploy pause: ABANDONED the resume of session <id> after <n> re-arm(s) (wake <lost>); the pause record says so`
19. `deploy pause: migration: <n> lost resume row(s) older than 21600s marked superseded (too old to resume)`
20. `wa-sentinel status`: `paused sessions: <n>, oldest <age>, abandoned: <m>` (text 17 now carries the count)

## Addendum 4 (Fable, 23/11 ~23:40Z): what `sync tick` is, and should it hold an install?

Read-only measurement; the proposal is on a branch that is **not** merged.

### What it is

`sync tick` is one label around the node's whole **housekeeping pass** on node-thread 0 - peer sync, the sync
cadence, retention - set by `begin_work("sync tick".to_string())` in the node-thread loop
(`rust/wa-capabilities/src/serve.rs:3145`, the block at `:3128` "Housekeeping last, and only when nobody is
waiting and the node has been quiet"). `begin_work` is what `/health` publishes as the thread's `label`, and
`holders::holders_from` turns every labelled thread into a holder; with no session on it, it lands in
`Verdict::Wait` ("the holder `sync tick` names no session, so nothing proves it paused") - so the install keeps
waiting, which is what the sentinel logged.

### How long it held today (`~/.wasm-agent/sentinel/sentinel.log`, read-only)

| deploy request (reason) | sync-tick hold lines | span of the hold | first tick line -> installer started |
| --- | --- | --- | --- |
| `179540254619617968` | 5 | **602 s** | 1264 s |
| `179546726666232120` (tool-args-honest c618da4f) | 8 | **661 s** | 705 s |
| `179546963874689690` (4287aae1) | 6 | **422 s** | 584 s |
| `179547102933736299` (4425f670) | 6 | **481 s** | 500 s |
| `179547337894649177` (ad3fb3c5) | 5 | **361 s** | 529 s |
| `179547471149786849` (ffd2a0a5 - this mission) | 1 | 0 s | **297 s** |

Six installs, and between 6 and 11 minutes of waiting each; the install of this mission's own fix waited 297 s on
it (`sentinel.log:1016`, `1795475023  maintenance-deferred  deploy 1795474711497868497 … the holder `sync tick`
names no session`, with the installer at `1795475320`). It is new in the sense that matters: no other unnamed
holder appears this often, and a pass that the node itself decides to start (because it looks quiet) is exactly
the work that a queued install should not have to outlast.

### Should it be excluded, the way admitted-not-started completions are? YES - within an allow-list

A housekeeping pass is not a turn: it holds no session, it can never pause, and the node the install brings up
runs the same pass again (sync and retention are idempotent and their progress is a file/ledger, not a
conversation). Waiting for it costs the install minutes and buys nothing a resume would not give back. So the
proposal skips it in `bound_verdict`, exactly as `completion` is skipped, under two rules:

1. an **ALLOW-LIST** (`is_housekeeping`: `sync tick`, `sync tick:*`), so a label this tree does not know still
   holds the install - unknown is not yes;
2. it changes nothing before the bound: the install still waits its `WA_DEPLOY_HOLD_BOUND` first, and the pass is
   only passed over afterwards.

Residual risk, stated: the installer stops the unit with SIGTERM while a pass may be mid-write. That risk already
exists for any run at the bound, the pass is idempotent, and a cut pass is redone by the new node - but it is the
one thing to weigh, and it is why this is proposed rather than landed. A second, independent lever (not proposed
here) is to make the node not START housekeeping while a deploy request waits: the node can read the sentinel's
box (`deploy_wait.read`), which is the same signal the pause uses.

### The proposal (branch `proposal/housekeeping-holds-no-install`, commit `5aba5a93`) - NOT merged

```diff
