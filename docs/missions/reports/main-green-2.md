# main-green-2: the two rows that kept main's health red

Branch `change/main-green-2`, base `6de2264c`, worktree `/home/victor/Work/missions/main-green-2/wt`.
Everything was measured on this node (avell, 16 cores) with the tree's own binary
(`/home/victor/wasm-agent/target/m-main-green-2/release/wa`, built from `6c17dccf`) or, for the single-row
runs, the installed `/home/victor/.local/bin/wa` with `WASM_AGENT_LUA_ROOT` pointed at the tree.

## Refactor-only: no product behaviour changes

Both items change TESTS only. Item 1 makes an existing case hermetic (it picked up the machine it ran on) and
adds three assertions that pin the product's candidate order; item 2 splits one row into ten parts and adds
`scripts/lib/land-row.lua` for what they share. `lua/core/font_setup.lua` and `lua/core/land.lua` change in
comments only (`git show a16bb41a --stat`, `git show 6c17dccf --stat`: no product line). Every test is green
on the base and on this branch = the exemption rule 16 asks for.

## The premises, re-measured

| brief said | measured here |
|---|---|
| `test-font-setup.lua`: 6 of 180 checks fail | 180 checks, 6 failed - reproduced exactly, same first failure |
| `test-land.lua`: 655 checks, 55 s alone | 655 checks, 53.3 s alone (`06e2264c` tree, no other load) |
| 4 red rows on f5373ef2 | not re-measured: main is not this branch's to move (see "not done") |

## 1. test-font-setup: the row, not the product (a16bb41a)

**What was wrong.** The case "the faces are found from this node's own install record" wrote an install record
into its scratch home and then asked where the faces were. It left the binary as the RUNNING one, and on this
node that is `~/.local/bin/wa` with a complete `~/.local/bin/ui/fonts` beside it - a candidate that
`lua/core/font_setup.lua:131` tries BEFORE the record (`:145`). So the verdict was a fact about the machine,
not about the code: green in the 21/11 landing gates, red once the local installs put the faces beside the
binary.

**Why the product's order is the right one** (the brief asked which side to fix):

* `scripts/upgrade.sh:58` installs to `${WA_INSTALL_DIR:-$HOME/.local/bin}` on POSIX and puts `ui/` there
  (`:85` `UI_DIR="${WA_UI_DIR:-$INSTALL_DIR/ui}"`); `rust/wa-sentinel/src/instance.rs:443` hands the node
  `WA_UI_DIR=<install_dir>/ui`. Beside-the-binary IS the installed layout.
* On this node: `~/.local/bin/ui/fonts` holds all three faces; `~/.local/share/wasm-agent/ui` holds none;
  and there is **no** `~/.wasm-agent/install-dir.txt` and no `installed.txt` at all. The record candidate
  answers nothing here, so an order that put it first would not even have helped this machine - it would only
  let a stale record shadow the bundle the running binary was installed with.
* The record exists for the case the row is about: a binary somewhere else, named by a record
  (`lua/core/font_setup.lua:135-141`).

