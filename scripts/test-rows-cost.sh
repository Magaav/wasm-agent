#!/bin/bash
# Does the cost command answer Victor's question in one screen? "as the gate grows, how long does the test
# batch take to run" (gate-stays-fast, 23/11).
#
# Pinned on a fixture archive (no run is started):
#   * the TOTAL seconds per archived run, newest first by the UTC stamp in the name;
#   * the budget verdict: a 41 s run is UNDER a 60 s budget and OVER a 30 s one;
#   * the slowest rows of the newest run, with their share, limited to --rows;
#   * rows over 20 s named apart (the brief requires a one-line reason in such a row's header);
#   * an empty archive answered as "no data", never as a zero-second run with a verdict.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
checks=0; failures=0
check() { checks=$((checks+1)); if [ "$1" != 0 ]; then echo "FAIL rows-cost: $2"; failures=$((failures+1)); fi; }

D=$(mktemp -d "${TMPDIR:-/tmp}/rows-cost.XXXXXX"); trap 'rm -rf "$D"' EXIT
printf '0\t1500\tscripts/test-a.lua\tok\tpass\n0\t25000\tscripts/test-slow.lua\tok\tpass\n0\t100\tscripts/test-c.lua\tok\tpass\n' > "$D/20260101T000000Z-aaaa.tsv"
printf '0\t1200\tscripts/test-a.lua\tok\tpass\n0\t40000\tscripts/test-slower.lua\tok\tpass\n0\t100\tscripts/test-c.lua\tok\tpass\n' > "$D/20260102T000000Z-bbbb.tsv"

out=$(WA_SUITE_BUDGET_S=60 bash "$ROOT/scripts/rows-cost.sh" --dir "$D" --rows 2 2>&1); rc=$?
[ "$rc" = 0 ]; check $? "the reporter exited $rc: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
first=$(printf '%s' "$out" | awk '/^ +[0-9]+ +[0-9]+ +(under|OVER)/ {print $4; exit}')
[ "$first" = "20260102T000000Z-bbbb.tsv" ]; check $? "the runs are not newest first: first was [$first]"
printf '%s' "$out" | grep -q 'OVER'; [ $? != 0 ]; check $? "a 41 s run under a 60 s budget is reported OVER"
over=$(WA_SUITE_BUDGET_S=30 bash "$ROOT/scripts/rows-cost.sh" --dir "$D" --rows 2 2>&1)
printf '%s' "$over" | grep -q 'OVER'; check $? "a 41 s run under a 30 s budget is NOT reported OVER: $(printf '%s' "$over" | head -3 | tr '\n' ' ')"

rows_block=$(printf '%s' "$out" | awk '/slowest rows/ {f=1; next} /^$/ {f=0} f')
printf '%s' "$rows_block" | grep -q 'test-slower.lua'; check $? "the slowest row of the newest run is not named: [$rows_block]"
printf '%s' "$rows_block" | grep -q 'test-slow.lua'; [ $? != 0 ]; check $? "a row from the OLDER run is listed among the newest run's slowest"
printf '%s' "$rows_block" | grep -q 'test-c.lua'; [ $? != 0 ]; check $? "--rows 2 listed a third row: [$rows_block]"
printf '%s' "$rows_block" | grep -q '96'; check $? "the share of the slowest row is not printed: [$rows_block]"
printf '%s' "$out" | grep -q 'rows over 20 s'; check $? "rows over 20 s are not named apart"
printf '%s' "$out" | awk '/rows over 20 s/ {f=1; next} /^$/ {f=0} f' | grep -q 'test-slower.lua'; check $? "the row over 20 s is not in that list"

E=$(mktemp -d "${TMPDIR:-/tmp}/rows-cost-empty.XXXXXX")
empty=$(bash "$ROOT/scripts/rows-cost.sh" --dir "$E" 2>&1); rc=$?; rm -rf "$E"
[ "$rc" = 0 ]; check $? "an empty archive exited $rc"
printf '%s' "$empty" | grep -q 'no archived run'; check $? "an empty archive is not answered as no data: $(printf '%s' "$empty" | head -2 | tr '\n' ' ')"
# the header is the table; the words 'under'/'OVER' also appear inside the no-data sentence, so the
# header - not a keyword - is what tells a run apart from no run.
printf '%s' "$empty" | grep -q 'seconds'; [ $? != 0 ]; check $? "an empty archive prints the run table as if a run had happened"

if [ "$failures" = 0 ]; then echo "rows-cost: $checks check(s), 0 failed"; else echo "rows-cost: $checks check(s), $failures FAILED"; exit 1; fi
