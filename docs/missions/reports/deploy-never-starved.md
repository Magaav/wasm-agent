# deploy-never-starved — a waiting install always gets its idle moment

Branch `change/deploy-never-starved`, base `4c443e66` (item 4 of `sentinel-on-avell`).

| item | commit |
| --- | --- |
| 1. a waiting deploy request pauses running turns and stops new ones | `79cdfc88` |
| 2. `wa-sentinel status` names every holder; a held deploy passes over paused sessions after its bound | `9f57d863` |
| 3. the cross-process proofs (a real node, a real `--once` worker, a real sentinel) | `82d00ef2` |
| docs and the suite wiring | `558f13a1` |
| the row that borrowed its subject, found by the preflight of 22/11 (`does-not`) | `38c27bfe` |
| round 2 (review MUST 1-3): a served operator turn is never refused nor cut, and the factory's callers wait out exit 2 | `42a3a57a` |

Citations are `git log -S` / `git show`; every claim below names the commit that implements it.

## The premises, re-measured (22/11, this laptop)

| the brief says | what the machine said |
| --- | --- |
| the request for `8082b42e` was "held: node busy" for 28 minutes, 22/11 10:01Z | **true, and longer: 30m24s.** `~/.wasm-agent/sentinel/sentinel.log` line 400: `maintenance-deferred deploy …1795341684727384607-2971842…` at `1795341684` (10:01:24Z); the deploy unit started at `1795343508` (10:31:48Z), reason `land-quick turn-no-probe-2 (8082b42e)` |
| "34 min on 22/11 01:27Z" | **not verifiable here.** The retained log starts 18/11 10:59:48Z and holds 53 `maintenance-deferred` lines; the only other deploy hold in it, 22/11 09:43:50Z (`land-quick turn-no-probe (d7597689)`), was released **11 s** later (deploy unit at 09:44:01Z). The 01:27Z hold is not in this file |
| the pause marker exists only while the installer runs | **true.** `scripts/lib/deploy-signal.sh` is sourced by `scripts/upgrade.sh` (`. "$DEPLOY_SIGNAL_LIB"`, then `wa_deploy_signal_write … bound "upgrade.sh"` before the idle wait, `clear_deploy_signal` on the EXIT trap). The sentinel claims a request by renaming it into `claimed/` and only then spawns `scripts/deploy.sh`, which verifies the tree and builds before `upgrade.sh` runs — so the claim-to-marker window had **no signal at all** |
| `release_due` releases the resume "at once (the marker is gone)" | **true in the base code.** Base `lua/core/deploy_pause.lua`'s `release_due` returned 0 only while `(opts.read or M.read)(now)` — the installer's marker (`79cdfc88` is the fix) |
| a parked session's running CLI turn is not stopped by the park | **true, and documented by the park itself**: `lua/core/session_park.lua`'s header says it "does not kill a run that is already in flight" |
| a new `--once`, a wake or a subagent keeps the node busy | **true — nothing refused them.** On the base, `git grep -n 'deploy_wait\|operator_present' 4c443e66 -- lua/` is empty: no path consulted the deploy state before a turn |
| "cargo is on PATH" (the briefing) | **false in a mission shell on this node**: `which cargo` finds nothing; `~/.cargo/bin/cargo` is the binary, and the pre-built target dir is `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-deploy-never-starved` |

## What was built

**1. A deploy is two signals, and one predicate answers both (`79cdfc88`).**

- `lua/core/deploy_wait.lua` (new) reads the sentinel's own box under `<data>/sentinel`, both lanes
  (`requests/` and `claimed/`; the rename into `claimed/` IS the claim, `rust/wa-sentinel/src/main.rs`), keeps
  only verbs that install a build (`M.INSTALLING = { deploy = true }`, an allow-list: `upgrade` is retired and
  held for ever by name, and `restart`/`stop`/`recover`/`spell`/`run`/`wake` install nothing), takes the
  oldest, bounds it (`M.DEFAULT_BOUND = 900` s from `queued_at`, or from the epoch in the file name for an
  older request), and says it in one sentence (`M.say`, `M.refusal`).
