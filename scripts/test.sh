#!/usr/bin/env bash
# Smoke test for the Rust+Lua wasm-agent: build, then exercise memory end to end.
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build --release --offline --manifest-path rust/Cargo.toml >/dev/null
BIN=rust/target/release/wa
DB="$(mktemp -u /tmp/wa-smoke-XXXXXX.db)"
trap 'rm -f "$DB" "$DB"-wal "$DB"-shm' EXIT

"$BIN" --db "$DB" init >/dev/null
ID="$("$BIN" --db "$DB" remember "smoke fact about the rust lua core")"
"$BIN" --db "$DB" recall smoke | grep -q "smoke fact"
"$BIN" --db "$DB" memories | grep -q "$ID"
"$BIN" --db "$DB" forget "$ID" | grep -q '"forgotten":true'
"$BIN" --db "$DB" memories | grep -q "(empty)"
"$BIN" --db "$DB" stats | grep -q '"memories":0'
echo "smoke ok"
