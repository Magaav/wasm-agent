# factory-3 - main stays green, and nothing waits for a model to notice

Change `change/factory-3`, base `93168d96` (main at the start of the round), commits `6a0ea96a`, `6c6c1dda`,
`52296945`, `6968c18e`, `2abe68f2`. Nothing pushed.

## The premise, re-measured before any code (rule 9)

- **"MAIN IS RED RIGHT NOW" was already false when I started.** `main` was `a8c4cca8` and
  `lua5.4 scripts/gen-refusal-codes.lua --check` exited 0 there (and 0 on my base `93168d96`). Someone landed
the "do first" fix before this round; the ROOT CAUSE was untouched, and that is what this round fixes.
- The numbers in the brief were close but not exact: the gate lines I could still read say **146 of 296**,
  **168 of 282**, **79 of 295** and **22 of 296** Lua rows (the brief had "121 of 294"; the tree now has 296
  Lua rows). The property it describes - a narrowed run that never selects a whole-tree row - is real.
- land245's "855 s, twice, 40+ minutes stopped" could not be re-measured: the land store keeps only the runs
  from `land-20261121T174240Z` onward, so land243-245's journals are gone. I did not restate them as fact from
  memory; they appear here only as the brief's account.
- **One premise was incomplete, and it changed the design.** The brief says "two branches from one base, each
  adding one refusal code in a different module, each green alone" make a STALE file. Measured on a real
  replay: if each branch regenerates its own inventory (which is what a worker does before committing), the
  merge of the second **conflicts** in `lua/core/refusal_codes.lua` - a file no person wrote. So the fix has to
  cover both failure modes, and a registry that names only a command could not: it needs the OUTPUT paths too.

## 1. The merge regenerates (commit `6a0ea96a`)