- `lua/core/deploy_pause.lua` (`79cdfc88`): `M.waiting(now, opts)` is the single predicate (installer marker
  first, then the request box); `at_boundary` pauses for either; `M.say_wait` keeps the old
  `deploy pending:` sentence for an INSTALL and says `deploy waiting: waiting for the install of <sha>` for a
  wait; `release_due` no longer releases while a request merely waits; `M.refuse` returns the one sentence
  every caller uses.
- **No new turn starts** (`79cdfc88`): `lua/core/agent.lua`'s `M:run` refuses an automatic turn before any
  ledger write, emit or model call, and only when `operator_present` is unset — set by `wa chat` at a terminal.
  `lua/core/chat.lua` refuses a scripted start (`--once`, a piped stdin) before the thread is opened, exit 2,
  writing nothing. `lua/core/selfloop.lua`'s tick dispatches no wake while either signal is live (the rows keep
  their time, order and prompt, and their `last_error` carries the sentence), and `run_wake` gives a row it had
  already claimed back, exactly as the park branch does.
- **The resume is short and then held** (`79cdfc88`): a pause for a WAITING request arms its one wake at
  `WAIT_RESUME_SECONDS = 60` instead of the installer's bound, the tick holds it while the deploy continues,
  and `release_due` makes it due the moment both signals are gone.
- **Where a session says it paused** (`79cdfc88`): `deploy_pause.record_pause` writes
  `<data>/deploy-paused/<session>.json` (`{session, since, to, source, request, by}`) at the moment the pause is
  decided — the fact the sentinel needs and `/health` cannot have.

**2. The wait is visible and bounded (`9f57d863`).**

- `rust/wa-sentinel/src/holders.rs` (new): `holders_from` reads the ONE `/health` snapshot (`node_threads`, the
  legacy `workers`, `current`, `queue`, `subagents`) into `{session, label, ms}`; `holder_lines` renders them;
  `bound_verdict` decides. `wa-sentinel status` prints `busy: <n> holder(s) of the node`, one
  `busy session <8> <label> <duration> paused for the deploy|working` line each, and the bound.
