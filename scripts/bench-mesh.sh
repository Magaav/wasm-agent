#!/usr/bin/env bash
# What one mesh decision costs on each path (`docs/MESH.md`, "Cost"; `docs/CORE-SPLIT.md`).
#
#   bash scripts/bench-mesh.sh [--offline]
#
# Three runs of the same measurement, one process each (a resident set is a property of a process, and the
# switch is a process variable):
#
#   native     — `wa_mesh_core`'s rule in the node, no guest at all;
#   component  — every routed operation through the built `mesh` artifact (`WA_MESH_COMPONENT=1`);
#   decisions  — only the policy answers routed (`WA_MESH_COMPONENT_OPS=decide,verify_roster,
#                verify_ticket,attest_message`), with the audit line and the dial order left native.
#
# The third run exists because the measurement says the operations are not equally worth a guest call: a
# decision is a rule an operator may want to swap, an audit line is formatting, and the seam costs the
# same either way (`docs/MESH.md`, "Cost", records which default the numbers support).
#
# The measurement is the bench in `rust/wa-mesh/src/bench.rs` (`#[ignore]`d, so a normal test run says
# "ignored" instead of quietly measuring nothing): p50/p95 per call in microseconds, the first call's
# compile+instance cost, and the process's peak resident set. Local only: no node, no socket, no network,
# no `wa serve`, no model.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
offline=""
[ "${1:-}" = "--offline" ] && offline="--offline"

TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/mesh.wasm"
manifest="$ROOT/rust/components/mesh/manifest.json"
if [ ! -f "$artifact" ]; then
  echo "building rust/components/mesh (wasm32-wasip2) ..."
  ( cd rust/components/mesh && cargo build --release $offline --target wasm32-wasip2 ) || exit 1
fi

# One measured run. The bench prints one TSV line per scenario; nothing here post-processes it.
measure() {
  local label=$1
  shift
  echo "== $label"
  env "$@" cargo test --manifest-path "$ROOT/rust/Cargo.toml" -p wa-mesh --release $offline \
    -- --ignored --nocapture mesh_seam 2>&1 \
    | grep -E "^(native|component)\s" | tee "$TARGET/mesh-bench-$label.tsv"
  [ "${PIPESTATUS[0]}" -eq 0 ] || echo "FAIL the $label bench did not run" >&2
}

measure native
measure component \
  WA_MESH_COMPONENT=1 \
  "WA_MESH_COMPONENT_WASM=$artifact" \
  "WA_MESH_COMPONENT_MANIFEST=$manifest"
measure decisions \
  WA_MESH_COMPONENT=1 \
  WA_MESH_COMPONENT_OPS="decide,verify_roster,verify_ticket,attest_message" \
  "WA_MESH_COMPONENT_WASM=$artifact" \
  "WA_MESH_COMPONENT_MANIFEST=$manifest"
