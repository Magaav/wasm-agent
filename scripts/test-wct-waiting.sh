#!/bin/bash
# THE WAITING QUERY ANSWERS A SHORT WINDOW TOO (28/11, waiting-costs-no-turns).
#
# The mission's after is a question about HOURS: the fix landed this morning, and "is it visible yet?" cannot be asked
# with a 7-day window. WCT_HOURS exists for that, and two defects were found by using it: the ledger ENDS by repeating a
# cursor (not by returning nil), which a short window reaches, and the header formatted a fractional day with %d.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail() { echo "wct-waiting: $*"; exit 1; }
[ -r scripts/wct-waiting.lua ] || fail 'scripts/wct-waiting.lua is missing'

# THE CALL, not the word: the first version matched the comment that explains the knob, so removing the call left the row green (measured).
grep -q "host.getenv('WCT_HOURS')" scripts/wct-waiting.lua || fail 'the query reads no hours window, so the after cannot be measured before a day has passed'
grep -q 'A REPEATED CURSOR IS THE END OF THE LEDGER' scripts/wct-waiting.lua || fail 'a repeated cursor is still treated as a fault, which makes a short window look broken'
grep -q "last %g hour(s)" scripts/wct-waiting.lua || fail 'the header still formats a fractional day with %d'

# A THREE-MINUTE WINDOW, on this node's own ledger: it must answer, and it must answer in the json shape.
out=$(WA_SCRIPT="$PWD/scripts/wct-waiting.lua" WCT_HOURS=0.05 WCT_JSON=1 wa 2>/tmp/wct-waiting.err | tail -1)
case "$out" in
  *'"waiting_rounds":'*) ;;
  *) fail "a three-minute window did not answer the json shape: [$out] $(cat /tmp/wct-waiting.err | tail -2)" ;;
esac
case "$out" in
  *'"days":0'*|*'"days":'*) ;;
  *) fail "the json lost its window field: [$out]" ;;
esac
grep -qi 'same cursor' /tmp/wct-waiting.err && fail 'the end of the ledger is still reported as an error'

echo "wct-waiting ok (hours window answers, a repeated cursor is the end of the ledger, the header survives a fraction)"
