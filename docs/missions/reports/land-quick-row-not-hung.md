# land-quick-row-not-hung: the quick row, and the 120 s watchdog

**One line:** the row was not hung and nothing in the tree waited on anything - one row of 178 checks and
~3,200 `host.exec` calls costs 112 s alone at load 12.8 and 145 s when eight copies run at once, so
`scripts/fast.sh`'s 120 s per-row deadline killed it and reported "no verdict within 120s"; the fix is the
one the land row got on 22/11 - the cases were already independent fixtures, so it is five rows by subject
now, with no check dropped and no bound raised.

**Load or env, by measurement: LOAD.** The row passes in fast.sh's own row environment, alone, and only
the machine's load pushes it over the deadline. Numbers and how each was taken are below.

## What the brief had wrong (rule 9: re-measure every premise)

| the brief said | measured |
|---|---|
| "main-health **e9a42d20** (the remote-undo-works landing) ... FAIL lua scripts/test-land-quick.lua (hung)" | e9a42d20's own log (`~/.wasm-agent/main-health/fast-e9a42d203fa5.log`) has **no** land-quick failure at all. Its reds there are `test-graph-crash-recovery`, `undo-pty` and `undo-remote-pty`. The quick row's hang line is in `fast-da912828082d.log`. |
| "since the remote-undo-works landing" | The same hang is in **four** main-health logs on **four** trees: `fast-22808bc81598.log`, `fast-899fdd47caee.log`, `fast-70205155fe34.log`, `fast-da912828082d.log`. Three of those trees are older than e9a42d20, so no landing introduced it. |
| "the row is green at 3665b1b7, hung at e9a42d20 - thus the landing" | The commit is not the variable; the machine's load is. The row's cost did not change at e9a42d20 (that diff touches `lua/core/{chat,commands,memory,server,remote_files,undo_command}.lua` and `scripts/fast.sh`'s check tail; `git show e9a42d20 -- scripts/test-land-quick.lua scripts/lib/land-row.lua lua/core/land.lua lua/core/event_ledger.lua` is empty). |
| "with WA_FAST_BIN=~/.local/bin/wa and a scratch HOME it fails fast: '<scratch>/h/.local/bin/wa: No such file or directory'" | Not reproduced. With an **absolute** `WA_FAST_BIN=/home/victor/.local/bin/wa` case 9's child runs and answers (the row is green). The scratch-home failure in the brief needed `HOME` set as well, which `scripts/fast.sh` does not do (it leaves `HOME` and overrides `WASM_AGENT_HOME`) - a run that sets `HOME` is refused by `scripts/lib/scratch-home.lua`, which is the guard doing its job, not this defect. |

## The wait that never ends: measured, and it is not a wait on anything in the code

- **Alone, in fast.sh's row environment, the row passes.** Measured with the shape `scripts/lib/fast-row-exec.sh`
  builds (`HOME` untouched, `WASM_AGENT_HOME` = the row's scratch root, `WA_COMPONENTS_DIR` inside it,
  `WA_FAST_BIN` the binary, `WASM_AGENT_LUA_ROOT` this tree, no rendezvous/relay, `--db <scratch>/t.db`):
  exit 0, `landing ok (178 checks)`.
- **Alone under the machine's normal load it is already at the edge:** 112 s at load 12.83 (same shape, exit 0).
  The deadline is 120 s.
- **Under the concurrency a fast-path run has, it is over it:** eight copies at once (load ≈ 15), traced, all
  eight green - at **145 s each**. `scripts/fast.sh` runs eight rows at a time, so this is the shape of the real
  run, and 145 s > 120 s is exactly "produced no verdict within 120s ... killed the group".
- **The tree's own binary makes no difference:** `scripts/test-land-quick-install.lua` (the part that spawns
  `WA_FAST_BIN` as its own process) run with `WA_FAST_BIN` = this tree's release build
  (`/home/victor/wasm-agent/target/m-land-quick-row-not-hung/release/wa`) is green in 31 s. So neither the
  binary nor the environment is the cause; what is left is the machine's load.
- **A live sample of the row while it is slow:** the node process in state `D`, `wchan = btrfs_sync_log`, with
  `journal/quick8/evidence/.merge.log.wa-tmp-...` open - an `fsync` waiting for a Btrfs log commit, with **no
  child process at all**. It left that state and finished. The "1 process(es)" the watchdog prints says nothing
  either way: `host.exec` starts every command as the leader of its **own** process group
  (`scripts/lib/land-row.lua`, the `setsid -w` note), so a row waiting on a child still counts as one.
- **The cost is the row's own work:** one traced run = 3,165 `host.exec` calls (2,604 of them `git` against the
  fixture repositories - a landing is real git) and 1,522 ledger SQL calls. Nothing in it blocks; it forks.

## The fix (commit 0e620a1b)

