#!/bin/bash
# The advisory canary step (Fable 26/11, r6) as ONE runner row.
#
# scripts/test-land-canary-step.lua drives land.impl.canaries with fixture canaries and WRITES state, so the
# test-home guard refuses a home that is not under the scratch root (measured: the row runner gives a home under
# _rows/, and the row refused to run). This wrapper owns a scratch root, exports GATE_ROOT/TMPDIR/WASM_AGENT_HOME
# inside it, and runs that row as its one check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WA_BIN="${WA:-$(command -v wa || echo /home/victor/.local/bin/wa)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/advisory-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
export GATE_ROOT="$WORK"
export TMPDIR="$WORK/tmp"
export WASM_AGENT_HOME="$WORK/home"
mkdir -p "$TMPDIR" "$WASM_AGENT_HOME"
cd "$ROOT"
OUT="$WORK/out.log"
WA_SCRIPT="$ROOT/scripts/test-land-canary-step.lua" "$WA_BIN" --db "$WORK/db.sqlite" >"$OUT" 2>&1
CODE=$?
VERDICT="$(grep -E 'land-canary-step (ok|FAILED)' "$OUT" | tail -1)"
if [ -z "$VERDICT" ]; then VERDICT="$(tail -2 "$OUT" | tr '\n' ' ')"; fi
echo "$VERDICT"
if [ "$CODE" -ne 0 ] || ! printf '%s' "$VERDICT" | grep -q ' ok ('; then
  echo "--- the row's own output ---"
  tail -20 "$OUT"
  exit 1
fi
exit 0
