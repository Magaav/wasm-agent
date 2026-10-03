#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTINEL="${WA_SENTINEL_BIN:-$HERE/../wa-sentinel.exe}"
[ -x "$SENTINEL" ] || SENTINEL="$HERE/../wa-sentinel"
exec "$SENTINEL" protocol compose "${WA_JOB_EVENT_FILE:?key-only event required}"
