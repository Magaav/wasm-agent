#!/usr/bin/env bash
# THE RUNNER'S DOOR TO THE tmp-cleanliness ROW (26/11).
#
# The row itself is scripts/test-tmp-cleanliness.mjs and it stays the only copy of the checks: the fast path runs it
# (`WA_BIN="$bin" check tmp-cleanliness node scripts/test-tmp-cleanliness.mjs`, scripts/fast.sh:1236) and the gate runs
# it (`WA_BIN="$BIN" gate_run node scripts/test-tmp-cleanliness.mjs`, scripts/test.sh:2828). This file exists because
# the orchestrator's row runner accepts `scripts/<name>.sh|.lua` and refused the .mjs by name (26/11: `refused: row
# must be scripts/<name>.sh|.lua`), and an item that must be shown green five times through the runner needs a row
# the runner will take.
#
# It is a door, not a test: `exec` hands the exit code and the verdict line through unchanged, `WA_BIN` travels (the
# runner always sets it), and nothing is decided here. There is no second assertion list to drift.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
command -v node >/dev/null 2>&1 || { printf 'SKIP test-tmp-cleanliness: no node on this host\n'; exit 0; }
exec node scripts/test-tmp-cleanliness.mjs "$@"
