#!/usr/bin/env bash
# Offline production read-view/artifact probe. The former TOOL_BUDGET A/B used
# an ignored variable; it did not measure two policies and must not spend model calls.
# Legacy positional run counts are rejected by the runner, not silently ignored.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
node scripts/bench-tool-views.cjs read "$@"
