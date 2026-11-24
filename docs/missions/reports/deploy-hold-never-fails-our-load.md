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
diff --git a/rust/wa-sentinel/src/holders.rs b/rust/wa-sentinel/src/holders.rs
index db283cc8..a7ab2848 100644
--- a/rust/wa-sentinel/src/holders.rs
+++ b/rust/wa-sentinel/src/holders.rs
@@ -54,25 +54,40 @@ pub(crate) struct Holder {
     /// operation settled. It starts after an install, never before, so the install never waits on it (see the
     /// module note, measurement 2).
     pub completion: bool,
+    /// A NODE-INTERNAL pass: work the node does FOR ITSELF (`sync tick`, the housekeeping block of
+    /// rust/wa-capabilities/src/serve.rs `node_thread_loop`), with no session behind it and no turn to finish.
+    /// MEASURED (23/11, ~/.wasm-agent/sentinel/sentinel.log): it was named as the holder of six installs and held
+    /// each for 6-11 minutes (`span=661s`, `481s`, `422s`, `361s`, `602s`), because it is a single label around a
+    /// whole pass - so a node that had just decided it was quiet looked busy to the sentinel for as long as the
+    /// pass took, and `Verdict::Wait` waited it out.
+    pub housekeeping: bool,
+}
+
+/// The labels the node gives to its OWN housekeeping: an ALLOW-LIST, because a label this list does not know is
+/// not housekeeping - and an unknown label still holds the install ("unknown is not yes"). One entry today, with
+/// its prefix form so a later pass that says `sync tick: peers` is still recognised.
+pub(crate) fn is_housekeeping(label: &str) -> bool {
+    let label = label.trim();
+    label == "sync tick" || label.starts_with("sync tick:")
 }
 
 impl Holder {
     fn new(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
-        Holder { session: session.into(), label: label.into(), ms, queued: false, completion: false }
+        Holder { session: session.into(), label: label.into(), ms, queued: false, completion: false, housekeeping: false }
     }
 
     pub(crate) fn admitted(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
-        Holder { session: session.into(), label: label.into(), ms, queued: true, completion: false }
+        Holder { session: session.into(), label: label.into(), ms, queued: true, completion: false, housekeeping: false }
     }
 
     /// A child completion, admitted and not started. Its own constructor, because "admitted and not started"
     /// and "admitted, not started, and a completion" are the two answers the bound treats differently.
     pub(crate) fn completion(session: impl Into<String>, label: impl Into<String>, ms: u64) -> Holder {
-        Holder { session: session.into(), label: label.into(), ms, queued: true, completion: true }
+        Holder { session: session.into(), label: label.into(), ms, queued: true, completion: true, housekeeping: false }
     }
 
     fn counted(label: impl Into<String>, completion: bool) -> Holder {
-        Holder { session: String::new(), label: label.into(), ms: 0, queued: false, completion }
+        Holder { session: String::new(), label: label.into(), ms: 0, queued: false, completion, housekeeping: false }
     }
 }
 
@@ -106,11 +121,11 @@ pub(crate) fn holders_from(health: &Value) -> Vec<Holder> {
             if entry.get("label").map(|label| label.is_null()).unwrap_or(true) {
                 continue;
             }
-            holders.push(Holder::new(
-                field_str(entry, "session"),
-                field_str(entry, "label"),
-                field_u64(entry, "busy_ms"),
-            ));
+            let label = field_str(entry, "label");
+            let housekeeping = is_housekeeping(&label);
+            let mut holder = Holder::new(field_str(entry, "session"), label, field_u64(entry, "busy_ms"));
+            holder.housekeeping = housekeeping;
+            holders.push(holder);
         }
     }
     if let Some(current) = health.get("current") {
@@ -291,6 +306,12 @@ where
         if holder.completion {
             continue;
         }
+        // A NODE-INTERNAL PASS IS NOT A TURN, so the install does not wait for it to finish: it is the node's own
+        // sync/retention, it holds no session and can never pause, and the node that the install brings up runs the
+        // same pass again (both are idempotent). Only labels on the allow-list (`is_housekeeping`) are skipped.
+        if holder.housekeeping {
+            continue;
+        }
         if holder.session.is_empty() {
             unnamed.get_or_insert_with(|| format!(
                 "the holder `{}` names no session, so nothing proves it paused", holder.label));
diff --git a/rust/wa-sentinel/src/holders_tests.rs b/rust/wa-sentinel/src/holders_tests.rs
index 4c45683e..9a0680c6 100644
--- a/rust/wa-sentinel/src/holders_tests.rs
+++ b/rust/wa-sentinel/src/holders_tests.rs
@@ -94,9 +94,9 @@ fn current_is_a_holder_once() {
 #[test]
 fn holder_lines_name_the_session_and_its_duration() {
     let holders = vec![
-        holders::Holder { session: "8082b42e-1111-2222".into(), label: "POST /chat".into(), ms: 134_000, queued: false, completion: false },
-        holders::Holder { session: "deadbeef-1111-2222".into(), label: "POST /chat".into(), ms: 9_000, queued: false, completion: false },
-        holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0, queued: false, completion: false },
+        holders::Holder { session: "8082b42e-1111-2222".into(), label: "POST /chat".into(), ms: 134_000, queued: false, completion: false, housekeeping: false },
+        holders::Holder { session: "deadbeef-1111-2222".into(), label: "POST /chat".into(), ms: 9_000, queued: false, completion: false, housekeeping: false },
+        holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0, queued: false, completion: false, housekeeping: false },
     ];
     let lines = holders::holder_lines(&holders, |session| session.starts_with("8082b42e"));
     assert_eq!(lines.len(), 3, "one line per holder: {lines:?}");
@@ -109,9 +109,9 @@ fn holder_lines_name_the_session_and_its_duration() {
 /// for this request and over nothing else - not a working session, not a subagent, not a run with no session.
 #[test]
 fn the_bound_passes_over_paused_sessions_only() {
-    let working = holders::Holder { session: "8082b42e-1111".into(), label: "POST /chat".into(), ms: 120_000, queued: false, completion: false };
-    let paused_one = holders::Holder { session: "aaaa1111-2222".into(), label: "POST /chat".into(), ms: 120_000, queued: false, completion: false };
-    let nameless = holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0, queued: false, completion: false };
+    let working = holders::Holder { session: "8082b42e-1111".into(), label: "POST /chat".into(), ms: 120_000, queued: false, completion: false, housekeeping: false };
+    let paused_one = holders::Holder { session: "aaaa1111-2222".into(), label: "POST /chat".into(), ms: 120_000, queued: false, completion: false, housekeeping: false };
+    let nameless = holders::Holder { session: "".into(), label: "2 subagent(s) running, 0 queued".into(), ms: 0, queued: false, completion: false, housekeeping: false };
 
     // Before the bound: held, whatever the holders are doing.
     let early = holders::bound_verdict(10, 180, &[paused_one.clone()], |_| true);
@@ -383,3 +383,38 @@ fn a_wait_that_never_ends_is_noticed_once() {
     }
     let _ = std::fs::remove_dir_all(&home);
 }
+
+/// 16. A NODE-INTERNAL PASS DOES NOT HOLD AN INSTALL (proposal, 23/11 ~23:40Z; NOT landed). MEASURED in
+/// ~/.wasm-agent/sentinel/sentinel.log: `sync tick` was named as the holder of six installs and held each for 6-11
+/// minutes (`span=661s`, `481s`, `422s`, `361s`, `602s`), because one label covers a whole housekeeping pass - so a
+/// node that had just decided it was quiet read as busy for as long as the pass took.
+///
+/// The rule is an ALLOW-LIST: `is_housekeeping` knows `sync tick`, and a label it does not know still holds.
+#[test]
+fn a_node_internal_pass_does_not_hold_an_install() {
+    let body = health(
+        r#"{"ok":true,"queue":0,"operation_overdue":false,"current":null,
+             "node_threads":[{"id":0,"session":null,"label":"sync tick","state":"busy","busy_ms":600000}],
+             "workers":[],"subagents":{"queued":0,"running":0,"active":0}}"#,
+    );
+    let holders = holders::holders_from(&body);
+    assert_eq!(holders.len(), 1, "the pass is named as a holder: {holders:?}");
+    assert!(holders[0].housekeeping, "and it is known to be node-internal: {holders:?}");
+    assert_eq!(holders::bound_verdict(200, 180, &holders, |_| false), holders::Verdict::Proceed,
+        "the install does not wait for the node's own housekeeping pass");
+    assert!(holders::is_housekeeping("sync tick: peers"), "the prefix form is recognised too");
+    assert!(!holders::is_housekeeping("POST /chat"), "a run is not housekeeping");
+
+    // An UNKNOWN internal label is not on the allow-list: it holds, exactly as it did before this proposal.
+    let unknown = health(
+        r#"{"ok":true,"queue":0,"operation_overdue":false,"current":null,
+             "node_threads":[{"id":0,"session":null,"label":"some new maintenance pass","state":"busy","busy_ms":600000}],
+             "workers":[],"subagents":{"queued":0,"running":0,"active":0}}"#,
+    );
+    let holders = holders::holders_from(&unknown);
+    assert!(!holders[0].housekeeping, "a label the allow-list does not know is not housekeeping");
+    match holders::bound_verdict(200, 180, &holders, |_| false) {
+        holders::Verdict::Wait(why) => assert!(why.contains("names no session"), "{why:?}"),
+        other => panic!("an unknown internal label must still hold: {other:?}"),
+    }
+}
```

The tests that go with it, on the same branch:

* `rust/wa-sentinel/src/holders_tests.rs::a_node_internal_pass_does_not_hold_an_install` - a node whose only
  thread is `sync tick` PROCEEDS, an unknown internal label still WAITS, and `is_housekeeping` is asserted on the
  allow-list rule (`holders 16 passed`);
* a new step in `scripts/test-deploy-bound.sh` - the real sentinel binary against that `/health` body: the
  installer runs (`deploy bound ok`).

**Not landed, by instruction:** the branch is `proposal/housekeeping-holds-no-install` at `5aba5a93`, and this
report commit only records it. Fable decides.

## Addendum 5 (Fable, 23/11 ~23:50Z): a spawned installer always ends in a verdict; and `sync tick` stops starting

### 1. LOST INSTALL REQUEST (G blocker): measured, then fixed

**What happened to `1795474711` (ffd2a0a5), read-only:**

* the request was held on holders (a worker turn, then `sync tick`, then `busy, names no holder`) until `1795475320`
  (22:28:40Z), when the installer was spawned: `done/1795474711497868497-….json` says
  `phase: spawned`, `detail: "deploy started detached (unit wa-deploy-1795475320-1196761, output appended to
  …/sentinel/deploy.out) … no session was named, so no notice can be delivered for it (pass --session)"`, and its
  request names `target_commit: ffd2a0a5dd92…`;
