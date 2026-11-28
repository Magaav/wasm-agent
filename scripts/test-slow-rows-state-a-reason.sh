#!/bin/bash
# Does every row that costs the suite more than 20 s say WHY in its header?
#
# gate-stays-fast item 2: "A NEW row states its measured seconds in its header; a row over 20 s needs a
# one-line reason." A rule nobody checks is a wish, and the cost is invisible without it: the first real
# table from scripts/rows-cost.sh showed ten rows over 20 s, six of them silent about their cost.
#
# This row reads the newest archived run (the same data rows-cost.sh prints) and requires a cost line in
# the first 12 lines of each row that took more than 20 s. It does NOT invent the reasons: a row that is
# slow and silent is named, and its owner writes the sentence.
#
# Where there is no archive yet (a fresh checkout), it says so and passes: the rule is about rows that
# have been MEASURED, not about rows nobody has run.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
DIR=${WA_ROWS_ARCHIVE:-$HOME/.wasm-agent/main-health/rows}
LIMIT=${WA_SLOW_ROW_S:-20}
checks=0; failures=0
check() { checks=$((checks+1)); if [ "$1" != 0 ]; then echo "FAIL slow-rows: $2"; failures=$((failures+1)); fi; }

newest=""
if [ -d "$DIR" ]; then newest=$(ls -1 "$DIR"/*.tsv 2>/dev/null | sort -r | head -1); fi
if [ -z "$newest" ]; then
  echo "slow-rows: no archived run under $DIR (nothing measured yet); a slow row is named once one exists"
  exit 0
fi

slow=$(awk -F'\t' -v limit=$((LIMIT*1000)) '$2 ~ /^[0-9]+$/ && $2 > limit {print $3}' "$newest")
if [ -z "$slow" ]; then echo "slow-rows: no row over ${LIMIT}s in $(basename "$newest")"; exit 0; fi

silent_count=0
silent_list=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$ROOT/$f" ]; then
    silent_count=$((silent_count+1)); silent_list="$silent_list  $f (the row no longer exists; prune it, do not annotate it)"$'\n'; continue
  fi
  if ! head -12 "$ROOT/$f" | grep -qiE 'seconds|slow|takes [0-9]|cost|budget'; then
    # A row that FAILED in that run has the seconds of its failure, not of its work: test-remote-pending
    # reads 7.5 s under the watchdog and 249.9 s when it passes. Say which, so nobody annotates a row with
    # the cost of its crash.
    read -r code secs <<<"$(awk -F'\t' -v r="$f" '$3==r {printf "%s %.1f", $1, $2/1000; exit}' "$newest")"
    if [ "${code:-0}" != 0 ]; then
      silent_count=$((silent_count+1)); silent_list="$silent_list  $f (${secs} s in a run where it FAILED - its cost is not known until it passes)"$'\n'
    else
      silent_count=$((silent_count+1)); silent_list="$silent_list  $f (${secs} s)"$'\n'
    fi
  fi
done <<< "$slow"

# Default: REPORT and pass. A rule this new cannot be flipped on in the same commit that reveals 37 silent
# rows - that would make main red for a documentation gap and hide it among the real reds. WA_SLOW_ROWS_STRICT=1
# is the flip, for after the rows have their lines (or for a release gate that wants it now).
if [ "$silent_count" = 0 ]; then
  echo "slow-rows: every row over ${LIMIT}s states its cost ($checks check(s), 0 failed)"
  exit 0
fi
printf 'slow-rows: %d row(s) over %ss state no cost line in their header:\n%s' "$silent_count" "$LIMIT" "$silent_list"
if [ "${WA_SLOW_ROWS_STRICT:-0}" = 1 ]; then
  echo "slow-rows: strict mode - this is a failure"
  exit 1
fi
echo "slow-rows: reported, not failed (WA_SLOW_ROWS_STRICT=1 makes it a failure)"
exit 0
