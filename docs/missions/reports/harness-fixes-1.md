# harness-fixes-1 — six items, what review r2 corrected, and the commits that answer each

Base `ac7717e0`, merged forward to `origin/main` `39bbf2b6`. Built and verified on this node (avell)
only. Nothing pushed.

**Read this first.** Two rounds of review corrected me twice, and both corrections are recorded here
rather than smoothed over:

* **Round 1** — my report claimed items 2 and 3 were "already fixed at base" because a test passed on a
  base worktree. That reasoning was wrong: avell **runs the base binary**, so both incidents happened
  ON BASE. A test that passes there proves the test is weak, not that the node is fixed.
* **Round 2** — my first fixes for items 1–3 still missed the measured shapes: the guard killed a
  `codemode` call (not `operation`), the nested record says `status: 202` (a number, not a state
  string), and a clock-only change in the pending answer was being counted as progress.

## Branch A — ships now (`change/harness-fixes-1a`, in its own worktree)

Three commits, reviewed OK, cherry-picked from `origin/main` (`39bbf2b6`) into a separate worktree. The
main branch was not touched to build it.

| commit | item |
| --- | --- |
| `12762a72` | item 6 — the deploy swap fixture carries the provenance line its block installs from |
| `5f0d1ada` | item 5 — an unknown field on `operation start` is refused by name |
| `5727436e` | item 4 — a worktree failure names git's verdict, its exit code and the command |

**Branch head: `5727436e`.** Verified there: `node scripts/test-sentinel-service-deploy.cjs` → 17 checks,
exit 0; `start_field_tests` → 3 passed; `scripts/test-land.lua` case 12b drives a failing worktree and
the `merge` step carries git's words with `exit 128` and the command. Fast path on that branch:
`fast path FAILED (1 of 49)` when first run, and the one red row was **not** these commits — it was
`rust wa-capabilities`, whose two operation tests refuse a non-scratch HOME. Re-run with a scratch
`HOME`: **348 passed, 0 failed**. That same defect is fixed on the main branch below.

## Branch B — `change/harness-fixes-1`, merged with `origin/main`

| commit | what it fixes |
| --- | --- |
| `69e4c829` | r2 item 1 — a reused served agent records EVERY failed turn, not only the first |
| `cd0e02a7` | r2 item 2 — a wait on a foreign operation sleeps instead of spinning at 100% CPU |
| `a2944fe6` | r2 item 4 — a dead owner's case has ONE named outcome per situation, cross-process |
| `28dacda5` | r2 item 3 — release before announce, proved by a second PROCESS |
| `b849c4f3` | r2 items 5 and 6 — the measured rel-native shape through the real loop; the clock is not progress |
| `678e738b` | r2 item 3 — the lease-order control is wired into the gate |
| `0af952d8` | merge `origin/main` (`39bbf2b6`); one conflict in `agent.lua` |
| `9acc5518` | a Rust row in the fast path gets its own scratch HOME |

The merge conflict was one hunk in `lua/core/agent.lua`: my `self.failure=nil` (r2 item 1) against
`origin/main`'s `self.gate` assignment (done-gate-trial r2 item 1). Both are kept — they are independent
per-run resets. Note `origin/main` carried that comment block **twice**; the duplicate was collapsed
rather than merged in. `Manager::wait`'s foreign poll composes with the bounded `wait_ms` await loop the
merge brought in: the loop bounds the total, `wait()` supplies the 100 ms sleep for an operation this
process does not own.

## Fast path, after the merge

`fast path ok (55 checks, 0 skipped, 206s)` at `9acc5518`, ledger
`/home/victor/wasm-agent/checkout/.git/worktrees/wt48/wa-fast-result.json`. Rows of interest, all `pass`:
`rust wa-capabilities` (10s), `rust wa-operation` (3s), `scripts/test-no-silent-stops.lua`,
`scripts/test-rel-native-replay.lua`, `scripts/test-run-lease-order.lua`,
`scripts/test-two-failures-reused-agent.lua`, `scripts/test-operation-survives-turn.lua`,
`scripts/test-land.lua`.

Run under the suite lock (`flock /tmp/wa-suite-hf1.lock`), never beside another suite.

### Two rows were red and neither was a regression I introduced

* **`rust wa-capabilities`** — measured at `origin/main` in a separate worktree: the same two tests fail
  with `refusing to run: this test starts real operations, so HOME must be a scratch or temp directory
  ... (got /home/victor)`. `scripts/test.sh` runs Rust rows with `HOME=$GATE_HOME`; `scripts/fast.sh`
  gave them none. Fixed in `9acc5518` — each Rust row gets `$work/home.XXXXXX`, with `CARGO_HOME`
  untouched so `--offline` still resolves. Before the fix the row failed; after it: `fast: rust
  wa-capabilities ok (10s)`.
* **`deadline_covers_both_streams_without_serial_graces`** — passed **5/5** alone in my tree and **5/5**
  at base (`39bbf2b6`). It is a load-sensitive timing row (its own comment records the same flake on
  04/11); it went green in the confirming run. Not attributed to this change.
