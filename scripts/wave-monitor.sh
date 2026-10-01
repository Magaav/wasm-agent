#!/usr/bin/env bash
# Approved external sentinel procedure, never a node turn. Registration is in the
# installation's canonical runtime binding; no new wave or arbitrary store here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/service-target.sh"
INSTALL="$(wa_install_target)"
REPO="$(tr -d '\r\n' < "$INSTALL/runtime-worktree.txt")"
ENTRY="$SCRIPT_DIR/wave-entry.mjs"
if command -v cygpath >/dev/null 2>&1; then ENTRY="$(cygpath -w "$ENTRY")"; fi
RESULT="$(node "$ENTRY" monitor "$REPO")" || STATUS=$?
printf '%s\n' "$RESULT"
if printf '%s' "$RESULT" | node -e 'let s="";process.stdin.on("data",x=>s+=x);process.stdin.on("end",()=>process.exit(JSON.parse(s).disable_monitor===true?0:1))'; then
  SENTINEL="$INSTALL/wa-sentinel"; [ -f "$SENTINEL.exe" ] && SENTINEL="$SENTINEL.exe"
  "$SENTINEL" job disable wave-convergence
fi
exit "${STATUS:-0}"