The same remedy `scripts/lib/land-row.lua` records for 22/11 ("the cases were already independent fixtures, so
they are ten rows by subject now ... no check was dropped and no watchdog was raised"), applied to the quick
row: five rows by subject, sharing one harness.

| row | what it proves | alone (load ≈ 3.7) | checks |
|---|---|---|---|
| `scripts/test-land-quick.lua` | the landing itself, the line the operator reads, the brief | 15 s | 81 |
| `scripts/test-land-quick-tests.lua` | the branch's own tests decide; a docs-only branch does not deploy | 13 s | 34 |
| `scripts/test-land-quick-components.lua` | the components a row names, handed over whole | 15 s | 12 |
| `scripts/test-land-quick-main.lua` | a red main blocks the next landing; a health ROW is not a verdict | 12 s | 26 |
| `scripts/test-land-quick-install.lua` | the install record, `--gate`, another process, the resume | 23 s | 25 |
| | | | **178** |

The one row was 178 checks; the five parts are 178 checks, measured, so nothing was dropped, and no watchdog
bound was touched. The same holds assertion by assertion - counted over `git show 3bbf9220:scripts/test-land-quick.lua`
against the five files: `ok(` 26 = 26, `eq(` 68 = 68, `contains(` 48 = 48, and `must(` 27 = 12 in the parts + 15
in the shared harness, which is where the fixture's own commands now live. The shared harness is
`scripts/lib/land-quick.lua` (commit 0e620a1b): the fixture, the scripted sentinel/health/fast-path routes, the
print capture and the scratch-home `arm()` that every part calls before it writes a ledger row.

**Wired where (rule 3):** all five are never-dropped core rows in `scripts/lib/fast-rows.sh`
(`wa_fast_core_rows`, commit 0e620a1b) - a narrowed run cannot drop one - and `scripts/test-fast-rows.sh`
judges the whole list against the tree, now counting a row that dofiles `scripts/lib/land-quick.lua` as a land
row (same commit): `fast-rows ok (37 checks)`.

**Refactor-only:** this branch changes no product code. The row was split by subject; every assertion moved
verbatim (the case blocks were cut by line range out of the previous file, not retyped), and the check counts
prove the set is the same. There is nothing for `scripts/test-discriminates.sh` to discriminate: no test's
verdict changed.

## The proof, through the mechanism that reported the hang

The five parts run through `scripts/fast.sh`'s OWN row runner - `scripts/lib/fast-row-exec.sh` builds each
row's environment and `scripts/lib/fast-watchdog.sh` owns its process group and its 120 s deadline - with
`FAST_BIN` = this tree's release build, five at once, at load 5.77:

    scripts/test-land-quick-components.lua     exit=0 seconds=13 | landing ok (12 checks)
    scripts/test-land-quick.lua                exit=0 seconds=13 | landing ok (81 checks)
    scripts/test-land-quick-main.lua           exit=0 seconds=23 | landing ok (26 checks)
    scripts/test-land-quick-tests.lua          exit=0 seconds=28 | landing ok (34 checks)
    scripts/test-land-quick-install.lua        exit=0 seconds=35 | landing ok (25 checks)

Worst part 35 s, 0.29 of the deadline; the one row it replaces was 145 s under the same kind of load, 1.21 of
it. Every part's "1 process(es)" would now be a row finished long before the watchdog looked.

## Not done, not claimed

- I did not run the whole fast path or `scripts/main-health.sh` here, and the narrowed fast-path run I queued
  did not execute either: `flock -o ~/Work/missions/.suite.lock` (rule 15) had six suites in front of it and the
  holder was still running after 36 minutes, so I cancelled it rather than leave it queued. What ran instead is
  the same machinery one level down - `scripts/lib/fast-row-exec.sh`'s `lua_run` and
  `scripts/lib/fast-watchdog.sh`'s 120 s deadline, five rows at once, the tree's binary (section above). The
  end-to-end verdict (`scripts/main-health.sh` green) is Victor's to take on the landed commit.
- The sibling finding (`undo-pty` and `undo-remote-pty` each failing one check in fast.sh since e9a42d20) is
  not investigated here: those rows belong to the remote-undo-works mission. The measurements above give one
  hint only - both are pty rows that drive the real binary, and this machine's rows are much slower per
  subprocess under load than their alone-times suggest - and that is a hypothesis, not a finding.
- Whether a 20 s row can still be pushed past 120 s by a machine at load 30 is not measured; what is measured
  is that this row's cost is now ≤ 23 s alone (0.19 of the deadline) instead of 112-145 s (0.93-1.2 of it).

## Texts to approve

None. No new string reaches the operator or the model: the parts' headers are comments, and each part still
ends with the line the runner reads, `landing ok (<n> checks)` - unchanged.

## How Victor tests it

`scripts/main-health.sh` on this commit: the five `test-land-quick*` rows green, and no row in the run
reported as hung.
