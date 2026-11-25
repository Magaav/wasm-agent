#!/usr/bin/env bash
# A .sh wrapper because the orchestrator's row runner runs scripts/<name>.sh|.lua only.
# The measurement itself is scripts/test-mcp-list-pty.mjs: the real binary, a real pty, a fixture rendezvous
# whose four peers accept and never answer, so a path that refreshes the catalogue pays their deadlines and a
# path that reads the cache pays nothing.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo 'SKIP mcp-list-pty: node is not on PATH'; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo 'SKIP mcp-list-pty: tmux is not on PATH'; exit 0; }
out="$(node "$ROOT/scripts/test-mcp-list-pty.mjs" 2>&1)"; rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || exit "$rc"
printf '%s\n' "$out" | grep -q 'mcp list pty ok' || { echo 'mcp-list-pty: the harness printed no verdict line'; exit 1; }
