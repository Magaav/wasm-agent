#!/usr/bin/env bash
# A PROBE CHILD NEVER PROBES AGAIN (item 0 of the node-ops round, the 19/11 OOM).
#
# scripts/test-nodes-probe-instances.lua builds TWO real instances of lua/core/nodes.lua and proves the
# second one starts no probe children once the process is marked. The mark used to live on one M table,
# and fifteen dofile() callers each get their own - which is how one child fanned out into 1,653.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-nodes-probe-instances-$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/home" || exit 2
cleanup() { local s=$?; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
. scripts/lib/scratch-home.sh
wa_scratch_home_guard "$SCRATCH/home" || exit 2
BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then
  for c in "$ROOT/rust/target/release/wa" "/home/victor/wasm-agent/target/m-node-ops/release/wa"; do
    [ -x "$c" ] && BIN="$c" && break
  done
fi
[ -n "$BIN" ] || { echo 'SKIP test-nodes-probe-instances: no wa binary (set WA_BIN)'; exit 0; }
out="$(WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WA_NODES_PROBE_CHILD= WA_SCRIPT="$ROOT/scripts/test-nodes-probe-instances.lua" "$BIN" --db "$SCRATCH/home/t.db" 2>&1)"
code=$?
printf '%s\n' "$out"
[ "$code" = 0 ] || exit "$code"
case "$out" in
  *'nodes probe instances ok'*) ;;
  *) echo 'test-nodes-probe-instances: the row exited 0 without its verdict line' >&2; exit 1 ;;
esac
