#!/usr/bin/env bash
# fast.sh runs under `set -u`: a counter incremented as $((NAME + 1)) that is never initialised kills the
# whole run with "unbound variable" and loses every later row and the verdict (measured 20/11: a fallback
# wrote SKIPPED=$((SKIPPED + 1)) while the counter is `skipped`). Every incremented counter must be
# initialised at top level.
#   bash scripts/test-fast-counters.sh [file]
set -uo pipefail
F=${1:-"$(dirname -- "$0")/fast.sh"}
bad=0
for name in $(grep -oE '\b[A-Za-z_][A-Za-z0-9_]*=\$\(\([A-Za-z_][A-Za-z0-9_]* \+' "$F" | sed -E 's/=.*//' | sort -u); do
  grep -qE "(^|; *)${name}=[0-9]" "$F" || { echo "test-fast-counters: $name is incremented but never initialised at top level in $F"; bad=1; }
done
[ "$bad" = 0 ] || exit 1
echo "fast counters ok"