## Items and commits

### Item 6 — `scripts/test-sentinel-service-deploy.cjs` red on main — `35029ffe`

Reproduced first: `EXIT=1`, `actual ['stop']`, `expected ['stop','copy','start']`.

Measured cause (which side changed): `936880f9` introduced the supervisor's one byte source,
`SENTINEL_SOURCE="${SENTINEL_SOURCE:-${NEW_SENTINEL:-}}"` (`scripts/deploy.sh:1652`). The fixture slices only
the swap block and sets `NEW_SENTINEL` alone, so under the wrapper's `set -eu` the copy line died on the
unset variable before `cp` ran. **The deploy script is right; the test was stale.** Not a code bug.

Fix (`35029ffe`): the fixture reads deploy.sh's own resolution line out of the source and runs it ahead of
the block, and asserts that line still exists — so it pins the script instead of drifting from it.
17 checks, exit 0.

### Item 1 — the progress guard stopped a legitimate wait — `de50a838`

Cause (`de50a838`, `lua/core/progress_guard.lua`): `observe()` counted repeats by call fingerprint and
returned `guard_repeated_calls` at `repeat_limit` whatever the round had learned. An await's answer IS a
new observation while the work runs (`elapsed_ms`, state, queue depth move).

Fix (`de50a838`): new `progress_guard.waiting(name, args, answer)` — true only for the `operation` tool,
only for `action` `await`/`wait`, only when the answer is a table with `settled ~= true` and a live state
(`accepted`, `queued`, `running`, `draining`). An answer with no `state` field is **unknown, not yes**, so it
is judged like any other repeat. `observe()` clears the repeat streak and idle count on such a round.
`lua/core/agent.lua` computes `round_waiting` from the call's own answer and passes it in.

A **settled** operation awaited three times is still `guard_repeated_calls` — unchanged.

Tests (`de50a838`): `scripts/test-no-silent-stops.lua` gains 19 checks (10 awaits of a running operation not
stopped; a settled one stops at three; `status` not exempt; a non-operation tool not exempt; an answer
without `state` not exempt). 103 checks pass. Row is in the fast path by default (not in
`scripts/fast-path.exclude`).

### Item 5 — the timeout notice must be impossible to miss — `e3844211`

Cause (`e3844211`, `rust/wa-capabilities/src/operations.rs`): `start` read only the keys it knew and
ignored everything else. A caller passing `timeout_ms` got no complaint, `requested_seconds` stayed `None`,
the kind default applied, and a long job died on a 300 s deadline nobody chose — the `timeout_notice` was
present and unread because the caller had no reason to doubt its own field.

Fix (`e3844211`): `start_fields_refused(args)` — an **allow-list** of the fields `start` reads (never a
block-list). Any other key refuses the launch before anything is admitted; several unknown fields are all
named, sorted. Called first in `control("start")`. `docs/OPERATIONS.md` states it beside the
`timeout_notice` rule it protects.

Tests (`e3844211`): `operations::start_field_tests` (3) — the measured `timeout_ms` case refused by name,
every field real callers send accepted (command, program, args, cwd, timeout_seconds, background,
`_launch_cwd`, owner, session, node_scope, tool, scope, wait_for, output, max_bytes), and every unknown
field named in a stable order. `cargo test -p wa-capabilities`: **343 passed, 0 failed**.

### Item 4 — `wa land` `worktree_failed` with EMPTY detail — `ab9eab4c`

Two causes, both in `lua/core/land.lua` (`ab9eab4c`):
1. `M.exec` read only `code`/`stdout`/`stderr` from the host's JSON. When `host.exec` refuses a launch it
   answers `{error: …}` with **no streams at all**, so a refusal became a failure with no message.
2. The detail was `first_line(stderr or stdout)`: a failure with neither stream reported `""`, and git's
   progress line (`Preparing worktree (new branch …)`) pre-empted its verdict line on stdout.

Fix (`ab9eab4c`): a stream-less `{error}` becomes `host_error: <text>`; the raw answer is kept when the host
did not answer the expected JSON; the detail is one durable sentence — `last_line(git's words)` +
`exit <code>` + `command: git worktree add …`, plus the raw host answer when there was one. `last_line`
replaces `first_line` for that field because git writes progress first and the reason last — **my own case
12b caught this while being written**, and it is why the helper exists.

Tests (`ab9eab4c`): `scripts/test-land.lua` case 12b (13 checks) drives five shapes through `land.run` —
git's stderr with exit 128, a host refusal with no streams, an unreadable host answer, git's stdout with
empty stderr, and a failure with **neither** stream — each asserting a non-empty `observed` naming the
verdict, the code and the command. The row passes in the fast path (`25866 ms`).

### Items 2 and 3 — both were REAL, and my first report got this wrong — `d5a98f03`, `15e7de31`

**Correction.** My first report claimed both were already fixed at base on the strength of
`ad2ee462`'s end-to-end test, which passed on a base worktree. That reasoning was wrong, and the
review named why: **avell runs the base binary**, so both incidents happened ON BASE. A test that
passes there proves the test is weak, not that the node is fixed. The earlier `ad2ee462` claim is
withdrawn; the test it added is kept as a regression guard, labelled as such.

