#!/usr/bin/env bash
# A PROBE CHILD NEVER PROBES AGAIN (item 0 of the node-ops round, the 19/11 OOM).
#
# scripts/test-nodes-probe-instances.lua builds TWO real instances of lua/core/nodes.lua and proves the
# second one starts no probe children once the process is marked. The mark used to live on one M table,
# and fifteen dofile() callers each get their own - which is how one child fanned out into 1,653.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
# THIS TEST OWNS ITS DIRECTORY AND NEVER DELETES THE ROOT IT WAS GIVEN (review item 2). The old line
# was `SCRATCH="${WA_TEST_ROOT:-...}"; rm -rf "$SCRATCH"`, which deletes the ROOT itself when the
# operator set WA_TEST_ROOT - measured shape 11/11, and the review found it here. wa_test_workdir makes
# <root>/<name>.XXXXXX and refuses by name a root that is a home or carries .git/.wasm-agent.
. scripts/lib/scratch-home.sh
WA_ROOT="${WA_TEST_ROOT:-$(dirname "$ROOT")}"
SCRATCH="$(wa_test_workdir "$WA_ROOT" test-nodes-probe-instances)" || exit 2
mkdir -p "$SCRATCH/home" || exit 2
cleanup() { local s=$?; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
wa_scratch_home_guard "$SCRATCH/home" || exit 2
BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then
  # NO HARDCODED OPERATOR PATH (review item 3): this row was written on avell and named that machine's
  # build directory, so it silently skipped on every other node. WA_BIN first, then this tree's own build
  # (CARGO_TARGET_DIR, the variable the brief and the fast path both use), then PATH.
  for c in "$ROOT/rust/target/release/wa" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" "$(command -v wa || true)"; do
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
