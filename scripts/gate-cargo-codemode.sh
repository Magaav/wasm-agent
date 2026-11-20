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
exec cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities codemode "$@"
