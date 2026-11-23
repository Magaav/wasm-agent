# deploy-prunes-pins

Priority 2, launched overnight 22-23/11. A deploy never removed its own pinned worktrees, so /tmp filled
and the NEXT install refused. Branch `change/deploy-prunes-pins`, base `6eb4b206`, worktree
`/home/victor/Work/missions/deploy-prunes-pins/wt`. Implementation: `654b4a76`; test ordering `0ba06b90`;
wiring `8611f154`; docs `a6a8b162`.

## Premises, re-measured before writing code

| brief said | measured on the base | verdict |
| --- | --- | --- |
| a deploy creates a pin under `/tmp/wa-deploy-pins/<sha>` | `scripts/deploy.sh:1176-1205` (step 3c) calls `node scripts/landing-queue.mjs pin --pin-dir "$PIN_DIR"`; `scripts/landing-queue.mjs` `PIN_ROOT_DEFAULT` = `<tmpdir>/wa-deploy-pins`, `ensurePinnedWorktree` does `git worktree add --detach` | correct |
| nothing ever removes them | a repo-wide search for `worktree remove` finds the reuse path inside `ensurePinnedWorktree` (its own tree only), `scripts/lib/deploy-gate.mjs` (its own `pin-check` tree), `scripts/reap-worktrees.mjs` (mission trees) - no code removes an old pin | correct |
| 19 pins = 2.5 GB, and the install of 5ea23581 refused with `deploy_pin_failed` | that refusal is in `~/.local/bin/deploy.log` (2026-11-22T13:29:43-0300, 5ea23581); at 22/11 23:40Z the directory held **5** pins / **637 MB** (the orchestrator had removed 18 by hand) | the refusal is real, the count is stale - by the time this mission started, 5 pins |
| one pin's size | `du -sh` on each of the five: **128 MB** each (a whole checkout; worktrees share objects) | new measurement |
| /tmp is a 16 G tmpfs with a per-user quota | `df -h /tmp`: `tmpfs 16G 12G 4.3G 73%` | correct |
| the last local install pinned its commit | it did not: `installed.txt` from the 6eb4b206 install says `build_pin=unpinned` (Lua fast path, "the installed binary is this build", `deploy.log` 2026-11-22T20:10), and no `/tmp/wa-deploy-pins/6eb4b206` exists | the brief's "keeps the running pin" is not enough on its own: a Lua fast-path install creates no pin |

That last measurement is why the keep set cannot be "the commit in `installed.txt`" alone.

## What changed

**`scripts/landing-queue.mjs` (`654b4a76`)** - `pruneDeployPins()` and its parts:

- `pinKeepsFromRecords(installDir)` reads `commit=`, `binary_commit=` and `build_pin=` from
  `<install>/installed.txt` and `<install>/rollback/installed.txt`, and keeps a value only when it has a
  commit's shape (`unpinned`, `unknown`, empty are not commits).
- `pinProcessUsers(pinDir, procRoot)` returns the pids whose cwd is inside a pin (a running build) and
  counts the processes it could not look at; when `procRoot` cannot be read at all it answers
  `known: false` and then nothing is removed.
- The keep set is an allow-list, capped at `--keep-max` (default 2): the commit being pinned first, then
  the record shas, then the newest pins by mtime; pins a live process is inside are added on top and are
  never removed.
- Removal is `git worktree remove` → on failure `git worktree remove --force` → for a directory git does
  not register, a delete; then `git worktree prune` and `build-target.sh forget <tree>` (the same call the
  reuse path already made). A failure is pushed into `failed` and named - it never throws.
- `commandPin` prunes **before** `ensurePinnedWorktree` (so a full /tmp can no longer stop the next
  install), inside a try/catch that can never fail the pin.
- New verb `prune-pins` (`--pin-dir`, `--install-dir`, `--keep`, `--keep-max`, `--proc-root`, `--json`),
  which takes no lease and writes no queue row.

**`scripts/deploy.sh` (`654b4a76`)**

- `PIN_DIR` is named outside the `WA_DEPLOY_PIN=1` branch, so a deploy that pins nothing still prunes.
- step 3c passes `--install-dir "$INSTALL_DIR"` to `pin`, so the prune before the new tree knows the
  records.
- step 8b, after the final `record_installed`: runs `prune-pins` with the pin directory and the install
  directory, prints its lines, and on failure is a `note` - never a `fail`.

**Docs (`a6a8b162`)**: `docs/LANDING-QUEUE.md` gains the rule, the allow-list and the measurement.

## Tests

`scripts/test-deploy-pin-prune.mjs` (new, `654b4a76`/`0ba06b90`), wired into the fast path
(`check deploy-pin-prune node scripts/test-deploy-pin-prune.mjs`, `scripts/fast.sh`, `8611f154`) and the
gate (`gate_run node scripts/test-deploy-pin-prune.mjs`, `scripts/test.sh`, `8611f154`). It runs the real
CLI against a real fixture repository and a real bare origin, with `HOME` and `WASM_AGENT_HOME` inside its
own temporary directory (and refuses to run when they resolve to the real ones). 52 checks, 2 s:

