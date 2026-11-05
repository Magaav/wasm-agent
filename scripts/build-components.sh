#!/usr/bin/env bash
# Build every WASI component (rust/components/*, wasm32-wasip2) and install it into the component
# directory with its pin and manifest. Separate from the core build on purpose: a component changes
# without rebuilding `wa`, and `wa` builds without compiling any component. See docs/COMPONENTS.md.
#
#   bash scripts/build-components.sh            # all components
#   bash scripts/build-components.sh mcp-whatsapp
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

OUT="${WA_COMPONENTS_DIR:-$HOME/.wasm-agent/components}"
mkdir -p "$OUT"
# Request components (MCP) are wasm32-wasip2; long-lived services are wasm32-wasip1 (what Go's
# GOOS=wasip1 produces). A manifest may name its target; the default is wasm32-wasip2.
ensure_target() {
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$1"; then
    rustup target add "$1" >/dev/null
  fi
}

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

built=0
for crate in rust/components/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi
  [ -f "$crate/manifest.json" ] || { echo "skip $name: no manifest.json" >&2; continue; }
  TARGET="$(sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([a-z0-9_-]*\)".*/\1/p' "$crate/manifest.json" | head -1)"
  TARGET="${TARGET:-wasm32-wasip2}"
  ensure_target "$TARGET"
  cargo build --manifest-path "$crate/Cargo.toml" --target "$TARGET" --release ${WA_COMPONENTS_OFFLINE:+--offline} >/dev/null
  wasm="$crate/target/$TARGET/release/$name.wasm"
  # A library component (cdylib) is named with underscores.
  [ -f "$wasm" ] || wasm="$crate/target/$TARGET/release/${name//-/_}.wasm"
  [ -f "$wasm" ] || { echo "skip $name: no $wasm produced" >&2; continue; }
  # Install atomically: manifest and module first under temporary names, pin last, so a reader
  # never pairs a new module with an old pin (it would be refused, never run).
  cp "$crate/manifest.json" "$OUT/.$name.json.tmp" && mv "$OUT/.$name.json.tmp" "$OUT/$name.json"
  cp "$wasm" "$OUT/.$name.wasm.tmp" && mv "$OUT/.$name.wasm.tmp" "$OUT/$name.wasm"
  sha "$OUT/$name.wasm" > "$OUT/.$name.wasm.sha256.tmp" && mv "$OUT/.$name.wasm.sha256.tmp" "$OUT/$name.wasm.sha256"
  echo "installed $OUT/$name.wasm ($(wc -c < "$OUT/$name.wasm") bytes, sha256 $(cat "$OUT/$name.wasm.sha256"))"
  built=$((built + 1))
done
echo "built $built component(s)"
