#!/usr/bin/env bash
# A row that produces no verdict is named, and the processes it started die with it.
#
# MEASURED 18/11 on avell: a row's own child (`sleep 600` in a fixture) outlived the row in every case -
# `timeout 120` ends the command it was given and nothing else, so a fixture that forked a child and then
# hung left that child holding a file, a pipe or a lock for the rest of the run, and the next row failed
# for a reason three rows away. A hung row also reported only `exit 124` with an empty verdict line, so
# the reader could not tell "this row deadlocked" from "this row failed an assertion and printed nothing".
#
# One rule, two facts, and they are different questions:
#   * the row is put in its OWN PROCESS GROUP (`set -m`, pure bash, no setsid and no util-linux), so the
#     kill reaches every child it forked, not just the one process `timeout` knows about;
#   * when the deadline passes, the whole group gets TERM, then KILL, and the runner prints ONE named
#     line saying which row hung, for how long, and which process group it killed. That line is the
#     row's verdict, so `fast.sh` can report `hung` instead of an unexplained exit code.
#
# A child that leaves the group on purpose (`setsid`, a daemon that double-forks) survives: that is a
# deliberate escape, and pretending to catch it would be a lie. Everything else dies.
#
#   . scripts/lib/fast-watchdog.sh
#   wa_fast_watchdog 120 "lua scripts/test-x.lua" -- timeout 120 wa --db ... 
#   -> exit 0/other: the command's own exit; 124: it hung, and its group is dead - but a command may
#      return 124 itself (timeout), so wa_watchdog_hung needs the LINE as well as the code (item 8).
#
# WA_FAST_WATCHDOG_GRACE (default 2s) is how long TERM is given before KILL.

wa_fast_watchdog() { # <seconds> <label> -- <command...>
  local seconds=${1-} label=${2-}
  shift 2 2>/dev/null || true
  [ "${1-}" = "--" ] && shift
  case "$seconds" in ''|*[!0-9]*) printf 'watchdog: refused(watchdog_seconds_invalid): %q is not a whole number of seconds\n' "$seconds" >&2; return 2 ;; esac
  [ "$#" -gt 0 ] || { printf 'watchdog: refused(watchdog_command_missing): no command for %s\n' "$label" >&2; return 2; }
  local grace=${WA_FAST_WATCHDOG_GRACE:-2} pid code waited=0 hung=0 children=0
  # Job control in a non-interactive shell puts the background command in a process group of its own,
  # whose id is that command's pid. Every child it forks inherits the group; that is the whole mechanism.
  set -m
  "$@" &
  pid=$!
  set +m
  # THE POLL IS A TENTH OF A SECOND, counted in tenths (`waited` is tenths; the deadline is seconds x 10).
  # It was `sleep 1`, so every row was rounded UP to a whole second: a row that answers in 150 ms cost
  # 1000 ms, on each of ~170 rows of every run. The deadline only ever errs late (each tick is the sleep
  # plus the cost of asking), never early, so no row gets less time than it was promised.
  # WA_FAST_WATCHDOG_POLL=1 restores the whole-second poll on a host whose sleep(1) takes no fraction.
  local poll=0.1 per_second=10
  if [ "${WA_FAST_WATCHDOG_POLL:-}" = 1 ] || ! sleep 0.01 2>/dev/null; then poll=1; per_second=1; fi
  local limit=$((seconds * per_second))
  while :; do
    kill -0 "$pid" 2>/dev/null || break
    if [ "$waited" -ge "$limit" ]; then hung=1; break; fi
    sleep "$poll"
    waited=$((waited + 1))
  done
  if [ "$hung" = 1 ]; then
    children=$(pgrep -g "$pid" 2>/dev/null | wc -l | tr -d '[:space:]')
    kill -TERM -- "-$pid" 2>/dev/null
    sleep "$grace"
    # Anything still standing in the group after the grace: KILL, and say how many there were.
    #
    # ASK AGAIN FIRST (review SHOULD). After a one-second grace the pgid may belong to somebody else: the
    # group emptied and the number was reused, and a blind kill -KILL -- "-$pid" would then signal an
    # unrelated process. pgrep -g is the question "is anybody still IN THIS GROUP", so it is asked before
    # each KILL, and an empty answer means there is nothing to kill.
    if [ "$(pgrep -g "$pid" 2>/dev/null | wc -l | tr -d '[:space:]')" -gt 0 ] 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
    printf 'watchdog: %s produced no verdict within %ss (process group %s, %s process(es)): killed the group with TERM, then KILL after %ss\n' \
      "$label" "$seconds" "$pid" "${children:-0}" "$grace"
    return 124
  fi
  wait "$pid"
  code=$?
  # A ROW THAT EXITS NORMALLY STILL OWNS ITS PROCESS GROUP (item 0, the 19/11 OOM - growth C).
  #
  # The kill above only ran when the row HUNG. A row that finished left every background child it had
  # forked running, and the next row started more: measured on this node at --jobs 2, the suite reached
  # 1,234 live "wa" processes and ~31 GB of RSS at row 45, and the sampler named their parent
  # ("bash -c run_lua ... scripts/test-session-vars.lua") as a row that had already reported ok. Each
  # such row alone peaked at 63 MB; the crowd was the sum of what nobody reclaimed.
  #
  # So the group is swept after a normal exit too. It is not a second timeout: the row is already gone.
  # Anything still in its group is a child the row forgot, killed the same way a hang's children are,
  # with one line saying so - a survivor is never silent.
  local leftovers
  leftovers=$(pgrep -g "$pid" 2>/dev/null | wc -l | tr -d "[:space:]")
  if [ "$leftovers" -gt 0 ] 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null
    sleep "${WA_FAST_WATCHDOG_REAP_GRACE:-1}"
    # ASK AGAIN (review SHOULD): the grace may have emptied the group and freed the pgid for reuse. A KILL
    # to a reused group signals an innocent process; membership is re-checked before every signal.
    if [ "$(pgrep -g "$pid" 2>/dev/null | wc -l | tr -d '[:space:]')" -gt 0 ] 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null
    fi
    printf "watchdog: %s exited %s but left %s process(es) in its group %s: killed them (a child the row forked and did not wait for)\n" \
      "$label" "$code" "$leftovers" "$pid"
  fi
  return "$code"
}

# Is this exit the watchdog's own? The runner reads it to report `hung` rather than `code`.
# WHICH 124 IS THE WATCHDOG'S? (item 8 of the node-ops round.)
#
# The watchdog answers 124 when it killed a row that produced no verdict - but 124 is also a code a
# command returns BY ITSELF: `timeout` uses it, and so does any row with a deadline of its own. So the exit
# code alone cannot tell "this row hung and its group is dead" from "this row ended with 124", and the
# previous `[ "$1" = 124 ]` answered "hung" for both - a row that timed itself out was reported as a hang
# the watchdog never saw.
#
# The other half of the question is the line the watchdog prints when (and only when) it hung:
# "watchdog: <label> produced no verdict within <n>s ...". wa_watchdog_hung asks for BOTH, so a caller
# passes the code and the text: with no text the answer is "not a hang", because a code on its own does not
# prove one.
WA_FAST_WATCHDOG_HANG_LINE='produced no verdict within'
wa_watchdog_hung() { # <exit-code> [the text the watchdog or the row printed] -> 0 only for the watchdog's own hang
  [ "${1-}" = 124 ] || return 1
  case "${2-}" in *"$WA_FAST_WATCHDOG_HANG_LINE"*) return 0 ;; esac
  return 1
}
