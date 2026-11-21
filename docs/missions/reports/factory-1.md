# factory-1: a mission is done only when the landing's gate is green

Branch `change/factory-1`, base bfad4f8f. Commits (all local, nothing pushed):

| commit | what it implements |
| --- | --- |
| 7390d624 | `wa land --until <step>`; a green gate kept across runs by TREE CONTENT; a red check re-run on the failed rows only |
| f35a2d5f | `scripts/preflight.sh` + `wa mission preflight <name>` + `scripts/test-preflight.sh`, wired into `scripts/fast.sh` |
| 449447b6 | `scripts/worker-gate.sh` (the worker's own red-fixing loop) + `scripts/test-worker-gate.sh`, wired into `scripts/fast.sh` |
| 94fd1e69 | a local path as `--incoming` (tracking namespace + a named `fetch_failed` refusal); the preflight reads its land root from `wa paths` |
| 5b1c1cde | `lua/core/refusal_codes.lua` regenerated: the row was red on the base (see the section below) |
| c9015ec7 | the land root read from the `config` line only (the `config file <path>` line made it `<config>\nfile/land`) |

## 1. `wa land --until <step>` (7390d624)

`--until` is a step name checked at parse time (`lua/core/land.lua` in `M.cli`: `elseif flag == "--until"`), and the
boundary is applied in ONE place in the run loop (`if name == options.until_step then reached_until = name break end`).
A round that reaches it records `result = stopped_at_until`, `stopped_at = <step>`, runs the report and exits 0
(`land: stopped after gate (--until): nothing after it ran (push main artifacts sign ship publish deploy)`).
The step is a BOUNDARY, not an acknowledgement: whether it ran, was skipped by the plan or was already settled,
nothing after it runs. `--until` is NOT one of the start options, so `wa land --resume` does not inherit it.
`--dry-run` prints `until  stop after gate: runs collect plan review merge gate; does not run push main ...`.

Tests: `scripts/test-land.lua` cases 33-35 (the stop itself, the kept gate, the different tree). On the base the
same call runs the whole round - a push, a main, every step `done` - so every assertion there fails.

## 2. `preflight.sh <mission>` and `wa mission preflight <name>` (f35a2d5f, c9015ec7)

`bash ~/Work/missions/preflight.sh <name>` runs `wa land --branches change/<name> --until gate` under
`flock -o <missions root>/.suite.lock`, writes `<mission>/preflight.json`
`{ok, run, branch, main_sha, tree_commit, tree_sha, seconds, gate_seconds, failed:[{row, first_lines}], gate_evidence, log, result, why}`
and exits 0 green / 1 red / 2 refused. `ok` is true only when the landing exited 0, the gate step is `done` and
no row failed; anything it cannot tell (no journal, no gate step, a missing interpreter) is `ok: false` with a
named `why`, never a pass. The merged tree is the landing's own (`<land root>/<run>/tree`, built by the same
`impl.merge`), so a test that behaves differently there behaves differently here.

`wa mission preflight <name>` (the `mission` verbs are landed - `lua/core/mission.lua`, dispatched in
`lua/core/init.lua:626`) runs the same script as a process and returns its fields; a missions root without the
script is refused by name with the `ln -s` that installs it. Both entry points are the same file: the canonical
`scripts/preflight.sh`, symlinked as `~/Work/missions/preflight.sh`.

## 3. The worker fixes its own reds (449447b6)

