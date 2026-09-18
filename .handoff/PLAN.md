# handoff-gate — plan and findings

## Findings before writing code (each checkable)

1. `scripts/test.sh` needs `cargo`. On this Windows worktree cargo is absent, and the
   suite dies at line 10 under `set -euo pipefail`:
   - real exit: **127**
   - stdout: one line, `scripts/test.sh: line 10: cargo: command not found`
   - `bash scripts/test.sh | tail` reported **EXIT=0**, because the exit code of a
     pipeline is the exit code of its last command. So *the same run* reads as failure
     or success depending on how the caller pipes it. The gate must read the exit code
     of the script itself, never of a pipeline, and must treat "died before emitting a
     verdict" as neither pass nor skip but **error**.
2. `scripts/test.sh` emits no check count. Its verdict is a word (`smoke ok`,
   `ui tests ok`). `scripts/test-windows.ps1` *does* count: `local suite ok (N checks)`.
   The JS tests emit one `ok`/`FAIL` line per assertion and then `ALL PASS`.
3. Therefore a "count that cannot silently drop" cannot be sourced from a count the
   bash suite does not print. See Mechanism below.

## Mechanism: where the count comes from

The count has to be derived from evidence the suites already emit, without rewriting
them. Two sources are available and both are recomputable by the reader:

- **JS suites**: one line per assertion, `^ok` / `^FAIL`. Counting lines is exact.
- **bash suite**: no per-assertion lines, so its count is *the set of verdict lines*
  (`attach tests ok`, `ui tests ok`, `smoke ok`, `line endings ok`, ...), i.e. how many
  named stages reported. Coarser, but still a number that can shrink.

Rather than invent a new number, the gate **counts what is printed**, keyed by suite,
and compares against the previous run's recorded count, stored in a committed file:

    .handoff/expected-counts   (key=value, one per suite, committed and reviewed)

Rule: **a count below the recorded one FAILS and says so.** A count above it PASSES and
**writes the new number** (growth is a decision too, and it must be committed to take
effect). This is the "cannot silently drop" property: an increase is allowed, a
decrease is an error, and neither is quiet.

Refusal to lower the bar in a flag: `--accept-counts` rewrites the baseline, and the
report records that it was used, so the decrease is a visible, attributable decision.

## Endings (property 4)

The gate cannot observe a *previous* run's death; that is harness territory. What it
can do, and will, is record at exit:
- its own exit code and the reason (which stage, which suite),
- for each suite: exit code, duration, and whether a verdict line was ever emitted,
- a `running` marker written at start and replaced at exit, so a gate that is killed
  leaves `running` behind and the *next* gate reports `previous run did not finish`.

That last part is the honest, in-scope version: I do not instrument the harness, I make
an unfinished run detectable after the fact. Stated as such in the report.

## Design

- `scripts/handoff.sh` — bash, no Python (AGENTS.md), LF, `set -uo pipefail`.
- Stages, each independent and each reported even if an earlier one fails:
  1. **rebase** onto `origin/main` — on conflict, stop and list the files
  2. **mergeability** — `git merge-tree --write-tree origin/main HEAD`, report verdict
  3. **suites** — `scripts/test.sh` if cargo exists, `scripts/test-windows.ps1` on Windows;
     a suite that cannot run is a counted **skip**, and a suite that dies without a
     verdict is an **error**, never a pass
  4. **counts** — compare to `.handoff/expected-counts`
  5. **report** — one screen, counts per suite, failures, skips, errors, merge verdict,
     commit hash, session id, plus every command the reader can re-run
- Report written to `.handoff/last-report.txt` and printed.
- Exit code: 0 only if nothing failed, nothing errored, and no count dropped.

## Order of work
1. commit the plan + findings (so the record exists)
2. write `scripts/handoff.sh`
3. run it on this branch — the gate's first customer is me
4. commit, push, report
