# land-gate-fix - `wa land`'s gate: the rows `fast.sh` can run, proved in the tree it runs in

Branch `change/land-gate-fix` in this worktree (`/home/victor/Work/missions/land-gate-fix/wt`), based on
`change/land-r1` (`4145b7f7`); round 2 starts on this branch's own head `17da9ef0`. Built and tested HERE
(avell, x86_64, 16 cores). Committed locally; **never pushed**.

Two rounds, one mission. **Round 1** (sections 1-5) made the plan request only rows the runner accepts.
**Round 2** (sections 6-11) proves that list in the merged tree the gate actually runs in - so a branch's own new
test runs and an exclude the branch adds cannot re-create `fast_narrow:unknown_row` - and stops an inherited
`WA_FAST_ROWS` from narrowing a `--full` run.

## 1. The failure, as it was measured

Two landings of the same round (`land-20261118T172243Z-666a59cf`, `land-20261118T173351Z-2a481142`) stopped at
`gate` with `fast failed twice (exit 2, then 2 alone)` and **0 tests run**. The plan wrote 154 rows into
`gate-rows.txt`; `scripts/fast.sh` refused the list:

    fast_narrow:unknown_row: scripts/test-agent-benchmark-runtime-route.lua is not a row this run can execute
    (not a scripts/test-*.lua, or listed in scripts/fast-path.exclude)

The row exists, but `scripts/fast-path.exclude` declares it not run (its own line carries the reason). There
were **two runnable-worlds**: `scripts/fast.sh` built `lua.list` from the glob minus `fast-path.exclude`
(`scripts/fast.sh` 307-321), while `wa land`'s planner (`lua/core/land.lua`, `M.gate_rows`) listed every
`scripts/test-*.lua` it could name and never consulted the exclude list. A plan that names a row the runner
cannot execute is not a warning: the filter refuses the whole request, nothing runs, and the gate reads 0 tests.

## 2. What changed

| file | change |
| --- | --- |
| `scripts/lib/fast-rows.sh` | new `wa_fast_row_candidates` (the rows this tree's fast path would run: the glob minus `fast-path.exclude`, the same `sed` pattern the runner used inline) and `wa_fast_row_skips` (the complement, `row<TAB>why`, reasons taken from the same file). The ONE inventory. |
| `scripts/fast.sh` | `lua.list` is now `wa_fast_row_candidates > "$work/lua.list"` instead of a second copy of the same loop; the narrowing block no longer re-sources the lib; the `... excluded: scripts/fast-path.exclude` line of the summary counts `wa_fast_row_skips`, because its inline `$excluded` variable is gone. |
| `lua/core/land.lua` | new `M.row_inventory(repo)` (runs `wa_fast_row_candidates` / `wa_fast_row_skips` in the planned tree; a `why` when the lib cannot be read at all). `M.gate_rows` now requests only rows the inventory lists and returns `rows, not_rows, why`: an affected row that is declared not run comes back in `not_rows` with its reason, is never requested, and `M.plan_text` prints it as `not a gate row: <path> (<reason>)`. The naming scan reads candidates AND declared rows, so a row found by name is reported rather than silently dropped. `build_plan` reports `full` when a non-doc round has no provable row or no readable inventory (the answer a missing classifier already gets). New `M.gate_rows_file(run, options)` is the single place the `WA_FAST_ROWS` file is written, and `--full` gets none; `M.gate_checks` treats `--full` as every check. |
| `scripts/test-core-parity.sh` | its own copy of the `sed` row list is now `wa_fast_row_candidates`, so the A2.4 harness and the fast path cannot disagree about which rows exist (the same 227 rows). |
| `scripts/test-fast-rows.sh` | +12 checks: the inventory lists rows the run executes, does not list a declared row (though the file exists), names its reason; the two lists partition the tree; a request naming a declared row is refused `unknown_row`; `fast.sh` and `land.lua` both read the one function, and no second copy of the `sed` rule survives under `scripts/`. 18 -> **30 checks**. |
| `scripts/test-land.lua` | +23 checks: a fixture carrying the REAL `scripts/lib/fast-rows.sh` and a `fast-path.exclude`; a plan over a change touching a declared-not-run test requests nothing and reports the reasons; the produced list is fed to the **real** `wa_fast_row_filter` and accepted, while the list including the declared row is refused `fast_narrow:unknown_row`; `--full` writes no rows file, writes none for a full/no-row plan, and runs every check. 243 -> **266 checks**. |
| `docs/LAND.md`, `skills/fast-path/SKILL.md` | the gate/narrowing paragraphs now state the one inventory, the `not a gate row:` report and what `--full` means. |

9 tracked files (7 code and docs, plus this report in two places). `lua/core/land.lua` syntax:
`lua5.4 -e 'loadfile(...)'` OK (`luac` on this box is 5.5 and rejects the pre-existing
`for path in ...gmatch` assignment in `M.changed_paths` - not this change).

## 3. The land-r1 case, reproduced through the planner

The failed round's own base and tip are in this repo, so the paths are the real ones:

    git diff --name-only --no-renames 74d4843190c4 4145b7f757a5   # 90 paths

Driven through the planner with this tree's Lua (`WASM_AGENT_LUA_ROOT=$PWD WA_SCRIPT=<script> wa --db ...`,
calling `land.row_inventory`, `land.gate_rows`, `land.build_plan`, `land.plan_text`, `land.gate_rows_file`):

