#!/usr/bin/env bash
# The mesh seam's parity run (`docs/MESH.md`, "The mesh as a component"; `docs/CORE-SPLIT.md`).
#
#   bash scripts/test-mesh-component.sh [--offline]
#
# What it proves, in order:
#
#   1. **The native default is unchanged.** `cargo test -p wa-mesh` with no `WA_MESH_COMPONENT` — the whole
#      suite: the unit tests of the roster, the grants, the cache and the audit lines, the three-node
#      end-to-end file, the four-node relay case (`tests_relay.rs`, A(0)/B(1)/T(1)/R behind a relay with
#      no address) and the generated shapes of both envelopes.
#   2. **The same suite, every decision routed through the guest.** The same command with
#      `WA_MESH_COMPONENT=1` and the built artifact. It must pass with the *same number of tests*, and it
#      must print **no** `decided natively` line: that line is what a failed or missing component logs,
#      so its absence is the evidence that the guest answered rather than the fallback.
#   3. **The answers are the same answers.** `rust/wa-mesh/src/tests_component.rs` runs in both of those
#      runs and compares the component's answer with the native rule field for field: every caller/target/
#      verb pair, the refusal *sentence* of a tampered roster (`roster_unverified:bad_signature`), every
#      audit-line shape, the dial order, the composed attestation and every ticket refusal slug.
#   4. **The capability is wired.** `scripts/test-mesh-component.lua` drives `host.mesh` through the real
#      interpreter (skipped, and said so, when this checkout has no `wa` binary).
#
# Local only, as the job's hard rule says: a temp `WASM_AGENT_HOME`, an empty rendezvous and relay,
# `WASM_AGENT_MANAGED=0`, no model, no `wa serve`, no port. Nothing outside this clone and
# `$CARGO_TARGET_DIR` is written, and no process this script did not start is touched.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
offline=""
[ "${1:-}" = "--offline" ] && offline="--offline"
status=0

TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/mesh.wasm"
manifest="$ROOT/rust/components/mesh/manifest.json"
if [ ! -f "$artifact" ]; then
  echo "== building rust/components/mesh (wasm32-wasip2)"
  ( cd rust/components/mesh && cargo build --release $offline --target wasm32-wasip2 ) || {
    echo "FAIL the mesh component did not build" >&2; exit 1; }
fi
[ -f "$artifact" ] || { echo "FAIL no artifact at $artifact" >&2; exit 1; }

# One suite run: the passed count, and whether any decision fell back to the native path.
run_suite() {
  local label=$1 log="$TARGET/mesh-suite-$1.log"
  shift
  echo "== cargo test -p wa-mesh ($label)"
  env "$@" cargo test --manifest-path "$ROOT/rust/Cargo.toml" -p wa-mesh $offline > "$log" 2>&1
  local rc=$?
  local passed
  passed=$(grep -oE 'test result: ok\. [0-9]+ passed' "$log" | head -1 | grep -oE '[0-9]+' | head -1)
  local fallbacks
  fallbacks=$(grep -c 'decided natively' "$log" || true)
  local skipped
  skipped=$(grep -c 'SKIPPED' "$log" || true)
  if [ $rc -ne 0 ]; then
    echo "FAIL the $label suite:"
    grep -E '^(test .* FAILED|error|thread )' "$log" | head -30
    status=1
  fi
  echo "   passed=$passed fallbacks=$fallbacks skipped-lines=$skipped ($log)"
  printf '%s\t%s\t%s\n' "$label" "$passed" "$fallbacks" >> "$TARGET/mesh-suite-summary.tsv"
}

rm -f "$TARGET/mesh-suite-summary.tsv"
run_suite native
run_suite component \
  WA_MESH_COMPONENT=1 \
  "WA_MESH_COMPONENT_WASM=$artifact" \
  "WA_MESH_COMPONENT_MANIFEST=$manifest"

native_passed=$(awk -F'\t' '$1=="native" {print $2}' "$TARGET/mesh-suite-summary.tsv")
native_fallbacks=$(awk -F'\t' '$1=="native" {print $3}' "$TARGET/mesh-suite-summary.tsv")
component_passed=$(awk -F'\t' '$1=="component" {print $2}' "$TARGET/mesh-suite-summary.tsv")
component_fallbacks=$(awk -F'\t' '$1=="component" {print $3}' "$TARGET/mesh-suite-summary.tsv")

# The two runs must have run the same tests, and the component run must have had nothing fall back: a
# guest that failed once would leave a `decided natively` line, and every routed decision after it would
# still pass *natively*, so "it passed" alone is not evidence for the seam.
if [ -z "$component_passed" ]; then
  echo "FAIL the component run reported no passed tests"; status=1
elif [ "$component_passed" != "$native_passed" ]; then
  echo "FAIL the two runs ran different numbers of tests: native=$native_passed component=$component_passed"
  status=1
else
  echo "== parity: $native_passed tests on both paths"
fi
if [ "$component_fallbacks" != "0" ]; then
  echo "FAIL $component_fallbacks decision(s) fell back to the native path in the component run:"
  grep 'decided natively' "$TARGET/mesh-suite-component.log" | head -5
  status=1
else
  echo "== the guest answered every routed decision (no fallback lines)"
fi
case "$native_fallbacks" in
  0) ;;
  *) echo "FAIL the native run logged fallbacks without the switch on: $native_fallbacks"; status=1 ;;
esac

# The capability, through the real interpreter.
bin="${WA_BIN:-}"
for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" \
         "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
         "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ]; then
  echo "== scripts/test-mesh-component.lua SKIPPED (no wa binary: set WA_BIN or build rust/wa-host)"
else
  native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
  echo "== scripts/test-mesh-component.lua"
  home=$(mktemp -d "${TMPDIR:-/tmp}/wa-mesh-component-XXXXXX")
  # `env` rather than a prefix assignment list: a Windows path inside a `NAME=value` word is one word
  # for `env` and a parser adventure for the shell.
  env "WASM_AGENT_LUA_ROOT=$(native_path "$ROOT")" "WASM_AGENT_HOME=$(native_path "$home")" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    WA_MESH_COMPONENT=1 "WA_MESH_COMPONENT_WASM=$(native_path "$artifact")" \
    "WA_MESH_COMPONENT_MANIFEST=$(native_path "$manifest")" \
    "WA_SCRIPT=$(native_path "$ROOT/scripts/test-mesh-component.lua")" \
    timeout 120 "$bin" --db "$(native_path "$home/t.db")" || status=1
  rm -rf "$home"
fi

echo "== mesh component: $([ $status -eq 0 ] && echo ok || echo FAILED)"
exit $status
