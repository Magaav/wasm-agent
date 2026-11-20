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

# WHICH BINARY, and never a silent one. A bench whose binary came from another tree reports another
# tree's code: measured here 20/11, a run whose environment lacked CARGO_TARGET_DIR fell through to an
# installed ~/.local/bin/wa and produced a table for a binary built commits ago - the stale-artifact
# failure scripts/lib/fast-binary.sh exists to stop, one layer down. So there is no PATH fallback: the
# tree's own build, or WA_BIN, or a refusal that names the build.
bin="${WA_BIN:-}"
if [ -z "$bin" ]; then
  for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" "$ROOT/rust/target/release/wa"; do
    [ -n "$c" ] && [ -x "$c" ] && bin="$c" && break
  done
fi
[ -n "$bin" ] || {
  echo "FAIL no wa binary from this tree (looked at ${CARGO_TARGET_DIR:-<unset>}/release/wa and $ROOT/rust/target/release/wa)." >&2
  echo "     Build it:  (in rust/) CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<dir>} cargo build --release --offline -p wa-host" >&2
  echo "     Or name one: WA_BIN=<path> bash scripts/bench-seams.sh" >&2
  echo "     A binary from PATH is refused on purpose: a table measured against another tree's code is not this tree's." >&2
  exit 2
}
stamp=$("$bin" --build-info 2>/dev/null | awk -F= '/^commit=/{print $2}')
[ -n "$stamp" ] || { echo "FAIL $bin does not answer --build-info; refusing to measure an unidentified binary" >&2; exit 2; }

home=$(mktemp -d "${TMPDIR:-/tmp}/wa-bench-seams-XXXXXX")
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/payloads"

echo "bench: seams (bin=$bin, binary-commit=$stamp, iterations=${iterations:-200}, home=$home)"
echo "bench: seam rows are os.clock (CPU) on this machine; codemode/mesh/fabric are those benches' own clocks"
echo
# THE VAULT ROW MEASURES A STUB OR NOTHING. `WASM_AGENT_VAULT_URL` is exported on a node that runs
# wa-serve, and inheriting it made this bench send 200+ GET /status calls to the REAL vault on every
# run (found in review r2). It is cleared here; a caller who wants the row names the bench's own stub
# with `WA_SEAM_VAULT_URL`, which is the only value that reaches the script.
vault_env=WASM_AGENT_VAULT_URL=
if [ -n "${WA_SEAM_VAULT_URL:-}" ]; then vault_env="WASM_AGENT_VAULT_URL=$WA_SEAM_VAULT_URL"; fi
env WASM_AGENT_LUA_ROOT="$ROOT" \
    WASM_AGENT_HOME="$home" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    "$vault_env" \
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
