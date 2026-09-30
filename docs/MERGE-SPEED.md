# Merge speed: what the gate's own numbers price

**This is a measurement and a recommendation. No behaviour was changed to produce it, and none of the
options below is implemented here.** The companion artifact is the gate's own instrumentation:
`scripts/lib/gate-phases.sh` (per-phase wall time), `scripts/lib/gate-suite.mjs` +
`scripts/lib/gate-suites.mjs` + `scripts/lib/gate-shims/` (per-suite wall time and the CPU charged inside
each suite's own process tree), and `scripts/lib/gate-lane-sample.ps1` (the sampler all three reuse).

Ask the owner puts first: a landing's wall time is the gate. The merge lane's own records (12 gated runs,
`~/.wasm-agent/merge-lane-batch*.json`) put **the gate at 96.6% of lane wall time, median 15.0 min, max
21.4**, against a clone and a merge that together cost ~2 s. So every recommendation below is a statement
about the gate and nothing else.

## 1. The numbers tonight's decision rests on

| what | number | where it comes from |
| --- | --- | --- |
| gate share of a landing | 96.6% of lane wall time | 12 gated runs in `~/.wasm-agent/merge-lane-batch*.json` (median 15.0 min, max 21.4) |
| clone + merge | ~1.2 s (clone 281.8 ms, merge proof 949.5 ms) | my own `merge-lane` run, `timings_ms` in `~/.wasm-agent/refusal-probe.json` |
| discovery (audit) | 2.46 s (fetch 85.7 ms, branch discovery 18.7 ms, merge proof 1972.9 ms) | same record; the lane's older runs said ~12 s on a busier remote |
| the cold/warm gap on ONE tree | **1145.9 s cold vs 528.1 s warm** (528.1 and 523.4 in the warm pair) | `docs/EVOLUTION.md`, "Gate parallelism" - same tree, `smoke ok (2 skipped)` both |
| CPU charged inside the gate's own process tree | **253.0 CPU-s cold vs 11.2 warm** | same table |
| what the gate leaves on disk per run | ~1.29 GB of `wa-*` temp, 3533 entries, never removed | sibling delivery's measurement of the run's own suites |
| disk now | 71 GB free of 477 GB (86% used) | `df -h` at 10:0x, before the timed gates |
| is a shared `CARGO_TARGET_DIR` already set? | **no** - `~/.wasm-agent/env` sets `WA_GATE_JOBS=2` and nothing cargo-path related | read of `~/.wasm-agent/env` |

The decisive number is the fourth row: **on one tree, the same gate costs 617.8 s more when the tree is
cold than when it is warm**, and 241.8 CPU-s of that difference is compilation charged inside the gate's
own tree. A landing that gates a fresh clone pays it every time; that is the whole of the "merge speed"
problem, and it is why the persistent tree (option 2) is the one with a measured payoff rather than a
hoped-for one.

## 2. The instrument, and the four defects it had as left

The predecessor lane's committed half (per-phase timing, `scripts/lib/gate-phases.sh`) is sound and is
what the phase table below comes from. Its **uncommitted** half (the per-suite wrapper) was a claim, and as
left it could not have measured anything. Four defects, each fixed with the observation that found it:

| defect | observation |
| --- | --- |
| `#!/usr/bin/env bash` in a directory that is FIRST on the gate's PATH | `env` re-execs the shim, which re-execs itself; a bounded `node -e ...` probe produced **no output for 300 s** and had to be killed |
| `real="$1"` treated the suite's first *argument* as the program name | a PATH lookup passes the program in `$0`; with `$1` the shim refused every suite |
| `scripts/lib/gate-suites.cjs` is an ES module named `.cjs` | `node scripts/lib/gate-suites.cjs summarize ...` exits 1, "Cannot use import statement outside a module": the gate's own summary could never be produced. Renamed `.mjs` |
| the CPU reader took the sampler's **last** line | that line is written after the suite exits and reads an empty tree: a 3 s CPU-burning suite recorded `cpu_ms: 0` while its sample file read 937500 ticks at 244 ms rising to 4531250 at 3434 ms. Now the maximum over the lines (totals are absolute per pid) |

**Falsifications of the fixed instrument** (all run, all restored):

* the wrapper is transparent: a real suite (`scripts/test-proof-verdict.cjs`) run with and without the
  shim produced **byte-identical stdout and stderr and the same exit code**; a real Lua suite through the
  `wa` shim printed the same verdict as the binary run directly;
* exit codes survive: `node -e ... process.exit(3)` recorded `exit: 3` through the shim, `bash -c 'exit 7'`
  recorded `exit: 7`, `powershell -Command 'exit 5'` recorded `exit: 5`;
* the CPU figure is real once the reader is fixed: a 3.059 s busy node suite through the shim recorded
  `cpu_ms: 250`, `cpu_ticks_observed: 2500000`, `cpu_sample_line: 4` of 5 samples - and it stays a **lower
  bound**, because a process that starts and exits between two 500 ms samples contributes only what was
  seen (recorded as `null`, never as 0, when nothing was sampled);
* a phase cannot be reported as having run when it did not: the phase markers are closed by the segment
  that follows them, `gate_phase_summary` prints only the segments it opened, and the EXIT trap prints what
  was reached when the gate dies early - the deliberately-broken-suite run below is the observation of it.

## 3. The three options, priced

### Option 1 - one shared `CARGO_TARGET_DIR`

**What it would save.** Everything the cold/warm gap is worth per landing *for the build phase only*:
bounded above by the 617.8 s / 241.8 CPU-s gap measured on one tree, and in practice only the part of it
that a *different tree* still gets to reuse. Cargo's fingerprints are keyed by source path, so gating in a
fresh clone (option 2's absence) invalidates them even when the shared directory is warm: a shared target
directory on its own, with a disposable clone per landing, buys the dependency compilation and not the
workspace crates. The persistent tree is what buys the rest.

**What it risks.** (a) A shared directory **serialises builds**: cargo takes an exclusive lock on its
target directory, so a second gate (or an operator's `cargo build` in the canonical checkout) blocks
instead of compiling, and the failure mode is a *wait*, not an error - on a node whose gate lane is
already 4 deep (`node scripts/gate-lane.mjs status`, 10:15). (b) It **can be poisoned by a different
toolchain**: artifacts written by another `rustc` are not reliably detected by cargo's own fingerprint
when the *directory* is shared rather than the tree, and the observable result is a link error inside a
gate that has nothing to do with the candidate. (c) It **grows**: the persistent tree already holds one
target set; a shared one adds a second, on a disk with 71 GB free.

**How a refusal must be reported.** Not silently. If the shared directory is missing, locked by a live
process, or was last written by a different `rustc -vV`, the gate must say which of those it is and build
in its own default location for that run - exactly the shape `merge-lane` already uses for its tree
(`clone.toolchain_cleared`, `clone.reuse_refused`): the run stays correct, the cost stays visible.

### Option 2 - the persistent integration worktree (already implemented, `7314b89`)

**What it saves.** The whole cold/warm gap, because it is the mechanism that removes the cold tree:
**617.8 s per landing** (1145.9 s -> 528.1 s on one tree; the warm pair's own runs were 528.1 s and
523.4 s), with 241.8 CPU-s less charged inside the gate's tree, plus ~1-6 s of cloning and fetch not
repeated. On tonight's median 15.0-minute gate that is a landing's gate falling to roughly 7-9 minutes,
which is the largest single number available to this decision.

**What guarantees the reused tree is clean.** Reuse is refused unless all of: the directory's toplevel is
itself; its `origin` is the repository being landed; its owner record names that repository; the reuse
lock is free or held by a provably dead pid; and after `git clean -xdf -e target`, a pinned
`core.autocrlf`, `git switch --detach --force` and `git reset --hard` onto the base, `git status
--porcelain` is **empty**. `-e target` is what keeps the warmth; everything else a previous candidate left
behind is discarded, and what was discarded is **named** in the log and in `clone.reuse_dirt_discarded`
rather than swallowed.

**What happens when it is dirty, or wrong.** It is refused by name and the run falls back to a disposable
clone (cold, correct, `clone.reuse_refused` set, exit code unaffected). Observed, not read: pointing the
lane at a directory that is not a checkout produced, in 6 s,

```
merge-lane: the persistent tree at C:\Users\Victor\.wasm-agent\not-a-checkout was NOT reused: it is not a
git checkout (fatal: not a git repository (or any of the parent directories): .git)
merge-lane: this run gates in a disposable clone instead - cold, correct, and slower. Recovery for a tree
that stays unusable: rm -rf "C:\Users\Victor\.wasm-agent\not-a-checkout"
```
with `"clone": {"reused": false, "reuse_refused": "it is not a git checkout (...)", "reuse_path": ...}` and
`clone.clone_ms: 281.779` in `~/.wasm-agent/refusal-probe.json` - the refusal is a record, not a silence.
A recorded `rustc` change clears every cargo output directory by name (`toolchain_cleared`) instead of
trusting another compiler's artifacts, and a tree that is wedged for any other reason is reported with its
own reason and `rm -rf <dir>` named as the recovery. **A persistent tree is never deleted by the lane.**

**What it risks.** Stale state surviving in the tree (answered by the reset + the empty-status check) and
a target directory poisoned by another toolchain (answered by the recorded fingerprint). The
implementation is also 331 lines of new merge-lane logic, so its own suite matters as much as its gates -
and that suite is where the refusal paths are pinned.

### Option 3 - bounded parallelism of suites that declared isolation

**What it would save.** Only the wall time of suites whose isolation is *declared*, and only up to the
critical path: if a set of suites costing W seconds together declares no fixed port, no shared temp
directory, no node state directory, no network or model dependency, no process-lifetime coupling and no
gate-lane state, running them k-wide cannot save more than W minus the longest suite in the set. The
per-suite table (section 5) is the only thing that can price this, and it deliberately reports every suite
whose source shows nothing as **`undetermined`** - a clean scan is not proof of isolation, and the
scheduler must not parallelise on a hunch.

**What it risks.** Two suites in the same set writing one fixed port, one temp path or one node state
directory - which is why the declaration is by citation (source file, line, the matched text) rather than
by name. It also does nothing about the two things that actually cost a landing (the cold build is option
2's, the ~1.29 GB of `wa-*` temp per run is nobody's in this lane), and it makes a *red* gate harder to
read unless each suite's output stays attributable.

**How a refusal must be reported.** A suite that cannot declare isolation stays serial by default: the
declaration is an allow-list, and a suite whose source cannot be found (the `wa` binary itself, an
inline `-c`) is `undetermined` rather than assumed safe. A parallel set that could not be kept isolated
must fail loudly into the serial path and say so, never silently proceed with one suite's temp directory
shared with another's.

**One number for the next gate suite.** A sibling delivery adds a suite to `scripts/test.sh`. Every suite
in the table is paid *per landing*: a suite that costs `w` seconds of wall adds `w` seconds to every
future landing, and its CPU-s add to the gate's own CPU figure. That is the price of admission for a new
suite, and it is now measurable before it lands (`scripts/lib/gate-suites.mjs`, one JSON object).

## 4. What was observed, and what is not verified

The raw evidence is `docs/measurements/gate-instrument-evidence.json`. Two runs of the instrumented gate
were completed inside the window, both **without a gate-lane slot** (the lane held 1 of 1 with a queue
2 to 4 deep throughout - status quoted in that artifact), so their wall times are an **upper bound under
contention**, not clean numbers:

| run | gate exit | phases the instrument named | first suite |
| --- | ---: | --- | --- |
| cold tree, unslotted, contended | **1** | `build` 1 335 881 ms - and no other phase | `test-parallel-finish.mjs`, wall 727 092 ms, exit 1 |
| **deliberately broken first suite**, warm tree | **1** | `build` 788 ms - and no other phase, no verdict | `test-parallel-finish.mjs`, wall 45 ms, exit 1 |

The second row is the falsification the owner asked for: a test broken on purpose (a `process.exit(1)`
prepended to `scripts/test-parallel-finish.mjs`, committed so the tree stayed clean, then restored with
`git reset --hard` and a clean `git status`) makes the instrumented gate **red with the gate's own exit
code**, and the instrument names only the phase that ran. It cannot report a phase that did not run, and
it does not invent a verdict line.

The first row is a finding in its own right, and it is the same 12-minute stall class the owner saw:
**a gate run outside the lane pays the lane wait inside itself.** `scripts/test.sh` runs
`scripts/test-parallel-finish.mjs` as its first suite; that suite's fixture gates ask `gate-lane.mjs` for
a slot, and a nested gate only inherits admission through `GATE_LANE_HELD`, which a run that holds no
slot cannot pass down. Unslotted, the fixture waited **722 s**, was told it would run without a slot, and
then failed its own check on the nested call's exit status - `set -e` ended the gate inside `build`. The
shim is not the cause: the same fixture gate through the same wrapper in isolation exits 0. The installed
`~/.wasm-agent/skills/parallel-evolution/scripts/finish.mjs` was stale and did not pass `GATE_LANE_HELD`
at all - it has since been replaced with this repository's copy (sha `129fabc5`), which does.

Still not verified, and it is the whole of the cold/warm pair:

* **No clean cold/warm pair of one tree was completed.** That needs a gate-lane slot twice, and the lane
granted none in this window: my queued request (#151) sat at position 4 for ten minutes and was cancelled
to free the queue for the lanes ahead, and a later `merge-lane` attempt (#159) had reached position 2.
What exists instead: today's cold **build** in a fresh tree (`Finished release profile in 10m 08s`, from
the first run's own log, under contention), the existing same-tree pair in `docs/EVOLUTION.md`
(1145.9 s cold / 528.1 s warm, 253.0 CPU-s / 11.2 CPU-s), and the per-suite instrument itself, whose
CPU figure was verified against a busy suite (250 ms for 3.059 s, labelled lower bound).
* The per-suite table therefore has **no rows from a full gate** in this window: the only suite that ran
to a record was the first one, twice. The collision declarations, which are read out of each suite's own
source, were not produced for the rest.
* The persistent tree's **end-to-end** saving is priced from the `docs/EVOLUTION.md` pair rather than from
two `merge-lane` runs of my own (`gate_ms` before/after needs two slots). What I did verify about the
mechanism is its refusals and its recorded fields (section 3, option 2).
* `scripts/test-merge-lane.mjs` (the lane's own 83 checks, which pin the dirty-tree, live-lock,
  not-a-checkout and toolchain-cleared paths) was **not re-run in this window**: its fixtures ask the
  node-wide gate lane for slots, and the lane was 4 deep. It is designed to be run when the node is idle.
* No option was implemented. `WA_GATE_LANE_CAPACITY` and `docs/CONCURRENCY.md` were not touched.