- inventory: **227 candidate rows, 56 declared not run**, unreadable: no;
- plan over the 90 paths: **120 rows requested, 33 reported** as `not a gate row: ...` with the ledger's reason,
  including `scripts/test-agent-benchmark-runtime-route.lua`, the row that failed both landings;
- `scripts/fast.sh`'s own filter over the produced file (121 rows = the 120 requested plus the core rows):

      . scripts/lib/fast-rows.sh; wa_fast_row_candidates > /tmp/lua.list    # 227 rows
      wa_fast_row_filter /tmp/lua.list <run>/gate-rows.txt                  # exit 0

- the list the two failed landings used (kept in `~/.wasm-agent/land/land-20261118T173351Z-2a481142/gate-rows.txt`,
  154 rows) is still refused by the same filter, naming the same row: **exit 2, `fast_narrow:unknown_row`**. The
  difference between the two plans is a verdict, not a format;
- `--full` on the same plan: `land.gate_rows_file(run, {full=true})` -> `nil`, no `gate-rows.txt` on disk;
  `land.gate_checks(..., {full=true})` -> all 5 default checks (`every check (--full)`).

Two notes from the reproduction, neither caused by this change: the round is **90** paths (the mission says
88 - the run's own plan says 90), and the failed plan also carried `scripts/test-mcp-share.lua`, which does
not exist in this tree: the planner reads the landing repo while `fast.sh` runs in the merged worktree, and
that difference alone would have been a second `unknown_row`.

## 4. What was run, and against what

Both rows were run the way `scripts/fast.sh` runs them (own scratch home, vault/node identity variables
cleared, `WASM_AGENT_LUA_ROOT` = this worktree):

| row | base `4145b7f7` | this branch |
| --- | --- | --- |
| `scripts/test-fast-rows.sh` (`bash`) | `fast-rows ok (18 checks)` | `fast-rows ok (30 checks)` |
| `scripts/test-land.lua` | `land ok (243 checks)` | `land ok (266 checks)` |
| `scripts/sync-prompt-docs.sh --check` | - | `ok (4 blocks current)` |

**No pre-existing failure was observed** in either row at the base: both were green before the change, so
every added check is the new behaviour and nothing is masked. The land row was run against the installed `wa`
on PATH (a 0.1.0 binary) with the tree's Lua - not against a `cargo build --release` of this tree, so "the row
is green with the tree's own binary" is **not** claimed here. `bash scripts/fast.sh` as a whole was **not**
run (it builds the tree binary and every component); the narrowed filter it applies to a plan was run directly
on the real candidate list, which is the step that failed.

## 5. What is not done / open

- not pushed, not landed, no deploy - per the mission;
- `scripts/fast.sh` full run not executed (see above); the two touched rows and the doc check were;
- the gate's `fast` row itself was not run through a real `wa land` round: the end-to-end proof here is the
  planner -> rows file -> real filter chain on the exact failed paths, plus the fixture cases in `test-land.lua`.

---

# Round 2: the merged tree, and `WA_FAST_ROWS` from the environment

Round 2 starts on this branch's own head `17da9ef0` (round 1 above is the history of the same branch). It closes
the two holes the review of `17da9ef0` named: the rows file is now proved **in the tree the gate runs**, and the
fast check can no longer be narrowed by an inherited environment variable.

## 6. Defect 1: the plan is proved in the operator's checkout, the run happens in the merged tree

Round 1 made the plan request only rows `scripts/fast.sh` accepts - but it asked **the wrong tree**. In the
pre-round file, `M.row_inventory` ran `wa_fast_row_candidates` with `cwd = journal.repo` (land.lua:766) and the
naming scan's `grep -rlF <module> scripts/test-*.lua` ran there too (land.lua:827). `journal.repo` is the
operator's checkout, which does not contain the round at all. The runner runs somewhere else: `impl.gate` gives
the `fast` check `cwd = run.tree`, the worktree `impl.merge` cuts from the base and merges the branches into
(land.lua:1446). The two trees differ by exactly what the round is landing, and the difference broke the gate in
both directions:

- **A row the branch adds is silently dropped.** A branch that adds `scripts/test-new.lua` has no such row in the
  planner's checkout, so `M.gate_rows` reported it "not a gate row" - and on a round that narrowed *anything
  else* (`plan.full` is false) the branch's own new test was never requested, never ran, and nothing said so
  beyond a plan line that read like a refusal.
- **A row the branch removes is requested anyway.** A branch that adds a `scripts/fast-path.exclude` line (or
  deletes a test) leaves the plan asking for a row the merged tree's runner can no longer execute:
  `wa_fast_row_filter` refuses the whole request - `fast_narrow:unknown_row` - and the round is gated on zero
  tests, which is the failure round 1 was meant to have removed.

## 7. Defect 2: an inherited `WA_FAST_ROWS` narrows a `--full` run

Pre-round `impl.gate` (land.lua:1443-1445) prefixed `WA_FAST_ROWS=<file>` only when the round had written a rows
file. `--full` writes none by design, so the fast check inherited whatever `WA_FAST_ROWS` the landing itself was
started with, and `scripts/fast.sh` narrows on a NON-EMPTY value (`[ -n "${WA_FAST_ROWS:-}" ]`). A `--full` run
could therefore execute a narrowed set, obeying a plan that was not its own, while its report said "the whole
suite".

## 8. What changed

| file | change |
| --- | --- |
| `lua/core/land.lua` | `M.gate_rows_file(run, options)` now returns `path, failed, notes` and proves the list in `run.tree`: it reads `wa_fast_row_candidates` there, keeps the plan's rows **and** every changed `scripts/test-*.lua` that tree has as a row, and drops what the tree's `scripts/fast-path.exclude` keeps out. Every drop is named in `notes` ("not asking for <path> (the plan asked for it|this round changes it): <reason>"); a round with no row left, or no merged tree at all, writes no file and runs the whole suite. New `M.gate_command(check, rows_file)` gives the `fast` check its `WA_FAST_ROWS` **always** - the file, or an empty value - and leaves every other check untouched. `impl.gate` logs the notes and the exact command it runs (the evidence used to print the check's command *without* its `WA_FAST_ROWS` prefix). |
| `scripts/test-land.lua` | 18c-3 reworked onto a real merged tree; new **18c-4** (both scenarios, against worktrees built the way `impl.merge` builds them - a worktree of the base with the branch merged in - and fed to the **real** `wa_fast_row_filter`); new **18c-5** (`WA_FAST_ROWS` always set, proved through `env` and through `impl.gate`'s own command). 266 -> **294** checks. |
| `docs/LAND.md`, `skills/fast-path/SKILL.md` | the merged-tree rule, the by-name drop and the always-set `WA_FAST_ROWS`. |

What the gate now writes in its own evidence (measured, from 18c-4's fixture run):

    gate rows: 2 row(s) of the merged tree: scripts/test-agent-live.lua scripts/test-new-agent-row.lua
    $ [fast] WA_FAST_ROWS='<run>/gate-rows.txt' bash scripts/fast.sh
    ...
    $ [fast] WA_FAST_ROWS= bash scripts/fast.sh

and, for the excluded row (18c-4, second scenario):

    gate rows: not asking for scripts/test-agent-live.lua (the plan asked for it): this round excludes it
    gate rows: no row the merged tree can run is left (1 dropped); the whole suite runs

## 9. The two scenarios, as they were run

The fixture carries the REAL `scripts/lib/fast-rows.sh` and a real `scripts/fast-path.exclude`; the merged trees
are real git worktrees. Three proofs, all in `scripts/test-land.lua`:

1. **The branch adds a row.** `change/newrow` adds `scripts/test-new-agent-row.lua`; the planner's checkout is
   left at the base without it. `M.gate_rows` in that checkout maps the changed module to
   `scripts/test-agent-live.lua` and reports the new row as "not a gate row" - the defect, reproduced.
   `M.gate_rows_file` on the merged tree writes **both** rows, and the merged tree's own
   `wa_fast_row_filter` accepts the file (exit 0) and lists the new row as one it would run.
2. **The branch adds an exclude.** The merged tree excludes `scripts/test-agent-live.lua`. With a second
   requested row still runnable, the file holds only that one and the evidence names the dropped row with the
   ledger's own reason; with the excluded row as the only request, no file is written at all ("the whole suite
   runs"). The pre-merge request that would have named it is fed to the same real filter and **refused** (exit 2,
   `fast_narrow:unknown_row`), so the case proves the failure it prevents.
3. **`WA_FAST_ROWS` is never absent.** `M.gate_command` answers `WA_FAST_ROWS= bash scripts/fast.sh` with no
   rows file and `WA_FAST_ROWS='<file>' ...` with one, and leaves other checks alone; run through `env` with an
   inherited `WA_FAST_ROWS`, the empty assignment removes it while a command that does not set it still sees the
   inherited value. At the gate itself (`impl.gate`, real rows file, checks stubbed), the fast check's command is
   `WA_FAST_ROWS='<run>/gate-rows.txt' bash scripts/fast.sh` when narrowed and `WA_FAST_ROWS= bash scripts/fast.sh`
   for `--full`, and the evidence logs that same command.

## 10. What was run, and against what

Both rows ran the way `scripts/fast.sh` runs a row: own scratch `HOME`/`WASM_AGENT_HOME`, the node's credential
lane and identity variables removed, `WA_FAST_ROWS` cleared, `WASM_AGENT_LUA_ROOT` = this worktree - never the
live `~/.wasm-agent`.

| row | head `17da9ef0` | this change |
| --- | --- | --- |
| `scripts/test-land.lua` | `land ok (266 checks)` | `land ok (294 checks)` |
| `scripts/test-fast-rows.sh` | `fast-rows ok (30 checks)` | `fast-rows ok (30 checks)` (untouched) |
| `scripts/sync-prompt-docs.sh --check` | - | `ok (4 blocks current)` |

**The new checks are not vacuous.** With the pre-round `lua/core/land.lua` restored byte for byte
(`b789d616…`, the file at `17da9ef0`) and the same new `scripts/test-land.lua`, the row fails at the first
scenario-1 assertion:

    lua error: check failed: AND the row the branch added, which the planner's checkout cannot see
    (looked for scripts/test-new-agent-row.lua in scripts/test-agent-live.lua)

and the file was then restored (sha `2606985e…`, unchanged afterwards).

**One unexplained observation, named as such:** of 24 runs of `scripts/test-fast-rows.sh` during this round, ONE
(the first) failed at its check 37, "test-land.lua is not in the narrowed run", while printing a list that
contains `scripts/test-land.lua`; the other 23 passed (`fast-rows ok (30 checks)`), and a 200-iteration replay
of that exact `printf | grep -qx` pipeline under `pipefail` produced no failure. Neither that script nor
`scripts/lib/fast-rows.sh` is touched by this change (the row reads `lua/core/land.lua` only to look for
`wa_fast_row_candidates`, which is still there). I did not establish the cause, so it is recorded as an observed
flake, not as a pass.

## 11. What is not done / open

- not pushed, not landed, no deploy - per the mission;
- `bash scripts/fast.sh` as a whole was **not** run (it builds the tree binary and every component); the rows it
  would narrow to were run directly through its own filter, which is the step that failed in the two measured
  landings;
- no real `wa land` round with a narrowed plan was run end to end: the pipeline cases in `test-land.lua` pass
  `--checks`, so the narrowing path is proved by the merged-tree fixtures above plus `impl.gate`'s own recorded
  command, not by a live gate over a real Lua change;
- the row was run against the installed `wa` (0.1.0) with this tree's Lua, not against a release build of this
  tree;
- `luac` on this box is 5.5 and rejects a pre-existing construct in `M.changed_paths`; syntax was checked with
  `lua5.4 -e 'loadfile(...)'` for both touched Lua files.