**Fix.** The row now builds every fact it depends on: no `WA_UI_DIR`, no `WASM_AGENT_LUA_ROOT`, a scratch
`HOME` (so the per-user default candidate is the case's own directory) and a binary at
`<scratch>/installed-node/bin/wa` with no `ui/` beside it - through `host.runtime_info()`, which is the
seam `font_setup.binary_path()` reads (`lua/core/font_setup.lua:86-95`), so the product path under test is the
one an install takes. No assertion was removed; the case gained three:

* "the UI beside this binary is tried before the install record (`<a> < <b>`)" - the order itself, both paths;
* "a complete ui/ beside this binary wins over a record naming another complete one" - the order from the
  other side, which is the behaviour the live node relies on;
* "and with the copy beside the binary gone, the record answers again".

Result: `font setup: ok (183 checks, 0 failed, 0 skipped)` - was 180 checks, 6 failed.

**It still discriminates** (run by hand, product restored afterwards, `git status` clean):

* delete the record candidate from `ui_candidates` -> 4 checks fail;
* move the record candidate before the beside-binary one -> 3 checks fail, including two of the new three.

## 2. test-land: one 655-check row becomes ten (6c17dccf, e2bbbe20)

**Measured cost of the one row**, by running it truncated at each of its independent-fixture boundaries
(`setup_fixture()` at column 0): setup 0.3 s, the cases 609-837 6.3 s, 838-942 3.4 s, 943-1056 4.4 s,
1057-1078 1.3 s, 1079-1214 3.5 s, 1215-1663 2.9 s, 1665-1960 19.9 s, 1962-1993 1.1 s, 1994-2271 8.4 s,
2272-2427 1.7 s; whole row 53.3 s.

**The split**, one row per subject, each measured alone on this node and each well under the 20 s the brief
asks for (the watchdog stays at 120 s):

| part | checks | alone |
|---|---|---|
| `scripts/test-land-plan.lua` | 105 | 6.6 s |
| `scripts/test-land-resume.lua` | 42 | 3.7 s |
| `scripts/test-land-sign.lua` | 46 | 6.1 s |
| `scripts/test-land-review.lua` | 47 | 3.8 s |
| `scripts/test-land-rows.lua` | 137 | 3.0 s |
| `scripts/test-land-resume-19-11.lua` | 20 | 8.0 s |
| `scripts/test-land-marks.lua` | 27 | 4.5 s |
| `scripts/test-land-release.lua` | 68 | 8.1 s |
| `scripts/test-land-gate-rows.lua` | 82 | 8.2 s |
| `scripts/test-land-until.lua` | 81 | 4.6 s |
| **total** | **655** | largest part 8.2 s |

**What they share** is `scripts/lib/land-row.lua` (678 lines): the original row's first 598 lines verbatim -
the scratch wa-vault, the fixture repository with its two remotes, the scripted peer call, the fake reviewer's
door and the assertion helpers - plus the four names a case REBINDS rather than reads
(`deploy_requests`, `routed_calls`, `sign_calls`, `VAULT_AVAILABLE`, now `state.*`, with a comment saying
why an alias would go stale) and the export table. The case text stayed in the parts, next to the comments
that record what was measured.

**No check was dropped**, proved twice:

* the ten parts print 655 checks between them, the same number the one row printed;
* line conservation against `git show a16bb41a:scripts/test-land.lua`: 1757 of the 1759 non-blank case lines
  (600-2427) are carried by exactly one part. The two that are not are the old wrapper's own header
  `local function cases_19_11()` and its call `cases_19_11()` - both regenerated per part
  (`resume_19_11_cases`, `publish_cases`, `release_cases`). Every line in the parts that is NOT an original
  case line is a header comment, an alias line, or the `red_checks` definition the marks part repeats (two
  lines, with a comment saying it belongs to the resume part).

**Wiring, both directions** (`scripts/lib/fast-rows.sh`, `scripts/test-fast-rows.sh`):

* `wa_fast_core_rows` (the never-dropped list) names all ten parts, with the reason the list grew;
* `scripts/test-fast-rows.sh` now proves it from the tree rather than from a list kept in the test: every
  `scripts/test-*.lua` that `dofile`s `scripts/lib/land-row.lua` MUST be a core row, and at least ten rows
  must use it (so the rule cannot become vacuous). Its narrowed-run fixture carries all ten parts and expects
  12 rows (11 core + 1 requested). `fast-rows ok (37 checks)`.
* the parts are NOT in `scripts/fast-path.exclude`.

**Where the new rows are wired:** `scripts/lib/fast-rows.sh:43` (`wa_fast_core_rows`), executed by
`scripts/fast.sh` through `wa_fast_row_filter`, and proven by `scripts/test-fast-rows.sh` (which
`scripts/fast.sh:1000` runs as the `fast-rows` check).

**References updated** so nothing points at the deleted file: `scripts/lib/fast-rows.sh` (comments + list),
`scripts/test-fast-rows.sh`, `scripts/lib/release-signing.sh:262` (a measurement note), `lua/core/land.lua`
(two case-number notes), `skills/fast-path/SKILL.md`, `docs/LAND.md` (twice). The harness's own history note
names the old file on purpose (`scripts/lib/land-row.lua:4`).

## Verification

**The full fast path on this tree**, under the suite lock, with the tree's own binary:

```
export CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-main-green-2
flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh
-> fast: lua 300/300 passed (59 excluded: scripts/fast-path.exclude)
-> fast path FAILED (1 of 372 checks, 1 skipped, 427s)
```

* All ten land parts and `scripts/test-font-setup.lua` are `pass` in the run's own result file
  (`wa-fast-result.json`, 300 lua rows, zero lua failures).
* The one red check is `install-guards`, and it is not this branch: it fails identically on a worktree of the
  base `6de2264c` (72 checks, 6 failed), because the suite is being run from inside a node turn:
  `scripts/lib/turn-guard.sh:12-42` walks the parent process tree, finds the `wa serve` this session runs in,
  and `scripts/upgrade.sh:39-42` therefore refuses with "refused inside a turn running on the node it
  would replace". `main-health` runs from a plain shell at nice 19 and does not have that ancestor - which is
  why the brief's 4 red rows on f5373ef2 did not include it.
* The 1 skipped check is `status-icon-metrics`, a counted skip the runner names (it is not a pass).

## Not done, and why

* I did not raise the per-row watchdog: it stayed at 120 s (`scripts/lib/fast-row-exec.sh:135`).
* I did not push and did not land: the brief says commit locally. So `bash ~/Work/missions/status.sh` line 1
  will only show `main-health ok` once this branch lands and `scripts/main-health.sh` runs on the new main.
  What can be checked before that is on this page: the fast path on this tree, and the ten parts green
  inside it.
* I did not run `scripts/main-health.sh` itself: it measures a checkout's `main`, and moving main is exactly
  what this branch may not do.

## Texts to approve (new or changed strings)

1. `the faces are found from this node's own install record, with no WA_UI_DIR, no WASM_AGENT_LUA_ROOT and no ui/ beside this binary (tried: <list>)` (check label, extended)
2. `the UI beside this binary is tried before the install record (<a> < <b>)` (new check label)
3. `a complete ui/ beside this binary wins over a record naming another complete one` (new check label)
4. `and with the copy beside the binary gone, the record answers again` (new check label)
5. `land ok (<n> checks)` (unchanged format, now printed by each of the ten parts)
6. `REFUSED <reason>` (the scratch-home guard's existing wording, now used by the ten parts; the reasons are `scripts/lib/scratch-home.lua`'s)
7. `Generated by scripts/lib/land-row.lua.` (the fake reviewer script the harness writes, in evidence logs; was "Generated by scripts/test-land.lua.")
