#!/usr/bin/env bash
# Peer probing runs AT ONCE, through supervised processes (item 10 of the node-ops round).
#
#   bash scripts/test-nodes-probe-parallel.sh
#
# The row is scripts/test-nodes-probe-parallel.lua: it stubs the host (nodes.lua reads the global host, so
# the stub IS the interface) and proves every child was STARTED before the first was awaited. This wrapper
# exists for the harness two reasons, not the test: the row needs a real binary and its own home, and that
# home must be proven not to be the operator home before anything runs.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$(command -v wa || true)"
[ -x "$BIN" ] || { echo 'SKIP test-nodes-probe-parallel: no wa binary to run the row with'; exit 0; }
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-nodes-probe-$$}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home/.wasm-agent" || exit 2
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$SCRATCH/home" || exit 2
out="$(WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_MANAGED=0 \
  WA_SCRIPT=scripts/test-nodes-probe-parallel.lua \
  "$BIN" --db "$SCRATCH/ledger.db" 2>&1)"
code=$?
printf '%s\n' "$out" | tail -3
[ "$code" = 0 ] || exit "$code"
printf '%s\n' "$out" | grep -q 'nodes probe parallel ok' || { echo 'test-nodes-probe-parallel: the row exited 0 without its verdict line' >&2; exit 1; }
