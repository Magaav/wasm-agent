#!/usr/bin/env bash
# Human-run frozen source build only. Does not install/start/pair anything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON3:-}"
if [ -z "$PY" ]; then PY="$(command -v python3 || true)"; fi
[ -n "$PY" ] || { echo 'explicit PYTHON3 or python3 required before build' >&2; exit 1; }
SCRIPT="$(cygpath -m "$ROOT/scripts/whatsapp-build.py" 2>/dev/null || printf '%s' "$ROOT/scripts/whatsapp-build.py")"
exec "$PY" "$SCRIPT"
