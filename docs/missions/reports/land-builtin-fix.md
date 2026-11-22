# land-builtin-fix: `wa land` judged a branch by main's changes, not its own

Mission: land-builtin-fix (branch `change/land-builtin-fix`, base c9904f6e).
Measured, fixed and verified on avell (this node), 22/11.

## The defect, re-measured

`M.changed_paths` (lua/core/land.lua) asked for `git diff --name-only --no-renames <run.journal.base> <branch tip>`.
`journal.base` is **main's tip** (lua/core/land.lua, `collect`: `incoming_main`/`origin_main`, "the FURTHEST MAIN
both sides agree on"), so the list it built was "how do main and the branch differ" - every commit main gained
after the branch was cut, reported as if the branch had made it. Four readers narrowed work on that list:
the plan's path (`impl.plan`), the gate's rows file (`gate rows`), the landing's own tests (`impl.tests`) and
whether main's health could have moved (`impl.health`). The measured consequence is the one in the brief:
run land-20261122T113743Z-f3fedc13 measured a docs/lua/scripts branch as "the branch changes Rust (3 file(s))",
so the branch's own three test files were never run before its push.

Measured again on this node, same repository, same binary (`~/.local/bin/wa`), only the Lua tree different
(`WASM_AGENT_LUA_ROOT`), `--dry-run` (writes nothing, fetches nothing):

| branch | old code (installed tree c9904f6e) | this tree |
|---|---|---|
| change/harness-fixes-2 (own change: 1 docs file) | `plan: 374 path(s) changed -> compiled` | `plan: 1 path(s) changed -> docs-only` |
| change/race-fabric-transport-W (own change: 6 paths, 1 scripts/test-*.lua) | `plan: 509 path(s) changed -> compiled` | `plan: 6 path(s) changed -> lua-scripts-only` + `tests run  the branch's own 1 row(s), each alone with its own home and ledger: scripts/test-remote-refusals.lua` |

## What changed

1. **The range is the fork point** (b3c8d7e8, lua/core/land.lua `M.fork_point` + `M.changed_paths`):
   `git merge-base <base> <tip>` then `git diff --name-only --no-renames <fork> <tip>`. A merge of main into the
   branch moves main by exactly that delta, so this is "what this landing changes about main". A merge-base that
   fails (unrelated histories) is a NOTE, never an empty answer - and every caller that narrows on the list
   already treats a note as "run everything".
2. **The tests step cannot pass on an unreadable diff** (b3c8d7e8, `impl.tests`): with notes it now says
   `"<note> - so the branch's own tests were NOT run here"` instead of "the branch changed no scripts/test-*.lua
   of its own". Unknown is not yes.
3. **The plan names the branch's own rows before the push** (a30f29a3, `M.build_plan`): the `tests` row of a
   printed plan now carries the branch's own `scripts/test-*.lua`, or the Rust skip with its count, or the reason
   there is nothing to run - computed from the same path list the step uses, so plan and round cannot disagree.
4. **The mission's own brief is the fallback for "You can now test"** (b3c8d7e8, `M.how_to_test` +
   `M.missions_root`): when no `wa land ready --brief` was recorded, `~/Work/missions/<branch-name>/brief.md`
   is read (its `## How Victor tests it` section, verbatim) and quoted; a missing file, a missing section or a
   branch name that cannot be a directory keeps today's "no brief was recorded" text. The missions root is read
   the way `wa mission` reads it (MISSION_ROOT, then MISSIONS_DIR, then ~/Work/missions - mission.lua `M.root`).
5. **A refusal says what it now means** (b827fbba, `impl.plan`): `plan_no_changes`'s `next` now names the
   fork-point range a reader should check and says a branch main already contains has nothing to land.

### A behaviour change this makes visible

