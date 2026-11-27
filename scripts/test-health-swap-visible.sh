#!/bin/bash
# A FORGOTTEN SWAP MUST BE A LINE, NOT AN AFTERNOON (28/11).
#
# MEASURED: every tip printed "NOT GRADED" for hours after the fix had LANDED, because the loop runs from a copy under
# _orch that a human swaps between landings (factory/MAP.md) and a running shell loop sources its lib once, at start.
# Nothing on the node said which copy was running, so the code was re-investigated three times for a deployment gap.
#
# This row exercises the check itself: two libraries that differ must produce a note, two identical ones must not, and
# a grading line must name the lib that produced the binary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "health-swap-visible: $*"; exit 1; }

loop=factory/health-loop.sh
[ -f "$loop" ] || fail 'factory/health-loop.sh is missing'

grep -q 'wa_factory_selfcheck' "$loop" || fail 'the loop has no self-check, so a stale _orch copy is silent again'
grep -q 'swap _orch per factory/MAP.md' "$loop" || fail 'the self-check does not say what to do about a stale copy'
grep -q 'orch(health): factory lib' "$loop" || fail 'a grading line does not name the factory lib that produced it'

# The function, lifted out of the loop and run on its own: differing libs, then identical ones.
body=$(awk '/^wa_factory_selfcheck\(\)/,/^}/' "$loop")
[ -n "$body" ] || fail 'could not lift wa_factory_selfcheck out of the loop'

work=$(mktemp -d "${TMPDIR:-/tmp}/swapcheck.XXXXXX")
mkdir -p "$work/mine/lib" "$work/landed/factory/lib"
printf 'old\n' > "$work/mine/lib/main-binary.sh"
printf 'new\n' > "$work/landed/factory/lib/main-binary.sh"

note=$(HERE=$work/mine C=$work/landed bash -c "$body"$'\nwa_factory_selfcheck')
[ -n "$note" ] || fail 'two DIFFERENT libraries produced no note - the whole point of the check'
case "$note" in *'swap _orch'*) ;; *) fail "the note does not say what to do: $note" ;; esac

cp "$work/mine/lib/main-binary.sh" "$work/landed/factory/lib/main-binary.sh"
quiet=$(HERE=$work/mine C=$work/landed bash -c "$body"$'\nwa_factory_selfcheck')
[ -z "$quiet" ] || fail "two IDENTICAL libraries still produced a note: $quiet"

rm -rf "$work"
echo "health swap visible ok (a stale copy is named, an identical one is quiet, every grading line carries the lib)"
