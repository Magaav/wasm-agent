# gate-fast: the landing gate's wasted seconds

Branch `change/gate-fast` from origin/main 975d4612. Five commits (the fifth only corrects this report), no Rust change, no prompt change.

## What changed, per commit

| commit | what |
| --- | --- |
| df49ac81 | `scripts/test-run-live-pty.mjs`: the "let the run finish" loop goes to the bottom of the pane (PgDn) on every poll and is now a check that FAILS, with the last frame, when the answer never arrives (ceiling 90 s, was a silent 180 s). |
| c2c44c8d | `scripts/gate-cargo-codemode.sh` builds into the tree's named build dir (`fast_binary_target_dir` / `wa_build_target`), compiles with `--no-run` under the node's one build lock, then runs the unchanged test command outside it. New row `scripts/test-gate-cargo-codemode.sh`, wired into `scripts/fast.sh` right after `check fast-watchdog` and into `scripts/test.sh` after the `test-fast-watchdog.sh` line. |
| 7782c2f1 | `scripts/lib/fast-watchdog.sh` polls every 0.1 s instead of every 1 s (deadline still whole seconds, counted in tenths). `scripts/test-fast-watchdog.sh` gains the timing assertion. |
| 8f804401 | the two new watchdog failure messages start with "assertion failed:" so `scripts/test-discriminates.sh` classifies them (its ASSERT_RE), plus this report. |

## Measurements (this laptop, 21/11, other agents building at the same time)

### 1. run-live-pty - the suspicion is PROVED

A temporary probe after the loop (not committed) printed, on the unchanged test:
`PROBE settle wait 180.1s, answer on screen: false`. The pane was left scrolled up by the test's own
PgUp, the answer is the last row, and it never came on screen; the loop ran out its 180 s and went on.

