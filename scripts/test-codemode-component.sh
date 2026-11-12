#!/usr/bin/env bash
# The code-mode seam's parity run: build the `codemode` component, then drive the same scripts through
# the native loop and through the component (docs/CORE-SPLIT.md, docs/CODEMODE.md).
#
#   bash scripts/test-codemode-component.sh
#
# Local only: a temp WASM_AGENT_HOME, an empty rendezvous/relay, an unmanaged node and no `wa serve`.
# Nothing outside this clone and the cargo target dir is written, and no node on this machine is
# touched.
#
# What runs:
#   1. scripts/test-codemode-boundary.lua on the native path (the suite that has always run).
#   2. scripts/test-codemode-boundary.lua routed through the component: the *same* suite, unchanged,
#      with WA_CODEMODE_COMPONENT=1 — the strongest form of "identical on both paths".
#   3. scripts/test-codemode-component.lua: the seam's own parity suite, which compares the native and
#      component loops field for field (value, items, calls, attempts, unexecuted) and asserts the
#      fence's discovery on both.
#
# All three need the pinned code-mode assets (`quickjs.wasm`, `prelude.js`), because both paths run the
# real guest. Without them this wrapper reports SKIPPED once, and says why — a skip is never a pass, and
# `bash scripts/fast.sh` shows the same.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

bin="${WA_BIN:-}"
for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" \
         "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
         "${CARGO_TARGET_DIR:-/nonexistent}/debug/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/debug/wa" \
         "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ]; then
  echo "FAIL no wa binary (WA_BIN, \$CARGO_TARGET_DIR/{release,debug}, rust/target/release, PATH, ~/.local/bin)" >&2
  exit 2
fi

# The component, built for wasm32-wasip2 from this checkout.
TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/codemode.wasm"
echo "building rust/components/codemode (wasm32-wasip2) ..."
( cd rust/components/codemode && cargo build --release --offline --target wasm32-wasip2 ) || {
  echo "FAIL the codemode component did not build" >&2; exit 1; }
[ -f "$artifact" ] || { echo "FAIL no artifact at $artifact" >&2; exit 1; }

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
home=$(mktemp -d "${TMPDIR:-/tmp}/wa-codemode-component-XXXXXX")
trap 'rm -rf "$home"' EXIT

# `run <script> [EXTRA=value ...]`: one hermetic run - its own temp home, no node, no network, no real
# store - and the extra variables only for that run. The component is reached through the development
# override, so no install and no pin are involved.
run() {
  local script=$1; shift
  env "$@" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
    WASM_AGENT_HOME="$(native "$home")" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    WA_SCRIPT="$script" \
    timeout 900 "$bin" --db "$(native "$home/t.db")"
}

# Both paths run the real guest, so the assets decide whether anything can run at all. Asked once, here,
# so a missing provision is a SKIP with its reason rather than three failures.
probe="$home/probe.lua"
cat > "$probe" <<'LUA'
local json = dofile('lua/vendor/json.lua')
local answer = host.quickjs('ready', json.encode({}))
print('quickjs ' .. tostring(answer))
LUA
probe_log=$(run "$(native "$probe")" 2>&1)
if ! printf '%s' "$probe_log" | grep -q '"ok":true'; then
  echo "SKIPPED codemode seam: the pinned code-mode assets are not available to $bin"
  printf '  %s\n' "$probe_log"
  echo "  (provision with scripts/provision-codemode-assets.mjs and build with WA_CODEMODE_BUILD_ASSETS)"
  exit 0
fi

failed=0
check() { # label, log, status
  if [ "$3" -eq 0 ]; then echo "  $1: ok"; else echo "  $1: FAILED (exit $3, log above)"; failed=$((failed + 1)); fi
}

echo "== scripts/test-codemode-boundary.lua (native path) =="
boundary_native="$home/boundary-native.log"
run scripts/test-codemode-boundary.lua 2>&1 | tee "$boundary_native"
check "boundary native" "$boundary_native" "${PIPESTATUS[0]}"

echo "== scripts/test-codemode-boundary.lua (component path: the same suite, unchanged) =="
boundary_seam="$home/boundary-seam.log"
run scripts/test-codemode-boundary.lua "WA_CODEMODE_COMPONENT=1" "WA_CODEMODE_COMPONENT_WASM=$(native "$artifact")" 2>&1 | tee "$boundary_seam"
check "boundary component" "$boundary_seam" "${PIPESTATUS[0]}"
# A silent fallback would make this suite pass while proving nothing, so a fallback line from THE CODEMODE
# SEAM is a failure. The pattern names the seam: every seam logs the same words about its own fallback
# (`memory: sessions served natively: component_missing` is what a node with no memory component prints),
# so an unqualified `grep 'served natively'` reported a codemode fallback that never happened - measured
# on cf866fb5, 11/11, with both codemode paths green and the memory row saying it ran natively.
codemode_fallback() { grep -qE '(\]|^) ?codemode: .*served natively' "$1"; }
if codemode_fallback "$boundary_seam"; then
  echo "  FAILED the component path fell back to native:"; grep -E '(\]|^) ?codemode: .*served natively' "$boundary_seam" | head -3
  failed=$((failed + 1))
fi
# ...and the check can still fail: the line it looks for is the one the seam really prints.
printf '[lua] codemode: script served natively: component_missing\n' > "$home/fallback.fixture"
if ! codemode_fallback "$home/fallback.fixture"; then
  echo "  FAILED this check cannot see a codemode fallback even when one is printed"; failed=$((failed + 1))
fi
printf '[lua] memory: sessions served natively: component_missing\n' > "$home/fallback.other"
if codemode_fallback "$home/fallback.other"; then
  echo "  FAILED another component's native fallback is read as codemode's"; failed=$((failed + 1))
fi

echo "== scripts/test-codemode-component.lua (parity suite) =="
parity_log="$home/parity.log"
run scripts/test-codemode-component.lua "WA_CODEMODE_COMPONENT=1" "WA_CODEMODE_COMPONENT_WASM=$(native "$artifact")" 2>&1 | tee "$parity_log"
check "parity suite" "$parity_log" "${PIPESTATUS[0]}"

echo
if [ "$failed" -gt 0 ]; then
  echo "codemode seam FAILED ($failed)" >&2
  exit 1
fi
comparisons=$(sed -n 's/.*\([0-9][0-9]*\) parity comparisons.*/\1/p' "$parity_log" | tail -1)
if [ -z "${comparisons:-}" ] || [ "${comparisons:-0}" -lt 1 ]; then
  echo "codemode seam FAILED: the parity suite ran no comparisons" >&2
  exit 1
fi
echo "codemode seam ok ($comparisons parity comparisons ran)"
