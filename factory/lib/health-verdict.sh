#!/bin/bash
# ONE VERDICT PER TIP, OR SAY WHY THERE IS NONE (28/11, Victor).
#
# MEASURED: 01:35Z wrote "grading 8b8b6400 - resolving a binary of this tip" and then NOTHING for 30+ minutes, and
# _orch/health-loop-run.out ended in
#   Terminated   WA_FAST_RESULT=... flock -o "$lock" nice -n "$nice_level" bash -c "cd '$tree' && bash scripts/fast.sh"
# - a suite that was KILLED, with no line saying who killed it or when. A watchdog whose answer can be silence cannot be
# trusted on either verdict: no news read as both "fine" and "broken" depending on who was looking.
#
# So the loop calls wa_health_verdict_line for EVERY tip, on every path, and that line is one of exactly three shapes:
#   <sha> <p>/<n> green (...)
#   <sha> NEW RED: <rows> -> <proposal file>
#   <sha> NO VERDICT after Ns: <named reason>
# A killed run is a NO VERDICT with the killer named - which is the fact that was missing.

# <run.out> <rc> <seconds> <budget> -> a short, named reason. Never empty: an unexplained kill still says "no reason
# recorded in <file>", because silence is the failure this file exists to remove.
wa_health_verdict_reason() {
  local out=${1:-} rc=${2:-0} took=${3:-0} budget=${4:-0} why=""
  if [ -r "$out" ]; then
    # systemd stops a unit by sending SIGTERM to the whole cgroup, and bash prints exactly "Terminated" for the
    # process that lost it. That word plus the command it names is the best evidence available of WHO ended it.
    why=$(grep -m1 -o 'Terminated.*' "$out" 2>/dev/null | cut -c1-140)
    if [ -z "$why" ]; then why=$(grep -m1 -i '^Killed.*\|Out of memory\|No space left' "$out" 2>/dev/null | cut -c1-140); fi
    # A SUITE THAT NEVER STARTED BECAUSE THE LOCK WAS TAKEN is its own named reason - it is a wait, not a hang.
    if [ -z "$why" ]; then why=$(grep -m1 -i 'suite lock\|flock: \|lock is held' "$out" 2>/dev/null | cut -c1-140); fi
  fi
  case "$rc" in
    124) why="the suite hit its ${budget}s budget${why:+; last output: $why}" ;;
    137) why="killed with SIGKILL after ${took}s${why:+ (last output: $why)}" ;;
    143) why="terminated by SIGTERM after ${took}s${why:+ (last output: $why)}" ;;
  esac
  if [ "$rc" != 0 ] && [ -z "$why" ]; then
    why="main-health exited rc=$rc after ${took}s, no kill recorded (log: $out)"
  fi
  if [ -z "$why" ] && [ "$rc" = 0 ]; then
    why="main-health exited 0 but wrote no readable verdict (log: $out)"
  fi
  printf '%s\n' "$why"
}

# <sha> <rc> <seconds> <run.out> <json> <proposal-writer>... The THREE shapes live here, so the loop has no other path.
# Prints the line; the caller appends it. Always prints exactly one line.
wa_health_verdict_line() {
  local sha=${1:-} rc=${2:-0} took=${3:-0} out=${4:-} json=${5:-} budget=${6:-0}
  local passed checks rows why
  # A READABLE JSON DECIDES, NOT THE EXIT CODE (28/11, operator). MEASURED: a suite that ran to the end and found ten red
  # rows exits rc=1, and this function only read the json when rc=0 - so a MAIN RED of ten rows was reported as
  # "NO VERDICT rc=1" and the rows were never named. A run that names its failures HAS a verdict; only an unreadable
  # json is a run with none.
  if [ -r "$json" ] && command -v jq >/dev/null 2>&1 && jq -e . "$json" >/dev/null 2>&1; then
    passed=$(jq -r '.counts.passed // "?"' "$json" 2>/dev/null)
    checks=$(jq -r '.counts.checks // "?"' "$json" 2>/dev/null)
    rows=$(jq -r '.failed[]?.row' "$json" 2>/dev/null | sort -u | tr '\n' ' ')
    if [ -z "${rows// /}" ]; then
      printf '%s %s/%s green (%ss)\n' "${sha:0:8}" "$passed" "$checks" "$took"
    else
      # MAIN RED, in the operator's words, with the rows and the counts: a reader must be able to act on this line alone.
      printf '%s MAIN RED (%s/%s): %s(%ss)\n' "${sha:0:8}" "$passed" "$checks" "$rows" "$took"
    fi
    return 0
  fi
  why=$(wa_health_verdict_reason "$out" "$rc" "$took" "$budget")
  printf '%s NO VERDICT after %ss: %s\n' "${sha:0:8}" "$took" "$why"
}
