# undo-rows-fast-env: the two /undo pty rows under fast.sh, and the evidence fast.sh was throwing away

Base `fc1334f0` (main; the /undo work itself landed as `e9a42d20`). Branch `change/undo-rows-fast-env`.
Commit `75f0f519`.

## The cause, in one line

The chat CLIPS a line of command output to the terminal width, and fast.sh sets `TMPDIR=$work/tmp` under
`~/.wa-scratch/wa-fast-XXXX/`, so the fixture's file path is ~30 characters longer than a `/tmp` one and
`version <hex>` fell off the clipped `/undo` answer row; both rows assert that version, so both failed in
every fast.sh run and passed by hand, where the same path came out short enough to fit.

## The measurement

Reproduced with the row's own environment, and with the tree binary fast.sh runs:

```
$ TMPDIR=/home/victor/.wa-scratch/wa-fast-jZoUL9/tmp \
    WA_BIN=/home/victor/wasm-agent/target/m-remote-undo-works/release/wa node scripts/test-undo-pty.mjs
FAIL - it names the version the file now holds (the recorded text's own sha256)
undo pty: 16 ok, 1 failed          <- the health run's own numbers

$ TMPDIR=... WA_BIN=... node scripts/test-undo-remote-pty.mjs
FAIL - it names the version the peer now holds (the recorded text's own sha256)
undo remote pty: 14 ok, 1 failed    <- the health run's own numbers
```

The same two rows with fast.sh's long `TMPDIR` and the file itself verified correct: the restored file's
`sha256` was `4fdbc441ea7b...`, exactly what the row expects - only the ANSWER ROW was clipped. So the
undo was right and the assertion could not read its own evidence.

## The fix (test side: nothing loosened)

Both pty rows now get 200 columns instead of 110 (`COLUMNS=200`, `tmux -x 200`) and the shortest scratch
name the guard allows (`wu-` / `wur-`). The assertions are unchanged, character for character: the same
version, on the same row, with room to be read. Both are green under the fast-like environment and under
the plain one:

```
TMPDIR=/home/victor/.wa-scratch/wa-fast-jZoUL9/tmp WA_BIN=<tree> node scripts/test-undo-pty.mjs        -> 17 ok
TMPDIR=/home/victor/.wa-scratch/wa-fast-jZoUL9/tmp WA_BIN=<tree> node scripts/test-undo-remote-pty.mjs -> 15 ok
```

## The fix (fast.sh: the evidence)

What made this take a round instead of a read: fast.sh reported `tail -3` of the row's log, and kept
nothing of a `check` row.

- `check()` now prints the row's OWN failure line and the path of its whole log:
  `FAIL <name> (exit <c>): <the row's failing line>` then `<name> failed on that line; its whole log: <path>`.
- The keeper copies **both** kinds of row log. A `check` row (a pty row) writes `$work/check-<name>.log`,
  and only `$work/logs/*.log` was kept - so a pty row's log was never kept at all, however the caller
  named a directory.
- The directory a row keeps itself ("scratch kept for diagnosis: <dir>") is copied too; it lives under
  `$work/tmp` and used to be deleted with the run, so the evidence the row pointed at was already gone.
- It runs on any failed run, not only when `WA_FAST_KEEP_LOGS` is set. The default destination is the
  worktree's own git dir (`<git dir>/wa-fast-evidence/<timestamp>-<pid>`), pruned to the five newest
  runs, with a `failures.txt` that names each row's failing line and its summary.

`scripts/test-fast-skip-count.sh` (already a fast-path row) now reads the shipped `check()`, the shipped
failure-line helper and the shipped keepers OUT of `scripts/fast.sh` and drives them: a row whose failing
assertion is followed by three green lines must still have that line reported, and the keeper must keep a
`check-<name>.log`, a Lua row's log and the directory the row kept. Against the base (`origin/main`) it
fails with `the runner did not print the failing line: FAIL three-lines-kept (exit 1): ok - two ok - three
undo pty: 16 ok, 1 failed` - the reported symptom, reproduced in a test.

## Texts to approve (operator-facing, verbatim)

1. `FAIL <name> (exit <c>): <the row's own failing line>`
2. `fast:   <name> failed on that line; its whole log: <path>`
3. `fast: kept <N> failed row log(s) and <M> scratch dir(s) in <dir> (what failed: <dir>/failures.txt)`
4. `fast: refused(keep_evidence_nowhere): no git dir to keep the failed rows' evidence in`
5. `fast: refused(keep_evidence_unwritable): cannot keep the failed rows' evidence in <dir>`

## What this does NOT do

- It does not make a clipped row wrap. A reader in a narrow terminal typing `/undo` still sees the row
  cut at the width (as every command's output is); making command output wrap is a different change.
- It does not touch the undo code: the undo was correct in every run, and the failing file was verified
  byte-for-byte and by sha256 before this was called a test bug.
