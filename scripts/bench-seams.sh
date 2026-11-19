#!/usr/bin/env bash
# One measured table for every seam whose crossing is a capability call: p50/p99 per call, the
# bytes that cross, and how much of the call is JSON (Lua's encoder/decoder and serde's, on the
# same payload bytes) against the work itself (docs/missions/reports/seam-audit.md).
#
#   bash scripts/bench-seams.sh [--iterations N] [--json]
#
# Local only, and hermetic: a temp WASM_AGENT_HOME, a scratch ledger inside it, an empty
# rendezvous/relay, no node, no network, no model, no 'wa serve'. The one process it starts is the
# tree's own binary.
#
# A SEAM THAT CANNOT BE MEASURED HERE IS A SKIP WITH ITS REASON, never a zero in the table: the MCP
# row needs a configured server, and the codemode row is scripts/bench-codemode.sh's (it needs the
# guest VM and measures both paths).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

iterations=""
json_out=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --iterations) iterations="${2:?}"; shift 2 ;;
    --json) json_out=1; shift ;;
    *) echo "usage: bash scripts/bench-seams.sh [--iterations N] [--json]" >&2; exit 2 ;;
  esac
done

bin="${WA_BIN:-}"
for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" "$ROOT/rust/target/release/wa" \
         "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "FAIL no wa binary (build it, or set WA_BIN)" >&2; exit 2; }

home=$(mktemp -d "${TMPDIR:-/tmp}/wa-bench-seams-XXXXXX")
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/payloads"

echo "bench: seams (bin=$bin, iterations=${iterations:-200}, home=$home)"
echo
env WASM_AGENT_LUA_ROOT="$ROOT" \
    WASM_AGENT_HOME="$home" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    WA_SCRIPT=scripts/bench-seams.lua \
    WA_SEAM_ITERATIONS="${iterations:-200}" \
    WA_SEAM_PAYLOAD_DIR="$home/payloads" \
    "$bin" --db "$home/seams.db" 2>"$home/stderr.log" | tee "$home/lua.tsv" || {
  echo "FAIL the bench run failed:" >&2; tail -5 "$home/stderr.log" >&2; exit 1; }

echo
echo "--- serde cost on the same payload bytes (cargo run -p wa-host-support --example json-cost) ---"
if ( cd rust && cargo run --release --offline -q -p wa-host-support --example json-cost -- "$home/payloads" ) 2>"$home/serde.err"; then
  :
else
  echo "SKIP the serde half: the example did not run here (see below); the Lua half above stands on its own"
  tail -5 "$home/serde.err" >&2
fi
