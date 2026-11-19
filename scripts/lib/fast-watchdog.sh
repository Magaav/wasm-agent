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
#   -> exit 0/other: the command's own exit; 124: it hung, and its group is dead.
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
  while :; do
    kill -0 "$pid" 2>/dev/null || break
    if [ "$waited" -ge "$seconds" ]; then hung=1; break; fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$hung" = 1 ]; then
    children=$(pgrep -g "$pid" 2>/dev/null | wc -l | tr -d '[:space:]')
    kill -TERM -- "-$pid" 2>/dev/null
    sleep "$grace"
    # Anything still standing in the group after the grace: KILL, and say how many there were.
    kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    printf 'watchdog: %s produced no verdict within %ss (process group %s, %s process(es)): killed the group with TERM, then KILL after %ss\n' \
      "$label" "$seconds" "$pid" "${children:-0}" "$grace"
    return 124
  fi
  wait "$pid"
  code=$?
  return "$code"
}

# Is this exit the watchdog's own? The runner reads it to report `hung` rather than `code`.
wa_watchdog_hung() { [ "${1-}" = 124 ]; }
