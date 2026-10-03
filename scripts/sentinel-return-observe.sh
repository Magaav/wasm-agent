#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WA_SENTINEL_BIN="${WA_SENTINEL_BIN:-$HERE/../wa-sentinel.exe}"
export WA_INSTALL_DIR="${WA_INSTALL_DIR:-$HERE/..}"
exec "$WA_SENTINEL_BIN" protocol observe
