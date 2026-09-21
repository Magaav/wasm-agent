#!/usr/bin/env bash
# Offline production shell-tail/artifact probe. No legacy runtime mode, no model
# inference, and no claims about agent quality from a synthetic truncation test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
node scripts/bench-tool-views.cjs tail "$@"
