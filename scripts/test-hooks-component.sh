#!/usr/bin/env bash
# The hooks seam's parity run: build the `hooks` component, then drive the same events through the
# native core (`lua/core/hooks.lua`) and through the component (docs/CORE-SPLIT.md,
# docs/HOOK-EVENTS.md "The engine as a component").
#
#   bash scripts/test-hooks-component.sh
#
# Local only: a temp WASM_AGENT_HOME, an empty rendezvous/relay, an unmanaged node and no `wa serve`.
# Nothing outside this clone and the cargo target dir is written, and no node on this machine is
# touched.
#
# The Lua test needs `WA_HOOKS_COMPONENT_WASM` in the *process* environment - the host resolves the
# artifact override from the environment, not from a script - so this wrapper is what makes the
# component half run. Without it the test reports the component half SKIPPED, which is exactly what
# `bash scripts/fast.sh` shows for it.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

bin="${WA_BIN:-}"
# This checkout's own build first: the installed binary may predate the `hooks` capability, and a
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
artifact="$TARGET/wasm32-wasip2/release/hooks.wasm"
echo "building rust/components/hooks (wasm32-wasip2) ..."
( cd rust/components/hooks && cargo build --release --offline --target wasm32-wasip2 ) || {
  echo "FAIL the hooks component did not build" >&2; exit 1; }
[ -f "$artifact" ] || { echo "FAIL no artifact at $artifact" >&2; exit 1; }

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-hooks-component-XXXXXX")
trap 'rm -rf "$work"' EXIT

# `run <script> [EXTRA=value ...]`: one hermetic run - **its own** temp home, because a suite that
# writes a config must not find the previous suite's - no node, no network, no real store, and the
# extra variables only for that run.
run() {
  local script=$1; shift
  local home
  home=$(mktemp -d "$work/home-XXXXXX")
  env "$@" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
    WASM_AGENT_HOME="$(native "$home")" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    WA_SCRIPT="$script" \
    timeout 600 "$bin" --db "$(native "$home/t.db")"
}

status=0
# 1. The engine's own suites on the native path (the default: no seam). They are the reference the
#    parity suite compares against, so a native regression has to be visible before the comparison.
for suite in scripts/test-hooks-engine.lua scripts/test-hooks-tools.lua scripts/test-hooks-agent.lua \
             scripts/test-hooks-mods.lua; do
  echo "== $suite (native path) =="
  run "$suite" || { echo "FAIL $suite on the native path" >&2; status=1; }
done

# 2. The same suites through the component: the seam must answer their decisions too.
for suite in scripts/test-hooks-engine.lua scripts/test-hooks-tools.lua scripts/test-hooks-agent.lua \
             scripts/test-hooks-mods.lua; do
  echo "== $suite (component path) =="
  run "$suite" "WA_HOOKS_COMPONENT=1" "WA_HOOKS_COMPONENT_WASM=$(native "$artifact")" || {
    echo "FAIL $suite through the component" >&2; status=1; }
done

# 3. The parity suite itself.
echo "== scripts/test-hooks-component.lua (native + component) =="
seam_log="$work/seam.log"
run scripts/test-hooks-component.lua "WA_HOOKS_COMPONENT=1" "WA_HOOKS_COMPONENT_WASM=$(native "$artifact")" | tee "$seam_log"
seam_status=${PIPESTATUS[0]}
# A SKIP is not a pass: if the comparisons did not run, this wrapper has not tested the seam - usually
# because the binary it found predates the capability (point WA_BIN or CARGO_TARGET_DIR at a build of
# this tree).
ran=$(sed -n 's/.* \([0-9][0-9]*\) parity comparisons (ran).*/\1/p' "$seam_log" | tail -1)
if [ "$seam_status" = 0 ] && [ "${ran:-0}" -lt 20 ]; then
  echo "FAIL the component half did not run against $bin (${ran:-0} parity comparisons, need at least 20)" >&2
  seam_status=1
fi

if [ "$status" = 0 ] && [ "$seam_status" = 0 ]; then
  echo "hooks seam ok (${ran:-0} parity comparisons)"
  exit 0
fi
echo "hooks seam FAILED (native $status, component $seam_status)" >&2
exit 1