**Item 2 (`d5a98f03`) — the run lease was released AFTER the failure was signalled.** The release was
unconditional but sat after `run_failure.handle`, which records the failure, publishes it on the
durable bus and schedules a wake: over a minute on that node. For that window the session was still
claimed by a run that had already ended, which is exactly the 22:53:18Z refusal and the 22:54:33Z
success. Fixed by ordering: mark uncertainty, release, then record and announce.

Proved by `scripts/test-run-lease-order.lua` (4 checks), which hooks `host.resource` — the one
process-wide seam; hooking a module cannot work here because `rawequal(dofile(x), dofile(x))` is
**false** in this node, so every load is a fresh table (measured). At the release it reads the
session's durable rows: release-first means no `run_failed` row exists yet, and the row must appear
afterwards so a never-recorded failure cannot pass. `scripts/test-run-lease-order.sh` is the negative
control: it reverts the order, requires the row to fail **by exit code**, and restores the file. Note
the control's own first version was wrong — it grepped for the row's `ok ...` line, which a failing row
still prints; the exit code is the only honest judge.

**Item 3 (`15e7de31`) — a new process declared every operation it did not remember `outcome_unknown`.**
`snapshot()`'s disk fallback never checked whether the owner was alive, so a resumed turn could not
await its session's live work or read its final result. It now reads the owner's lease file (held with
`BEGIN EXCLUSIVE` for the process's life): settled → its own record is the result; lease still held →
`reattached: true` with the owner's state and readable streams; lease free → the old
`operation_owner_not_attached`. Anything undecidable answers dead — unknown is not yes.

Proved across a real process boundary by `a_fresh_process_reattaches_to_live_work_and_spares_dead_work`
with `operation_owner_helper`: a fresh `Manager` in another process sees `reattached`, reads the
operation's own stdout (`reattach-marker`), awaits it by id, and answers differently once the owner is
killed. Reverting only the `snapshot` branch to base makes that test fail (`left: true, right: false`).

### On `scripts/test.sh:233` — it is NOT Windows-only

The review asked me to confirm whether the sentinel row sits in a Windows-only section. Measured: it
does **not**. The Windows block opens at line 214 (`if [ "${OS:-}" = "Windows_NT" ]`) and closes with
`fi` at line 231; `gate_run node scripts/test-sentinel-service-deploy.cjs` is line **233**, outside it,
so the gate runs that row on Linux too. Item 6's fix is therefore exercised by the gate on this
machine — it was genuinely red here, and it is genuinely green here now (`17 checks`, exit 0).
## Brief premises that were wrong

| Brief said | Measured |
| --- | --- |
| item 6 is a code bug in the deploy swap | the code is right; the **test fixture** was stale after `936880f9` |
| items 2 and 3 are open defects | **true** — my first report wrongly called them fixed; see the correction above |
| `test-no-silent-stops.lua` is a gated row | it is a fast-path row by default; **not** referenced in `scripts/test.sh` |
| (review) `test.sh:233` may be Windows-only | it is **not**: the Windows block ends at line 231, and the row is line 233 |

## Pre-existing failures (not mine)

* `scripts/test-land.lua` case 9 (`the journal names the node that signed`) fails **identically at
  `ac7717e0`** in a base worktree: it needs a scratch vault admin listener this machine does not have. My
  case 12b was therefore inserted **before** case 9 so it actually executes; the suite still stops at case 9
  for that environmental reason, exactly as at base.

## Texts to approve (new or changed operator/model-facing strings, verbatim)

1. `operation_unknown_field: <fields> - start reads none of these, so nothing was launched. The deadline is timeout_seconds (1-86400); an unknown field is refused rather than silently given the default.` (`e3844211`)
2. `guard_repeated_calls: the same call was made N rounds in a row with no new observation (<label>); the turn stopped where a continuation can pick it up` — **unchanged wording**, now no longer fires on a live wait (`de50a838`)
3. `(git answered with no output)` — the worktree failure detail when git wrote nothing (`ab9eab4c`)
4. `; exit <code>; command: git worktree add -b <branch> <tree> <base>` — appended facts in that same detail (`ab9eab4c`)
5. `raw host answer: <answer>` — appended when the host did not answer the expected JSON (`ab9eab4c`)
6. `host_error: <text>` — a stream-less host refusal, formerly an empty stderr (`ab9eab4c`)
7. `An unknown field on start is refused BY NAME (operation_unknown_field: <fields>) instead of being ignored: …` — new docs/OPERATIONS.md paragraph (`e3844211`)

## What I did not do / did not verify

* Did not push (per instructions) and did not run the full nightly gate `scripts/test.sh` — the focused rows
  plus the fast path are what I ran; `scripts/test.sh` is ~50 min and is not the landing requirement here.
* `wa land` against a live fleet was **not** run (node rule 13); item 4 is proved by the fixture cases.
* Items 2/3 are not code changes: I could not make a defect appear that the base does not have.