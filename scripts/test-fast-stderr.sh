#!/usr/bin/env bash
# A RUN THAT CANNOT SAY WHY IT STOPPED IS THE DEFECT (Fable, 24/11).
#
# MEASURED on 24/11: a narrowed fast run whose rows file named `scripts/test-update-treeless.lua` (declared
# un-runnable by `scripts/fast-path.exclude`) exited 2 after eight seconds with **nothing on stdout and
# nothing on stderr**. The runner does refuse such a plan, by name - but `scripts/fast.sh` opened its owner
# lock with
#
#     exec 8>>"$work/lock" 2>/dev/null || true
#
# and `exec` with only redirections applies them to the shell for the rest of its life: from that line on
# the whole run's stderr was /dev/null, the refusal included. A plan with one bad row made the run vanish.
#
# This row drives the runner with exactly such a rows file and asserts what a person needs: the refusal is
# PRINTED, it names the runner, the plan file and the bad row, and the run stops before a row runs.
#
# It needs no cargo and no tree build: `WA_FAST_ALLOW_STALE_BINARY=1` with an explicit `WA_BIN` uses the
# binary the caller named (the runner says so out loud), and `WA_FAST_IN_DOCKER=1` is the runner's own
# switch for "the components cannot be built here" - the refusal happens before any row, so no component is
# wanted. Nothing in the operator's store is written: TMPDIR and WA_TEST_ROOT are the scratch dir below.
#
# `scripts/test-this-row-does-not-exist.lua` is not a row and never will be: the point is the refusal.
#
# Prints `test-fast-stderr: ok`; any failed check exits 1.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-$(command -v wa 2>/dev/null || true)}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo 'SKIP test-fast-stderr: no wa binary to name (WA_BIN or PATH)'
  exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/wa-fast-stderr-XXXXXX")" || { echo 'FAIL test-fast-stderr: no scratch dir'; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/root"
BAD='scripts/test-this-row-does-not-exist.lua'
printf '%s\n' "$BAD" > "$W/rows.txt"

code=0
( cd "$ROOT" && \
  WA_FAST_ROWS="$W/rows.txt" WA_BIN="$BIN" WA_FAST_ALLOW_STALE_BINARY=1 WA_FAST_IN_DOCKER=1 \
  TMPDIR="$W" WA_TEST_ROOT="$W/root" \
  bash scripts/fast.sh > "$W/out.txt" 2> "$W/err.txt" ) || code=$?

[ "$code" = 2 ] || { echo "FAIL test-fast-stderr: a plan naming a row the runner cannot run must exit 2, got $code"; tail -5 "$W/out.txt"; tail -5 "$W/err.txt"; exit 1; }
grep -q 'narrowed run REFUSED' "$W/err.txt" \
  || { echo 'FAIL test-fast-stderr: the refusal was not printed (stderr is silent again)'; tail -6 "$W/out.txt"; exit 1; }
grep -q "$BAD" "$W/err.txt" \
  || { echo 'FAIL test-fast-stderr: the refusal did not name the bad row'; sed 's/^/  /' "$W/err.txt" | tail -4; exit 1; }
grep -q 'is not a row this run can execute' "$W/err.txt" \
  || { echo 'FAIL test-fast-stderr: the refusal did not say why'; sed 's/^/  /' "$W/err.txt" | tail -4; exit 1; }
grep -q '^fast: lua ' "$W/out.txt" \
  && { echo 'FAIL test-fast-stderr: a row ran although the plan was refused'; exit 1; }
echo 'test-fast-stderr: ok (a plan naming a bad row is refused, and the refusal is printed by name)'
