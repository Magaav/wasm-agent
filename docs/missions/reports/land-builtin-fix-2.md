# land-builtin-fix-2: the health step's program, and the false main_red

Branch `change/land-builtin-fix-2`, base 8862b600. Two defects left over from land-builtin-fix
(a9d4617d): `wa land` stopped at `health` with `program_not_found` after every install, and the row that
failure wrote was then read as a red main and refused the NEXT landing at merge.

## 1. What was re-measured first (the brief's premises, each against the machine)

| premise | measured | verdict |
|---|---|---|
| the health step starts the operation with `runtime_info().binary_path` | `lua/core/land.lua:3991-4010` (M.start_operation), `impl.health` at `:4060` | true |
| the operation manager refuses a program that is not a file | `rust/wa-capabilities/src/operations.rs:1356` (`program_not_found` when an absolute program `is_file()` is false) | true |
| a replaced binary's path is not a file | a copy of this node's binary that renames a fresh file over its own path answers `/tmp/.../wa (deleted)` from `runtime_info()`; `host.operation start` with that program answers `{"error":"program_not_found"}`, and with the marker removed the same call is ACCEPTED (`op-1795395905544056-587557-1`) | true |
| a failed health STEP is read as a red main | the live ledger, `wa events --kind land --step main-health`: `2026-11-22T12:48:09Z land main-health red ... sha=c9904f6e... program_not_found`; then `2026-11-22T13:26:03Z land refused red ... main is red: main-health measured c9904f6e red at 1795351689: program_not_found`, and `land stopped ... stopped at merge` | true |

Two corrections to the brief's wording, neither changing the work: (a) the field is not in
`operations.rs`'s own vocabulary - the refusal is `program_not_found` at `operations.rs:1356`, the *source* of
the bad path is `host.runtime_info()` (`rust/wa-capabilities/src/host.rs:3596`, `std::env::current_exe()`),
which keeps Linux's ` (deleted)` marker by design (`host.rs:5788` strips it only for `binary_changed`); (b)
the ledger has exactly two `main-health` rows on this node, and the only red one is the false one, so nothing
honest was lost by teaching the reader which rows are measurements.

## 2. The fixes

**fe991294 - the health run is started with a program path that exists after the swap.** `M.start_operation`
now resolves the program through one function (`running_program`, `lua/core/land.lua:3994`): it takes
`runtime_info().binary_path`, strips a trailing ` (deleted)` - the file the install replaced is the file that
now sits AT that path, i.e. the binary the landing just installed, which is what main must be judged with -
and then applies the operation manager's own rule (`test -f`, a regular file) so the refusal can say what to
do. A path with nothing at it is refused BY NAME and never satisfied by whatever `wa` is on PATH. `impl.health`
(`:4066`) says in its own words that main was NOT measured when the run cannot start, instead of stopping with
a bare `program_not_found`.

**1077e621 - the red-main rule reads a MEASUREMENT of main.** `wa land health-run` writes
`data = { measured = "scripts/main-health.sh" }` beside its verdict (`lua/core/land.lua:4108`), and
`M.main_red` (`:2610`) reads only rows carrying that marker (`measured_verdict`, `:2598`). A landing's health
STEP writes a row with the same step name and no marker, because it answers a different question (did the step
start the measurement). Such a row is now skipped in BOTH directions: it cannot red a green main (the 22/11
refusal) and it cannot green a red one by accident - a green `started as operation ...` row no longer erases a
measured red about the same main.

The Rust host is NOT touched: `runtime_info().binary_path` keeps its `(deleted)` marker for the consumers that
want it (`host.binary_changed` is the documented way to notice a replacement), and the landing is the one
caller that must resolve it. The other consumers of `binary_path` (`lua/core/session_watch.lua:161`,
`lua/core/nodes.lua:491`, `lua/core/wave_autoflush.lua:325`, `lua/core/payload.lua:94`) were not changed and
were not measured for this defect - they are out of this brief's scope and are named here as unproven.

## 3. Tests, and where they are wired

* `scripts/test-land-health-program.lua` (new, **fe991294**) - the program, judged ACROSS PROCESSES: a copy of
  this tree's binary renames a fresh file over its own path (the swap an install makes) and then calls
  `land.start_operation` against the REAL operation manager. It asserts (i) the premise (a replaced binary's
  path carries ` (deleted)`), (ii) the operation is accepted after the swap, (iii) with nothing at the path the
  call is refused by name, naming the rule and the path. 8 checks. Wired as a **core row** in
  `scripts/lib/fast-rows.sh` (`wa_fast_core_rows`), so a narrowed run keeps it; it is also a
  `scripts/test-*.lua` candidate, i.e. in `scripts/fast.sh`'s own row list.
* `scripts/test-land-quick.lua` (**1077e621**) - case 5's rows now carry the marker; **5b** proves a failed
  health STEP does not block a landing; **5c** proves a green STEP does not un-red a measured red; **5d** proves
  `health_run` writes the marker. 166 checks, green here.

Both new rows were run against the base worktree `/tmp/base-wt-8862b600` (a separate `git worktree`, never a
stash):

* `test-land-health-program.lua` on the base: `FAILED: after the swap the operation was ACCEPTED (not
  program_not_found) (the answer was [])`.
* `test-land-quick.lua` on the base: `lua error: check failed: a health STEP that failed is not a red main:
  the landing runs (got 1, want 0)` - which is the 22/11 refusal itself.

## 4. Texts to approve (new or changed, verbatim)

1. `main's health was NOT measured: the health run was not started (<the reason>)` - the health step's detail
   when `start_operation` cannot start it (`lua/core/land.lua`, `impl.health`).
2. `the binary this process runs is not a file at <path>` - the refusal `M.start_operation` returns in place of
   the operation manager's bare `program_not_found` (`running_program`).
3. `the binary this process runs is not a file at <path> (this process's binary was replaced, and nothing is
   installed at that path)` - the same refusal when the path carried the ` (deleted)` marker.
4. `scripts/main-health.sh` - the value of the ledger row's new `data.measured` field: it names the one thing
   that measures main, and it is what makes a `main-health` row a verdict (`wa land health-run`).

## 5. How Victor tests it

`wa land change/<a finished branch>`: the steps end with "installed, verified" and a health verdict, not
`program_not_found`; the next `wa land` is not refused with `main_red` while `~/Work/missions/main-health.json`
is green.

## 6. What is still open

* The landing was not performed here (this branch is committed locally and not pushed, as the brief asks), so
  the end-to-end shape above is proven by the two rows and by the recorded defect, not by a fresh landing.
* `health_run` records a `refused` verdict when `scripts/main-health.sh` cannot judge (no jq, no result file).
  That row is a measurement attempt, so it is marked like any other and it does not block a landing - the
  pre-existing rule, kept deliberately: a main-health that could not run is not a red main.
* The four other consumers of `runtime_info().binary_path` listed in section 2 keep the raw marker; if one of
  them hands the path to a program launcher, it has the same defect. Not measured, not claimed.