A branch **main already contains** (or main's own tip) used to look like a change: the diff reported the branch's
own files as deletions. With the fork point it has no paths, so `wa land <that branch>` now refuses with
`plan_no_changes` instead of merging an empty merge commit. scripts/test-land-plan.lua relied on the old shape
(cases 3-5c reused `change/one`, which case 2 had landed and `advance_main` pushed), so those cases now land a
branch of their own (`change/gate-round`, b827fbba). Every assertion those cases make is unchanged.

## Tests, and where they are wired

- `scripts/test-land-quick.lua` (a fast-path row, listed by `scripts/lib/fast-rows.sh:58`) gains two cases:
  - the fork-point case (`quick3n`): main gains `rust/wa-new/src/main.rs` AFTER the branch's base; the branch
    changes `lua/core/own-lua.lua` + `scripts/test-own-lua-new.lua`; the plan counts 2 paths, its `tests` row
    names that one row, the step runs it and is "1 green", and nothing says "changes Rust".
  - the mission-brief case (`quick2m`): no ready brief, `<scratch HOME>/Work/missions/own-brief/brief.md`
    exists; the landing's last line quotes its `## How Victor tests it` and not the text past the next heading.
- `scripts/test-land-plan.lua`: the gate cases' own branch (b827fbba).
- Discrimination, by the gate's own script (`scripts/test-discriminates.sh c9904f6e --repo <tree>`, base c9904f6e,
  base binary `~/.local/bin/wa` c9904f6e): `discriminates  scripts/test-land-quick.lua  check failed: the plan
  counts the branch's own two paths, not main's Rust (got 3) (got 3, want 2)`; `unchanged-verdict
  scripts/test-land-plan.lua` (a fixture repair that still passes - named here, not a pass).

Measured on this node against the REAL mission directory, through the real path (a Lua row run by
`~/.local/bin/wa` with only `WASM_AGENT_LUA_ROOT` pointed at this tree): `land.missions_root()` is
`/home/victor/Work/missions` and `land.how_to_test({branches={{name="change/land-builtin-fix"}}})` answers
`/home/victor/Work/missions/land-builtin-fix/brief.md` with this mission's own `## How Victor tests it` text
("After it is installed: `wa land change/<some lua-only branch> --dry-run` ..."). The root follows `HOME` as the
node sees it, which is what `wa mission` reads (a run with `WASM_AGENT_HOME` set has the node rewrite HOME, and
the root follows it - the same rule, not a second one).

Rows run green on this node after the change: test-land-quick (155 checks), test-land-plan (105), test-land-rows
(137), test-land-review (47), test-land-release (68), test-land-until (81), test-land-resume (42),
test-land-resume-19-11 (20), test-land-marks (27), test-land-sign (46), test-land-gate-rows (82),
test-land-gate-log (8), test-fast-rows.sh (37), test-preflight.sh (38).

## What I did NOT do, and what is still unknown

- **The health verdict that never arrived, and `program_not_found`** (the brief's two "Also" items) are NOT
  fixed here. Measured on this node from the failed run's own records:
  `~/.wasm-agent/land/land-20261122T124317Z-cd6de275/journal.json` has `steps.health = {state:"failed",
  error:"main_health_not_started", observed:"program_not_found"}` and `evidence/health.log` holds only the args
  line: the refusal came from the operation manager, not from main-health (rust/wa-capabilities/src/operations.rs
  refuses a `program` that is not a file), i.e. the `runtime_info().binary_path` the running landing reported
  (`M.start_operation`, lua/core/land.lua) no longer existed after the install that preceded it. Fixing that
  needs a decision about which binary may replace a replaced one, and a landing on this node to prove it - which a
  mission is not allowed to perform. The silence after the 11:38 operation has the same root (the operation's
  owner died with serve) and no verdict event.
- No `health`/`install` behaviour was touched, so a landing still starts main-health as an operation after the
  install.
- The reviewer (`wa eval reviewer`) already diffs from its own merge base
  (lua/core/harness_evaluator_reviewer.lua, "every diff was base..tip - 92 files of other people's landed work"),
  so it needed nothing; that is measured, not changed.

## Texts to approve (new or changed, verbatim)

1. tests step, unreadable diff (new): `<notes> - so the branch's own tests were NOT run here`
2. plan `tests` row, own rows (new): `the branch's own <N> row(s), each alone with its own home and ledger: <paths>`
3. plan `tests` row, Rust (reworded, the step's own reason): `the branch changes Rust (<N> file(s)): its tests need the new binary, so main-health judges them after the install`
4. plan `tests` row, unreadable diff (new): `the paths this round changes could not be read (above), so the merged tree decides which of the branch's own rows run`
5. plan `tests` row, nothing of its own (existing text, now also printed in the plan): `the branch added or changed no scripts/test-*.lua of its own: nothing of its own to run`
6. `plan_no_changes` `next` (changed): `nothing to land: a branch has no change of its own (main already contains it, or the branch is main's tip) - check it with \`git -C <repo> log --oneline $(git merge-base main <branch>)..<branch>\``
7. changed-paths note (changed wording): `the changed paths of <branch> could not be read (git merge-base <base> <tip>: <reason>), so the paths this round changes are unknown`
8. "You can now test" (text unchanged, new source): the mission's `## How Victor tests it`, when no ready brief was recorded.
