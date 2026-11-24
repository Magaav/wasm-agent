# deploy-alive-holds - an install holds a session once, because the deploy says it is alive

Branch `change/deploy-alive-holds` from `origin/main` `39e862d6`. Two commits, built and run HERE on avell. Nothing
pushed.

| commit | what |
| --- | --- |
| `5f4d488e` | the deploy's own running state: written by `scripts/deploy.sh` at its start, cleared by its exit trap, read by `lua/core/deploy_pause.lua` as one more reason an install is in progress |
| `6ae677dd` | a release stamps every pending resume, DUE OR NOT - the second defect the node row found (below) - plus the four-case real-node row |

## The hole, measured

`~/.wasm-agent/sentinel/deploy.out` for 39e862d6 (24/11 21:15-21:27Z): the sentinel CLAIMED the request and started
`scripts/deploy.sh` DETACHED, moving the request to `done/` 8 s later (`rust/wa-sentinel/src/main.rs:
start_deploy_detached`, `finish_request`). `scripts/deploy.sh` then fetched and COMPILED for 430 s; the deploy-pending
marker belongs to `scripts/upgrade.sh:663`, which runs AFTER the build. Between the claim and that marker there was no
request in `requests/`, no claimed file and no marker, so `release_due` concluded the install was over. Two sessions
were released, each ran a paid resume turn, found `installed.txt` still naming `345e51be` and were told "[deploy] the
update did not happen"; the marker then paused them again, for a second release and a second paid turn.

## The mechanism, and why it is the smallest one that is true for every install kind

One file, written by the deploy process itself: `<data>/deploy-alive.json` = `{pid, since, bound_seconds,
pid_start, commit, by}` (`scripts/lib/deploy-alive.sh`, atomic write). `lua/core/deploy_pause.lua`'s `M.alive` judges it
and `M.waiting` adds it to the two facts it already knew (a waiting request, the installer's marker), so **every**
caller - the pre-run gate, the pause at a step boundary, a wake's deferral, `release_due` - treats a running deploy
exactly as it treats a waiting one. `release_due` therefore releases only when there is no request, no claimed
request, no marker AND no live deploy.

It is true for every install kind because it does not describe the install's phases at all: a Rust deploy that
compiles for seven minutes, a Lua fast-path deploy that swaps in seconds, a deploy a human runs by hand with no
sentinel, a deploy whose request was withdrawn - all of them are "the deploy process is alive", which is the only
fact common to them.

### (a) the fact cannot go stale

The record carries the writer's pid AND that pid's own start time: field 22 of `/proc/<pid>/stat` (clock ticks since
boot), compared on every read. A recycled pid is `pid_recycled`, a zombie is not alive, and a record past its own
`bound_seconds` is `expired`. Measured by `scripts/test-deploy-alive.lua`: a live pid with its own start time is a
deploy; the same pid with a start time off by 7 ticks is NOT; a dead pid is `not_running`; a record 1900 s old with a
1800 s bound is `expired`; a record with no pid holds nothing.

### (b) a deploy that dies releases, and then the did-not-happen line is true

With `/proc`, the next read sees the pid gone: measured on the real node row, a deploy `kill -9`ed mid-compile
released the session **1-3 s** later, with `[deploy] the update did not happen` (case 2). On a host where the process
table cannot be read at all (Windows, a sandbox without /proc), the record's own bound is the only thing that can end
the hold: `M.ALIVE_BOUND` = 1800 s, and the answer is marked `unverified` rather than pretending the deploy was
proven alive. That 1800 s is the stated bound for such a host.

### (c) the marker's bound against a long compile

Checked, and the compile is not under the marker at all: `scripts/deploy.sh` builds, and only then calls
`scripts/upgrade.sh`, which writes the marker (`scripts/upgrade.sh:661-664`) with `DEPLOY_IDLE_BOUND` (default 1800 s,
`WA_DEPLOY_IDLE_BOUND`); `deploy_pause.decode` obeys the marker's OWN `bound_seconds` and uses `DEFAULT_BOUND` (900 s)
only for a marker that names none. So a 430 s compile cannot consume the marker's bound - it sits in the alive state's
window (1800 s, over 4x the measured compile) - and the wait that follows it has its own 1800 s.

### (d) scripts and Lua only

No Rust change, no binary rebuild: `scripts/deploy.sh` writes the state right after it takes the build lock and clears
it in the `EXIT` trap it already had; `scripts/lib/deploy-alive.sh` is shipped beside `deploy-signal.sh`
(`ship_file`), so an installed node's next deploy has it.

**Is "done means finished" in the sentinel the right long-term fix? Yes.** The request file is the only piece of
state that knows which commit is coming, and it is thrown away when the sentinel hands the work to a detached child.
Long term the sentinel should keep the request in a RUNNING lane for the whole life of the child it spawned - with
that child's pid and start time, which is the same liveness fact this state file uses - and move it to `done/` when
the child exits. That is better than this file because the process that spawned the child is the one that can reap
it; this file stays necessary for the case the sentinel does not cover: a person running `scripts/deploy.sh` with no
sentinel at all.

## The second defect the node row found

`release_due` only stamped rows whose `due_at` was still in the FUTURE. A pause arms its resume for its own poll (60 s
for a waiting request); during a 60 s compile that poll comes due; the tick refuses it while the deploy runs and it
stays pending, already due. When the install ended, that row was never stamped, so the ordinary due path ran the
resumed turn with the pause-time words - "[deploy pending] The node is installing a new build ..." - after the install
had finished. Red before `6ae677dd` on the row's own assertion: `the first line of the resumed turn is not '[deploy]
installed': [deploy pending] The node is installing a new build (bbbb5555eeee6666), ...`. The release now stamps every
pending resume of an unparked session, due or not.

## Rows (a real scratch node, own HOME/port/ledger, requests counted at a loopback stub)

`scripts/test-deploy-alive-hold.sh`, wired into `scripts/fast.sh` and `scripts/test.sh`. The stub deploy follows the
real timeline in the real scripts' own functions: it states that it is running (`deploy-alive.sh`), compiles (a sleep),
then writes the marker (`deploy-signal.sh`), waits for idle as `upgrade.sh` does, swaps `installed.txt`, clears both.

| case | result |
| --- | --- |
| (1) Rust-like install, 60 s compile, **three sessions mid-turn**: request claimed and moved to `done/` at once | 30 s of the compile spent **ZERO** model requests; then exactly **ONE resume each** (6 requests: 3 pauses + 3 resumes, no delivery in between), first line `[deploy] installed`, naming `bbbb5555eeee`; three resume rows, none armed twice |
| (2) the same install **killed** mid-compile | ONE resume each, released **1-3 s** after the kill, `[deploy] the update did not happen` |
| (3) a **scripts-only** install (no compile) | still exactly ONE resume, `[deploy] installed` - no regression |
| (4) **two requests back to back** (the second's whole queue life inside the first deploy's compile) | releases nothing early; ONE resume at the end |

RED on `origin/main` 39e862d6: the same row fails at the first case - the session's pause is never held through the
compile and the ledger fills with `[deploy] the update did not happen` rows, which is the incident's own signature.

Lua row `scripts/test-deploy-alive.lua` (36 checks, wired into `scripts/test.sh`): the reader's judgement (constraints
a and b, above), the wait every caller sees, the refusal's words, and the release that must not happen while the
deploy runs (`0` released, the row keeps its own time) and must happen once it is gone (`1` released, one turn).
RED on `origin/main`: `attempt to call a nil value (field 'alive_path')`.

