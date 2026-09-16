#!/usr/bin/env bash
# Build the WASM UI renderer into ui/render.wasm.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

cargo build --manifest-path rust/ui-wasm/Cargo.toml --target wasm32-unknown-unknown --release --offline >/dev/null
cp rust/ui-wasm/target/wasm32-unknown-unknown/release/wa_ui.wasm ui/render.wasm
echo "built ui/render.wasm ($(wc -c < ui/render.wasm) bytes)"
