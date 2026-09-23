#!/usr/bin/env bash
# Scheduled local speech lane. The Lua script owns the durable cursor and send
# reservation; this wrapper only supplies native paths and preserves its verdict.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for candidate in "${WA_BIN:-}" "${LOCALAPPDATA:-}/wasm-agent/wa.exe" "${HOME:-}/.local/bin/wa" \
  "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && WA="$candidate" && break
done
if [ -z "${WA:-}" ]; then
  echo '{"ok":false,"step":"startup","error":"wa_binary_missing"}'
  exit 1
fi
lua_script="$ROOT/scripts/whatsapp-transcribe.lua"
plugins="$ROOT/plugins"
if command -v cygpath >/dev/null 2>&1; then
  lua_script="$(cygpath -m "$lua_script")"
  plugins="$(cygpath -m "$plugins")"
fi
result="$(WASM_AGENT_PLUGINS="$plugins" WA_SCRIPT="$lua_script" "$WA" "$@")"
code=$?
if [ -n "${WA_JOB_RESULT_FILE:-}" ]; then
  printf '%s' "$result" > "$WA_JOB_RESULT_FILE" || code=1
fi
printf '%s\n' "$result"
exit "$code"
