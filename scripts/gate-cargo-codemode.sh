#!/usr/bin/env bash
# The gate's cargo-codemode check: the code-mode Rust tests in the release profile, with the code-mode assets
# resolved THE WAY scripts/fast.sh resolves them (scripts/lib/fast-binary.sh fast_binary_assets: the caller's
# WA_CODEMODE_BUILD_ASSETS, else the clone's <git-common-dir>/codemode-assets). wa-capabilities/build.rs refuses a
# release build without them, and the gate ran a bare `cargo test --release` that passed only when whoever
# launched `wa land` happened to export the variable (gate 20/11, land68: "code-mode assets required").
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. scripts/lib/fast-binary.sh
fast_binary_assets
if [ -z "$FAST_CODEMODE_ASSETS" ]; then
  echo "FAIL cargo-codemode: no code-mode assets (WA_CODEMODE_BUILD_ASSETS unset and none prepared under the clone's codemode-assets); prepare them with: node scripts/codemode-build.mjs build" >&2
  exit 1
fi
export WA_CODEMODE_BUILD_ASSETS="$FAST_CODEMODE_ASSETS"
# WHERE IT BUILDS: this tree's ONE named build dir (scripts/lib/build-target.sh), the same directory
# scripts/fast.sh built `cargo test --release -p wa-capabilities` into minutes earlier in the same gate.
# This script used to name no CARGO_TARGET_DIR, so cargo cold-built a SECOND copy of the workspace into the
# landing tree's rust/target: 138 s of every landing (land-20261121T210239Z-fd11e699) for tests that take
# seconds. A caller that names CARGO_TARGET_DIR keeps it, and WASM_AGENT_SHARED_BUILD_DIR=0 still means
# rust/target (fast_binary_target_dir: one rule, the fast path's own).
. scripts/lib/build-target.sh || { echo "FAIL cargo-codemode: scripts/lib/build-target.sh cannot be loaded" >&2; exit 1; }
codemode_target=$(fast_binary_target_dir)
if [ -z "${CARGO_TARGET_DIR:-}" ] && [ "$codemode_target" != "$ROOT/rust/target" ]; then
  # The sweep, the cap and the `tree` marker `wa clean` judges a build dir by - for a run of this script
  # alone; after scripts/fast.sh the directory already exists and this only refreshes the markers.
  wa_build_prepare "$ROOT" --quiet >/dev/null || { echo "FAIL cargo-codemode: cannot prepare the build dir $codemode_target" >&2; exit 1; }
fi
echo "cargo-codemode: target $codemode_target" >&2
# The COMPILE waits on the node's one build lock (one heavy build at a time); the tests then run outside
# it, the way the fast path's Rust rows do. `--no-run` compiles exactly what the next line runs.
build_started=$(date +%s)
CARGO_TARGET_DIR="$codemode_target" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(wa_build_jobs)}" wa_build_host_lock \
  cargo test --no-run --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities >&2 || {
    echo "FAIL cargo-codemode: the test build failed (target $codemode_target)" >&2; exit 1; }
echo "cargo-codemode: test build $(( $(date +%s) - build_started ))s" >&2
CARGO_TARGET_DIR="$codemode_target" exec cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities codemode "$@"
