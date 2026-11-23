# deploy-hold-never-fails-our-load

An install under the factory's own load waits or proceeds - it never fails at the bound. Two deadlock shapes and
the promise a pause makes to the worker that paused.

Branch `change/deploy-hold-never-fails-our-load`, base `41d6420c`. Commit list at the end; every claim below
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

`rust/wa-sentinel/src/main.rs` (**ae815084**): `fail_held_request` writes the same `failed/` record and then
parks the request in `<sentinel>/requeue/<id>.json`; `replay_requeues()` runs at the top of every
`process_requests` tick (so `once` does it too) and puts it back in `requests/` with `queued_at = now` and
`requeued: true` on the first tick `hold_for` says the node is quiet enough to run it — the same predicate the
dispatcher uses. A request that already carries `requeued` is not parked again: once is the bound. The reason
in `failed/` and in `status` names the landing that asked (`the request's reason: ...`), and
`wa-sentinel status` prints `requeue:   N request(s) that failed at their bound run when the node is quiet
enough`.

### 4. A paused worker is not killed by its own pause (the ADDED item)

`lua/core/deploy_pause.lua` (**4daff95a**): `M.claim_wait(claimed, now, opts)` — a session claim that is busy
**while a build waits or is being installed** is the wait, not the run's failure. Only `resource_busy` qualifies;
every other claim failure stays the caller's error.

`lua/core/agent.lua` (**4daff95a**) uses it at the claim: a non-operator run whose session claim is held while
a build waits emits the deploy sentence, sets `turn_refused` and returns — nothing ran, nothing was claimed,
the same request runs again when the node is back. A person's turn is exempt, which is the existing rule for a
merely waiting request (`deploy_pause.at_boundary`).

`lua/core/chat.lua` (**4daff95a**): `M.deploy_refused(agent)` recognises both sentences (`deploy_waiting:`
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

Unit level: `rust/wa-sentinel/src/holders_tests.rs` tests 12–14 (**ae815084**),
`scripts/test-deploy-pause.lua` (5 new checks, **4daff95a**) and `scripts/test-thinking-block.lua`
(5 new checks, **4daff95a**) — all three files are existing rows.

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
| `ae815084` | holders: `Verdict` (Proceed/Wait/Fail), a child completion never holds the install, an unnamed holder is never a failure, the reporter names `current`-without-a-label and an overdue operation; the bound failure is re-queued once; unit tests 12–14 |
| `4daff95a` | `deploy_pause.claim_wait` + `agent.lua` defers instead of failing a run whose claim the pause holds; `chat.deploy_refused` and exit 2 and `not started`; the six new steps in `scripts/test-deploy-bound.sh` and the new checks in `test-deploy-pause.lua` / `test-thinking-block.lua` |
