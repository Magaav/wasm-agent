#!/usr/bin/env bash
# Check (default) or rewrite (--write) the generated prompt-doc blocks from the live Lua source.
# The generator is scripts/sync-prompt-docs.lua; it runs inside the wa binary with this checkout as
# the Lua root, so it reads the code being committed, not the copy embedded in the binary.
#
# The binary: $WA_BIN, else `wa` on PATH, else ~/.local/bin/wa, else this checkout's release build.
# Exit 0 = current (or written), 1 = stale, 2 = no wa binary to run the generator.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=check
[ "${1:-}" = "--write" ] && mode=write

bin="${WA_BIN:-}"
if [ -z "$bin" ]; then
  for candidate in "$(command -v wa 2>/dev/null || true)" "$HOME/.local/bin/wa" \
      "$root/rust/target/release/wa" "$root/rust/target/release/wa.exe"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then bin="$candidate"; break; fi
  done
fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  echo "sync-prompt-docs: no wa binary found (set WA_BIN); generated docs were NOT checked" >&2
  exit 2
fi

db="$(mktemp -d)"
trap 'rm -rf "$db"' EXIT
cd "$root" && WASM_AGENT_LUA_ROOT="$root" WA_SCRIPT=scripts/sync-prompt-docs.lua \
  WA_PROMPT_DOCS_MODE="$mode" "$bin" --db "$db/docs.db"
