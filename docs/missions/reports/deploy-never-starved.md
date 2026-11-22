# deploy-never-starved — a waiting install always gets its idle moment

Branch `change/deploy-never-starved`, base `4c443e66` (item 4 of `sentinel-on-avell`).

| item | commit |
| --- | --- |
| 1. a waiting deploy request pauses running turns and stops new ones | `79cdfc88` |
| 2. `wa-sentinel status` names every holder; a held deploy passes over paused sessions after its bound | `9f57d863` |
| 3. the cross-process proofs (a real node, a real `--once` worker, a real sentinel) | `82d00ef2` |
| docs and the suite wiring | `558f13a1` |
| the row that borrowed its subject, found by the preflight of 22/11 (`does-not`) | `38c27bfe` |

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

## What this does not claim

- **Not verified end to end on a live deploy.** The bound and the holder lines were proved against a stub
  `/health` and the real sentinel binary (`82d00ef2`), and the pause/refusal/resume against a real node and a
  real `--once` worker; no deploy of this branch ran on this node from this worktree, so "`wa-sentinel status`
  shows the request, then 0 waiting within about three minutes" (Victor's own test) is **not** measured here.
- **A served turn is refused while a deploy waits.** `lua/core/server.lua` does not set `operator_present`, and the
  node cannot tell the window from a script on `/chat`, so the window's own turn gets sentence 1 during a deploy
  instead of starting. That is the safe side and it is a behaviour change for the window; it is named here rather
  than silently accepted.
- **A subagent child that is already running keeps running**: `deploy_pause` never pauses a child (its parent owns
  the continuation, unchanged since `dfa88ca9`'s neighbours), so a child in flight still holds the node until it
  ends — the sentinel names it (`N subagent(s) running, M queued`, no session) and refuses to pass the bound over
  it.
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

## Knobs

| variable | default | what it does |
| --- | --- | --- |
| `WA_DEPLOY_HOLD_BOUND` | `180` | seconds a held deploy waits before it may pass over PAUSED holders; `0` keeps the old unbounded wait |
| `WA_DEPLOY_IDLE_BOUND` | `1800` | the installer's own wait once it runs (`scripts/upgrade.sh`, unchanged) |
| `deploy_wait.DEFAULT_BOUND` | `900` | how long a waiting request may keep new turns stopped (a stuck request cannot freeze the node) |
| `deploy_pause.WAIT_RESUME_SECONDS` | `60` | how soon a turn paused for a WAITING request asks again |
