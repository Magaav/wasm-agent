#!/usr/bin/env bash
# The stt seam's row: build the `stt` component, then prove the seam against it.
#
#   bash scripts/test-stt-seam.sh [--offline]
#
# What it proves, in order:
#   1. **The crate's own rules** — `cargo test -p wa-stt-remote` (the wire, the policy, the loops).
#   2. **The seam's happy path** — `cargo test -p wa-kernel-runtime stt_host::` with the built artifact
#      named: the guest admits one call, refuses its own replay from its own ledger, and refuses a caller
#      that is not one of the owner's nodes. Without the artifact that test SKIPS (and says so); this
#      script builds it, so here it runs.
#   3. **The five capabilities' answers** — `scripts/test-stt-seam-answers.lua` against
#      `fixtures/stt-seam-answers.txt`, recorded on the pre-move build: the model-facing and operator-facing
#      shapes of `host.stt_call/submit/admin/pending/deliver`, byte for byte.
#
# Local only: a temp WASM_AGENT_HOME, an empty rendezvous and relay, no model, no serve, no port.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
offline=""
[ "${1:-}" = "--offline" ] && offline="--offline"
TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/stt.wasm"
status=0

# 0. **The async rule as a row, not a reading** (Victor 26/11): every export in the interface is an
#    \`async func\`, or a sync \`func\` with a "SYNC ON PURPOSE" reason line above it; and the world either
#    declares an output/progress stream or writes why it has none. Static: no build, no toolkit.
WIT="$ROOT/wit/stt/stt.wit"
sync_exports=$(grep -cE '^[[:space:]]+[a-z][a-z0-9-]*:[[:space:]]+func\(' "$WIT" || true)
async_exports=$(grep -cE '^[[:space:]]+[a-z][a-z0-9-]*:[[:space:]]+async func\(' "$WIT" || true)
reasons=$(grep -c 'SYNC ON PURPOSE' "$WIT" || true)
if [ "$async_exports" -lt 1 ]; then
  echo "FAIL wit/stt has no async export: the async rule says a new interface is born async" >&2; status=1
fi
if [ "$sync_exports" -ne "$reasons" ]; then
  echo "FAIL wit/stt has $sync_exports sync export(s) and $reasons \"SYNC ON PURPOSE\" reason line(s): a sync export needs its written reason" >&2
  status=1
fi
if ! grep -qE 'stream<|no output stream' "$WIT"; then
  echo "FAIL wit/stt neither declares an output/progress stream nor writes why it has none" >&2; status=1
fi
if [ "$status" -eq 0 ]; then
  echo "  async rule: $async_exports async export(s); $sync_exports sync with its reason line; stream-or-reason declared"
fi

echo "== building rust/components/stt (wasm32-wasip2)"
( cd rust/components/stt && cargo build --release $offline --target wasm32-wasip2 --target-dir "$TARGET" ) || {
  echo "FAIL the stt component did not build" >&2; exit 1; }
[ -f "$artifact" ] || { echo "FAIL no artifact at $artifact" >&2; exit 1; }

# The rows below get their artifact the way the node does: the installed component set. This script
# prepares one (the built artifact, its pin, its manifest) and points the node's component dir at it.
# No product code reads a path from the environment; the seam loads what is installed, pinned and
# verified, exactly as it does on a real node.
components=$(mktemp -d "${TMPDIR:-/tmp}/wa-stt-seam-components-XXXXXX")
trap 'rm -rf "$components"' EXIT
cp "$artifact" "$components/stt.wasm"
sha256sum "$components/stt.wasm" | cut -d' ' -f1 > "$components/stt.wasm.sha256"
cp rust/components/stt/manifest.json "$components/stt.json"
export WA_COMPONENTS_DIR="$components"

echo "== cargo test -p wa-stt-remote"
cargo test --release $offline --manifest-path rust/Cargo.toml -p wa-stt-remote || status=1

echo "== cargo test -p wa-kernel-runtime stt_host:: (the seam's happy path, against the installed set)"
cargo test --release $offline --manifest-path rust/Cargo.toml -p wa-kernel-runtime stt_host:: || status=1

# The node-level case the module test binary cannot hold: the switch is process-global, so it lives in
# a test target of its own. A configured node take is admitted by the guest, its replay is refused from
# the component ledger, and no fallback line may appear.
echo "== cargo test -p wa-kernel-runtime --test stt_node_routed (a configured node, routed)"
cargo test --release $offline --manifest-path rust/Cargo.toml -p wa-kernel-runtime --test stt_node_routed || status=1
bin="${WA_BIN:-}"
for c in "$TARGET/release/wa" "$ROOT/rust/target/release/wa" "$(command -v wa 2>/dev/null)"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ]; then
  echo "== scripts/test-stt-seam-answers.lua SKIPPED (no wa binary: set WA_BIN or build rust/wa-host)"
else
  echo "== scripts/test-stt-seam-answers.lua"
  home=$(mktemp -d "${TMPDIR:-/tmp}/wa-stt-seam-XXXXXX")
  trap 'rm -rf "$home" "$components"' EXIT
  # Twice: with no component (the native rule answering) and with it installed (the seam answering), so
  # the same bytes are held to both paths.
  for mode in native component; do
    dir=""
    [ "$mode" = component ] && dir="$components"
    out=$($([ -n "$dir" ] && printf 'env WA_COMPONENTS_DIR=%s' "$dir" || printf 'env -u WA_COMPONENTS_DIR') \
      "WASM_AGENT_LUA_ROOT=$ROOT" "WASM_AGENT_HOME=$home" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
      "WA_SCRIPT=$ROOT/scripts/test-stt-seam-answers.lua" \
      timeout 300 "$bin" --db "$home/t.db" 2>&1)
    echo "$out" | tail -2
    echo "$out" | grep -q 'stt seam answers ok' || { echo "  FAILED the $mode path"; status=1; }
    rm -rf "$home"; mkdir -p "$home"
  done
fi

echo "== stt seam: $([ $status -eq 0 ] && echo ok || echo FAILED)"
exit $status
