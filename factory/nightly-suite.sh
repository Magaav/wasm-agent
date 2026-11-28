#!/usr/bin/env bash
# THE NIGHTLY FULL SUITE (Victor, 28/11): scripts/test.sh once a night, no parallel width, behind the suite
# lock, ADVISORY - it reports and nothing waits on it.
#
# Why it exists: the full gate is 431 rows and, measured four times on this node (the archives under
# ~/.wasm-agent/main-health/rows), it costs 2403 s quiet and up to 4049 s while other missions build into
# the shared target - 39 to 67 minutes. Nothing ran it on a schedule (checked 28/11: the only relevant unit
# was orch-health-loop, which runs fast.sh on main's tip), so the cost archive only ever held a table per
# release, never a trend.
#
# THE FOUR RULES THIS SCRIPT IS:
#   1. NO PARALLEL WIDTH. One suite at a time and each row alone (WA_GATE_JOBS=1, which test.sh applies to
#      cargo jobs and test threads): the loaded runs above are exactly what width plus a busy node looks
#      like, and a nightly number that moves with the load tells nobody anything.
#   2. BEHIND THE SUITE LOCK, and never in front of it: flock -n. If the rows are running, the night is
#      SKIPPED BY NAME in the log rather than queued behind an hour of somebody else's work.
#   3. ADVISORY. The unit exits 0 whatever the suite says, because a red suite is a verdict to read, not a
#      unit failure to restart; systemd retrying it would only add a second run nobody asked for.
#   4. EVERY RUN SAYS WHAT IT COST: nightly-<stamp>.log holds the output, nightly.json the verdict
#      {at, sha, rc, seconds, log} so a machine can read the trend.
set -uo pipefail

tree=${WA_NIGHTLY_TREE:-$HOME/wasm-agent/checkout}
state=${WA_NIGHTLY_STATE:-$HOME/.wasm-agent/main-health}
missions=${WA_MISSIONS:-$HOME/Work/missions}
lock=${WA_SUITE_LOCK:-$missions/.suite.lock}
budget=${WA_NIGHTLY_SECONDS:-7200}
nice_level=${WA_NIGHTLY_NICE:-10}
mkdir -p "$state" 2>/dev/null || true

stamp=$(date -u +%Y%m%dT%H%M%SZ)
log=$state/nightly-$stamp.log
verdict=$state/nightly.json

say() { echo "$(date -u +%Y-%m-%dT%H:%MZ) nightly: $*"; }

if [ ! -f "$tree/scripts/test.sh" ]; then
  say "refused(no_suite): $tree/scripts/test.sh is not there - nothing was run"
  printf '{"at":"%s","ok":false,"reason":"no_suite","tree":"%s"}\n' "$stamp" "$tree" > "$verdict"
  exit 0
fi

# RULE 2. The lock is taken non-blocking, and the holder is NAMED, so "skipped" can never be mistaken for
# "ran and found nothing".
if ! flock -n -o "$lock" true 2>/dev/null; then
  holders=$(command -v fuser >/dev/null 2>&1 && fuser "$lock" 2>/dev/null | tr -s ' ' ' ' | sed 's/^ //;s/ $//')
  say "skipped(suite_lock_held): ${lock} is held${holders:+ by pid $holders} - the rows are running, and the night does not queue"
  printf '{"at":"%s","ok":false,"reason":"suite_lock_held","holder":"%s"}\n' "$stamp" "${holders:-unknown}" > "$verdict"
  exit 0
fi

sha=$(git -C "$tree" rev-parse HEAD 2>/dev/null || echo unknown)
say "starting: $tree at ${sha:0:8}, no parallel width (WA_GATE_JOBS=1), budget ${budget}s, nice ${nice_level}"

started=$(date +%s)
flock -o "$lock" nice -n "$nice_level" env WA_GATE_JOBS=1 CARGO_BUILD_JOBS=1 RUST_TEST_THREADS=1 \
  timeout "$budget" bash -c 'cd "$1" && bash scripts/test.sh' _ "$tree" > "$log" 2>&1
rc=$?
took=$(( $(date +%s) - started ))

# RULE 3 and 4: advisory exit, and a verdict a machine can read. 124 from timeout is named as a budget hit,
# not as a red suite - the two send a reader to different places.
case "$rc" in
  0) result=ok ;;
  124) result=budget_hit ;;
  *) result=red ;;
esac
say "finished: $result in ${took}s (rc=$rc), log $(basename "$log")"
printf '{"at":"%s","sha":"%s","rc":%s,"result":"%s","seconds":%s,"log":"%s","jobs":1}\n' \
  "$stamp" "$sha" "$rc" "$result" "$took" "$log" > "$verdict"
exit 0
