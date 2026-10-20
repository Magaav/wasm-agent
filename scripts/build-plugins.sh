#!/usr/bin/env bash
# Build every WASM tool plugin and install it into the agent's plugin directory.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

OUT="${WASM_AGENT_PLUGINS:-$HOME/.wasm-agent/plugins}"
mkdir -p "$OUT"

built=0
for crate in rust/plugins/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  cargo build --manifest-path "$crate/Cargo.toml" --target wasm32-unknown-unknown --release --offline >/dev/null
  wasm="$(ls "$crate"/target/wasm32-unknown-unknown/release/*.wasm 2>/dev/null | head -1 || true)"
  if [ -z "$wasm" ]; then
    echo "skip $name: no .wasm produced"
    continue
  fi
  cp "$wasm" "$OUT/$name.wasm"
  # The pin travels with the module, like the code-mode assets' compiled-in digests: the loader
  # verifies `<module>.sha256` beside the module and refuses a mismatch (`plugin_hash_mismatch`).
  # Install writes a fresh pin; a module swapped afterwards no longer matches it.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$OUT/$name.wasm" | awk '{print $1}' > "$OUT/$name.wasm.sha256"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$OUT/$name.wasm" | awk '{print $1}' > "$OUT/$name.wasm.sha256"
  else
    echo "note: no sha256sum or shasum; $OUT/$name.wasm is installed unpinned" >&2
  fi
  echo "installed $OUT/$name.wasm ($(wc -c < "$OUT/$name.wasm") bytes)"
  built=$((built + 1))
done
echo "built $built plugin(s)"