- `rust/wa-sentinel/src/main.rs`: `hold_bound_secs()` (`WA_DEPLOY_HOLD_BOUND`, default **180 s**),
  `request_queued_at`, `paused_dir`/`paused_since` (a record only counts at or after the request's queue time),
  `oldest_waiting_queued_at`, the `status` section, and the dispatcher: past the bound it proceeds only when
  `bound_verdict` says every holder paused (`audit("hold-bound-passed", …)`), and otherwise holds with the
  reason naming the session that blocks it.

**3. The proofs (`82d00ef2`).**

- `scripts/test-deploy-wait.lua` — the reader's judgement with injected clocks and boxes (55 checks).
- `scripts/test-deploy-wait.sh` + `scripts/lib/deploy-wait-e2e.lua` — five processes on one scratch home: a real
  node (`wa serve`, this tree's Lua) with a stub model on loopback; a served turn refused while a request waits
  and **no completion spent**; a real `wa chat --once` refused with exit 2 and **nothing written** (no thread, no
  message, no completion); a turn already running when the request arrives pausing at its next step boundary by
  itself and recording its pause; the node's own tick holding a due worker wake across the wait, the installer's
  marker AND the claimed lane, then performing the held wakes exactly once when the deploy ends; and the worker's
  next turn running again.
- `scripts/test-deploy-bound.sh` — the **real `wa-sentinel` binary of this tree** against a stub `/health`: it
  names both holders with their labels and durations, marks the paused one, holds before the bound, names the
  session that is still working when the bound has passed, runs the install when every holder paused, refuses a
  pause record older than the request, refuses a holder with no session, refuses a node that reports itself busy
  and names nobody, and runs an idle node's deploy without any bound.

**Wiring** (`558f13a1`): both `.sh` rows are in `scripts/fast.sh` (`check deploy-wait`, `check deploy-bound`) and in
`scripts/test.sh` (`gate_run bash scripts/test-deploy-wait.sh`, `… test-deploy-bound.sh`), the new Lua row is a
fast-path row by the glob (`scripts/test-deploy-wait.lua` is not in `scripts/fast-path.exclude`), `cargo test
--manifest-path rust/wa-sentinel/Cargo.toml` picks up `holders_tests` (8 tests) with no wiring of its own, and
`scripts/test-deploy-signal.sh` — a row that existed and was run by no suite — was wired into `scripts/test.sh`.

## What was measured

- `cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1`: **142 passed, 0 failed**,
  `holders_tests`' 8 among them.
- `scripts/test-deploy-wait.sh`: **ok** (33 checks, 15 s). `scripts/test-deploy-bound.sh`: **ok** (24 checks, 0.6 s).
  `scripts/test-deploy-wait.lua`: **55 checks**. `scripts/test-deploy-signal.sh`: **13 checks**.
- Unchanged and still green after the change: `scripts/test-deploy-pause.lua` (23), `scripts/test-deploy-resume.lua`
  (25), `scripts/test-session-park.lua` (68), `scripts/test-selfloop.lua` (114 checks, 1 skip),
  `scripts/test-selfloop-pause.lua` (101).
- **Discrimination on the base** (`4c443e66`, a separate worktree at
  `/home/victor/Work/missions/deploy-never-starved/base-wt`, never a stash): the Lua row exits 1
  (`lua_root_unreadable: …/lua/core/deploy_wait.lua`), `scripts/test-deploy-wait.sh` exits 1 with **17 FAILs**
  (first: `the turn is refused by name`), `scripts/test-deploy-bound.sh` exits 1 with **12 failures**.

## Texts to approve (new or changed, verbatim)

1. `deploy_waiting: waiting for the install of <sha 12> (deploy request <id>, asked <when>). This node starts no
   new turn while a build is waiting for it or being installed - a turn in flight is exactly what keeps the node
   from going idle - and this turn did not start. Nothing was lost: this is a wait, not a failure, and the work
   starts again once the swap is done. A running turn pauses after its current step instead
   (lua/core/deploy_pause.lua). To stop waiting, withdraw the request: wa-sentinel request withdraw <id>`
2. `deploy waiting: waiting for the install of <sha 12> (deploy request <id>, asked <when>); this turn paused
   after its step and scheduled a resume, so the node can go idle and the install can start (the wait is bounded:
   <n>s from the request)`
3. `waiting for the install of` — the one phrase a reader meets in all three places (chat refusal, wake deferral,
   paused turn).
4. `busy:      <n> holder(s) of the node`
5. `  busy     session <8>  <label> <2m|9s|1h|for an unrecorded time>` with `  paused for the deploy` or
   `  working`, and `  busy     (no session named)  <label> …` for a holder that is not a session.
6. `  the request has waited <n>s; past <n>s the sentinel proceeds if every holder has paused`
7. `deploy proceeding: held <n>s, past the <n>s bound, and all <n> holder(s) of the node have paused for it`
8. Hold reasons the bound adds: `the hold bound is <n>s and <n>s have passed`; `the node reports itself busy and
   names no holder, so nothing proves a turn paused`; `the holder \`<label>\` names no session, so this request
   has no proof it paused`; `session <8> is still working (<label>)`.
9. `wa session status`/a wake row's `last_error` now carries sentences 1–2 instead of nothing when a wake is
   held for a deploy.
10. The window's chat body carries `"operator": true` (a scheduling hint; `ui/app.js`).
11. `deploy-wait <time> the node is waiting for or installing a build: asking again (<n>s of <n>s)` - the mission
   runner's line, in `out.log`, per re-ask.
12. `deploy-wait <time> gave up after <n>s: the node is still waiting for or installing a build, so this turn
   never started (nothing ran)` - the runner past its limit.
13. `deploy-wait <time> refused (nothing ran; asking again in <n>s)` - the same wait in `lease.log`.
14. `deploy-wait the node is waiting for or installing a build: asking again (<n>s of <n>s)` - the resume
   runner's line.
15. `worker-gate: the node is waiting for or installing a build: the resume waits <n>s and asks again (<n>s of
   <n>s) - round <n> is not spent`.
16. `worker-gate: the node refused the resume for <n>s (a build is waiting for or installing on it): nothing ran,
   and no round was spent - the request is in its sentinel's box`.
17. `docs/SCRIPTED-RUNS.md`: `2` is documented as *refused, nothing ran*, and a runner that resumes a worker
   must WAIT on it (`WA_DEPLOY_WAIT_LIMIT`/`WA_DEPLOY_WAIT_STEP`) rather than count a round.

## What this does not claim

- **Not verified end to end on a live deploy.** The bound and the holder lines were proved against a stub
  `/health` and the real sentinel binary (`82d00ef2`), and the pause/refusal/resume against a real node and a
  real `--once` worker; no deploy of this branch ran on this node from this worktree, so "`wa-sentinel status`
  shows the request, then 0 waiting within about three minutes" (Victor's own test) is **not** measured here.
- **A served AUTOMATIC turn is refused while a deploy waits.** `POST /chat` from a client that does not send
  `operator: true` is refused (round 2, `42a3a57a`); the window's own turn is not, because the window says so.
  A peer's relayed turn (`/node/chat`) is a program and is always refused.
- **A subagent child that is already running keeps running** - the follow-up brief is in the round-2 section
  above.
- **The 01:27Z incident could not be re-measured** (not in the retained log; see the table).
- `scripts/test-deploy-signal.sh` was added to `scripts/test.sh` only; the fast path runs the `.sh` rows it names,
  and this one is not among them.

## The whole fast path, and the two rows that failed in it

`flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` on this tree: **384 checks, 2 failed, 506 s** (306/307
Lua rows; `fast: deploy-wait ok (15309ms)` and `fast: deploy-bound ok (207ms)` ran and passed as rows). Neither
failure is attributable to this diff, and both were measured:

| row | what it said | measured again |
| --- | --- | --- |
| `scripts/test-start-instant.lua` | `FAIL quiet ledger: the model call starts in under 1 s (1073)` | **passes alone on this tree, 2 of 2 runs** (`start-instant ok`). It is a wall-clock threshold row and the suite run was compiling a release binary beside it. The gate this diff adds costs **0.062 ms** per turn start with an empty box and **0.083 ms** with a request waiting (2000 calls each, measured in a scratch home), so it cannot be the 73 ms |
| `scripts/test-install-guards.sh` | `test-install-guards: 72 checks, 6 failed` | **identical on the base worktree** (`4c443e66`, same 6 FAIL lines, same 72 checks): the in-turn deploy guard answers `refused inside a turn running on the node it would replace` because the runner itself is inside a node turn (`WASM_AGENT_IN_TURN`). Pre-existing and environmental, not this diff |

The fast path also printed the tree's binary as `b56581895221 is on NO branch the remote has` - expected: this branch is
committed locally and never pushed, as instructed.

## The preflight's discrimination row, and the defect it found (`38c27bfe`)

The first preflight of this branch (22/11, HEAD `ac33856e` merged with main `e1d457f0`) stopped on
`discrimination` with exactly one blocking row:

```
does-not	scripts/test-deploy-bound.sh	it passed on the old code, and the branch ADDS it: it does not catch this change
```

**It was right, and the row was wrong in two ways.**

1. **Its subject was borrowed.** The row looked for a prebuilt sentinel at
   `${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa-sentinel`. Run against the BASE tree with the mission's
   `CARGO_TARGET_DIR` in the environment, it found the sentinel built from the BRANCH, drove it, passed - and
   proved nothing. Fixed: the subject is now BUILT from `$ROOT`'s own sources by a cargo invoked with `$ROOT`'s
   manifest, into that target directory; `WA_SENTINEL_BIN` is accepted only INSIDE `$ROOT`; and the bytes that
   build produced are copied into the row's own `$WORK/wa-sentinel`, so no concurrent build can swap them
   between a check and a `once`. The row prints the tree commit and the binary's `sha256` so a reader can see
   which build it judged. Cost of the honesty: 5 s in a warm target, 12 s from cold.
2. **Its skips looked like passes.** Every hole was spelled `deploy bound: SKIP (...)` - not `SKIP ` at the
   start of a line, which is the spelling `scripts/fast.sh` collects and the spelling that made
   `scripts/test-discriminates.sh` record exit 0 as "it passed on the old code". Both rows now print
   `SKIP test-deploy-bound: <reason>` / `SKIP test-deploy-wait: <reason>`, and the absence of cargo, of node or
   of curl is a named non-judgment instead of a silent success.

Re-measured after the fix (`38c27bfe`): `bash scripts/test-discriminates.sh origin/main --branches
'change/deploy-never-starved' 4c443e66` -> **2 discriminating, 0 blocking, 1 not judged** (`changes=1`,
`unrevertable=1`: the Lua row, which the tool cannot judge while the branch changes `rust/`, its own named
limit). On the base worktree the two `sh` rows fail with **12** and **16** failures, and both pass on this
tree (`deploy bound ok`, `deploy wait ok`).

**What was NOT re-run after `38c27bfe`/`4665e68c`: the whole fast path.** It was started twice and both times
queued behind another mission's suite in `~/Work/missions/.suite.lock`; the second attempt sat waiting 24
minutes while `main-health` held the lock and a `wa land` preflight for another branch queued behind it, so it
was cancelled (its queued `flock` was blocking that preflight) and the two rows it would have run were run
directly instead, with the fast path's own environment (`CARGO_TARGET_DIR` set, `WA_BIN` set): both ok. The
last complete fast-path run of this branch (the preflight of 22/11, on the merged tree `ac33856e`) reports
`fast: ok (217 checks, 0 failed)`; the earlier full run here (before these two test-only commits) was 384
checks / 2 failed, both pre-existing and both re-measured on the base - see below.

## Round 2 - the review's three MUSTs (`42a3a57a`)

### MUST 1 - a served operator turn is never refused

The first version refused EVERY run without `operator_present`, and only `lua/core/chat.lua` set it - so the
window's own turn got `deploy_waiting` for up to 900 s on every landing, and the comment in `agent.lua` claiming
otherwise was false. Every served entry that can start a turn, and who is behind it:

| entry | who is behind it | verdict |
| --- | --- | --- |
| `POST /chat` non-streaming -> `wa_reply` (`lua/core/server.lua`) | the window's non-SSE fetch, a script, a `curl` | a person IFF the body says `operator: true` (`ui/app.js` sends it); otherwise refused |
| `POST /chat` streaming -> `wa_reply_stream` | the window (SSE), a script | the same rule, same field |
| `POST /node/chat` -> `node_agent` (`server.lua`, peer relay) | another node's program | a program: never exempt, refused like any automatic turn |
| `agent_for`'s cached agent (`server.lua:90`) | whatever the next request is | the marker is set per RUN at both call sites, so an automatic turn cannot inherit a person's exemption |
| idle compaction (`server.lua:652`) | the node itself | not a turn (a summary model call), unchanged |
| efficiency report (`server.lua:1980`) | the operator's `/report` | not a turn, unchanged |
| `wa chat` at a terminal (`chat.lua`) | the operator | exempt since the first round (`scripted` is false at a tty) |

The field is a SCHEDULING hint, not an identity: what a caller may read, write or deploy is still decided from
its credential (`resolve_admission`, the session-isolation rules), and a client that lied about it could only
spare its own turn a wait. `parse_run_body` now treats `operator: true` as one of the three things that make a
body structured (with `images` and `thread`), so the JSON is never handed to the model as text.

### MUST 2 - an operator's turn IN FLIGHT is not cut by a merely WAITING request

`deploy_pause.at_boundary` asked both signals for everybody. Now an `operator_present` run asks the INSTALLER's
marker alone: a request that is only waiting needs the node to stop starting turns, not to end the turn a person
is in the middle of, and the real swap still pauses everybody as it always did. `wa-sentinel status` names such
a session `working` (its holder line, unchanged - it marks `paused for the deploy` only from a pause record, and
this run writes none).

### MUST 3 - the factory's scripted callers survive the new exit 2

`wa chat --once` exits 2 with `deploy_waiting` while a build waits for or installs on the node. Three callers
used to spend something on that:

| caller | before | now |
| --- | --- | --- |
| `scripts/worker-gate.sh` | counted the refusal as one of the three rounds, then asked the preflight again - three refusals and the mission is recorded red although nobody worked on it | waits and asks again, up to `WORKER_GATE_DEPLOY_WAIT` (900 s) in `WORKER_GATE_DEPLOY_STEP` (15 s) steps, and counts a round only when a turn actually ran; a wait that never ends records `preflight=refused` with `rounds` unchanged |
| `scripts/mission.sh`'s generated `run.sh` | wrote `rc=2` into `done` - a mission that never ran, read as a failed turn | waits and asks again (`WA_DEPLOY_WAIT_LIMIT`/`WA_DEPLOY_WAIT_STEP`), writes the wait into `out.log` AND `lease.log`, and binds `run.lock` to the session of the attempt that finally ran; past the limit `done` says `rc=2` and the log says nothing ran |
| `wa mission launch`'s `run.sh` and `wa mission resume`'s `resume-run.sh` (`lua/core/mission.lua`) | the same, and the resume spent one of its 25 tries on the wait | the same wait; the resume's tries are spent only on real attempts |

**The factory's own copy.** `~/Work/missions/worker-gate.sh` is a SYMLINK to the canonical checkout's
`scripts/worker-gate.sh`, so it inherits this fix when the branch lands - nothing to copy. I first copied the
fixed file onto that path, which wrote THROUGH the symlink into the canonical checkout's working tree; I saw it
in `git status` there, restored the file (`git checkout -- scripts/worker-gate.sh`, tree clean again) and left
the symlink as it was. That mistake is here rather than buried: a factory script that is a link into another
tree must not be "updated" by copying onto it.

### What the tests measure now (and what fails on the pre-round tip)

| row | on this branch | on the pre-round tip (`1bcd8779`) |
| --- | --- | --- |
| `scripts/test-deploy-wait.lua` (59 checks, 1 s) | ok | **fails**: `a waiting request does not end the operator's turn` (MUST 2) |
| `scripts/test-deploy-wait.sh` (36 checks, 17 s) | ok | fails: the window's turn is refused (step 2a), the operator's in-flight turn is cut (step 4b) |
| `scripts/test-worker-gate.sh` (39 checks) | ok | **fails**: `two refused asks and two real resumes, not 2` (MUST 3) |
| `scripts/test-mission.sh` (282 checks) | ok | fails: the launch records `rc=2` for a turn that never ran |
| `scripts/test-mission-verb.sh` (47 checks, 12 s) | ok | fails: the generated runner exits 2 with the refusal as its rc |
| `scripts/test-deploy-bound.sh` (24 checks) | ok | fails (12 FAILs) |

`bash scripts/test-discriminates.sh origin/main --branches 'change/deploy-never-starved' 4c443e66` ->
**5 discriminating, 0 blocking, 1 not judged** (the Lua row; the tool cannot judge a Lua row while the branch
changes `rust/`).

`scripts/test-deploy-wait.sh` step 2 was split as the review asked: **2a** the window's turn (`operator: true`)
runs while the request waits and spends a completion; **2b** a served turn that says nothing is refused by
name and spends none. Step **4b** starts an operator turn, writes the request while its first model call is in
flight, and asserts it reaches its own answer, is not refused, goes on to the model and records no pause.

While building that row I also fixed a real defect it exposed: the launcher's timeout watchdog
(`( sleep 21600; kill ... ) &`) was killed as a subshell, so the `sleep` inside it survived and held the
caller's stdout open - `$(bash run.sh)` never saw EOF and hung for up to six hours. The watchdog's own output
is `/dev/null` now (it needs none), which is a one-line change and is what let the runner be tested in a
command substitution at all. The rows that drive a runner write its output to a FILE anyway
(`scripts/test-mission-verb.sh`), so the old tree - where the orphan still exists - fails this row by name
instead of hanging it.

And one in the harness's favour: `wa chat --once` treats a stdin that is not a terminal as a queue of prompts,
so a row whose child inherited the discrimination gate's own stdin (the list of rows) ATE THE REST OF THE LIST -
six rows were listed and three ran, the other three consumed as extra prompts. Every row that can start a CLI
now begins with `exec </dev/null` and says why; that is also why the gate now reports all six rows of this
branch instead of three.

## SHOULD: what happens when a turn's step never ends within the bound

A turn that is inside a long tool call when a request starts waiting does not reach a step boundary until the
call returns, so it keeps the node busy. What the node does about that, exactly:

* no NEW turn starts beside it (the gate), so nothing adds to the wait;
* the sentinel holds until `WA_DEPLOY_HOLD_BOUND` (180 s) and then asks `bound_verdict`: a holder that is still
  working is NOT passed over - the deploy keeps waiting and `status` names the session and its label
  (`session 8082b42e  POST /chat 3m  working`);
* when the call returns, that turn's next step boundary is where it pauses (or finishes), and the install
  starts on the next watcher tick;
* a `bash` call is bounded by the node's own `exec_timeout_seconds` (300 s by default, reported by `/health`),
  so "never" is a call's bound, not an unbounded wait. If the bound were raised above the request's own window
  (900 s) the request would expire and the node would start new turns again - named here because that is the
  setting an operator would reach for on a machine doing long builds.

## SHOULD: the running subagent child (follow-up, not this round)

A child that is already running when the request arrives keeps running: `deploy_pause` never pauses a child
("its parent owns the continuation", unchanged since the park work), so it holds the node until it ends. The
sentinel names it (`2 subagent(s) running, 0 queued`, no session) and refuses to pass the bound over it. The
follow-up brief: give a child the same step-boundary pause, with the parent's continuation carrying the resume -
or let the sentinel treat a running child like a paused holder once its parent has paused. Both need a test that
crosses processes (a real child run against a real node), which is why it is not in this round.

## Knobs

| variable | default | what it does |
| --- | --- | --- |
| `WA_DEPLOY_HOLD_BOUND` | `180` | seconds a held deploy waits before it may pass over PAUSED holders; `0` keeps the old unbounded wait |
| `WA_DEPLOY_IDLE_BOUND` | `1800` | the installer's own wait once it runs (`scripts/upgrade.sh`, unchanged) |
| `deploy_wait.DEFAULT_BOUND` | `900` | how long a waiting request may keep new turns stopped (a stuck request cannot freeze the node) |
| `deploy_pause.WAIT_RESUME_SECONDS` | `60` | how soon a turn paused for a WAITING request asks again |
