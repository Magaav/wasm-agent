#!/bin/bash
# ONE TEST FOR daily-line, on a FIXTURE DAY, and it can fail.
#
# The line is one sentence about YESTERDAY IN THE READER'S OWN DAY, so the two things that can go wrong are the
# numbers and the window: a landing counted from the wrong day, a median that ignores the day boundary, a revert
# counted as a landing. The fixture pins both: a scratch git repository with commits on two days, landing-times
# rows in UTC that straddle midnight in America/Sao_Paulo (03:30Z is the previous local day), and one flake.
#
# WHAT IT CAN CATCH: a window computed in UTC instead of the local day (the 03:30Z row would move), a landing
# count that includes another day's merges, a revert folded into the landing count, a median over all rows
# instead of the day's, and a line that stops being written to HANDOVER.md.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-daily-line.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
checks=0; failed=0
fail() { echo "FAIL test-daily-line: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

HOME_DIR="$WORK/home"; M="$HOME_DIR/Work/missions"; O="$M/_orch"; C="$HOME_DIR/wasm-agent/checkout"
mkdir -p "$O" "$C"

# ---- the fixture day, in the node's own zone ----------------------------------------------------------
export TZ=America/Sao_Paulo
DAY=2026-11-20                      # the local day the line is about
# LOCAL time parsed first, then printed as UTC: `date -u -d '<local time>'` PARSES the string as UTC and
# would silently put 00:30 local at 00:30Z, which is the previous local day - the exact window this test is
# about.
utc() { date -u -d "@$(date -d "$1" +%s)" +%Y-%m-%dT%H:%M; }
DAY_START_UTC=$(utc "$DAY 00:00")
noon_utc=$(utc "$DAY 12:00")
early_utc=$(utc "$DAY 00:30")          # 03:30Z: the same local day, early
before_utc=$(utc "$DAY 00:30")         # replaced below by the real previous-day stamp
before_utc=$(date -u -d "@$(( $(date -d "$DAY 00:00" +%s) - 7200 ))" +%Y-%m-%dT%H:%M)  # 22:00 the PREVIOUS local day

git -C "$C" init -q --initial-branch=main
git -C "$C" config user.email row@example.invalid
git -C "$C" config user.name row
# Both dates are EXPORTED inside the function: a prefix assignment on a shell function is not passed to the
# child process in bash, and a commit made with the default clock would land on today instead of the day
# this test is about.
commit() {
  GIT_AUTHOR_DATE="$1"; GIT_COMMITTER_DATE="$1"; export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  git -C "$C" commit -q --allow-empty -m "$2"
}
# The OTHER DAY goes FIRST in the history, not last: `git log --since` stops walking at the first commit
# older than the window, so a previous-day commit at the tip makes the whole log empty - which looked like
# "landings 0" and took a fixture bug to see.
commit "$(date -d "$DAY -1 day" '+%Y-%m-%d 10:00')" "land-quick: merge change/previous-day"
commit "$DAY 10:00" "land-quick: merge change/one"
commit "$DAY 11:00" "land-quick: merge change/two"
commit "$DAY 12:00" "Revert \"land-quick: merge change/bad\""
commit "$DAY 13:00" "docs: nothing to count"
git -C "$C" update-ref refs/remotes/origin/main "$(git -C "$C" rev-parse main)"

# ---- the tables the line reads, one row straddling local midnight --------------------------------------
printf '%s\tchange/one\tcompiled\t0\t0\t120\t120\n' "${noon_utc}Z" >> "$O/landing-times.tsv"
printf '%s\tchange/two\tcompiled\t0\t0\t180\t180\n' "${early_utc}Z" >> "$O/landing-times.tsv"
printf '%s\tchange/three\tlua\t0\t0\t60\t60\n' "${noon_utc}Z" >> "$O/landing-times.tsv"
# 22:00 LOCAL is the local day BEFORE the one asked about, and its UTC stamp is already the asked-about DATE.
printf '%s\tchange/before\tcompiled\t0\t0\t900\t900\n' "${before_utc}Z" >> "$O/landing-times.tsv"
printf '%s\trow-x\n' "${noon_utc}Z" >> "$O/flaky.tsv"
printf '%s\t1\t6\n' "${noon_utc}Z" >> "$O/throughput-samples.tsv"

# ---- the run -------------------------------------------------------------------------------------------
out=$(HOME="$HOME_DIR" TZ=America/Sao_Paulo DAY="$DAY" bash "$HERE/daily-line.sh" 2>&1)

like "$out" "DAILY $DAY:" "the line names the day it is about"
like "$out" "landings 2 " "two merges that day, and the previous day's merge is not one of them"
like "$out" "reverts 1" "the revert is counted as a revert"
like "$out" "median min compiled 2.5 / not 1.0" "the medians are the day's rows: (120,180)->2.5 min compiled, 60 s -> 1.0 not compiled; the 900 s row is another local day"
like "$out" "flakes 1" "the day's flake is counted"
like "$out" "idle worker-h 1.0" "ten minutes of samples are an hour of worker idleness"
grep -q "DAILY $DAY:" "$M/HANDOVER.md" || fail "the line is written to HANDOVER.md, not only printed"
checks=$((checks + 1))

# ---- the boundary case on its own: the 22:00 local row must not enter the median ----------------------
like "$out" "median min compiled 2.5" "one row outside the local day cannot move a median of two"

if [ "$failed" -gt 0 ]; then echo "test-daily-line: $failed failed of $checks checks"; exit 1; fi
echo "test-daily-line ok ($checks checks)"
