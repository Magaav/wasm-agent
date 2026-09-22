#!/usr/bin/env bash
# The copilot pipeline's first step: read the store, diff it against the cursor, print the new eligible
# messages as one JSON object. No model, no event, no children - the job's own foreach step starts those.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for candidate in \
  "${WA_BIN:-}" \
  "$LOCALAPPDATA/wasm-agent/wa.exe" \
  "$HOME/.local/bin/wa" \
  "$ROOT/rust/target/release/wa" \
  "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && WA="$candidate" && break
done
if [ -z "${WA:-}" ]; then
  echo '{"events":[],"error":"no_binary"}'
  exit 0
fi

lua_script="$ROOT/scripts/whatsapp-ingest.lua"
if command -v cygpath >/dev/null 2>&1; then
  lua_script="$(cygpath -m "$lua_script")"
fi

# Nothing is printed here on purpose: the step succeeds on exit 0 and a JSON object on stdout.
WA_WHATSAPP_JSON_EVENTS=1 WA_SCRIPT="$lua_script" "$WA" "$@"
