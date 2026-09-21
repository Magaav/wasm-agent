#!/usr/bin/env bash
# Model-free executor timing: admission/setup, process spawn, child execution,
# cleanup/drain and durable output work. No live node or user command is touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
cargo run --release --offline --manifest-path rust/Cargo.toml -p wa-operation --example phase_bench
