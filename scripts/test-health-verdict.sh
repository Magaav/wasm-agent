#!/bin/bash
# EVERY TIP ENDS IN ONE LINE, OR SAYS WHY IT HAS NO VERDICT (28/11, Victor).
#
# MEASURED: 01:35Z wrote "grading 8b8b6400 - resolving a binary of this tip" and then NOTHING for 30+ minutes, and
# _orch/health-loop-run.out ended in
#   Terminated   WA_FAST_RESULT=... flock -o "$lock" nice -n "$nice_level" bash -c "cd '$tree' && bash scripts/fast.sh"
# The suite was killed and no line said by whom or after how long. Silence read as "fine" to one reader and "broken" to
# another; a watchdog with either answer is no watchdog.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "health-verdict: $*"; exit 1; }
lib=factory/lib/health-verdict.sh
loop=factory/health-loop.sh
[ -r "$lib" ] || fail "$lib is missing"

# THE LOOP MUST HAVE NO PATH THAT PRINTS NOTHING: it sources the module, traps TERM, budgets the suite, and always emits.
grep -q 'health-verdict.sh' "$loop" || fail 'the loop does not source the verdict module'
grep -q 'trap wa_health_on_term TERM' "$loop" || fail 'the loop does not trap TERM, so a unit restart is invisible'
grep -q 'WA_HEALTH_SUITE_SECONDS' "$loop" || fail 'the suite has no budget, so a hang is indistinguishable from slow'
grep -q 'timeout "$SUITE_BUDGET" bash $C/scripts/main-health.sh' "$loop" || fail 'the suite is not run under the budget'
grep -q 'wa_health_verdict_line "$N" "$RC" "$TOOK"' "$loop" || fail 'the loop has a path that runs the suite without printing a verdict'
# A LOCK WAIT MUST NAME ITS HOLDER: measured 02:14Z, a tip sat "resolving" for 39 minutes because .suite.lock was held
# by an unrelated job, and only `fuser` could have said so.
grep -q 'waiting for the suite lock' "$loop" || fail 'the loop waits for the suite lock in silence'
# AND THE TERM MESSAGE MUST READ AS A WHOLE SENTENCE, whatever was running: the first live firing printed
# "<sha>  NO VERDICT after 0s: this loop was TERMINATED (SIGTERM) while - a unit restart ..." with an empty sha.
grep -q 'between tips - no tip was being graded' "$loop" || fail 'a SIGTERM between tips leaves the trap message half-written'
# AND THE TIP MUST BE CLAIMED BEFORE ANY RESOLUTION: measured 02:48Z, a restart during a 15-minute resolution was
# reported as "between tips", because TIP_SHA was only set once the binary existed. Resolution is grading.
awk '/rev-parse origin\/main/ { seen=1; next } seen && /TIP_SHA="\$N"/ { claimed=1 } END { exit !claimed }' "$loop"   || fail 'the tip is not claimed right after main is read, so a restart during resolution reads as "between tips"' 
grep -q 'what="while grading' "$loop" || fail 'the trap does not say what it was grading'
grep -q 'fuser' "$loop" || fail 'the lock-wait line does not name the holder' 

work=$(mktemp -d "${TMPDIR:-/tmp}/verdict.XXXXXX") || fail 'no temp dir'
trap 'rm -rf "$work"' EXIT
SHORT=deadbeef

line() { # <rc> <took> <run.out> <json> [budget] -> the verdict line
  . "$PWD/$lib"
  wa_health_verdict_line "$SHORT" "$1" "$2" "$3" "$4" "${5:-0}"
}

# 1) GREEN: one line, with the counts and the time it took.
cat > "$work/green.json" <<'JSON'
{"sha":"deadbeefdeadbeef","counts":{"passed":410,"checks":425},"failed":[]}
JSON
: > "$work/empty.out"
out=$(line 0 214 "$work/empty.out" "$work/green.json")
case "$out" in "$SHORT 410/425 green (214s)") ;; *) fail "a green tip did not produce the green line: [$out]" ;; esac

# 2) RED: one line naming the rows.
cat > "$work/red.json" <<'JSON'
{"sha":"deadbeefdeadbeef","counts":{"passed":408,"checks":425},"failed":[{"row":"test-done-gate"},{"row":"test-cli-notice"}]}
JSON
out=$(line 0 300 "$work/empty.out" "$work/red.json")
case "$out" in *"NEW RED: test-cli-notice test-done-gate"*) ;; *) fail "a red tip did not name its rows: [$out]" ;; esac

# 3) KILLED BY A UNIT RESTART: SIGTERM, and the evidence the log actually carries, plus how long it ran.
printf 'Terminated   WA_FAST_RESULT=$result flock -o "$lock" nice -n 10 bash -c "cd tree && bash scripts/fast.sh"\n' > "$work/killed.out"
out=$(line 143 1800 "$work/killed.out" "$work/missing.json" 2400)
case "$out" in *"NO VERDICT after 1800s"*) ;; *) fail "a terminated suite produced no NO VERDICT line: [$out]" ;; esac
case "$out" in *"SIGTERM after 1800s"*) ;; *) fail "the killer (SIGTERM) and the elapsed time are not named: [$out]" ;; esac
case "$out" in *Terminated*) ;; *) fail "the log's own evidence of the kill is not quoted: [$out]" ;; esac

# 4) KILLED BY THE BUDGET: the budget is named as the killer, not the log.
out=$(line 124 2400 "$work/empty.out" "$work/missing.json" 2400)
case "$out" in *"2400s budget"*) ;; *) fail "a budget kill does not name the budget: [$out]" ;; esac

# 4b) LOCK: a suite that never started because the lock was taken says so.
printf 'flock: .suite.lock is held by pid 1058005
' > "$work/lock.out"
out=$(line 1 12 "$work/lock.out" "$work/missing.json")
case "$out" in *lock*) ;; *) fail "a lock-blocked run does not name the lock: [$out]" ;; esac

# 5) rc=0 BUT NO READABLE JSON: that is a NO VERDICT, not a green.
out=$(line 0 90 "$work/empty.out" "$work/missing.json")
case "$out" in *"NO VERDICT"*) ;; *) fail "a run that wrote no verdict was reported as something else: [$out]" ;; esac
case "$out" in *"green"*) fail "a run that wrote no verdict was reported as GREEN: [$out]" ;; esac

# 6) NOTHING AT ALL: still a line, never empty.
out=$(line 2 5 "$work/nonexistent.out" "$work/missing.json")
[ -n "$out" ] || fail 'an empty log and no json produced an empty line'
case "$out" in *"NO VERDICT"*) ;; *) fail "the empty case is not a NO VERDICT: [$out]" ;; esac

echo "health verdict ok (green, red, SIGTERM, budget, no-json and nothing-at-all each end in exactly one named line)"
