#!/usr/bin/env bash
# The model gateway's OPTIMIZATION CHECK (docs/MODEL-GATEWAY.md, "Cost"): what one call costs through the
# seam, measured against the same request built directly, plus the process's peak RSS.
#
#   bash scripts/bench-model-gateway.sh
#
# Local only: no network, no provider, no node, nothing deployed. The example's transport answers in the
# same instant, so the numbers isolate the seam's own work (the provider's latency is not in them).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
echo "bench: model gateway added latency (cargo run -p wa-model-gateway --release --example gateway-overhead)"
cargo run --offline --release -q -p wa-model-gateway --example gateway-overhead
