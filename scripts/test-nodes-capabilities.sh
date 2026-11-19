#!/usr/bin/env bash
# tools.nodes reports each peer's live accepted capabilities, in a scratch home this script owns.
#
#   bash scripts/test-nodes-capabilities.sh
#
# The Lua half is scripts/test-nodes-capabilities.lua. The wrapper exists because the row needs a real
# binary and a real ledger, and it proves the scratch home is not the operator's before anything runs
# (the row asserts it again from inside).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$(command -v wa || true)"
[ -x "$BIN" ] || { echo 'SKIP test-nodes-capabilities: no wa binary to run the row with'; exit 0; }
# Beside the repo, never under it, and never /tmp on a node where /tmp is a small tmpfs (measured 19/11:
# SQLite answered 'disk I/O error' at 80% full and it looked like a defect in the code under test).
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-nodes-caps-$$}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home" || exit 2
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
home="$SCRATCH/home"
case "$(CDPATH= cd -- "$home" && pwd)" in
  "$(CDPATH= cd -- "${HOME:-/nonexistent}" && pwd)"/.wasm-agent)
    echo 'test-nodes-capabilities: refused(real_node_home): the scratch home resolved to the operator'"'"'s own ~/.wasm-agent' >&2
    exit 2 ;;
esac
out="$(WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT=scripts/test-nodes-capabilities.lua \
  "$BIN" --db "$SCRATCH/ledger.db" 2>&1)"
code=$?
printf '%s\n' "$out" | tail -5
[ "$code" = 0 ] || exit "$code"
printf '%s\n' "$out" | grep -q 'nodes capabilities ok' || { echo 'test-nodes-capabilities: the row exited 0 without its verdict line' >&2; exit 1; }
