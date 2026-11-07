#!/usr/bin/env bash
# The self-loop seam's parity run: build the `selfloop` component, then drive the same calls through
# the native core and through the component (docs/CORE-SPLIT.md; docs/KERNEL.md "The self-loop as a
# component").
#
#   bash scripts/test-selfloop-component.sh
#
# Local only: a temp WASM_AGENT_HOME, an empty rendezvous/relay, an unmanaged node and no `wa serve`.
# Nothing outside this clone and the cargo target dir is written, and no node on this machine is
# touched.
#
# The Lua test needs `WA_SELFLOOP_COMPONENT_WASM` in the *process* environment - the host resolves the
# artifact override from the environment, not from a script - so this wrapper is what makes the
# component half run. Without it the test reports the component half SKIPPED, which is exactly what
# `bash scripts/fast.sh` shows for it.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

bin="${WA_BIN:-}"
# This checkout's own build first: the installed binary may predate the `selfloop` capability, and a
# parity run against it would SKIP while looking like it had examined the seam.
for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" \
         "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
         "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ]; then
  echo "FAIL no wa binary (WA_BIN, \$CARGO_TARGET_DIR/release, rust/target/release, PATH, ~/.local/bin)" >&2
  exit 2
fi

# The component, built for wasm32-wasip2 from this checkout.
TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/selfloop.wasm"
echo "building rust/components/selfloop (wasm32-wasip2) ..."
( cd rust/components/selfloop && cargo build --release --offline --target wasm32-wasip2 ) || {
  echo "FAIL the selfloop component did not build" >&2; exit 1; }
[ -f "$artifact" ] || { echo "FAIL no artifact at $artifact" >&2; exit 1; }

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
home=$(mktemp -d "${TMPDIR:-/tmp}/wa-selfloop-component-XXXXXX")
trap 'rm -rf "$home"' EXIT

# `run <script> [EXTRA=value ...]`: one hermetic run - its own temp home, no node, no network, no real
# store - and the extra variables only for that run.
run() {
  local script=$1; shift
  env "$@" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
    WASM_AGENT_HOME="$(native "$home")" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    WA_SCRIPT="$script" \
    timeout 300 "$bin" --db "$(native "$home/t.db")"
}

# 1. The native suite on the native path (the default: no seam).
echo "== scripts/test-selfloop.lua (native path) =="
run scripts/test-selfloop.lua
native_status=$?

# 2. The parity suite, with the component reachable.
echo "== scripts/test-selfloop-component.lua (native + component) =="
seam_log="$home/seam.log"
run scripts/test-selfloop-component.lua "WA_SELFLOOP_COMPONENT_WASM=$(native "$artifact")" | tee "$seam_log"
seam_status=${PIPESTATUS[0]}
# A SKIP is not a pass: if the parity comparisons did not run, this wrapper has not tested the seam -
# usually because the binary it found predates the capability (point WA_BIN or CARGO_TARGET_DIR at a
# build of this tree).
if [ "$seam_status" = 0 ] && ! grep -q 'parity comparisons (ran)' "$seam_log"; then
  echo "FAIL the component half did not run against $bin (no host.selfloop, or no artifact)" >&2
  seam_status=1
fi

if [ "$native_status" = 0 ] && [ "$seam_status" = 0 ]; then
  echo "selfloop seam ok"
  exit 0
fi
echo "selfloop seam FAILED (native $native_status, component $seam_status)" >&2
exit 1