`scripts/worker-gate.sh <mission> <rc> [session]`, called by the run.sh that `launch.sh` now generates. After a
turn with rc=0 it runs the preflight; a red one resumes the SAME session (`wa chat --resume <sid> --once`, the
session read from the runner's own `err.log` line `wa: session <id> ok`) with the failed rows and
"Fix them, and do not weaken a test to do it"; at most `WORKER_ROUNDS` (3) rounds. `<mission>/done` becomes
`rc=<rc> preflight=<green|red|refused|not_asked|unknown> rounds=<n>` - `not_asked` when the worker's own rc was
not 0, `refused` when the preflight judged nothing, `unknown` when the script is not installed. The orchestrator's
model is not in the loop.

`launch.sh` is changed in the same edit (backup `launch.sh.bak.20261121T144540-pre-worker-gate`): the
`echo rc=... > done` line became the worker-gate call, with the old line kept as the fallback when the script is
not installed. The generated runner is checked with `bash -n` after emulating the heredoc's own escaping.

## 4. The landing keeps a green preflight (7390d624)

Two mechanisms, both in `impl.gate`:

* a row is kept when ITS OWN RUN passed it on this `tree_commit` with the same identity (as before);
* a row is kept when ANOTHER RUN passed it on the same TREE OBJECT (`tree_sha`, new in `impl.merge`) with the
  same identity (`M.gate_identity`: check name, command, cwd, `min_tests`, the row list's content, and for the
  discrimination check its branches and base). The kept row carries `kept_from = <run id>` and `seconds = 0`.

WHY THE TREE OBJECT AND NOT THE COMMIT - measured, not assumed: the recorded landing
`land-20261121T102542Z-995291fa` merged onto 13247bdb and produced commit `d87727fc`, tree `7c827979a3d1`; my
replay of the same branch on the same base produced commit `5b1db110`, tree `7c827979a3d1`. Same bytes, different
commit: a keep keyed on `tree_commit` would have been dead code.

Tests: `scripts/test-land.lua` case 34 (two rounds, one fixture, the check's counter does not move, the row says
`kept_from=case33` and `seconds=0`, the two commits differ and the two tree objects are equal) and case 35 (a
different branch runs the check again).

## 5. A red check is classified in seconds (7390d624)

The retry after a red check now runs ONLY the rows that failed. `M.failed_rows(tree)` reads the runner's own
result file (`<worktree>/.git/worktrees/<name>/wa-fast-result.json`: name, section, status, first_error), and the
retry command is composed by the SAME `compose()` that composed the first attempt with `WA_FAST_ROWS` pointing at
`<run>/gate-retry-rows.txt`. A contract check cannot be narrowed (this runner runs every one by name), and a tree
whose result file cannot be read gets the WHOLE check again with the reason in the evidence - unknown is not
"nothing failed". The verdicts are unchanged: `flaky under load` when the retry passes, `failed twice` when it does
not, and the vacuous-check refusal is untouched. The gate row now also carries `failed = [{row, first}]`, which is
what `preflight.json` reports.

Tests: `scripts/test-land.lua` case 36 (a fake runner that reports 2 failed Lua rows and 1 failed contract check:
the retry asks for the two, not the row that passed, and the verdict is still `flaky under load`), case 37 (a runner
with no result file: the whole check again, `retry.rows_file = nil`, the reason recorded).

## Proof: three recorded reds, replayed through the preflight

Each replay used the recorded base and the recorded branch tips, a scratch bare incoming repository, a scratch
`WASM_AGENT_HOME` and a scratch missions root, and the branch's own `preflight.sh`. Commits are untouched, nothing
was pushed, and no node was called.

| recorded run | recorded red | preflight replay |
| --- | --- | --- |
| land-20261120T092415Z-5b1630fa | `fast: stale_binary: ... cargo is not on PATH` (an ENVIRONMENT red: the landing ran without the toolchain) | refused at the gate in 121 s: `build_env_incomplete` - that 20/11 tree predates the gate's build-record reader (`wa_build_env_audit` does not exist in it), so a current `land` refuses it BY NAME before running a check. The original red cannot reproduce here: this machine has cargo. |
| land-20261121T102542Z-995291fa | fast: 3 failed rows (scripts/test-prompt-golden.lua, instructions, direct-workflow) | RED in 588 s, and the SAME three rows are among the 19 named (see below); tree `7c827979a3d1` = the recorded landing's tree |
| land-20261121T124854Z-e9d09664 | fast: 3 failed rows, four branches meeting | NOT replayed (time). Its class is reachable through the same script: `WA_PREFLIGHT_BRANCH=a,b,c,d` is passed straight to `wa land --branches`, which takes a comma list |

What the case-2 replay printed (`preflight.json`, and the gate log):

```
preflight RED: 19 row(s) failed for change/orchestrator-rules on main 13247bdb1c5c
  - scripts/test-prompt-golden.lua: Add a `harness evaluation` block only when a harness...
  - instructions:  check-instructions: FAIL (79 checks, 302 files, 10 deferred, 0 allowed)   failed: AGENTS.md grew
  - direct-workflow: ... Node.js v26.13.1
fast path FAILED (19 of 347 checks, 0 skipped, 324s)
retry rows: 7 row(s) failed (...); the retry asks for those and nothing else
fast: narrowed by the landing plan (gate-retry-rows.txt): 9 of 288 Lua rows
fast path FAILED (14 of 68 checks, 0 skipped, 261s)
```

Eight of the 19 rows are artifacts of the replay box, not of the branch, and they are named here so nobody reads
them as the branch's: `prompt-docs` ("no wa binary found"), `build-seed`, `cli-scripted`, `fence-card-pty`,
`nodes-probe-instances`, `pin-label`, `scratch-home` (the last four plus `fast-watchdog`, `fast-watchdog-reap`,
`fast-row-cleared` refuse with `refused(real_node_home)` because this replay's node store sits under /tmp, where
the scratch-home guard finds no writable root outside it - on the landing box the store is under $HOME and the
recorded runs did not have those rows).

### Before / after, minutes

| | recorded landing | through the preflight |
| --- | --- | --- |
| a red gate, found | gate 960 s (fast 489 s + retry 470 s); the round had already collected, merged and, on a green, would have pushed | preflight 588 s: gate 586 s (fast 324 s + retry 261 s), and NO push, NO main, NO artifacts, NO release, NO node |
| the same kind of red's second look | 470 s (the whole fast path again, 347 checks) | 261 s (68 checks: 9 of 288 Lua rows + the contract checks) - **-209 s, -44 %** |
| what the operator learns | a stop detail and a gate log | the rows by name in `preflight.json`, and the same rows handed to the worker |
| a red after this lands | landing attempt (16 min) + hand fix + landing again | preflight red (10 min, unattended) + the worker's own rounds + a landing whose gate is KEPT |

The last cell is the mechanism (7390d624 + 449447b6), measured in fixtures (test-land case 34, test-worker-gate)
and NOT yet in a real landing: I must not push, so no landing was made.

## Premises from the brief that were wrong or stale

1. **The three reds' ids have a suffix** (`land-20261120T092415Z-5b1630fa`, ...): the prefix alone names no journal.
2. **The 20/11 red was not "stale refusal_codes.lua"**: the recorded evidence is
   `fast: stale_binary: build 39bbf2b69ea3 is not this tree (df787751d697); cargo is not on PATH` - a landing run
   without the toolchain, not a tree that changed. The land.lua retry the brief points at is
   `bfad4f8f:lua/core/land.lua:1838` ("Alone, once"), not 1836.
3. **`--incoming` with a LOCAL PATH did not work** (the brief assumes it does):
   `git fetch <path> +refs/heads/*:refs/remotes/<path>/*` is refused by git, the fetch failed in silence and the
   branch read as "neither on the incoming nor a local branch". Fixed in 94fd1e69 (`tracking()`, and a failed
   fetch is `fetch_failed`), tested in test-land case 38/39.
4. **The land root is not `<WASM_AGENT_HOME>/land`**: `wa paths` prints `config = <home>/.wasm-agent`, and the
   journals live in `<config>/land` (f35a2d5f + c9015ec7). A guess here meant "the landing never started" about a
   landing that had run.
5. **The `mission` verbs ARE landed** (`lua/core/mission.lua` + `lua/core/init.lua:626`), so the verb was added.
6. **The `refused(real_node_home)` difference still exists**, but not for the landing: it now depends on where the
   NODE STORE is. A preflight/landing whose store is under $HOME passes those rows; a replay whose store is under
   /tmp refuses them (measured above). Nothing in this round changes that guard.

## What I did not do

* **No landing.** Nothing was pushed; `main` is where it was. Item 4's "a landing of a preflighted branch keeps
  the gate" is therefore measured in fixtures and by the tree-object identity above, not by a real landing.
* **The four-branch red was not replayed** (time; the reason is in the table).
* **The full fast path of this branch** is the gate of the landing; see "Checks run" below.
* `~/Work/missions/preflight.sh` and `~/Work/missions/worker-gate.sh` are symlinks to THIS mission's worktree so
  that they work today; after the landing, repoint them at the runtime tree:
  `ln -sfn ~/wasm-agent/checkout/scripts/preflight.sh ~/Work/missions/preflight.sh` (same for `worker-gate.sh`).

## A pre-existing red this branch also had to fix (5b1c1cde)

The first full `fast.sh` on this branch failed ONE of 354 checks: `scripts/test-refusal-contract.lua`,
`lua/core/refusal_codes.lua is stale`. It is not mine: the generated file at the base (bfad4f8f) carries no
`agent_control` code at all, while `lua/core/agent_control.lua` landed in b220fd53 (change/mastermind, merged by
land-20261121T124854Z) and was never regenerated - and that landing's gate ran a NARROWED row list that did not
include this row, which is how the hole opened. `lua5.4 scripts/gen-refusal-codes.lua --write` added 20 code
mappings (17 insertions, 10 deletions, from agent_control.lua plus the codes this round introduces); the row then
answers `refusal contract: 17003 checks passed`. The regeneration is its own commit so a reader can see it is not
part of the round's logic.

## Checks run (this node, one suite at a time, `flock -o` where the suite takes the lock)

* `WA_SCRIPT=scripts/test-land.lua` with `WASM_AGENT_LUA_ROOT` = this worktree: `land ok (533 checks)`.
  NOTE: without `WASM_AGENT_LUA_ROOT` the binary runs its EMBEDDED `lua/` and the suite reads green against code
  that is not under test - the first baseline of this round measured exactly that, and every run afterwards sets it.
* `bash scripts/test-preflight.sh`: `preflight ok (25 checks)`; the land-root case FAILS on the old reader
  (`<config>\nfile/land`), which is how it is known to discriminate.
* `bash scripts/test-worker-gate.sh`: `worker-gate ok (29 checks)`.
* `WASM_AGENT_LUA_ROOT` = this worktree, `bash scripts/test-mission-verb.sh`: `mission-verb ok (36 checks)`.
* `flock -o ~/Work/missions/.suite.lock bash scripts/test-discriminates.sh bfad4f8f`: `1 discriminating, 0 blocking, 0 not judged (1 environment: scripts/test-land.lua, the tool cannot run a Lua row against a base tree with no wa binary)` - the two shell rows classify as `new-symbol` ("it died on code the base does not have: no such file or directory"), which is the truth: the base has neither script. My first run of this check BLOCKED on those two rows because their refusal line did not use the words the classifier reads (2457da85).
* `bash scripts/sync-prompt-docs.sh --check`: `sync-prompt-docs: ok (4 blocks current)`.
* `flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` on this branch: `fast result ok (354 checks, 0 failed, 0 skipped)` - the gate of this branch is green as it stands

## Texts to approve

1. `wa land: <step> is not a step of this file; the steps are <list>` (a mistyped `--until`)
2. `land: stopped after <step> (--until): nothing after it ran (<steps>)`
3. `land: --until` help line: `--until <step>         stop cleanly after that step: exit 0, result stopped_at_until`
4. dry run: `until        stop after <step>: runs <steps>; does not run <steps>`
5. gate evidence, kept across runs: `<check>: kept - passed on tree <sha12> with this command in run <run> (<n> test(s), <s>s)`
6. gate evidence, retry: `retry rows: <n> row(s) failed (<rows>); the retry asks for those and nothing else`
7. gate evidence, retry not narrowable: `no Lua row failed (only contract checks did): the retry is the whole check, because this runner runs every contract check by name and none of them can be narrowed`
8. gate evidence, retry unreadable: `the failed rows could not be read (<why>): the retry is the whole check`
9. collect refusal: `fetch_failed`: `git fetch <incoming> exited <n>: <first line>`
10. `preflight: refused(no_mission): <dir> is not a directory`
11. `preflight: refused(flock_missing): flock is not on PATH, so the suite lock cannot be taken`
12. `preflight: refused(python_missing): <python> is not on PATH, so no preflight.json can be written`
13. `preflight: refused(wa_missing): <wa> is not on PATH (set WA_BIN)`
14. `preflight: refused(land_root_unknown): wa paths printed no config directory, so no journal can be found`
15. `preflight green: <branch> on main <sha12>, gate <s>s of <s>s, tree <sha12>`
16. `preflight RED: <n> row(s) failed for <branch> on main <sha12>`
17. `preflight: refused(no_verdict): <why>`
18. `worker-gate: preflight green after <n> round(s) of reds: the branch may land`
19. `worker-gate: still red after <n> round(s): the rows are in <mission>/preflight.json - the mission is NOT done`
20. `worker-gate: the preflight could not judge (exit <n>): nothing was proved either way - read <mission>/preflight.log`
21. `worker-gate: red, and no session to resume was found in <err.log>: the rows are in <mission>/preflight.json`
22. `worker-gate: round <n> of <N>: resuming session <sid> with <n> red row(s)`
23. the resume message: `[preflight] The gate of your branch (change/<name>) is RED on the current main. The landing would stop on these rows. Fix them, and do not weaken a test to do it (no assertion deleted, no row removed from a list, no timeout raised to hide a hang): <rows> ... Round <n> of <N>: work on the branch in <mission>/wt, run the failing rows yourself, and commit.`
24. `<mission>/done`: `rc=<rc> preflight=<verdict> rounds=<n> <utc>`
25. `wa mission preflight` usage line: `       wa mission preflight <name>   the gate this branch will meet, run before anybody lands it`
26. `mission.preflight` refusals: `preflight_script_missing` (`<path> is not there`, next_action `install it from the runtime tree: ln -s <tree>/scripts/preflight.sh <path>`), `preflight_no_report`, `preflight_refused`

## How Victor tests it

```
bash ~/Work/missions/preflight.sh <a finished mission>
```
prints `preflight green: ...` in minutes, or the red rows by name, and writes
`~/Work/missions/<name>/preflight.json`. Then `cat ~/Work/missions/<name>/done` on a mission launched after this
lands shows `rc=0 preflight=green rounds=<n>`; `wa mission preflight <name>` answers the same in JSON. Once a
green preflight exists, the landing of that branch on the same main reports the gate as kept and
`wa land status` shows the gate step at 0 s.

## One mistake of mine, reported

While writing patches I ran `python3 /tmp/patch1.py` believing it was mine; it belonged to the
`release-ancestry` mission and applied ITS patch again inside `~/Work/missions/release-ancestry/wt`, duplicating a
`let floor = {...}` block and one `ANCESTORS_FLOOR` line in `rust/wa-host/build.rs`. I removed exactly the
duplicated copy (the file's diff against HEAD is now the single intended patch, 26 added lines) and deleted the
stale /tmp file. The mission's own other modified files were not touched. Since then every scratch file lives in
`~/Work/missions/factory-1/scratch/`.

