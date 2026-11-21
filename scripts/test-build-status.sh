#!/usr/bin/env bash
# A build is graded against the bytes it embeds, and a row inherits only what it was given (item 4, #45).
#
#   bash scripts/test-build-status.sh
#
# The Lua half is scripts/test-build-status.lua. The wrapper exists because the row needs a real binary
# and a real ledger, and it proves the scratch home is not the operator's before anything runs.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$(command -v wa || true)"
[ -x "$BIN" ] || { echo 'SKIP test-build-status: no wa binary to run the row with'; exit 0; }
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-build-status-$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/home" || exit 2
cleanup() { local s=$?; set +e; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
# The scratch home is compared against the RIGHT side (item 4 of the node-ops round):
# WASM_AGENT_HOME is the USER home (rust/wa-host-support/src/paths.rs:12), and the node store
# hangs off it as <home>/.wasm-agent. The guard refuses the real $HOME, the real store, anything
# inside it and anything above it - the measurements are in scripts/lib/scratch-home.sh.
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$SCRATCH/home" || exit 2
out="$(WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT=scripts/test-build-status.lua \
  "$BIN" --db "$SCRATCH/ledger.db" 2>&1)"
code=$?
printf '%s\n' "$out" | tail -4
[ "$code" = 0 ] || exit "$code"
printf '%s\n' "$out" | grep -q 'build status ok' || { echo 'test-build-status: the row exited 0 without its verdict line' >&2; exit 1; }
