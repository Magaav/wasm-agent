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
# AND THE BUDGET MUST BE BIGGER THAN ONE RUN: MEASURED, the last full suite reported seconds=1491 (24.9 min) and the
# run for d6b73496 was killed at 2936 s under the old 2400 s default. A default below ~2x a normal run turns every
# ordinary tip into "NO VERDICT: the suite hit its budget".
budget_default=$(sed -n 's/.*WA_HEALTH_SUITE_SECONDS:-\([0-9][0-9]*\).*/\1/p' "$loop" | head -1)
[ -n "$budget_default" ] || fail 'the suite budget default is not a plain number the row can read'
[ "$budget_default" -ge 3000 ] || fail "the suite budget default ($budget_default s) is not 2x the measured 1491 s run" 
grep -q 'timeout "$SUITE_BUDGET" bash $C/scripts/main-health.sh' "$loop" || fail 'the suite is not run under the budget'
grep -q 'wa_health_verdict_line "$N" "$RC" "$TOOK"' "$loop" || fail 'the loop has a path that runs the suite without printing a verdict'
# A LOCK WAIT MUST NAME ITS HOLDER: measured 02:14Z, a tip sat "resolving" for 39 minutes because .suite.lock was held
# by an unrelated job, and only `fuser` could have said so.
grep -q 'waiting for the suite lock' "$loop" || fail 'the loop waits for the suite lock in silence'
# AND THE TERM MESSAGE MUST READ AS A WHOLE SENTENCE, whatever was running: the first live firing printed
# "<sha>  NO VERDICT after 0s: this loop was TERMINATED (SIGTERM) while - a unit restart ..." with an empty sha.
grep -q 'between tips - no tip was being graded' "$loop" || fail 'a SIGTERM between tips leaves the trap message half-written'
# AND NO TIP MAY BE LEFT OPEN: measured 03:11Z, d6b73496 was graded-then-abandoned with NO line at all, and the suite
# log was 0 bytes with an hours-old mtime. The loop records the tip it opens and reports any left open on the next pass.
grep -q 'wa_health_open_note' "$loop" || fail 'the loop has no open-tip ledger, so a tip can be abandoned in silence'
grep -q 'health-open' "$loop" || fail 'nothing records which tip is open'
# WRITTEN, not merely mentioned: the record must be created when work on a tip begins, or nothing can be reported later.
grep -q '> "$M/_orch/health-open"' "$loop" || fail 'the loop never WRITES the open-tip record, so an abandoned tip stays silent'
grep -q 'rm -f "$M/_orch/health-open"' "$loop" || fail 'the loop never CLEARS the open-tip record, so every later tip would be reported as superseded' 

# AND THE TIP MUST BE CLAIMED BEFORE ANY RESOLUTION: measured 02:48Z, a restart during a 15-minute resolution was
# reported as "between tips", because TIP_SHA was only set once the binary existed. Resolution is grading.
awk '/rev-parse origin\/main/ { seen=1; next } seen && /TIP_SHA="\$N"/ { claimed=1 } END { exit !claimed }' "$loop"   || fail 'the tip is not claimed right after main is read, so a restart during resolution reads as "between tips"' 
grep -q 'what="while grading' "$loop" || fail 'the trap does not say what it was grading'
grep -q 'fuser' "$loop" || fail 'the lock-wait line does not name the holder' 

work=$(mktemp -d "${TMPDIR:-/tmp}/verdict.XXXXXX") || fail 'no temp dir'
trap 'rm -rf "$work"' EXIT
SHORT=deadbeef

# The helper itself, lifted out and run against a throwaway missions dir.
open_fn=$(awk '/^wa_health_open_note\(\)/,/^}/' "$loop")
[ -n "$open_fn" ] || fail 'could not lift wa_health_open_note out of the loop'
mkdir -p "$work/missions/_orch"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$work/missions/_orch/health-open"
note=$(M="$work/missions" bash -c "$open_fn"$'\nwa_health_open_note bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
case "$note" in *'aaaaaaaa NO VERDICT: superseded by bbbbbbbb before a verdict'*) ;; *) fail "an abandoned tip is not reported: [$note]" ;; esac
[ -e "$work/missions/_orch/health-open" ] && fail 'the open-tip record was not cleared after reporting it'

printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$work/missions/_orch/health-open"
quiet=$(M="$work/missions" bash -c "$open_fn"$'\nwa_health_open_note aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
[ -z "$quiet" ] || fail "a tip that is still current produced a note: [$quiet]"

quiet=$(M="$work/missions" bash -c "$open_fn"$'\nwa_health_open_note cccccccccccccccccccccccccccccccccccccccc')
[ -z "$quiet" ] || fail "no open tip but a note appeared: [$quiet]" 

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
