#!/bin/bash
# THE MEASUREMENT A REPORT CITES MUST EXIST (27/11, waiting-costs-no-turns).
#
# docs/missions/reports/waiting-costs-no-turns.md decides the mission and then names its own after-measurement: "the
# same ledger query (wct-query.sql)". MEASURED: no such file was in the tree, so the before lived only in the head of
# whoever wrote it. This row is the guard that the query exists, parses, and still counts the four numbers the report
# was written against - a cited-but-absent artifact is the cheapest debt in the repo and the easiest to stop.
#
# It is a STRUCTURAL row plus one real run on the smallest window that answers: the ledger is a guarded path (bash may
# not read memory.db), so the query is a lua script run by the node itself, which is the only reader allowed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "wct-query: $*"; exit 1; }

[ -f scripts/wct-query.lua ] || fail 'scripts/wct-query.lua is missing - the report cites a query nobody can run'
command -v luac >/dev/null 2>&1 && { luac -p scripts/wct-query.lua 2>/dev/null || fail 'scripts/wct-query.lua does not parse'; }

# THE FOUR NUMBERS, by name, because a reader comparing a before against an after needs the same words.
for label in 'runs over' 'operation calls inside' 'more than' 'worst single run'; do
  grep -q "$label" scripts/wct-query.lua || fail "the query no longer reports '$label' - the after could not be compared with the before"
done

# ONE REAL RUN, the smallest window that answers, and only where a ledger exists: without one the row SKIPS BY NAME
# rather than passing on nothing.
if [ ! -d "${HOME:-/nonexistent}/.wasm-agent" ]; then
  echo "SKIP test-wct-query: no node ledger under ${HOME:-/nonexistent}/.wasm-agent, so the query has nothing to count"
  exit 0
fi
out=$(timeout 120 env WCT_DAYS=1 WCT_JSON=1 WA_SCRIPT="$PWD/scripts/wct-query.lua" wa 2>&1 | tail -1)
case "$out" in
  *'"long_runs"'*'"operation_calls_in_long_runs"'*)
    echo "wct-query ok (the report's measurement is a command: $out)" ;;
  *ledger*) echo "SKIP test-wct-query: the ledger could not be read here ($out)"; exit 0 ;;
  *) fail "the query answered something unusable: $out" ;;
esac