- four deploys in a row (one of them the Lua fast path, record `build_pin=unpinned`) leave exactly two
  pins, and they are the commit installed and the one before it; the pin directory never holds more than
  the kept set plus the new tree at any point;
- a pin a live process is inside survives even with the keep set full, named with the pid, and the same
  command removes it once that process is gone;
- a `--proc-root` that cannot be read removes nothing and says why;
- a chmod-0555 pin directory makes the removal fail: exit 0, the failure named, the tree left in place;
- a note, a file named like a commit and a symlink are not candidates;
- a `--keep-max` that is not a positive integer is refused by name (exit 75, not read as 'no cap');
- `scripts/deploy.sh`'s call site is after the final `record_installed`, hands over `--install-dir`, and
  its failure branch is a `note`.

**Discrimination** (`bash scripts/test-discriminates.sh 6eb4b206`): `discriminates scripts/test-deploy-pin-prune.mjs
FAIL check failed: deploy 1: the post-install prune exits 0` - 1 discriminating, 0 blocking. On the base the
behaviour fails first (there is no `prune-pins`), not the wiring check.

## What was verified, and what was not

Verified by running: the test above (51/51 on the branch, FAIL on the base worktree at `6eb4b206`);
`node scripts/test-landing-queue.mjs` (100 checks, green - the `pin` verb it exercises still reuses and
answers the same fields plus `prune`); `node scripts/check-deploy-shipped.mjs` (190 checks);
`bash scripts/test-deploy-ship.sh` (all pass); `bash scripts/test-deploy-policy-order.sh` and
`bash scripts/test-deploy-luafast-record.sh` (pass); `node scripts/check-temp-retention.mjs` reports
`ok scripts/test-deploy-pin-prune.mjs (mint at 6; removes via node-rm)`.

Pre-existing failures, reproduced on a separate worktree of the base (`/home/victor/Work/missions/deploy-prunes-pins/base`),
not caused by this branch: `bash scripts/test-deploy-record.sh` (`wa_build_info: command not found` in its
generated `run-record.sh`), `bash scripts/test-deploy-preconditions.sh` ("the WSL shell was not refused by
name"), `bash scripts/test-deploy-gate-policy.sh` (`NODE_BIN: unbound variable` in its `run.sh`), and
`node scripts/check-temp-retention.mjs`'s 54 failing rows (none of them this branch's test).

**Not run: the full fast path and the full gate.** Both are heavy suites and the node was installing
builds of main throughout this window; the rows this change can move were run individually instead (listed
above). **Not verified end to end:** `deploy.sh`'s own step 8b has never executed - it is asserted
structurally by the test (call site, order, `--install-dir`, note-not-fail) and behaviourally by the CLI in
a fixture, not by a real install. The first real proof is Victor's own check: after the next two local
installs, `ls /tmp/wa-deploy-pins` should show two directories, the running sha and the one before.

The record reading was also run against THIS node's real install, read-only (`--proc-root /nonexistent-proc`,
so nothing could be removed): it kept `8862b60085fb` with the reason `installed.txt:commit=` and
`8fccc83360dd` with `rollback/installed.txt:binary_commit=`, and all 7 pins were still there afterwards.