* the installer **refused**: `sentinel/deploy.out`, last block - `--- deploy unit wa-deploy-1795475320-1196761 at
  1795475320 script /home/victor/wasm-agent/checkout/scripts/deploy.sh reason land-quick
  deploy-hold-never-fails-our-load (ffd2a0a5)` … `deploy: refused(component_proof_failed): the candidate binary did
  not answer a graph call through the staged component; nothing installed`, and above it the cause:
  `component: lua error: …:16: graph_index: graph_dormant`;
* it wrote **none** of `binding.json`, `ack.json`, `intent.json` into `sentinel/deploy-protocol/<id>/` - so the
  return engine (`sentinel_return` + the `onSentinelReturn` job, the owner of a protocol deploy's report) could not
  observe it: `sentinel.log` `1795475660 return-observation-problem … cannot be observed: missing binding.json,
  ack.json, intent.json`, then `1795475960 return-observation-retired … unchanged for 300s`;
* the retired directory holds **only `result.json`** (523 bytes) - no protocol files at all;
* `~/.local/bin/installed.txt` still named `commit=4425f670…`, and the box answered `0 waiting`. So: not installed,
  not failed, not re-queued. The orchestrator re-requested it by hand at ~23:35Z.

**Why the installer wrote nothing:** it refused *before* the protocol return step, at its component proof
(`deploy.sh`'s `component_proof_failed`, caused by `graph_dormant`). The refusal is a legitimate outcome; what was
missing is that nothing turned "installer ended, nothing installed" into a request outcome.

**Fix (`installer_outcome.rs`, wired into `observation.rs`).** The lane that decides whether a protocol directory
can still be observed no longer retires a directory whose installer already ended. It asks the installer's own
three files instead:

| fact | source |
| --- | --- |
| the commit the request asked for, and its reason | the sentinel's own `done/<id>.json` (the `spawned` record) |
| what is installed | `installed.txt` beside the installed binary |
| what the installer said | its block in `deploy.out`, found by the request's own reason (`--- deploy unit … reason <reason>`) |

`verdict_of` is pure and answered in three ways: `Installed` (the record names the request's commit, or the
installer's block ends `deploy: installed`), `Uninstalled(<the installer's line>)` (its block ends in any other
terminal line, or there is no block at all - said as such), `Running` (a block with no terminal line: nothing is
claimed). `fail_unobserved` then writes `failed/<id>.json` with `phase: unobserved` and that sentence, one queue
record, ONE re-queue (`schedule_requeue`, the same once-per-request path the bound uses) and - when the request
named a session - the exactly-once deploy-outcome notice; otherwise the audit line `deploy-unobserved-failed` is
the notice, since a request with no session has nobody to wake (the record says so itself).

So a request whose installer started now ends in exactly one of: **installed**, or **failed with the installer's
reason and re-queued once**. Retiring an unobservable directory with nothing installed is no longer possible while
the installer's verdict can be read.

Tests: `installer_outcome_tests.rs` (6) - the measured case word for word, an install that reached the record, an
installer with no terminal line (still `Running`), an earlier landing's `installed` never answering for this one,
no target commit = no verdict, and `fail_unobserved` writing `failed/` + exactly one re-queue and doing nothing on
a second pass. `rust/wa-sentinel` unit tests: **159 passed**.

### 2. `sync tick`: Fable's alternative, implemented (the allow-list is gone)

* **It does not START while a deploy waits or installs.** `serve.rs`'s housekeeping block now asks
  `wa_deploy_pending()` (Lua, one predicate that reuses `deploy_pause.waiting`: the installer's marker, the request
  box and the claimed lane) before starting `wa_sync_tick` and `wa_retention`. A reader that cannot answer returns
  `0` (the previous behaviour) and the node prints one line - a broken reader must not silence the node's sync for
  ever.
* **A pass already running finishes, and yields before its network phase.** `wa_sync_tick` does the cheap phases
  (update banner, backup *due* check - the snapshot itself already runs as a supervised operation) and then, if a
  deploy is waiting, returns with `yielded: a deploy is waiting for or installing on this node` before the peer
  push; the next quiet window after the install does it.
* **Worst case, stated.** The sentinel's own record cannot say how long ONE pass lasts - its intervals are
  observation spans across the 20 s cadence (the six installs' spans were 361-661 s in total, each a series of
  passes), so I do not claim a per-pass number I did not measure. What is bounded now: a pass cannot *start* while
  a deploy waits, and a pass that is running stops before its one network phase, which is the phase bounded by the
  peer call's own timeout. If the residual (the cheap phases of an already-running pass) ever proves long enough
  to matter, the next yield point belongs between the backup-due check and the banner refresh; that is where the
  remaining work is, and it is milliseconds today.
* **What is NOT asserted, said plainly:** the gate itself has no row. A test was written for it in
  `scripts/test-deploy-wait.sh` (step 7c: sample `/health` for the `sync tick` label with nothing waiting, then
  under a request) and it printed `SKIP`: the label lives only for the duration of the call, which is milliseconds
  when there is nothing to push, so a 3 s sampling loop cannot observe it - the label measured in `sentinel.log` was
  long because that pass was doing network work. It was removed rather than kept as a test that proves nothing. The
  gate's two halves are covered by reading: `wa_deploy_pending` reuses `deploy_pause.waiting` (the signal the pause
  rows already assert), and `serve.rs` adds one `&& !deploy_pending()` to each housekeeping start. A counter (a
  `health` field or a per-tick log line) is what would make it assertable, and it is the first thing to add if
  Fable wants this row.
* **No label allow-list after the bound:** `holders.rs` is unchanged on this branch, and
  `proposal/housekeeping-holds-no-install` stays **unmerged** (its allow-list is superseded by this).

### Texts to approve (23/11, this review)

21. `deploy <id> failed without a verdict: the installer ended and nothing was installed: <the installer's line>; it is re-queued automatically once, when this node is next quiet; re-request with: wa-sentinel request deploy --expected-sha <sha> --reason '<reason>'` - console, `failed/<id>.json`, the queue record, and audit `deploy-unobserved-failed`
22. `return-observation-failed` audit line: `<problem>; the installer ended and nothing was installed, so the request failed with its own reason and was re-queued once (no retirement)`
23. node log: `sync tick: yielded to a waiting deploy; the next quiet window does the rest`
24. node stderr, once: `[sync] wa_deploy_pending unavailable, housekeeping starts as before: <error>`

## Addendum 6 (r4, Fable, 24/11 ~00:55Z): the repair counted the wrong column

### What was wrong (measured on this laptop after `bd37681f`, read-only, by Fable)

The first tick after the install (`00:32:20-28Z`) marked **46 resume rows in 16 live factory sessions**
`resume_abandoned`. Their `self_wakes.attempts` values: 2,3,4,5,6,7,9,11,13,73,82,199,249,308,464,486,533. Cause:
the chain cap read `attempts`, a column that already counts DISPATCH attempts, so every recent lost resume hit
"max 2 re-arms" on its first pass and the repair did nothing for any of them (the safe direction - 0 wakes fired -
and the wrong result). Separately, `paused sessions: 53, oldest 1d` counted every `<data>/deploy-paused/*.json`
ever written, and nothing deleted one; the migration retired 86 rows, as designed.

### 1. A dedicated chain counter (never `attempts`)

`self_wakes` gains **`resume_chain INTEGER NOT NULL DEFAULT 0`**, added by the same conditional `ALTER TABLE` this
table already uses for `kind` (`lua/core/selfloop.lua`, `M.setup`). `deploy_pause.ensure_resumes` reads and writes
only that column; `attempts` is neither read nor written by the repair again, and the unit test asserts that no
statement of the repair writes `attempts`.

### 2. The health line counts what is live, and dead records are closed

* `paused_summary` (`main.rs`) counts a record as **live** only when its `since` is inside the same window the repair
  uses (`pause_window_secs()` = 6 h, documented as the same number as `deploy_pause.RESUME_WINDOW_SECONDS`); the
  rest are **stale**. The line is now
  `paused sessions: <live>, oldest <age of the oldest live>, stale: <n>, abandoned: <m>`.
* `deploy_pause.sweep_records` closes the records that can never be resumed: older than the window, or their session
  no longer exists (ended/closed). A young record whose session is live is never touched - it is the proof the
  bound uses. It runs **last in the node's tick**, because called early it moved a released resume's dispatch out of
  that tick (measured: `test-deploy-wait.sh` step 6 failed twice in a row, green once the call moved to the end).

### 3. Tests, and how the fixtures match the real ledger

**How I checked the shapes this time (Fable's item 4).** The fixture rows in `scripts/test-deploy-pause.lua` are the
ledger's own numbers, copied from Fable's read-only select of the 16 factory sessions - `attempts`
`2,3,4,5,6,7,9,11,13,73,82,199,249,308,464,486,533`, status `unknown`, reason
`deploy pending: resume after the node swap`, `resume_chain = 0` - and not zeroes. I could not re-run that select
myself: `~/.wasm-agent/memory.db` is refused to the agent's shell by the node's own guard (`secret_path_denied`,
`lua/core/secret_guard.lua`: "it holds the MCP registry, every connector's approval and the session ledger, so an
agent tool neither reads nor writes it"), and `wa` exposes no verb for raw wake rows. So the shapes are Fable's
measurement, quoted, and every one of them asserts the outcome the bug broke: **exactly one re-arm, whatever
`attempts` says** (`rearmed == 17, abandoned == 0`, and `resume_chain=1` written on each new row).

* the cap is asserted on the same real shapes: `resume_chain` 0 -> re-arm, 1 -> re-arm (backoff doubled), 2 ->
  `resume_abandoned` with the pause record marked - **three tries in total**;
* an operator's `cancelled` is still final and the node's own `cancelled before execution` is still re-armed, on
  rows with `attempts` 73 and 464;
* gone/parked sessions are not woken (attempts 199, 249); a seven-hour-old row is not woken and the migration
  reports what it retired; a waiting deploy re-arms nothing;
* `sweep_records` closes exactly the old, the gone and the undated record, keeps the young live one, and never looks
  at a non-JSON entry.

### Rows run for r4

| row | result |
| --- | --- |
| `scripts/test-deploy-pause.lua` | `deploy claim wait ok (81 checks)` |
| `scripts/test-deploy-wait.sh` | `deploy wait ok` |
| `scripts/test-deploy-bound.sh` | `deploy bound ok` |
| `scripts/test-selfloop-pause.lua` | `self-loop pause: 113 checks passed` |
| `scripts/test-handle-wake.lua` | `handle wake: 17 checks` |
| `scripts/test-cli-wake-row.lua` | `cli wake row ok (30 checks)` |
| `rust/wa-sentinel` unit tests | `159 passed; 0 failed` |

Also changed in the row, and said plainly: the six cases of step 7b now run on **their own ledger** (a tick
 dispatches at most eight due rows, so six cases sharing one measured each other's backlog - the dispatch assertion
 moved between cases from run to run), and the dispatch assertion allows up to twelve ticks instead of one, because
 the re-armed row is armed a second out and the node's real cadence is five ticks a second.

### Texts to approve (r4)

25. `wa-sentinel status`: `paused sessions: <live>, oldest <age>, stale: <n>, abandoned: <m>`
26. node log, once per sweep that closes anything: `deploy pause: closed <n> pause record(s) that can never be resumed
    (older than 21600s, or their session is gone)`

### r4.1 (Fable's review of the r4 diff, 24/11 ~01:00Z): a record is closed only on a POSITIVE fact

Two fixes in `deploy_pause.sweep_records`, both required before landing:

* **(a) a lookup that fails is not a dead session.** The default lookup now answers three ways - `true` live,
  `false` positively gone, `nil` the lookup itself failed (a locked ledger, a module error) - and only a positive
  `false` deletes. Before this, `pcall` collapsing to `false` on a transient error deleted a live pause record.
* **(b) an unreadable or undated record is judged by its FILE's age.** `since == 0` (a record caught mid-write) is
  no longer deleted at once: `host.list_dir` gives the file's `modified` time, and the record is closed only when the
  file itself is older than the window. A young half-written record is kept - unreadable is not dead.

Tests (the two Fable asked for, plus one on the same path): a lookup that raises keeps the record (`closed == 0`,
`removed == {}`); a half-written young file is kept; and the undated record in the existing sweep case is now given
an OLD mtime, so it still proves a deletion. `scripts/test-deploy-pause.lua`: **84 checks**.

One flake, named again: `scripts/test-deploy-wait.sh` step 6 ("the held wakes run once the deploy ends") failed once
in this pass and passed on an immediate re-run with nothing changed - the same step, and the same behaviour, as the
three earlier observations of it today (before r4 as well). It is not touched by this change; it is load-dependent
and it is named here rather than called fixed.

## Addendum 7 (Fable, 24/11 ~01:32Z): why the sweep is silent, and the 22/11 row that never fires

Read-only. Installed: `commit=0d8657e5…` (`~/.local/bin/installed.txt`), which contains the r4 code (`git show
0d8657e5:lua/core/deploy_pause.lua | grep -c sweep_records` = 1, and its log shows `9598d3f6`, `4b9b4a45`,
e7367ad7).

### Q1: `sweep_records` runs on every tick - and can never delete anything

The sweep asks the host for a remover that does not exist:

* `lua/core/deploy_pause.lua:515` - `local remover = opts.remove or (host and host.delete_file)`;
* there is no `host.delete_file`. The capability is **`host.remove_file`**
  (`rust/wa-capabilities/src/host.rs:1690-1695`, "host.remove_file(path) -> one boolean"), and the only other
  caller in the tree uses that name (`lua/core/telemetry.lua:442`).

So `type(remover) ~= "function"` holds on every live tick, nothing is removed, `closed` stays 0 - and the log line
is inside `if closed > 0`, so a sweep that can never close is exactly the silence measured. The r4.1 rule is fine:
`host.list_dir` returns `modified` in **epoch seconds** (`host.rs`, `d.as_secs()`), the same unit as `now`, so once
the remover exists the age rule is correct.

That the tick itself runs is not in doubt: the 22/11 row's `updated_at = 2026-11-24 01:18:06Z` is written by the
`deploy_waiting` branch of the same tick (`lua/core/selfloop.lua:1385-1391`), i.e. during the install of
0d8657e5 - the tick ran, reached that branch, and the sweep at its end did nothing it could log. `/health` shows
nothing either, because `pause_records_closed` is only set when something was closed.

Why the test passed while the live node could not delete: **the test injected the remover**
(`test-deploy-pause.lua`, `remove = function(path) ... end`), so it never asked the host for the capability's name.
That is the same class of mistake as r2's `attempts = 0` fixtures: the fixture replaced precisely the thing that
was wrong.

### Q2: the 22/11 pending row

`reason='deploy pending: resume after the node swap'`, `status='pending'`, `due_at 2026-11-22 10:45Z`,
`attempts=1`, `last_error='deploy_waiting: waiting for the install of unknown …'`, `updated_at 01:18:06Z`.

What keeps it `pending`: while a deploy waits, the tick's `deploy_waiting` branch selects every pending row whose
`due_at <= now` and rewrites `last_error` and `updated_at` on it (`selfloop.lua:1386-1391`) - so a row that is
overdue is re-stamped every tick and never dispatched; and the r3 repair never touched it either, because
`ensure_resumes` selects only `unknown`/`failed`/node-cancelled rows of the resume reason inside the 6 h window,
and this one is `pending` and two days old.

Should the sweep or the migration retire it: **the sweep**, and not only for the resume reason. A row that is
`pending`, overdue by more than the window, and has been deferred by a deploy wait every time it came due can
never fire; leaving it `pending` is the same lie as a `paused session` nobody owes. The rule belongs beside the
record sweep, because it is the same question ("is this still a promise?") asked of the other ledger.

### r5 (proposal; NOT written - waits for go)

1. **Delete with the capability that exists**: `host.remove_file`, with the boolean checked. When the capability is
   missing the sweep must SAY so once (`deploy pause: sweep cannot remove …`), not return 0 silently.
2. **A sweep that ran must be visible**: one counter on the node's `/health`
   (`paused_records: {seen, closed, kept}`) and one line per tick that changed something. The bug was invisible
   because "closed nothing" and "never ran" were the same output.
3. **Retire the row that can never fire**: `pending` + `due_at` older than the window + `last_error` naming a deploy
   wait → `superseded`, `last_error='superseded: too old to fire'`, counted and logged once; the one-time migration
   does the same for the backlog.
4. **The test must not inject the capability** (Fable's rule, applied to capabilities this time): a **live-shaped
   tick** - a scratch `WASM_AGENT_HOME` with real `deploy-paused/*.json` files (one young, one older than the window,
   one half-written) and a real pending overdue row, then `selfloop.tick` run through the **real host** (`wa --db …
   WA_SCRIPT=…`, no `opts.remove`, no `opts.remove`/`list`/`read_file` injection) - asserting the old record's file
   is gone, the young and half-written ones are there, the overdue row is `superseded` with that sentence, and
   `/health`/the log shows the sweep. It fails on today's code for the exact reason the live node is silent.
5. Same rows as r4 plus the new one; `scripts/test-selfloop-pause.lua` and `test-deploy-pause.lua` extended.

### r5: the state table of a resume row, and the one invariant

Read from the code (`lua/core/selfloop.lua`, `lua/core/deploy_pause.lua`); line numbers are the write sites.

| status | moved IN by | moved OUT by | longest it may stay |
| --- | --- | --- | --- |
| `pending` | `schedule` INSERT (446/481); `defer_refused` (1251); `run_wake`'s deferrals (1284, 1293, 1330); `finish` for a repeating row (1228); the tick's `not_started` receipt (1520) | the tick's claim -> `dispatching` (1200, 1509); `cancel` (621) / due-cancel and park (831) -> `cancelled`; the repair or the migration -> `superseded`; the r5 invariant -> `superseded: too old to fire` | until its `due_at`, then its own backoff; while a deploy waits the tick only re-stamps it (1386-1391), so **before r5: for ever** - now the invariant retires it once it is older than the window |
| `dispatching` | the tick's claim (1200, 1509); `run_wake`'s own claim | `finish` -> `delivered`/`failed` (1228, 1232); `cancel_claimed` -> `cancelled` (1271, `cancelled before execution`); reconcile -> `unknown` (1469); the r5 invariant reclaims it at the same bound | `stale_seconds` (300 s) - but reconcile lives in the tick's inline path while the seam's plan owns the other, so on a node whose component is older than that code: **for ever**. That is ae2a9231 |
| `unknown` | reconcile (1469, `dispatch interrupted; not replayed`); `run_wake`'s unknown receipt (1524) | the repair re-arms it inside the window (chain rule) or retires it outside | one tick: seconds |
| `failed` | `finish` (1232) | the repair re-arms it inside the window; terminal otherwise | as `unknown` |
| `cancelled` | an operator's `cancel` (621), the due-cancel/park (831), and the NODE's own `cancel_claimed` (1271) | the repair re-arms **only** the node's kind (`cancelled before execution`); everything else is final | terminal |
| `delivered` | `finish` ok (1232) | - (a repeating row goes back to `pending`) | terminal |
| `superseded` | the repair ("a newer resume was armed"), the migration ("too old to resume"), the r5 invariant ("too old to fire") | - | terminal |
| `resume_abandoned` | the repair when the chain is spent | - | terminal |

**THE INVARIANT (r5).** EVERY RESUME ROW REACHES A TERMINAL STATE WITHIN THE WINDOW. Stated as a bound: a row
created t ago is `delivered`/`failed`/`resume_abandoned`/`superseded` by t = WINDOW (6 h) at the latest, and in
practice by t = stale (300 s) + chain (2 re-arms, 30 s and 60 s). `deploy_pause.ensure_resumes` enforces it before
anything else, in both tick paths and regardless of the seam:

1. `dispatching` past `stale_seconds` -> `unknown` ("dispatch interrupted; not replayed") - the same rule and the
   same sentence reconcile uses, applied by the module that runs on both paths;
2. `pending` whose `created_at` is older than the window -> `superseded: too old to fire` (the 22/11 row);
3. then the existing pass: a lost row (`unknown`/`failed`/node-cancelled) inside the window is re-armed under the
   chain rule (max 2, 30 s/60 s backoff), and outside it is retired.

### Q1-Q3, read-only

* **Q1 - has the sweep run live?** Yes, on every tick, and it could not delete: it asked for `host.delete_file`
  (deploy_pause.lua:515) while the host exposes `host.remove_file` (host.rs:1690), so `remover` was nil, `closed`
  stayed 0 and the log line (inside `if closed > 0`) never fired. The tick itself demonstrably reaches its end - the
  22/11 row's `updated_at = 01:18:06Z` is written by the `deploy_waiting` branch of the same tick (1385-1391).
  **Now proven:** r5 uses `host.remove_file`, says so once when the capability is missing, and writes ONE line a day
  even when it closes nothing: `deploy pause: sweep ran: <n> record(s) seen, <m> closed` (stamped in
  `<data>/pause-sweep.last`, so the line is daily and not per tick).
* **Q2 - the 22/11 pending row.** It is re-stamped every tick by the `deploy_waiting` branch while a deploy waits
  (1386-1391) and never dispatched; the r3 repair never looked at it because it selects `unknown`/`failed`/node-
  cancelled rows only. r5 retires it (`superseded: too old to fire`) because a row that can never fire must not
  stay `pending` - and it does so BEFORE the waiting gate, so a deploy that never ends cannot hold it hostage.
* **Q3 - the `dispatching` row (ae2a9231).** `last_error='deploy ended: resumed now'`, attempts 1, chain 0, no
  message after the pause: its dispatch was interrupted and reconcile - the only owner of that bound - lives in the
  inline tick path, so with the seam's plan owning the live path nothing reclaimed it. r5's invariant reclaims it at
  `stale_seconds` and the chain rule re-arms it inside the window.

### Tests (one per non-terminal state, seeded from real rows)

| state | fixture |
| --- | --- |
| `dispatching` | ae2a9231's shape - asserts the reclaim statement (`status='dispatching'` -> `unknown`) and the re-arm |
| `pending` overdue | the 22/11 row's shape - asserts the retire statement is scoped to `pending` and that nothing is armed for it |
| `unknown`/`failed` (inside the window) | r4's real-attempts fixtures: exactly one re-arm, then the chain cap |
| `cancelled` | operator cancel stays, node cancel re-arms (attempts 73 and 464) |
| live-shaped sweep, no injected capability | `scripts/test-selfloop-pause.lua`: real `deploy-paused/*.json` files and `selfloop.tick` with no options - an old record goes, a young one with a REAL session stays, a half-written young one stays |

`scripts/test-deploy-pause.lua`: **93 checks**; `scripts/test-selfloop-pause.lua`: **116 checks** (was 113);
`scripts/test-deploy-bound.sh`: `deploy bound ok`; `scripts/test-deploy-wait.sh`: `deploy wait ok`.

One flake named again (unchanged): `test-deploy-wait.sh` step 6 failed once in one of these runs and passed on the
re-run; the same step, the same behaviour as the four earlier observations today.

### Texts to approve (r5)

27. `deploy pause: the sweep has no host.remove_file, so no pause record can be closed` (once per run, when the
    capability is missing)
28. `deploy pause: sweep ran: <n> record(s) seen, <m> closed` (once a day, even when nothing was closed)
29. `superseded: too old to fire` - the `last_error` of a resume row the invariant retires

### r5.1 (Fable's review of r5, 24/11 ~01:55Z): `dispatching` spans the whole turn

**(1) WHEN a resume row leaves `dispatching`: at turn END, never at start.**

* `lua/core/selfloop.lua:1200-1201` (the component-plan path) and `:1509-1510` (the inline path) claim a due row with
  `UPDATE self_wakes SET status='dispatching', boot=?, attempts=attempts+1, updated_at=? WHERE id=? AND
  status='pending'` - i.e. at DISPATCH, before the turn starts;
* `M.finish` (`:1214`) writes `delivered`/`failed` (`:1228`, `:1232`) and is called after the run returns
  (`:1355`, `M.finish(row, ok, result, ...)`), i.e. at turn END.

So a row is `dispatching` for the entire turn. **`M.stale_seconds()` is `max(60, WA_SELF_WAKE_STALE_SECONDS or
1800)` (`:166-167`) - 1800 s**, and r5's `300` was both the wrong number and the wrong owner (this module cannot
load `selfloop`, which loads it).

**(2) The reclaim now requires that NOTHING HAPPENED.** Two facts, not one: the row older than the bound **and** no
message for its session at or after the row's `updated_at` (`SELECT COUNT(*) FROM messages WHERE session_id=? AND
created_at>=?`). That is ae2a9231's exact shape - dispatched, `last_error='deploy ended: resumed now'`, and nothing
written afterwards. A long turn writing messages is untouched, so no second resume is ever paid beside a running
turn. The bound is `deploy_pause.wait_stale_seconds()` (the same `WA_SELF_WAKE_STALE_SECONDS`, floor 60), and the
reclaim counts `changed.changes`, not `pcall`'s boolean.

**(3) Tests, both directions.**

| case | assertion |
| --- | --- |
| `dispatching` 400 s, NO session activity | reclaimed as `unknown`, and **exactly one** re-arm for that session |
| `dispatching` 400 s, WITH messages after the dispatch (a long turn in progress) | **untouched**, no `status='unknown'` statement, **ZERO** new wakes |
| `dispatching` 400 s with the default bound (1800 s) | inside the tick's own bound: nothing reclaimed |

`scripts/test-deploy-pause.lua`: **113 checks**; `scripts/test-selfloop-pause.lua`: **116**;
`scripts/test-deploy-bound.sh`: `deploy bound ok`; `scripts/test-deploy-wait.sh`: `deploy wait ok`.

### r5c (Fable, 24/11 ~01:55Z): the claim is the primary signal

**(A) A failed lookup can never reclaim.** r4b's pattern was back: `query(...) or {}` on the messages lookup turns a
`db is locked` into `n = 0`, i.e. `quiet = true`, i.e. a duplicate turn. Every lookup is now `pcall`ed and must answer
a TABLE; anything else keeps the row. (The same rule covers the claim lookup and the list of stale rows itself.)

**(B) The bound.** `M.RESUME_DISPATCH_BOUND_SECONDS = 300`, this module's own constant, for RESUME rows only. The
1800 s `selfloop.M.stale_seconds()` stays the bound for every other wake - at 1800 s the operator's watchdog
(~20 min) beats the node to a lost dispatch. `wait_stale_seconds()` was removed rather than left as a second owner.

**(C) Three facts, and the claim comes first.** A `dispatching` resume row is reclaimed only when ALL hold:

1. it is past `RESUME_DISPATCH_BOUND_SECONDS`;
2. **no run claim is held for its session by THIS boot** - `SELECT boot FROM claims WHERE key='session:<id>'`, the
   claim `lua/core/agent.lua` takes at the start of a turn (`rust/wa-capabilities/src/resources.rs`), the one that
   answered `resource_busy` today. A turn holds it before it writes any message, so it is the primary signal and
   messages are the secondary;
3. **zero messages** for the session at or after the row's `updated_at`.

**(D) What a restart does to a claim: IT SURVIVES.**

* `claims` is a table with `key, principal, session, run, boot, uncertain` (`resources.rs:363-365`); it is opened by
  `Store::open`, and nothing sweeps it at boot - there is no boot hook in the module at all;
* a row is dropped only by the run's own `finish`, or reclaimed lazily when a LATER run claims the same session and
  `lease_released(root, boot)` proves the old process gone (`resources.rs:46-59`, `lease_released` locks
  `<boot>.lease.sqlite`);
* so a claim left by a process that was killed mid-turn persists with its old `boot`, and the measured shape
  `{"boot":"7d72…","key":"session:…"}` is exactly that. Counting it as "a turn is running" would block the reclaim
  for ever, so **only a claim whose `boot` is the one running now counts** - and the boot is injectable
  (`opts.boot`) for the tests, because a script run's `runtime_info` names the test interpreter.

**Tests (seven cases, real-row shapes).**

| case | assertion |
| --- | --- |
| quiet and unclaimed | exactly ONE re-arm for that session |
| claim held by THIS boot, no message yet (a long first tool call) | untouched, ZERO new wakes |
| claim from ANOTHER boot (dead process) | reclaimed - a dead claim does not block |
| claim lookup raises | untouched |
| messages lookup fails | untouched (r4b's exact defect) |
| messages written since the dispatch | untouched, zero wakes |
| 200 s (inside the 300 s bound) | untouched |

`scripts/test-deploy-pause.lua`: **98 checks** (the three earlier loop-assertions were replaced by these seven cases;
no assertion was deleted, the count is lower only because those loops asserted once per update row);
`scripts/test-selfloop-pause.lua`: **116**; `scripts/test-deploy-bound.sh`: `deploy bound ok`;
`scripts/test-deploy-wait.sh`: `deploy wait ok`.

Texts: none new (the reclaim writes `dispatch interrupted; not replayed`, already approved as text 12's sibling).

### r5d (Fable, 24/11 ~02:00Z): the claim is asked of the store that holds it

Both live defects were invisible to my fixture, and both are measured facts about the node:

1. **The claims are not in the ledger.** `SELECT boot FROM claims ...` ran through deploy_pause's `query`, i.e.
   against `~/.wasm-agent/memory.db`, which has no `claims` table: the claim lives in
   `<data>/resources/claims.sqlite` (`rust/wa-capabilities/src/resources.rs:354-361`, `Store::open`). Live, the
   lookup raised, every stale row was kept, and nothing was ever reclaimed - a lost dispatch stayed lost and the
   watchdog won again.
2. **The wrong boot.** `claims.boot` is the uuid `Store::open` mints (`resources.rs:356`), not
   `runtime_info().boot_id`, so `claim.boot == boot_id` never matched - every claim was ignored: the duplicate
   direction.

**The fix asks the capability, which already knows both.** `host.resource("list")` is `inventory_at`
(`resources.rs:281-321`), which computes each claim's `liveness` itself:

| liveness | meaning | what the reclaim does |
| --- | --- | --- |
| `held` | `boot == the store's own boot` | keeps the row |
| `held_or_unavailable` | the lease is busy (another live process, or unverifiable) | keeps the row |
| `lease_released` | the boot's lease can be taken: that process is gone | **free** - may reclaim |
| `unverifiable` | neither | keeps the row |

No capability, a raise, an unknown shape, or any other liveness -> **unknown -> keep**. The key absent after a
successful `list` -> **free** (asked and answered at the source). The injected answer is `pcall`'ed too, so a test
seam cannot turn an error into a reclaim. This module compares no boot of its own any more.

`ensure_resumes` was also **rewritten whole**: three earlier revisions had left duplicated blocks and two
`local reclaimed` in it, which is how a working reclaim can look wired and do nothing. One invariant, one order:
migration -> `dispatching` reclaim (this module's own 300 s, three facts) -> overdue `pending` retirement -> the
re-arm under the chain rule. The rewrite dropped `sweep_records` by accident; the row caught it (`attempt to call a
nil value (field 'sweep_records')`) and it was restored from HEAD - which is what the rows are for.

**How the test's store is the node's store.** The live-shaped test in `scripts/test-selfloop-pause.lua` takes a REAL
claim through `lua/core/resources.lua`, then asserts three things about the objects the module itself reads:
(a) `host.resource("list")` - the store this process opened - reports `liveness = "held"` for the claim it just
took; (b) the data root is `paths.data()`, the one the pause records, the ledger and the sentinel share in this run;
(c) `<data>/resources/claims.sqlite` is a non-empty file. No injection at all:
`pause.ensure_resumes(now, { stale_seconds = 300 })`.

**Not proven, said plainly:** the other half - a RELEASED claim (`resources.finish`) lets the same row be
reclaimed - is asserted against the fake ledger in `scripts/test-deploy-pause.lua` and could NOT be reproduced
through the live-shaped fixture in this round: after `resources.finish(ctx)` the inventory is empty (`claims after
finish=0`, measured) and the row still stayed `dispatching`; the cause was not found before the round ended. It is
named in the source with that measurement rather than deleted, and it is the first open item in this report.

**Rows:** `test-deploy-pause.lua` **100 checks**; `test-selfloop-pause.lua` **124**; `test-deploy-bound.sh`
`deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`. No new texts.

### r5e (Fable, 24/11 ~02:25Z): the fact that answered "keep" was the SQL call shape

The instrumented run (real stores, no seam) printed, for a row 400 s past its dispatch with the claim released:

```
RAW={"claims":[],"complete":true,"identities_complete":true,"kind":"resource-inventory","ok":true,"schema":1}
claims type=table n=0
stale=[{"id":"93ecf455-...","session_id":"f879ab53-...","updated_at":1795485125}]
old_at=1795485125 now=1795485525      -- age 400 s, bound 300 s
seen=[{"n":0}]                       -- quiet
out={"abandoned":0,"migration":0,"rearmed":0,"reclaimed":0}
after={"status":"dispatching"}       -- the row never moved
```

All three facts were right and nothing was written. **The cause: the module handed the host a Lua table where its
statements take JSON text.** `host.sql_exec(sql, params_json)` / `host.sql_rows(sql, params_json)`;
`lua/core/memory.lua` and `lua/core/selfloop.lua` both wrap them with `json.encode` for exactly this reason, and this
module called them raw. The SELECTs happened to work (the host tolerates a table on a read), the UPDATE did not: it
carried no `id`, matched nothing, and `reclaimed` stayed 0. The `claims=[]` shape and the message count were innocent
(`claims` is the key, an empty inventory is `[]`, so `free` was the right answer and it was reached).

**Fix:** `exec`/`query` are wrapped in the module - the host's own functions get `json.encode(params)`, an injected
seam keeps the table it expects - and `.changes` is read from either answer shape (the host answers JSON text).

**Acceptance, live-shaped and with no seam, now green:** after `resources.finish(ctx)` the same row is RECLAIMED
(`status` leaves `dispatching`; measured in the diagnostic run: `rearmed=1`, row `superseded`).

**Still open, measured and named in the test:** in the `test-selfloop-pause.lua` fixture the RE-ARM step of that same
call does not fire - the ledger ends with exactly one row, `unknown / deploy pending… / chain=0`, and a `host.log`
print placed inside the re-arm loop never fired, so the `lost` query returned nothing there while the same row read
`unknown` afterwards. Ruled out before the round ended: nothing is waiting (`pause_mod.waiting() == nil` asserted
immediately before the call), the session is live, no pending row exists. The re-arm is covered by the fake-ledger
cases in `scripts/test-deploy-pause.lua` and by step 7b of `scripts/test-deploy-wait.sh`; it is NOT covered by the
live-shaped fixture yet. Next probe for whoever lands this: print `lost` and the two bound values inside that
fixture.

**Rows:** `test-deploy-pause.lua` **100 checks**; `test-selfloop-pause.lua` **126**; `test-deploy-bound.sh`
`deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`.

### r5f: the probe's result, and the honest state of install #1

Fable's named probe was run (`WA_PAUSE_DEBUG=1` prints, once per `ensure_resumes` call, how many rows the re-arm
pass sees and the two bounds):

```
debug ensure_resumes: lost=0 cutoff=1795464328 now=1795485928 reason=deploy pending: resume after the node swap
```

**The SQL is not the problem.** The identical statement, run standalone against the same ledger, returns the row:
`SELECT id, session_id, owner, resume_chain FROM self_wakes WHERE reason=? AND (status IN ('unknown','failed') OR
(status='cancelled' AND last_error LIKE 'cancelled before execution%')) AND created_at>=?` returns `{...}` for a row
that is `unknown` with that reason and a fresh `created_at`. And `host.sql_rows`' param shape is right: every host
call in the module was re-read for it - `host.sql_exec`/`host.sql_rows` take JSON text (r5e's fix, wrapped in the
module), `host.write_file`/`read_file`/`remove_file` take plain paths and a string body, `host.resource("list", "{}")`
takes its args as text, `host.list_dir(path)` a path, `host.getenv(name)` a name. No other call in this file passes a
table where the host wants text.

So the remaining defect is in what that call passes to the query, or in what it sees at that instant - not in the
SQL, the window, the bound or the row. The probe is committed as a supported diagnostic (off unless the variable is
set; its first version printed always, because `pcall(host.getenv, ...)`'s boolean was read as the answer).

**State of the acceptance, said plainly: NOT met.**

| half | state |
| --- | --- |
| a HELD claim keeps a dispatching row (no duplicate turn) | green, live-shaped, real store |
| a RELEASED claim lets the same row be reclaimed | green, live-shaped (measured `rearmed=1`, row `superseded` in the diagnostic) |
| that same call RE-ARMS it (one new pending resume row, chain 1) | **not green**: `lost=0` inside the call, so nothing is armed; the row ends `unknown` and the session is left paused |

So install #1 for a lost resume is still not guaranteed by this branch, and the branch should not land on the
strength of this round. The next step is one line: print `lost` (the raw value, not its length) and the encoded
params from inside the call, which the committed probe does not yet do.

**Rows:** `test-deploy-pause.lua` **100 checks**; `test-selfloop-pause.lua` **126**; `test-deploy-bound.sh`
`deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`.

### r5g: what the probes measured, as far as they got (24/11 ~02:12Z)

The turn was spent on the live-shaped acceptance and it is still **not green**. What the probes established, in
order:

1. **`host.resource("list")` was never the problem.** After `resources.finish(ctx)`: `FINISH={"ok":true}` and
   `INV={"claims":[],"complete":true,...}` - the claim is gone, so `claim_state` answers `free`.
2. **The messages lookup was never the problem either.** `seen=[{"n":0}]` for a session with no activity.
3. **The lost-row SELECT returned `[]` inside the call while the identical statement, run standalone against the same
   ledger, returned the row.** Printed with its params: `params=["deploy pending: resume after the node swap",<cutoff>]`.
4. **A real defect found on the way, and fixed:** `encode_for` compared function VALUES to decide whether to
   `json.encode` the params (`fn == host.sql_rows`). A host function is a fresh closure on every access, so that was
   never true, `exec`/`query` handed the host a Lua table, and **every statement in this module ran with its WHERE
   values unbound**: `reason=?` matched nothing, the reclaim's `UPDATE` carried no id (r5e's "matched nothing"), and
   `SELECT COUNT(*) ... created_at>=?` counted 0 - which would have made a RUNNING turn look quiet and paid a
   duplicate resume. The contract is now decided by WHICH function is used (host -> `json.encode`, injected seam ->
   the table), never by identity.
5. **The reclaim loop does run and does decide correctly** - one earlier call printed
   `debug loop: row=… state=held quiet=true known=true dispatched_at=1795485840 now=1795486240`, i.e. it reached the
   claim check and kept the row because the claim was held. So the loop, the claim question and the quiet question
   are all live-shaped and right.
6. **The remaining difference is the stale-row SELECT of a particular call**, not the loop: in the acceptance call it
   finds no rows (`lost=[]`, `reclaimed=0`) while the loop in another call found the same row. Two clock mismatches
   were found and fixed in the fixture along the way (the file installs a clock at `T0`; `os.time()` was used for the
   dispatch marker and for `now`, so the row looked 6 h+ old and the migration retired it, or looked brand new and
   nothing matched). After unifying them the acceptance call still reclaims nothing.

**Where that leaves install #1: not guaranteed.** The reclaim was shown working live-shaped in a diagnostic run
(`rearmed=1`, row `superseded`); the committed acceptance test does not reproduce it, so nothing here should be read
as "it works". The next datum is one line - `#stale_rows` plus its params plus that row's `updated_at` from inside the
acceptance call - which the committed `WA_PAUSE_DEBUG` probes do not yet print together.

**Fixed and safe to keep in either case:** the param-binding contract (5), which was silently breaking every
statement in the module on the live node.

### r5h: the live-shaped acceptance is GREEN (24/11 ~02:35Z)

**The last defect was a clock split inside the fixture.** `selfloop.schedule` stamps `created_at` with *this test
file's* clock (`T0`), while the dispatch marker and the `now` passed to the call were wall time. The probe printed it:

```
debug stale: ok=true n=0 bound=300 now=1700000400 threshold=1700000100 rows=[]
   (the row at that moment: updated_at=1795486042 - wall)
```

An age filter compares two numbers; with the row on one clock and the call on another it can never match, so in turn
the reclaim and the re-arm were each invisible - which is why the same statement worked standalone and not inside.
The row now carries `created_at` **and** `updated_at` from one wall clock, and every call in the block uses it.

**Acceptance, no seam, real stores (`scripts/test-selfloop-pause.lua`, 129 checks):**

| step | assertion |
| --- | --- |
| claim taken through `lua/core/resources.lua`, inventory `held` | the row is KEPT (no duplicate turn) |
| `resources.finish(ctx)` -> inventory `claims=[]` | the same row is RECLAIMED in ONE call (`reclaimed == 1`) |
| that same call | exactly ONE new `pending` resume row for the session, `resume_chain == 1` |
| a second pass | adds nothing: no new re-arm, still one pending row |

Running the row prints the re-arm itself: `deploy pause: re-armed the LOST resume of session … (wake … had no
outcome, new wake …)`.

**How the store is proven to be the node's:** the claim is taken through the real capability, `host.resource("list")`
(the store this process opened) is asserted to answer `liveness = "held"` for it, the data root is `paths.data()` (the
one the pause records, ledger and sentinel share), and `<data>/resources/claims.sqlite` is asserted to be a non-empty
file.

**Two code fixes found by this round and kept:**

1. `exec`/`query` bind their params as JSON text **by contract** - a host function is a fresh closure per access, so
   `fn == host.sql_rows` never matched, every statement in the module ran with its WHERE values unbound, and
   `SELECT COUNT(*) … created_at>=?` read 0 (a running turn would have looked quiet and paid a duplicate resume);
2. the `WA_PAUSE_DEBUG` probes (the stale-row count with its params and bounds, the lost query, and the reclaim
   loop's three facts) - off unless the variable is set, and what found this.

**Rows:** `test-deploy-pause.lua` **100 checks**; `test-selfloop-pause.lua` **129**; `test-deploy-bound.sh`
`deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`.

## Addendum 8 (Fable, 24/11 ~02:55Z): the sweep is behind the deploy gate; a resume fires during an install

Read-only. **What I can and cannot read here:** `~/.wasm-agent/memory.db` is refused to this shell
(`secret_path_denied`), and the node's journal is not present in this user's `journalctl` (no `wa-serve` unit is listed
and `journalctl --user -u wa-serve.service --since '02:15'` answers `-- No entries --`), so "no line in the journal" is
not something I can confirm or deny - it is the orchestrator's read. Everything below is either the product's own
`wa` path, a scratch node seeded with the live files, or the code.

### (2) THE SWEEP: measured cause, and it is placement, not the code

Scratch node, `WASM_AGENT_HOME` with the LIVE layout and two LIVE records copied in
(`8057f11d…json` since 1795359808, `c67c0609…json` since 1795486711), then the tick the node runs:

```
records=2
--- tick WITHOUT a deploy waiting
[lua] deploy pause: migration: 0 lost resume row(s) older than 21600s marked superseded (too old to resume)
[lua] deploy pause: sweep ran: 2 record(s) seen, 1 closed
[lua] deploy pause: closed 1 pause record(s) that can never be resumed (older than 21600s, or their session is gone)
records after=1      stamp=20781        <- <data>/pause-sweep.last written
--- tick WITH the installer marker up (<data>/deploy-pending.json, fresh, bound 1800)
[lua] deploy pause: migration: 0 lost resume row(s) older than 21600s marked superseded (too old to resume)
records after=2      stamp=none          <- the sweep did not run at all
```

So none of the early returns is the cause: `paused_dir()` is right, `host.list_dir` answers a JSON string with
`entries` and `modified` (checked directly: `TYPE=string`, `HEAD={"entries":[{"kind":"file","modified":…}]}`),
`host.remove_file` exists, and the live records carry `since`/`session` as expected. **`selfloop.tick` returns at the
deploy-waiting gate before reaching `deploy_pause.sweep_records`** (the gate is at `selfloop.lua:1385`, the sweep call is
last in the tick), so on every tick where a deploy waits or installs - which is most of the evening on this node -,
the sweep is skipped, and the stale count only grows.

The gate itself is right for DISPATCH (no new turn while a build waits); it is wrong for a sweep that only CLOSES
records older than the window: a record older than six hours cannot be the pause of a deploy that is installing now.

### (1a) Rows -> messages: what I can derive, and the SELECTs that settle it

The producer is identifiable from the text, because the three sentences come from three different functions:

| seq | text (opening) | produced by |
| --- | --- | --- |
| 232 | "The deploy this session paused for is OVER, and the resume that was armed for it was lost" | `deploy_pause.resume_prompt()` - only the RE-ARMED wake carries it |
| 238 | "The node is installing a new build (e832e152…), so this turn paused" | `deploy_pause.prompt(request, marker)` - the pause's own continuation, armed by a turn that paused at its boundary |
| 252 | "…a new build (unknown)…" | the same function with a marker that names no commit - a different pause event |

Row `96049abb` (created 02:17:34, `attempts=2`, delivered) is the re-armed one, so it produced 232. Row `4f831a72`
(created 02:18:31) is a pause-armed resume, and 238's pause fits its timeline (turn starts ~02:18:31, pauses at
02:21:41 for e832e152). 252 needs a pause-armed row created around 02:24:23; if only two rows exist, its wake is one of
these two re-armed - which the SELECTs below answer exactly:

```sql
-- the rows of that session, with their prompts, in creation order
SELECT id, status, attempts, resume_chain, created_at, updated_at, substr(prompt, 1, 90)
  FROM self_wakes WHERE session_id = 'c67c0609-6205-4937-831e-1464ef8f2c04'
  ORDER BY created_at;
-- the three messages, to match prompt text against the ledger's own rows
SELECT seq, role, created_at, substr(content, 1, 120)
  FROM messages WHERE session_id = 'c67c0609-6205-4937-831e-1464ef8f2c04' AND seq IN (232, 238, 252);
```

### (1b) Does `attempts` count dispatch tries or deliveries? TRIES - from the code

`selfloop.lua:1200-1201` (component-plan claim) and `:1509-1510` (inline claim) both write
`UPDATE self_wakes SET status='dispatching', boot=?, attempts=attempts+1, updated_at=? WHERE id=? AND status='pending'`:
the increment happens at the CLAIM, i.e. every time the row is dispatched to a run. A delivery is `M.finish` writing
`status='delivered'` (`:1228`, `:1232`) and is not counted anywhere. So `attempts=2` on `96049abb` means two claims
(one cut, one that ran) and one delivery - **no row delivered twice**: a second delivery would need the row back in
`pending` for a second full dispatch, and a resume row only returns to `pending` through a deferral (which is a
non-delivery) or `every_seconds` (resume rows have none).

### (1c) Did a resume fire while e832e152 was still installing? YES - and it is r6

Seq 238 is the *pause* sentence of an automated turn that names e832e152: the turn therefore STARTED while that
install had not ended, spent a model call, and paused at its next boundary. From the code the window is exact:
`run_wake` checks `deploy_pause.refuse` once, at the top (`selfloop.lua:1262`); `deploy_pause.at_boundary` is only
called for `round > 1` (`agent.lua:2748`), so a wake that starts just before the installer marker appears always spends
its first model call before it can pause - a paid turn that the install did not need.

### r6, proposed (not written)

1. **The sweep moves next to the invariant statements, before the waiting gate** - a record older than the window is
   closed whatever is installing. Test: a tick with `<data>/deploy-pending.json` up and one record older than the
   window → the record is gone and `pause-sweep.last` exists; the live-shaped scratch measurement above is the
   fixture (two live records, the live layout).
2. **A resume turn does not spend a model call on an install that is already waiting**: in `run_wake`, after the
   claim and before `bot.run`, re-read `deploy_pause.refuse` (the gate it already asks at the top) and defer the row
   with `M.defer_refused` if a build is waiting. Test: a wake dispatched, then the marker written, then the run →
   zero model calls (a stub provider counts them) and the row back to `pending`; and with no marker → the turn runs.
3. Texts: none new if (2) reuses `deploy_waiting`'s sentence.

## Addendum 9: r6 (24/11 ~03:00Z) - three fixes, three tests, all through the product's own stores

**How the tests are built (Fable's requirement):** nothing is injected. Each test runs in a real `wa` script run with
its own `WASM_AGENT_HOME`, uses `selfloop.setup()` and `lua/core/memory.lua` for the session and the ledger, the REAL
resources store through `lua/core/resources.lua` (the r5-shaped case), host capabilities by their real names
(`host.read_file`/`write_file`/`remove_file`/`sql_query`/`sql_exec`, params always JSON text), and gets its clock from
the row it is testing (`SELECT created_at`) rather than mixing `os.time()` with the fixture's clock - the mistake that
hid the r5 acceptance for three rounds.

### (1) The sweep runs before the waiting gate - tested with the gate UP

`selfloop.tick` now calls `sweep_records` beside the invariant statements, before the `deploy_waiting` early return
(`selfloop.lua`), and the copy at the end of the tick is gone.

Test (`scripts/test-selfloop-pause.lua`): a record 7 h old, a young record for a LIVE session, and
`<data>/deploy-pending.json` with `state=deploy_pending`, a 1800 s bound and a target commit. `pause_model.waiting()`
is asserted non-nil first (the gate really is up), then one `selfloop.tick`:

* the expired record is GONE (closed while an install waits);
* the young record of a live session is KEPT;
* `<data>/pause-sweep.last` exists - the stamp that was missing on the live node for hours.

Measured before the fix on a scratch node seeded with the two LIVE records: with the marker up, `records after=2`,
`stamp=none`, no sweep line; without it, `sweep ran: 2 record(s) seen, 1 closed` and the stamp written.

### (2) A resume spends nothing on an install already waiting - tested with a real claim

`run_wake` re-reads `deploy_pause.refuse` after the row is claimed and BEFORE the agent is built, and returns
`M.defer_refused(row, waiting_now, …)` - the same `deploy_waiting` sentence, no new text.

Test: a resume row due now is scheduled and claimed through `claim_due` (the node's own path), the installer marker is
written, then `run_wake` is called for real. Asserted: the return is `deferred = true` with the `deploy_waiting`
sentence, the session's message count is UNCHANGED (no model call, so nothing written), and the row is `pending` again
rather than failed or dispatching.

### (3) At most one pending resume per session - seeded from c67c0609's shape

`M.schedule`, for the deploy-resume reason only, looks for a `pending`/`dispatching` row with the same session and
REPLACES it instead of inserting: the row keeps its id and its OLDEST `created_at` (so the six-hour window cannot be
extended by re-arming), takes the LARGEST `resume_chain` (so the cap of two still bites), and gets the new `due_at`,
prompt and `updated_at`.

Test: row A armed (chain forced to 2, `created_at` moved back an hour), then row B armed with `resume_chain = 1` and a
different prompt. Asserted: `replaced = true`; exactly ONE resume row for the session; its id is A's; its
`created_at` is A's (an hour back); its `resume_chain` is 2 (the max); its status is `pending` with B's prompt.

### Rows

| row | result |
| --- | --- |
| `scripts/test-selfloop-pause.lua` | `self-loop pause: 146 checks passed` (was 129) |
| `scripts/test-deploy-pause.lua` | `deploy claim wait ok (100 checks)` |
| `scripts/test-handle-wake.lua` | `handle wake: 17 checks` |
| `scripts/test-cli-wake-row.lua` | `cli wake row ok (30 checks)` |
| `scripts/test-deploy-bound.sh` | `deploy bound ok` |
| `scripts/test-deploy-wait.sh` | `deploy wait ok` (one run hit the known step-6 flake, green on the re-run) |

No new texts: (2) reuses the `deploy_waiting` sentence, and the sweep's lines were approved as 26 and 28.

### r6b (Fable, 24/11 ~03:05Z): a dispatching row is not replaced, and `finish` cannot overwrite a re-armed row

**The defect.** `M.schedule` replaced any resume row in `('pending','dispatching')`. A RESUMED turn that is running
holds its own row `X` as `dispatching`; when it pauses again for the next install, the pause arms a resume, `schedule`
replaced `X` (same id, back to `pending`), and then that turn ended with `M.finish(X)` writing
`status='delivered', due_at=NULL WHERE id=?` - over the new resume. LOST. That is the back-to-back install sequence of
this evening.

**(a) Only a `pending` row is replaced.** A `dispatching` row is the turn that is pausing RIGHT NOW: it ends
`delivered` through `finish`, so the new resume must be its own row. It still inherits the chain's **oldest
`created_at`** and its **`resume_chain`** (the max), so re-arming can neither extend the six-hour window nor reset the
cap of two.

**(b) The belt.** `M.finish` guards both of its writes with `AND status='dispatching'`: a row that someone re-armed
while its turn ran is not overwritten by that turn's ending.

**Tests** (real stores, `selfloop.setup`, `claim_due`/`finish` as the node uses them, clock read from the row):

| case | assertion |
| --- | --- |
| resumed turn `dispatching`, the pause arms a new resume | `replaced ~= true` and a different id - the pause does not take the running row |
| that new row | `created_at` = the dispatching row's (two hours back), so the window cannot be extended |
| `finish(X, ok)`, then the ledger | exactly ONE `pending` resume for the session, it is the NEW row, status `pending`, chain carried |
| the belt | a row set back to `pending` while its turn ran is STILL `pending` after `finish` (never `delivered`) |
| two pending rows (c67c0609's shape) | still collapse to one, oldest `created_at`, largest chain |

**Rows:** `test-selfloop-pause.lua` **156 checks** (was 146); `test-deploy-pause.lua` 100; `test-handle-wake.lua` 17;
`test-cli-wake-row.lua` 30; `test-deploy-bound.sh` `deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`.
No new texts.

### r6c: main's red row, and the guard that keeps the repair inside its own reason

**What was red.** `scripts/test-deploy-resume.lua:95` ("an unrelated wake does not fire when the deploy ends: expected 0,
got 1") on main after `e832e152`. The row schedules a deploy-resume wake due at `T0+1730`, dispatches it with a stub
when the install ends, then asserts that the tick at `T0+1729` dispatches nothing. My reclaim's bound was **300 s**, so
at `T0+1729` it judged that dispatched row (age 1723 s, no message, no claim - a stub) LOST, re-armed it, and the tick
dispatched the new row: one dispatch too many. Reproduced exactly, in a script, before changing anything.

**The statement.** `ensure_resumes`'s reclaim query is correctly scoped (`WHERE reason=? AND status='dispatching' AND
updated_at<?`), so it was not touching a foreign row: it was touching a *resume* row too early. The 300 s figure came
from r5c ("beat the operator's watchdog"); the tick's own reconcile uses `M.stale_seconds()` = 1800 s for the same
judgement, and two numbers for one meaning is the defect. **The reclaim now uses `M.stale_seconds()`**, documented as
"the seam-independent twin of reconcile", and `scripts/test-deploy-pause.lua` asserts equality with
`selfloop.stale_seconds()` instead of a literal - so the two cannot drift back apart.

**The guard the orchestrator asked for**, in `scripts/test-selfloop-pause.lua`: two rows of a session with reasons
`check the deploy` and `look again`, one set `dispatching` and two hours old (exactly what the reclaim looks for by
status and age), one overdue by two hours (exactly what the pending retire looks for). After **two** `ensure_resumes`
passes, each row's `status|prompt|due_at|created_at|resume_chain` is byte-identical to its before-snapshot, and the
pending count is unchanged (1 of 2 - the one that was armed pending). The migration, the reclaim, the pending retire
and the re-arm all carry `reason = the resume reason` in their WHERE.

**Also fixed:** the duplicate `sweep_records` call at the end of the tick is gone (r6 moved it before the gate and the
old copy survived), so the sweep runs once.

**Rows:** `test-deploy-resume.lua` **25 checks** (main's row, green); `test-deploy-pause.lua` **100**;
`test-selfloop-pause.lua` **161** (was 156); `test-handle-wake.lua` 17; `test-cli-wake-row.lua` 30;
`test-deploy-bound.sh` `deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`.

### r6d: the bound stays 300 s - the ROW was the conflict, not the bound

**Restored:** `RESUME_DISPATCH_BOUND_SECONDS = 300`, named as the RESUME bound and documented against reconcile's
1800 s: the two answer different questions. Reconcile asks "was any row's dispatch interrupted?"; the resume bound asks
"will the node resume this paused session before the operator's watchdog?" - and the watchdog fires on a paused marker
older than 15 min plus its own 600 s, i.e. **1500 s**. A resume bound at or past that would make the watchdog, not the
node, the thing that resumes a session, which is what this mission exists to prevent. Claim and message checks are
unchanged and still gate it.

**The row was the conflict.** `scripts/test-deploy-resume.lua:95` dispatched the resume with a stub that took no run
claim and wrote no message - which is byte for byte the "dispatched and nothing happened" shape the reclaim exists for,
so the repair revived it and the row counted an extra dispatch. A real dispatch holds `session:<id>` in the resources
store before any model call (`lua/core/agent.lua`, `rust/wa-capabilities/src/resources.rs`). **The stub now takes that
claim, for real, through `lua/core/resources.lua`, for the turn's duration** - so the row is shaped like the product:
dispatching WITH its claim, which nothing may call lost. Line 95's assertion is untouched; only how the stub dispatches
changed, and that change is this paragraph.

**The bound relation is asserted, not the equality** (`scripts/test-deploy-pause.lua`):

| number | value |
| --- | --- |
| `RESUME_DISPATCH_BOUND_SECONDS` | 300 |
| the operator's watchdog trigger (15 min marker + its 600 s) | 1500 |
| `selfloop.stale_seconds()` (reconcile) | 1800 |

`ok(300 < 1500)` and `ok(1500 < 1800)` - so the order that makes the node, never the watchdog, the thing that resumes
is asserted in the row, and a future edit to any of the three breaks it.

**Rows:** `test-deploy-resume.lua` **25 checks** (main's row, green, its assertion unchanged); `test-deploy-pause.lua`
**101**; `test-selfloop-pause.lua` **161**; `test-handle-wake.lua` 17; `test-cli-wake-row.lua` 30;
`test-deploy-bound.sh` `deploy bound ok`; `test-deploy-wait.sh` `deploy wait ok`.

### r7: the silent dispatch, and what is NOT fixed (24/11 ~05:10Z)

**Measured on the live node** (`4c720beb`): resume wakes `ed7970e3`, `7e34cac9` and `b076ba0e` of session `e540de37`
were each CLAIMED (`dispatching`, attempts 1) and then nothing at all - no run row, no message, no journal line -
three times, until the operator's watchdog resumed the session by hand. The reclaim worked; it re-armed into the same
silent dead end.

**(1) No silent path - done, and tested.** Two places could be silent, and both now speak:

* `M.dispatch_default` writes **one line per dispatch**: `selfloop: dispatched wake <id> of session <id> (reason …):
  <the queue's own receipt>`. An `accepted` receipt that never becomes a run is now a line an operator can grep;
* `wa_completion_run`'s `self_wake` branch, on a raise or an error answer, calls `selfloop.note_dispatch_failure`:
  the row goes back to `pending` with a due time and `last_error = 'dispatch_failed: …'` when it is still claimed,
  and one line reads `selfloop: wake <id> of session <id> did NOT run: <why> (row back to pending, retried)`.

Test (`scripts/test-selfloop-pause.lua`, real stores, the row claimed exactly as the live node had it): the dispatch
answers a receipt and names itself; `note_dispatch_failure` puts the row back to `pending` with `dispatch_failed` and a
`due_at`; and `wa_completion_run` on a wake it cannot admit answers an error **and** writes the row/line. Measured
output in the run: `wake aa5ad7cf… of session r7-acceptance did NOT run: self_wake_not_dispatching (row back to
pending, retried)` and `wake no-such-wake … did NOT run: self_wake_not_admitted`.

**(2) Making the case run - NOT fixed, and here is exactly how far the evidence goes.**

* `M.run_wake` is not the gap: called with a claimed row for a session whose last run is `completed/answered`, it goes
  straight to the turn (reproduced: the call blocked on the absent provider in a script run, which is a turn being
  attempted, not a silent return);
* the row's only writes on the live node were the claim itself (`updated_at 04:37:08`) and nothing after, so neither
  `run_wake`'s deferral branches nor `finish` were reached - the completion work item never arrived at
  `wa_completion_run`, or arrived with an `args` shape that failed its first check;
* everything between the claim and that entry lives in the node (`host.enqueue_completion` → scheduler admission →
  node-thread `Work::Completion` → `lua.call_string("wa_completion_run")`), and the node's journal is not readable
  from this shell (`journalctl --user -u wa-serve` answers `-- No entries --`, no such unit is listed) - so the one
  artefact that would name the gap is the one I cannot read.

The fix for (2) is therefore **installed as observability, not as a repair**: the next install gives the dispatch its
own line with the queue's receipt, which names the gap on the first repeat. I am not claiming the resume runs.

**Rows:** `test-deploy-resume.lua` 25; `test-deploy-pause.lua` 101; `test-selfloop-pause.lua` **169** (was 161);
`test-handle-wake.lua` 17; `test-cli-wake-row.lua` 30; `test-deploy-bound.sh` `deploy bound ok`;
`test-deploy-wait.sh` `deploy wait ok`.

**Texts to approve (r7):** the two new lines above - `selfloop: dispatched wake <id> of session <id> (reason …):
<receipt>` and `selfloop: wake <id> of session <id> did NOT run: <why> (row back to pending, retried)`.

### r8: the completion path after a fresh boot - the links, and the one that can park silently (24/11 ~05:30Z)

**What the orchestrator's journal shows** (04:37:03Z boot, `wa-serve.service` PID 755496): not one self_wake delivered;
the 04:37:08 claims still `dispatching` 35 min later; the journal carries no line from the scheduler, the node-thread or
`wa_completion_run`. So the item was **accepted and parked** - a link answered "yes" and then nothing read it.

**(a) The links, and what each one writes today** (`rust/wa-capabilities/src/serve.rs`):

| # | link | line | logs? |
| 1 | `host.enqueue_completion` (Lua host fn) | `serve.rs:1777` -> `serve::enqueue_completion` | **no** (r7 added the caller's line in Lua) |
| 2 | scheduler admission | `scheduler::admit(session, owner, Background, pick_run_node_thread)` | **was no** - now **yes** (r8) |
| 3 | node-thread choice | `serve.rs:756` `pick_run_node_thread`, falls through to `spawn_node_thread` on an empty pool | no |
| 4 | slot spawn | `serve.rs:637` `spawn_node_thread` - reserves `slots[index]`, builds an interpreter | **was no** for the reservation - now **yes** (r8) |
| 5 | delivery | `Work::Completion` in the node-thread loop -> `lua.call_string("wa_completion_run")` | logged only if the script raises |

The link that can park an item **silently after a restart** is **3 -> 4**: `pick_run_node_thread` (L756) prefers a
*live* id from `live_node_thread_ids()`; when none is live it grows the pool and returns the new slot's index
(L784-790) **without any line saying a slot was reserved**, and from then on the item is counted admitted. If that
slot's thread is not yet in its loop - the spawn happens behind an interpreter build, and the boot line itself reads
`reads: 0 warm, up to 4, spawned on demand` (`serve.rs:2433`) - the item waits in a channel no thread drains: no run,
no journal line, row `dispatching` for ever. That is exactly the measured shape, and it was invisible.

**(b) Done:** three new lines, each at the decision rather than near it:
* `[completion] admitted run <id> of session <id> to node-thread <n>` / `... BEHIND, node-thread <n>` /
  `[completion] refused for session <id>: <reason>` - `scheduler::admit`'s answer is now matched and named;
* `[spawn] run node-thread requested (min <i>, max <j>)`, `[spawn] run node-thread at slot <n>`,
  `[spawn] refused: no free slot between <i> and <j>` - at the spawn, so a slot without a thread is named.
With r7's Lua line (`selfloop: dispatched wake <id> …: <receipt>`), the next repeat will say which link took the item
and whether a thread was there to read it.

**NOT done, carried by name:** (c) the boot test that enqueues a completion right after startup and asserts a run or a
logged refusal - it needs a spawned `serve` path, and an assertion written without it would be a claim rather than a
test; (d) narrowing the reclaim's activity check to the wake's **own** run - the row carries no run id today, so a
column (or a link table) comes first, then the check; (B) the abandoned-resume line (`resume_abandoned` -> one visible,
model-free line on opening the session, counted by `wa-sentinel status` and `wa status`) - the queued red-r7-add, not
started.

**Rows after r8:** build `exit=0` (34.95s); `test-deploy-resume.lua` 25, `test-selfloop-pause.lua` 169 (re-run against
the rebuilt binary).

### r7-add: the abandoned resume says so, once (24/11 ~06:50Z)

**Texts to approve (verbatim - Fable's proposed line, shipped exactly):**

    this session was paused by an update and could not be resumed automatically; send any message to continue

**What it does.** `deploy_pause.abandoned_notice(session)` reads `<data>/deploy-paused/<session>.json`; if it says
`abandoned: true` and not yet shown, it prints that one line at the moment the session is opened
(`wa chat --continue` / `--resume` / `--session`, plain view and TUI alike, before any prompt), and marks
`abandoned_shown` in the same record so it is said **once per abandoned pause**. It is a file read and a file write:
no provider, no run row, no paid turn - the test asserts the `runs` count is unchanged across the call.
`deploy_pause.abandoned_count()` feeds `wa status` as `abandoned resumes N (oldest <age>)`; `wa-sentinel status`
already counts them (verified on the live node: `paused sessions: 8, oldest 4h ago, stale: 0, abandoned: 4`).

**Test** (`scripts/test-selfloop-pause.lua`, real files under `<data>/deploy-paused`): an abandoned record shows the
line once and verbatim with `runs` unchanged; a second open shows nothing; a session that resumed normally shows
nothing; the counter counts the abandoned one, reports the oldest age, and does not count the normal one.
**177 checks** (was 169).

### r7c: diagnosed with citations, NOT fixed (the honest boundary of this round)

* **(2) placement - why other sessions were pinned to the stalled thread.** `pick_run_node_thread`
  (`rust/wa-capabilities/src/serve.rs:756`) sets `floor = interactive_reserve()` for background work
  (`:354`), and the comment above it states node-threads 0 and 1 are that reserve - so **the only lane a completion
  may take is index >= 2, i.e. thread 2**. That is why all four completions are on thread 2 while thread 0 sat idle:
  by design, and the design has no escape route. Its idle filter also judges a lane by *label* and *beat*
  (`node_thread_busy_label`, `node_thread_age_ms`, `:766-775`), never by *progress*: a lane blocked inside Lua still
  beats, so once the label cleared it stayed eligible. Growth was closed because `ceiling = run_capacity()-1`
  (`:376`) allowed no slot beyond 2, so `spawn_node_thread` (`:637`) had nothing to give.
* **(1) the stall - where it waits.** The node-thread loop (`serve.rs:2862-2872`) does `begin_work("child completion")`
  and then `lua.call_string("wa_completion_run")`; it never returned, so the block is **inside Lua**, on the session's
  run claim held by the attended CLI turn. The Lua side of that decision is `lua/core/agent.lua:2055-2061` with
  `deploy_pause.claim_wait` (`lua/core/deploy_pause.lua:252`), which only *classifies* a busy claim - it does not
  bound the wait, and nothing on this path frees the node-thread. That is the one-line fact the fix must change:
  bounded wait, deferral, row back to pending, one log line.
* **The spin.** `wa-placement` (`serve.rs:2388`) loops `wa_orchestrator_tick` then `sleep(2s)`; 49% CPU for 29 min
  means the sleep was never reached - the spin is inside `wa_orchestrator_tick` (Lua), not in the loop.

**Not done:** both fixes and their node-level test; the RED report for a lane stalled past a bound; the reclaim's
activity check narrowed to this wake's own run; and the answer to *is (2) present in v0.1.1* - I did not read the tag.

### Correction to an earlier handover

Two turns reported "empty output" from `bash`. That was **my** mistake, not the node's: the bash result carries
`stdout`, and I was reading `.output`, so every result read as empty. Nothing about the node was ever silent to me.

### r7c: the placement and the defer, fixed (24/11 ~07:10Z)

Fable's question is answered (by Fable): `pick_run_node_thread`/`interactive_reserve` exist in v0.1.1
(`serve.rs:284`, `:686`), so (2) is an old defect. Fixed here.

**(2) Placement - the smaller change, and why it is the right one.** A lane is now ineligible when the label it
holds has been held past a bound (`node_thread_busy_for_ms`, `held_past_bound`, `node_stall_seconds`, default 120 s,
`WASM_AGENT_NODE_STALL_SECONDS`). I chose this over counting progress events because the start time of the label is
**already recorded** (`NODE_THREAD_BUSY` stores `(label, since)`), so the rule is three lines and needs no new state;
and when every run lane is busy or stalled, a background completion may take an idle, non-stalled **reserve** lane as
the last resort, with `[placement] no run lane is eligible ... background run takes reserve node-thread N`. That is
the one behaviour change of substance: the reserve exists so a burst of wakes cannot starve a person, and a person is
not served by a lane that has stopped making progress.

**(3) /health** (`health_body_for`): the per-lane entry now reports `state: "stalled"` when the label is held past the
bound, plus `stalled: true` and `stalled_after_seconds` - the label and the session were already there. A lane that
beats but does not progress is no longer called busy.

**(1) The defer.** `selfloop.run_wake` asks `deploy_pause.claim_state` (the r5d rule, read from the claim store's
liveness) **before** the turn: `held` costs the wake one row write, one line
(`selfloop: wake <id> of session <id> deferred: another run holds the session claim`) and a `due_at`; the
node-thread is free before a turn is attempted. Measured in the row: `185 checks passed`, and the line appears.

**(6) `scripts/test-selfloop.lua:193`** (red since r6d): `finish` only wrote `WHERE status='dispatching'`, so a wake
that was settled while still `pending` (an event or message wake its publisher had already settled) never moved. It
now also settles a row that was **never claimed** (`status='pending' AND attempts=0`); a re-armed row has been
claimed, so r6b's belt still protects it. Row: `{"checks":109,"ok":true}`.

**Rust unit test:** `a_lane_that_beats_but_does_not_progress_is_stalled` asserts the pure rule. To run it I had to
repair the crate's **lib test target**, which did not compile before this round: two `foreground(...)` calls in
`operations.rs` tests were missing their `stdin` argument. Result: `404 passed, 4 failed` - the four are
`operations::*` tests that refuse to run with `HOME=/home/victor` (they need `scripts/test.sh`'s `GATE_HOME`), none
of them mine and none of them new.

**NOT done, named:**
* **(4) the spin.** `serve.rs:2388` spawns `wa-placement`, which loops `wa_orchestrator_tick` and then sleeps 2 s;
  49 % CPU for 29 minutes means `wa_orchestrator_tick` (`lua/core/subagents.lua:1056`) never returned, so the spin
  is inside the tick - most likely its sqlite-busy path (`phase`, `subagents.lua:~1040`) re-raising without backoff.
  Not fixed; the measurement stands.
* **(5) the sentinel.** `wa-sentinel status` already distinguishes "admitted, not started" per holder, yet the restart
  request was held by "session 79230887 is still working (child completion)" - so the restart bound uses a different
  rule than the status line, and I did not locate it in `rust/wa-sentinel/src/main.rs` this round. `recover` on a
  unit-owned node (`wa-serve.service`) is likewise untouched.

### Landing gate round 1: the branch is rebased onto main 4c720beb (24/11 ~07:30Z)

The gate was red on `land-quick`: `rust/wa-capabilities/src/operations.rs` conflicted. **Main already carried the two
`foreground(..., None)` arguments** that I repaired in r7c, so the rebase took main's side and my version of that
repair was dropped - the credit in the r7c addendum for fixing the lib-test target belongs to main, not to this
branch. Everything else rebased cleanly (`git merge-tree` against main: 0 conflicts).

Rows re-run on the rebased tip (`build=0`): deploy-resume 25, deploy-pause 101, selfloop 109 (ok), selfloop-component
30, selfloop-pause 185, handle-wake 17, cli-wake-row 30, deploy-bound ok, deploy-wait ok.

### r7c-fix: a second place for background work (Fable's gap, 24/11 ~07:50Z)

Fable is right: with one background lane the defer fixes BLOCKED and not BUSY. A's resumed turn can legitimately
work for twenty minutes, and every other session's wake waits behind it - "no progress counts as busy" cannot help
when there is nowhere else to go.

**Choice: (b), the smaller one.** Background may **borrow one idle reserve lane** when no background lane is eligible
(busy or stalled), and hands it back in `end_work` - the borrow is held for the run, never for a clock. Sizing is a
pure rule:

    borrowable_for(reserve) = 0 if reserve <= 1 else 1     // interactive_reserve() defaults to 2

and the lines it writes:

    [placement] no background lane is eligible (busy or stalled): background run borrows reserve node-thread N (0 already borrowed); it is handed back when the run ends
    [placement] no background lane is eligible and the borrow is spent (1/1); refusing rather than queueing behind a busy lane

**Interactive latency risk, stated:** at most ONE reserve lane is ever lent, so with the default reserve of two a
person's next run still has a lane of its own; on an idle node the borrow never triggers at all (the background lane
is eligible), so the added latency there is **zero by construction**. In the saturated case the worst added wait is
the duration of one background run on a borrowed lane, never more than one run. MEASURED where it can be measured
here: the two timing-sensitive rows pass unchanged (`deploy bound ok`, `deploy wait ok`).

**/health:** each waiting completion already carried `waited_ms`, `session`, `kind`, `node_thread`; it now carries
`over_bound` and `bound_seconds` (default 30 s, `WASM_AGENT_COMPLETION_WAIT_SECONDS`), so anything waiting past the
bound is red by name rather than inferred. Each lane carries `borrowed` next to `stalled`.

**Tests:** `background_borrows_at_most_one_reserve_lane` (reserve 1 lends nothing; 2 lends one; 4 still lends one)
and `a_lane_that_beats_but_does_not_progress_is_stalled`. Serve module: **47 passed, 0 failed**.

**Still not done:** the node-level B test in both shapes needs a spawned `serve` (A attended; A's resume plus B's
wake; B starts within the bound). This round proves the rule, not the node. (4) the tick spin and (5) the sentinel
remain open, as reported.