## Regressions (green on this branch, each on its own scratch home under flock -o)

`test-deploy-release-honest` 81, `test-resume-window` 41, `test-deploy-pause` 116, `test-deploy-wait` 59,
`test-deploy-resume` 25, `test-deploy-alive` 36, `test-selfloop-pause` 200, `test-cli-wake-row` 30,
`test-completion-deploy-wait` 16, `test-peer-deploy-wait` 14, `test-kept-message-one` 36.

Pre-existing, NOT mine: `node scripts/check-deploy-shipped.mjs` fails on `scripts/check-component-proof.lua`
identically on `origin/main` 39e862d6 (measured in a clean worktree of that commit).

## Texts to approve

1. `"waiting for the install of %s (a deploy has been running %s)"` - NEW branch of `deploy_wait.M.say`, used when the
   wait is a RUNNING deploy rather than a request in the box (there is no request id left to name).
2. `"deploy_waiting: <the sentence above>. This node starts no new turn while a deploy is being installed - a turn in
   flight is exactly what keeps the node from going idle - and this turn did not start. Nothing was lost: this is a
   wait, not a failure, and the work starts again once the swap is done. A running turn pauses after its current step
   instead (lua/core/deploy_pause.lua). retry when idle: nothing was asked and nothing ran, so ask again once the node
   is back"` - NEW branch of `deploy_wait.M.refusal`: the same promise as the request sentence, without telling the
   reader to withdraw a request that is a detached process.
3. `"could not write the deploy-running state in <dir>: a session paused in this deploy may be resumed while it
   compiles"` and `"the deploy-alive library is missing (<path>): a session paused in this deploy may be resumed while
   it compiles"` - NEW operator lines on the deploy's own log (`scripts/deploy.sh`).

## Not done, written for after the cut

* Place the pause as LATE as possible: sessions work through the fetch and the compile and pause only for the swap.
  With this state the pause already lands where the sessions are when the deploy starts; moving it later would keep
  them productive for the compile and needs the marker's own "about to swap" phase, not this file.
* The sentinel's RUNNING lane (above), which is the long-term fix and needs a binary.