| | whole test (`time`, real) | settle wait |
| --- | --- | --- |
| before | 209.9 s (the other agent's 208.5 s agrees) | 180.1 s, answer never seen |
| after | 48.2 s | 17.0 s, answer on screen |

Negative proof that an expired wait now fails: a scratch copy without the PgDn and with a 40 s ceiling
ended `FAIL - the run finishes and its answer is drawn at the bottom of the window`, `19 ok, 1 failed`, exit 1.
All 19 earlier checks are kept; the count is now 20 ok, 0 failed, 1 skipped (the skip is the known split-scrollbar row).

### 2. cargo-codemode

Run twice with a private `CARGO_TARGET_DIR=~/wasm-agent/target/m-gate-fast`, `CARGO_BUILD_JOBS=4`:

| run | real | of which |
| --- | --- | --- |
| cold (empty dir) | 322.8 s | 15.4 s waiting on the node build lock; 4 jobs on a busy machine, so not comparable with the gate's 138 s at 10 jobs |
| warm | 16.9 s | 16.4 s waiting on the node build lock for ANOTHER agent's build; the script's own work was about 0.5 s |

Both: `test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 345 filtered out`.

What I checked in `lua/core/land.lua` (DEFAULT_CHECKS, lines 386-408): the order is fast, codemode-component,
cargo-codemode, cargo-wa-whatsapp, discrimination, prompt-docs, so `fast` has always filled the named dir
before this check runs. `land.lua` itself names no `rust/target` and no CARGO_TARGET_DIR. The one neighbour
that looks inside the tree is `scripts/test-codemode-component.sh` (falls back to `$ROOT/rust/target` for
the binary and components when CARGO_TARGET_DIR is unset); it never depended on what cargo-codemode built,
and I did not change it. `cargo-wa-whatsapp` builds in its own crate directory and is untouched.

### 3. watchdog poll

Same function, old file vs new, one row each: `sleep 0.15` 1.038 s -> 0.245 s; `sleep 1.2` 2.025 s -> 1.335 s.
A hung row with a 2 s deadline: killed at 4.13 s (2 s deadline + 2 s grace), exit 124, as before.

### 3b. the duplicate prompt-docs check - NOT removed, on purpose

The two are not the identical command. `scripts/fast.sh:733` runs `WA_BIN="$bin" ... sync-prompt-docs.sh --check`
(the tree's own binary) on every run, narrowed or not (the narrowing at fast.sh:427 only filters Lua rows).
The gate's own check runs the same script WITHOUT WA_BIN, so `sync-prompt-docs.sh` picks `wa` on PATH, then
`~/.local/bin/wa`, then `rust/target/release/wa` - the installed binary, not the tree's. It is also in
`M.GATE_ALWAYS` (land.lua:469), pinned by `scripts/test-land.lua` (lines 1222-1230, 1429), and reachable alone
through `--checks`. Removing it is a decision about which binary proves the documents; ~13 s, left for the owner.

## Seconds saved per landing

MEASURED (this laptop):
- run-live-pty: 161.7 s per run of the row (209.9 -> 48.2).

ESTIMATED (could not run a landing):
- cargo-codemode: about 135 s on a landing that runs it (138 s cold by the other agent's measurement -> a warm
  run, which I measured at about 0.5 s of own work). It only runs when the plan names it (code-mode paths) or on a full gate.
  If a narrowed `fast` did not test `wa-capabilities`, the test binary still has to be compiled once (dependencies reused); not measured.
- watchdog: about 0.7-0.8 s per Lua row of row-slot time (measured per row); 170 rows in the measured landing,
  divided by the number of parallel jobs. At 8 jobs that is roughly 15 s of wall clock; unmeasured as a whole.

## Test commands run (last line of each)

All with `TMPDIR=~/wasm-agent/scratch/gate-fast-EyZl/tmp` (the /tmp quota warning), in the worktree:

- `WA_BIN=$HOME/.local/bin/wa WASM_AGENT_LUA_ROOT=$PWD node scripts/test-run-live-pty.mjs` -> `run live pty: 20 ok, 0 failed, 1 skipped` (48.2 s)
- `bash scripts/test-gate-cargo-codemode.sh` -> `test-gate-cargo-codemode: ok`; with the old gate script put back: 6 FAIL lines
- `bash scripts/test-fast-watchdog.sh` -> `test-fast-watchdog: ok (...)`; with the old watchdog put back: `a 150 ms row took 1024 ms ...`, exit 1
- `bash scripts/test-fast-watchdog-reap.sh` -> `test-fast-watchdog-reap: ok (...)`
- `bash scripts/gate-cargo-codemode.sh` twice (cold, warm) with the private target dir -> `test result: ok. 13 passed ...` both times
- `bash -n scripts/fast.sh scripts/test.sh scripts/gate-cargo-codemode.sh` -> clean

## NOT verified

- No landing, no `scripts/fast.sh`, no `scripts/test.sh` was run (forbidden here). The new `check gate-cargo-codemode`
  row and the watchdog change have not been seen inside a whole fast run.
- `scripts/test-land.lua` WAS run (scratch HOME, 106 s, exit 0); it stubs the gate commands, so it does not execute the changed script.
- The real path of item 2 - the default named dir under `~/.wasm-agent/build/target` after a real `fast` - was
  exercised only by the stub test in a scratch build root, never against the real node root.
- `scripts/test-discriminates.sh` was not run on this branch. Expected rows: test-gate-cargo-codemode.sh
  discriminates; test-fast-watchdog.sh discriminates; test-run-live-pty.mjs is a MODIFIED test that still
  passes on the base code (`unchanged-verdict`, does not block) - it is a test-only fix.
- Windows/macOS: `sleep 0.1` is probed on each call (`sleep 0.01`), and the whole-second poll is the fallback.
- The 800 ms best-of-three threshold in test-fast-watchdog.sh under a heavily loaded gate: three slow tries in a row would fail it.

## Brief facts re-measured

- `check()` is at scripts/fast.sh:721 (brief: ~721, right); run-live-pty row at :813 (right); the loop was at
  test-run-live-pty.mjs:318 (right); watchdog poll at fast-watchdog.sh:42 (right); land.lua checks at 386-408 (right).
- The row is invoked with WA_BIN only; the test builds its own scratch home, fixture endpoint and tmux socket.
- The brief's order "fast, cargo-codemode, codemode-component, prompt-docs, discrimination" is not the table's order (see above).

## Texts to approve

- test output: `run-live-pty: the run settled <N>s after the scroll check` (and `... - NOT: the answer never reached the screen`)
- check name: `the run finishes and its answer is drawn at the bottom of the window`
- gate stderr: `cargo-codemode: target <dir>`, `cargo-codemode: test build <N>s`,
  `FAIL cargo-codemode: the test build failed (target <dir>)`, `FAIL cargo-codemode: cannot prepare the build dir <dir>`,
  `FAIL cargo-codemode: scripts/lib/build-target.sh cannot be loaded`
- fast row name: `gate-cargo-codemode`
- new variable: `WA_FAST_WATCHDOG_POLL=1` (whole-second poll)

## How Victor tests it

In `~/Work/missions/gate-fast/wt`:

1. `time WA_BIN=$HOME/.local/bin/wa WASM_AGENT_LUA_ROOT=$PWD node scripts/test-run-live-pty.mjs`
   - about 50 s instead of 3.5 minutes; a line `run-live-pty: the run settled 17.0s after the scroll check`; last line `run live pty: 20 ok, 0 failed, 1 skipped`.
2. `bash scripts/test-gate-cargo-codemode.sh` - ten `ok -` lines, then `test-gate-cargo-codemode: ok`, in about a second.
3. `bash scripts/test-fast-watchdog.sh` - one line `test-fast-watchdog: ok (...)` in about 13 s.
4. On the next real landing that touches code-mode: in the gate log the `cargo-codemode` check prints
   `cargo-codemode: target /home/victor/.wasm-agent/build/target/tree-<hash>` and `cargo-codemode: test build <a few>s`
   instead of 138 s of `Compiling ...`, and no `rust/target` appears in the landing tree because of it.

## Proposals for the next round (not done, by instruction)

### Parallel contract checks

Of the 64 checks, three kinds must stay serial, each for a reason that can be checked:
- pty / timing rows that read a live frame or a wall-clock budget: `run-live-pty`, `fence-card-pty`, `cli-scripted`,
  `fast-watchdog` (its 800 ms assertion), `fast-watchdog-reap`, and anything asserting a duration. Under 16 busy cores they flake.
- rows that build or take the node build lock: `onebuild`, `build-heat`, `fast-binary`, and any row that runs cargo -
  they would queue on the lock anyway and their timings are their assertions.
- rows that share a fixed resource: a fixed TCP port, the default tmux socket, a fixed path outside their own mktemp dir.
  This needs an audit, row by row (grep for literal ports and for `/tmp/` names without mktemp) before anything moves.

Concrete shape: a second function `check_bg` beside `check()` with a small pool (4), used ONLY for rows put on an
explicit allow-list after that audit; each writes its own log and a result file, and one `wait` loop calls
`record_row` in the original order so the report and ledger do not change. Everything not on the list stays on `check()`.
Expected: the ~150 s of non-pty checks (359 - 208.5) down to roughly 50 s. Proof before landing: run the pool row set
20 times under a parallel cargo build and require 20 of 20 green.

### Build seeding

The incident was one tree running a sibling's code. Seeding is safe only if nothing of the seed tree's OWN crates survives:
- seed third-party dependencies only: after the copy, delete every fingerprint/dep/incremental entry of a workspace
  member (`cargo metadata --no-deps` lists the names) and every final binary under `release/` and `debug/`, so each
  member is recompiled from this tree's sources. The cost is the members' compile (wa-host dominates), the saving is the dependency graph.
- require the same toolchain AND the same `Cargo.lock` hash as the seed (the lock decides the dependency artifacts);
  a different lock means no seed.
- prove it with the existing two-tree check in `scripts/test-onebuild.mjs`: tree A prints value A, tree B seeded from A
  must print value B, with mtimes arranged so cargo's mtime fingerprint would be fooled if a member artifact had survived.
- stamp check as the last line of defence: the binary's embedded commit must equal the tree's HEAD (`fast_binary_plan`
  already reads it) or the build is discarded and redone cold.
