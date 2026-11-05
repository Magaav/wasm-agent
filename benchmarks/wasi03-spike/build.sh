#!/bin/bash
# Build + run the WASI 0.3 spike (on wasm_the_first). Usage: build.sh [target-dir-prefix]
set -e
cd "$(dirname "$0")"
T=${1:-$PWD/target}
(cd guest && CARGO_TARGET_DIR=$T/guest cargo build --release --target wasm32-wasip2)
(cd runner && CARGO_TARGET_DIR=$T/runner cargo build --release)
G=$T/guest/wasm32-wasip2/release/wasi03_guest.wasm
ls -l "$G"
R=$T/runner/release/wasi03-runner
"$R" "$G" 10000 512 0
"$R" "$G" 100000 64 0
"$R" "$G" 200 4096 20000