At the time of writing, `/tmp/wa-deploy-pins` on this node held 7 pins (the base had 5; two more were
created by main's own deploys during the session) - so the first install of this branch will remove five,
and the second will remove one more.

## Texts to approve

New operator-facing lines (verbatim from the diff, `654b4a76`):

1. `landing-queue: pin prune: kept <sha12> (<reason>)` - reason is one of: `the commit this pin builds`,
   `installed.txt:commit=`, `installed.txt:binary_commit=`, `installed.txt:build_pin=`,
   `rollback/installed.txt:commit=` (and the same two other fields there), `named by --keep`,
   `one of the <n> newest pins`, `a live process is inside it (pid <pid>)`,
   `nothing could say which processes are alive (<why>), so nothing was removed`
2. `landing-queue: pin prune: removed <sha12>` - optionally ` (needed --force: <git's last line>)` or
   ` (a directory git did not register (<git's last line>))`
3. `landing-queue: pin prune: could not remove <sha12>: <reason> - left in place, and the deploy goes on`
4. `landing-queue: pin prune: <n> removed, <n> kept, <n> left in place in <dir>`, with ` - nothing was
   removed: <why>` when liveness is unknown and ` (<n> process(es) not inspected)` when some pids could not
   be read
5. `landing-queue: pin prune: <error> - the pin is created anyway` (the pin step's own housekeeping catch)
6. `landing-queue: --keep-max must be a positive integer, not '<value>'`
7. deploy.sh note on a failed prune: `pin prune: <last 3 lines> - the install stands; the trees under
   <dir> are left as they are`
8. deploy.sh note without node: `pin prune: node is not on PATH, so this deploy cannot tell which pins
   under <dir> are still wanted; nothing was removed`

## Follow-up 23/11: every Lua fast-path deploy died at step 8b

The first version of step 8b (`654b4a76`, landed as `70b24e52`) broke the path this node mostly runs. Measured
in `~/.wasm-agent/sentinel/deploy.out`, on the deploys of `44479b7f`, `3665b1b7` and `e9a42d20`:

```
deploy: recorded in /home/victor/.local/bin/installed.txt
/home/victor/wasm-agent/checkout/scripts/deploy.sh: line 2422: PIN_DIR: unbound variable
```

The install had already finished and been recorded; the `wa-deploy-*` unit was then marked failed and no pin
was pruned - on exactly the deploys this laptop mostly runs.

**Root cause, re-measured rather than guessed.** `scripts/deploy.sh` writes the bodies of its big blocks at
**column 0**, so indentation says nothing about nesting. The pin step (3c) - and the `PIN_DIR` line I had moved
two lines up, still in the same place - sits inside the `else` of `if [ "$LUA_FAST" = 1 ]; then` (line 899 on
the base): the branch a Lua fast-path deploy never enters. Step 8b is in the shared tail every path reaches, so
the assignment was skipped and the reference was not.

That premise of the original brief ("keeps the running pin") was stale in a second way, and this is what hid
it: **a Lua fast-path deploy creates no pin at all**, because the pin step is inside the build branch. The 22/11
observation that the last installs recorded `build_pin=unpinned` was the symptom of the same structure.

**Fix (this branch).**

- `PIN_DIR="${WA_DEPLOY_PIN_DIR:-${TMPDIR:-/tmp}/wa-deploy-pins}"` is declared **before** the Lua fast-path
  branch (immediately above its `LUA_FAST=0`), where both paths pass, with the measurement in its comment.
- Step 8b is marked (`# wa-deploy-pin-prune: begin` / `end`) and reads `${PIN_DIR:-}` through a `case`: a path
  that names no pin directory says so in a `note` and the install stands, so the step can never die under
  `set -u` again even if the file is restructured.

**Test.** `scripts/test-deploy-pin-prune.mjs` grows `fastPathBlock()`, which extracts the real step out of
`scripts/deploy.sh` (by its markers, and on the older code by its unmarked step, so the row still runs) and
executes it under `set -uo pipefail`, the deploy's own strictness:

- no pin directory named: exit 0, a note naming the hole, and no `unbound variable`;
- a pin directory whose command cannot run: exit 0, the failure named, "the install stands";
- a real pin directory and the real CLI: the prune happens and exactly the kept set is left;
- structurally last: the declaration's byte offset is before `if [ "$LUA_FAST" = 1 ]; then` - the placement
  this bug was.

On `origin/main` (`e9a42d20`, a separate worktree, no stash) the test fails with the production error itself:
`FAIL step 8b survives a path that names no pin directory: exit 1: ... line 7: PIN_DIR: unbound variable`. On
this branch: 65 checks, 0 skipped, 5 s.

Re-run on this branch: `test-deploy-luafast-record.sh` (it extracts a neighbouring block of the same file),
`test-deploy-policy-order.sh`, `test-deploy-ship.sh` - all pass; `check-deploy-shipped.mjs` (190 checks);
`check-temp-retention.mjs` (`ok scripts/deploy.sh`).

**Still not verified:** a real install of this branch. What would have caught this on the base is a real
fast-path deploy inside the gate, and the gate does not run one; the extracted-block harness is the closest
cheap thing, and it reproduces the failure exactly.

Text to approve (new):

9. `pin prune: this path names no pin directory (WA_DEPLOY_PIN_DIR is not set and PIN_DIR is empty), so nothing
   under it was removed - the deploy's pin step and this one disagree about WA_DEPLOY_PIN_DIR, which is a hole
   in this script, not a machine state`


## Open questions

- The keep set is capped at two, which is what the brief asks for and what Victor's check measures. A
  deploy where `commit=` and `binary_commit=` are different commits AND both have pins can want three
  (running, its binary's tree, the previous install); the cap keeps the two the records name first and
  removes the third. Nothing today reads a pin except a retry of a build, so this is a cache size, not a
  correctness question - but it is a deliberate truncation, not an oversight.

## Why this branch is called `change/deploy-prunes-pins`

The first round of this mission landed as `70b24e52` and its branch was deleted, so the next round's work
(marked below) was committed on `change/deploy-prunes-pins-fix`. The preflight that followed reported one row,
`land-quick: no branch change/deploy-prunes-pins` - not a code failure: it resolved the mission's branch name,
which no longer existed. The fix branch was renamed back to `change/deploy-prunes-pins` (its commits unchanged)
so the mission, its preflight and the branch a landing would merge are the same name again, and the "Follow-up
23/11" section above is what that branch carries.