- `scripts/generators.txt`: one line per derived file, `<output>[,<output>...] = <command>`, with the rules for
  adding a line and with the exclusions **and their reasons**: the balloon/prompt goldens (a golden is an
  APPROVAL, not a function of the tree) and `scripts/sync-prompt-docs.sh --write` (it runs the generator inside
  an installed `wa`, so what it writes depends on which binary is installed - in a merged worktree that is the
  operator's older binary). Today the registry has one entry: `lua/core/refusal_codes.lua`.
- `scripts/regenerate.sh`: runs every registered generator on a tree, prints `regenerate: changed <path>` and
  `regenerate: changed_count <n>` (machine-readable, because "did the merge need amending" is a question about
  bytes), names a failing generator (`regenerate: FAILED <cmd> (exit N)`) and still runs the others, refuses a
  tree that is not a git worktree (exit 2: without git there is no way to tell what was written), reports a
  missing registry as "this tree declares no derived file" rather than as clean, refuses a registry line whose
  declared output does not exist after the run, reports only files THIS run changed (a before/after git
  snapshot, so a hand run's own dirty files are not misreported), and never runs a writer git command.
- `lua/core/land.lua`: `M.regenerate` (merge step) runs it on the MERGED tree, stages what it wrote and amends
  the **merge commit**, so main's tip is fresh without a second commit. `M.regenerate_outputs` and the local
  `merge_generated_conflict` resolve a merge conflict that is ONLY in paths the registry declares as generated
  (take ours, stage, regenerate); a conflict anywhere else aborts the merge and stops the landing exactly as
  before. The journal records `regenerate: {ran, changed, commit}` and `regenerate_resolved: [{branch, paths}]`.
- The **preflight** needs no separate code: it runs `wa land --until gate`, i.e. the same merge step, so its
  merged tree is regenerated too.
- Proof: `scripts/test-land.lua` case 2 (a stale generated file in the base repo is fresh in the landed merge
  commit, which still has two parents), case 2b (two branches that each edited the generated file still land,
  and the landed file is the generator's output, not either branch's bytes), case 2c (a conflict in a file
  nobody declared generated still stops with `merge_conflict` and names the file). `scripts/test-regenerate.sh`
  replays the real incident with the REAL generator over a copy of this tree's `lua/` and
  `rust/wa-capabilities/src`.

## 2a. A whole-tree row is never dropped (commit `6c6c1dda`)

The list, and how it was found (scan of every `scripts/test-*.lua` for the two shapes that enumerate the
repository rather than a named file - (1) a listing of it: `ls lua`, `find lua`, `rg --files`, `git ls-files`
without a pathspec, a glob over `lua/`; (2) a check quantified over a namespace other rounds extend: "every
tool", "each tool", "the whole catalogue"):

| row | why it cannot be reached by path narrowing |
| --- | --- |
| `scripts/test-refusal-contract.lua` | its input is the inventory of EVERY reachable module's refusal codes |
| `scripts/test-tool-schema-fidelity.lua` | it builds the catalogue from every source that contributes one |
| `scripts/test-codemode-parity.lua` | every tool the catalogue offers outside must be reachable inside |

`scripts/lib/fast-rows.sh` (`wa_fast_core_rows`) carries them with that evidence; `scripts/test-fast-rows.sh`
proves each is core, that narrowing to one ordinary row keeps it, and enforces the pairing with the generator
registry in both directions: any row that reads a path `scripts/generators.txt` declares as generated MUST be a
never-dropped row, so the list cannot fall out of date when a generator is added later.

## 2b. "main is green" is recorded (commit `52296945`)

`scripts/main-health.sh` runs the FULL fast path once on main's own tip (a scratch worktree of that sha, under
the suite lock, `nice 19`) and writes `<missions>/main-health.json`:
`{schema, sha, at, seconds, ok, counts:{checks,passed,failed,skipped}, failed:[{row, first_lines}], log, result}`.
A run that wrote no result file exits 2 and records `ok:false` with a named why - never green.
`~/Work/missions/status.sh` prints it on its FIRST line, and prints `main-health STALE ...` when the record is
about a main that has since moved instead of reading it as today's.

## 2c. A row red on main alone is MAIN RED (commit `52296945`)

`scripts/preflight.sh` compares its failed rows with the record, **only when the record is about the same
commit and the same branch**: matching rows become `main_red` (kept out of `failed`), the verdict prints
`preflight MAIN RED: N row(s) are red on main <sha> itself, not on <branch>`, says the mission is not blamed,
and says no landing runs until main is fixed. A record about another sha excuses nothing (unknown is not yes).
The landing path is covered by construction: the driver never starts a landing whose preflight is MAIN RED.

## 3. The machine lands, a model reads one file (commit `6968c18e`)

`scripts/drive.sh` (`~/Work/missions/drive.sh` is a symlink to the runtime tree's copy, like `preflight.sh`):
no model in it. Done missions (`done` with `rc=0`), branch not yet an ancestor of main, oldest first, one
landing each (`wa land --until main`: merge, gate, push, main - no release, no fleet), then the local install
(`WA_DRIVE_INSTALL`, default `scripts/deploy.sh`; `none` skips and says so), then the LOCAL-CHANGELOG entry built
from the mission's own `## How Victor tests it` (appended once, `state: untested`), then `scripts/main-health.sh`
on the new main, detached at `nice 19`. A preflight is never assumed: missing, red, or about another
main/branch is re-run, and the re-run counts only if it is green ABOUT THIS MAIN. On anything red it stops and
writes ONE file, `<missions>/ATTENTION` (mission, kind, rows, journal path, the next command); a second driver
refuses by name (kernel lock on `<missions>/.drive.lock`); `--skip <name>` clears that stop by name and archives
the file; `--dry-run` prints the queue. `~/Work/missions/wait-any.sh` now returns on that file and prints it
first.

## Texts to approve (verbatim, new or changed)

1. `regenerate: running <command>` / `regenerate: ok <command> (<last line>)`
2. `regenerate: FAILED <command> (exit <n>): <last line>` / `regenerate: FAILED <command> (timed out after <n>s)`
3. `regenerate: FAILED <command> (declared output '<path>' does not exist after a successful run)`
4. `regenerate: FAILED (malformed line, want '<output>[,<output>...] = <command>'): <line>`
5. `regenerate: changed <path>` / `regenerate: changed_count <n>`
6. `regenerate: <n> file(s) written by <m> generator(s) - the caller must commit them` /
   `regenerate: <m> generator(s) left the tree unchanged`
7. `regenerate: no registry at scripts/generators.txt - this tree declares no derived file, nothing was run`
8. `regenerate: refused(not_a_worktree): <tree> is not in a git worktree, so what a generator writes cannot be told`
9. `regenerate: refused(root_missing|root_unreadable|unknown_argument): ...`
10. merge evidence: `resolved as generated (the merge regenerates them): <paths>`
11. merge step detail suffix: `; regenerate wrote <paths>` / `; no generator: <why>`
12. merge commit trailer: `regenerate: <n> derived file(s) refreshed by scripts/regenerate.sh on the merged tree`
    plus one `regenerate: <path>` line each
13. `main-health: green at <sha12> (<n> s, <n> checks) -> <file>`
14. `main-health: MAIN RED at <sha12>: <rows> (<n> s) -> <file>`
15. `main-health: REFUSED(no_result): the fast path wrote no result file (exit <n>); log <path>`
16. `main-health: refused(tool_missing|jq_missing|no_repo|no_main|root_unwritable|lock_unwritable|worktree_failed|write_failed): ...`
17. `preflight MAIN RED: <n> row(s) are red on main <sha> itself, not on <branch>:` + one `  - <row>: <first line>`
    each + `  the mission is NOT blamed, and no landing runs until main is fixed:` +
    `  one small landing whose only purpose is that fix, then this preflight again`
18. preflight.json gains `main_red: [...]` and `main_health: {path, sha, ok, same_commit, red_rows, why}`
19. `drive: nothing to do (no done mission is waiting on main)`
20. `drive: landing <name> (<land> --branches change/<name>)` / `drive: <name> landed; main is now <sha12>`
21. `drive: <name>: no green preflight - running one` / `drive: <name>: the preflight is for main <sha12> / <branch>,
    not this main <sha12> - running it again` / `drive: <name>: preflight green on main <sha12>`
22. `drive: ATTENTION written for <name> (<kind>) -> <path>`
23. `drive: stopped - <path> names <name>` + `drive: clear it, or go on without that mission: bash scripts/drive.sh --skip <name>`
24. `drive: ATTENTION for <name> cleared (kept as <path>/ATTENTION.cleared-*)`
25. `drive: installing main on this node: <cmd>` / `drive: install skipped (WA_DRIVE_INSTALL=none); main is not what this node runs`
26. `drive: appended the LOCAL-CHANGELOG entry for <name>`
27. `drive: main-health started in the background (log <path>)` / `drive: main-health skipped (WA_DRIVE_HEALTH=none)` /
    `drive: main-health NOT started (no setsid on PATH): run <cmd> by hand`
28. `drive: refused(another_driver): <lock> is held by another drive.sh; two landings never run at once`
29. `drive: refused(tool_missing|value_missing|unknown_argument|no_missions_root|no_main|root_unwritable): ...`
30. `drive: --once, stopping after <name>` / `drive: done (<n> landed)` / `drive: would land <name> (<sha12>)`
31. `ATTENTION` file body: `# ATTENTION - written by scripts/drive.sh at <time>; nothing lands until this is cleared.`,
    `mission:`, `kind:`, `at:`, `main:`, `rows:`, `journal:`, `preflight:`, `land log:`, `next:`
32. `status.sh` first line: `== main-health green at <sha12>` / `== main-health MAIN RED at <sha12>: <rows>` /
    `== main-health STALE: recorded for <sha12>, main is <sha12> - run scripts/main-health.sh` /
    `== main-health: no record yet (scripts/main-health.sh writes it after a landing)`
33. `wait-any.sh`: `== ATTENTION (<path>):` before the status
34. new test verdicts: `test-regenerate ok (28 checks)`, `test-main-health ok (20 checks)`,
    `test-drive ok (26 checks)`, `fast-rows ok (36 checks)`, `land ok (574 checks)`
35. `SKIP test-main-health: this tree has no scripts/main-health.sh (nothing to judge)`
36. `SKIP test-drive: this tree has no scripts/drive.sh (nothing to judge)`
37. `SKIP test-regenerate: this tree has no scripts/regenerate.sh or scripts/generators.txt (nothing to judge)`

## What I verified, and how to see it again

- `bash scripts/test-regenerate.sh` - the real replay: two clean branches, the second merge conflicts in the
  generated file, the runner repairs it, the amended commit carries both codes, `--check` exits 0, and a second
  run writes nothing.
- `bash scripts/test-fast-rows.sh` - the three whole-tree rows are core and survive a narrowing; the registry
  pairing is enforced.
- `bash scripts/test-main-health.sh` - green / red / refused(no_result) / refused(no_repo), and the worktree is
  removed afterwards.
- `bash scripts/test-drive.sh` - the queue is oldest first; m1 lands and its changelog entry is written; m2 is
  red, the driver stops and writes ATTENTION naming the row, m3 does NOT land; a second run still stops; `--skip
  m2` clears it by name and m3 lands; a second driver refuses by name; a red preflight never lands.
- `bash scripts/test-preflight.sh` (38 checks, was 25) - the four MAIN RED cases: both rows red on main, one of
  each, a record about ANOTHER main (excuses nothing), and a green main (blames the mission as before).
- `bash scripts/test-land.lua` - `land ok (574 checks)`, including the three new cases above.
- `bash ~/Work/missions/drive.sh --dry-run` on the real missions root lists the five done missions and lands
  nothing.
- `bash ~/Work/missions/status.sh` prints `== main-health: no record yet ...` on its first line (true: no
  landing has happened since this file was written; after the first landing the driver writes the record).

## What I did not do, and what is still unknown

- I did not run a real landing, so `main-health.sh` against the real suite, `drive.sh` landing a real mission,
  and the local install step have NOT been exercised end to end. They are wired and their own rows pass with a
  fixture; the first real landing is the first real use (the install default is `scripts/deploy.sh`, which
  factory-2 may replace with a `wa land` local-install step - then set `WA_DRIVE_INSTALL` and delete the default).
- `main-health.json` does not exist yet on this node; `status.sh` says so rather than guessing.
- The landing itself does not re-read `main-health.json`; it enforces "no landing while main is red" through the
  driver's preflight gate and ATTENTION (see 2c). If a human runs `wa land` by hand while main is red, nobody
  stops them.
- `scripts/sync-prompt-docs.sh --write` is deliberately NOT in the registry (the reason is in the file), so a
  merge-induced stale prompt-doc block still reds a landing - by name, in a check that is never narrowed.
- `prompt-docs`, `discrimination` and the component checks of the real gate were not run in this round's own
  gate; the branch's gate is the fast path (see the run below).

## The discrimination check (rule 16)

`bash scripts/test-discriminates.sh 93168d96` -> **0 blocking**: `discriminates` for `scripts/test-fast-rows.sh`
("the refusal inventory row is not a never-dropped row: the 21/11 red is back") and `scripts/test-preflight.sh`
(the MAIN RED assertion fires on the base); `skipped` for the three new rows whose subject exists only on this
branch (`scripts/test-drive.sh`, `scripts/test-main-health.sh`, `scripts/test-regenerate.sh` print
`SKIP ... this tree has no <script> (nothing to judge)`), and `environment` for `scripts/test-land.lua` (that
scratch base worktree has no `wa` binary, so a Lua row cannot run the base code there - the landing's gate, which
has one, judges it).

## What a person has to know before trusting the wiring

`~/Work/missions/drive.sh` is a symlink to the RUNTIME tree's copy (`~/wasm-agent/checkout/scripts/drive.sh`),
like `preflight.sh`; that file only exists once this round lands. Until then run it from the worktree:

    bash /home/victor/Work/missions/factory-3/wt/scripts/drive.sh --dry-run

## Pre-existing failures

None met. **The full fast path on this branch is green: 362 checks, 0 failed, 0 skipped, 600 s**
(`flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh`, result in `/tmp/fast-factory-3.json`), run with
all of this round's changes except the last two commits; the last two touch `scripts/preflight.sh` (whose row
was re-run green at 38 checks) and documentation only. Per-row counts: `test-fast-rows.sh` 36 (was 26),
`test-preflight.sh` 38 (was 25), `test-regenerate.sh` 28 (new), `test-main-health.sh` 20 (new),
`test-drive.sh` 26 (new), `test-land.lua` 574.
