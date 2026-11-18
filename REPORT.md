# land-gate-fix - `wa land`'s gate names rows `fast.sh` cannot run

Branch `change/land-gate-fix` in this worktree (`/home/victor/Work/missions/land-gate-fix/wt`), based on
`change/land-r1` (`4145b7f7`). Built and tested HERE (avell, x86_64, 16 cores). Committed locally; **never
pushed**.

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
