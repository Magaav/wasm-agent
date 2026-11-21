#!/usr/bin/env bash
# A REAL NODE PROBES A REAL PEER (review r2, B: one real-wa row with a stub peer).
#
# Every other probe row stubs host.operation, so it never leaves the process: a probe path that sends no
# owner, or a wait_s the host ignores, passes there and fails in the field. This row starts a stub
# rendezvous whose ONE reachable peer answers capabilities over HTTP, runs the REAL wa binary against it,
# and asserts the answer comes back.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
command -v node >/dev/null 2>&1 || { echo "SKIP test-nodes-probe-real: no node for the peer stub"; exit 0; }
. scripts/lib/scratch-home.sh
WA_ROOT="${WA_TEST_ROOT:-}"
if [ -z "$WA_ROOT" ]; then
  WA_ROOT="$(wa_scratch_root test-nodes-probe-real 2>/dev/null)" || { echo "SKIP test-nodes-probe-real: no scratch root"; exit 0; }
fi
SCRATCH="$(wa_test_workdir "$WA_ROOT" probe-real)" || exit 2
stub_pid=
cleanup() { [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
mkdir -p "$SCRATCH/home" || exit 2
wa_scratch_home_guard "$SCRATCH/home" || exit 2

BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then for c in "$ROOT/rust/target/release/wa" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" "$(command -v wa || true)"; do [ -x "$c" ] && BIN="$c" && break; done; fi
[ -n "$BIN" ] || { echo "SKIP test-nodes-probe-real: no wa binary (set WA_BIN)"; exit 0; }

cp "$ROOT/scripts/lib/nodes-probe-real-stub.mjs" "$SCRATCH/stub.mjs" 2>/dev/null || { echo "SKIP test-nodes-probe-real: the peer stub is not in this tree"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP test-nodes-probe-real: no curl to wait on the stub"; exit 0; }
node "$SCRATCH/stub.mjs" "$SCRATCH/port" >"$SCRATCH/stub.log" 2>&1 &
stub_pid=$!
i=0; while [ ! -s "$SCRATCH/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$SCRATCH/port" ] || { echo "test-nodes-probe-real: the stub printed no port: $(head -c 300 "$SCRATCH/stub.log" 2>/dev/null)" >&2; exit 1; }
port="$(cat "$SCRATCH/port")"

out="$(WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$ROOT" \
  WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$port" WASM_AGENT_MANAGED=0 \
  "$BIN" --db "$SCRATCH/home/t.db" nodes list 2>&1)"
code=$?
[ "$code" = 0 ] || { echo "test-nodes-probe-real: nodes list failed (exit $code): $out" >&2; exit 1; }

# THE REACHABLE PEER IS REPORTED WITH ITS CAPABILITIES: the answer came back over HTTP through the real
# probe path. A path that sends no owner is refused by the host and answered probe_leaseholder_pending.
case "$out" in
  *\"stub-peer\"*) ;;
  *) echo "test-nodes-probe-real: the stub peer is not in the roster: $out" >&2; exit 1 ;;
esac
case "$out" in
  *bash*) ;;
  *) echo "test-nodes-probe-real: the reachable peer reported no capabilities: $out" >&2; exit 1 ;;
esac
# And it says the answer was ASKED, not that it gave up waiting.
case "$out" in
  *probe_timeout*|*probe_leaseholder_pending*)
    echo "test-nodes-probe-real: a reachable peer was left waiting: $out" >&2; exit 1 ;;
esac

echo "test-nodes-probe-real: ok (a real node probed a stub peer over HTTP and got its capabilities back: asked, not probe_timeout or probe_leaseholder_pending)"