#!/usr/bin/env bash
# THE DEPLOY'S OWN "I AM RUNNING" STATE: one small file the installer writes before it fetches or compiles
# anything, clears when it exits, and every running turn reads at its next step boundary
# (lua/core/deploy_pause.lua).
#
# WHY THIS EXISTS (measured on this node, 24/11 21:15-21:27Z). The sentinel CLAIMS a deploy request, starts this
# script DETACHED, and moves the request to `done/` the moment it has started it - 8 s after the claim, in the live
# case. This script then fetched and COMPILED for 430 s and wrote the deploy-pending marker only after that (the
# marker belongs to scripts/upgrade.sh, which runs after the build). In between there was NO request, NO claimed
# request and NO marker, so lua/core/deploy_pause.lua's release_due concluded the install was over: it released two
# paused sessions, they each ran a paid resume turn that found installed.txt unchanged and were told "[deploy] the
# update did not happen", and then the marker paused them again and they were released a second time. Two sessions,
# two paid turns each, for one install.
#
# WHAT THIS IS NOT. It is not a second state machine and not a control channel: a turn only reads it, `deploy.sh`
# only writes and clears it, and the reader ignores it past its own bound. It is the deploy saying "I am the
# install in progress" for the whole of its life, instead of the request file saying it for the first 8 s.
#
# THE FACT CANNOT GO STALE: the record carries the writer's pid AND that pid's OWN start time (field 22 of
# /proc/<pid>/stat, in clock ticks since boot), so a recycled pid - the reason a bare pid is not enough - is not this
# deploy. A deploy that dies or is killed stops matching at once (the next reader sees the pid gone), and a reader
# that cannot look at the process table at all (no /proc) falls back to the record's own bound: a killed deploy then
# holds sessions for at most that bound, which is the stated cost of not being able to see the process table.

wa_deploy_alive_dir() { # <data-dir>
  printf '%s' "${1:-${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}}"
}

wa_deploy_alive_path() { # <data-dir>
  printf '%s/deploy-alive.json' "$(wa_deploy_alive_dir "$1")"
}

# The start time a pid began at: the 22nd field of /proc/<pid>/stat, in clock ticks since boot, after the
# command's own parentheses (which may contain spaces and, in the kernel's escaping, other parentheses).
wa_deploy_alive_start_time() { # <pid>
  local pid=${1:-$$} stat tail
  [ -r "/proc/$pid/stat" ] || return 1
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  tail=${stat##*\) }
  [ "$tail" != "$stat" ] || return 1
  # `$tail` starts at field 3 (state), so starttime (field 22) is its 20th word.
  printf '%s' "$tail" | awk '{print $20}'
}

# Write the state atomically: a reader either sees the previous file or the whole new one.
# THE LIVE HOLDER, if there is one: the pid the record names, read only when that pid is still alive AND its start
# time is the one the record carries (a recycled pid is not this deploy). Prints the pid, or nothing.
wa_deploy_alive_holder() { # <data-dir> -> pid of the deploy that owns the record, or nothing
  local path text pid started now bound
  path="$(wa_deploy_alive_path "$1")"
  [ -r "$path" ] || return 0
  text="$(cat "$path" 2>/dev/null)" || return 0
  pid="$(printf '%s' "$text" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p' | head -1)"
  started="$(printf '%s' "$text" | sed -n 's/.*"pid_start":\([0-9]*\).*/\1/p' | head -1)"
  bound="$(printf '%s' "$text" | sed -n 's/.*"bound_seconds":\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$pid" ] || return 0
  case "${bound:-}" in ''|*[!0-9]*) bound=1800 ;; esac
  # A LIVE PID WITH THE RECORD'S START TIME IS THE HOLDER. A pid that is gone, or one that has been recycled (its
  # start time differs), is not, and a record older than its own bound is not either - the stated cost of a reader
  # that cannot look at the process table.
  if [ -r "/proc/$pid/stat" ]; then
    # A ZOMBIE IS NOT A HOLDER (measured while writing this test): /proc/<pid>/stat exists until the pid is reaped,
    # so a killed deploy would hold its sessions until its parent got round to wait().
    case "$(sed -n 's/^[0-9]* (.*) \([A-Za-z]\).*/\1/p' "/proc/$pid/stat" 2>/dev/null)" in
      Z|X|x) return 0 ;;
    esac
    now="$(wa_deploy_alive_start_time "$pid" 2>/dev/null)" || return 0
    if [ -n "$started" ] && [ "$now" != "$started" ]; then return 0; fi
    printf '%s' "$pid"
    return 0
  fi
  # A PID THAT IS ABSENT FROM A READABLE /proc IS A DEAD HOLDER, not a reader that cannot look: the fallback below
  # is for a host with no process table at all, and applying it here made a killed deploy hold its sessions for the
  # record's whole bound (measured while writing this test: the write still refused after the holder was killed).
  if [ -d /proc/self ]; then return 0; fi
  local since age
  since="$(printf '%s' "$text" | sed -n 's/.*"since":\([0-9]*\).*/\1/p' | head -1)"
  case "${since:-}" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(date +%s) - since ))
  [ "$age" -lt "$bound" ] && printf '%s' "$pid"
}

wa_deploy_alive_write() { # <data-dir> [bound-seconds] [commit] [writer]
  local dir path tmp bound pid_start
  dir="$(wa_deploy_alive_dir "$1")"
  path="$(wa_deploy_alive_path "$1")"
  bound="${2:-1800}"
  case "$bound" in ''|*[!0-9]*|0) bound=1800 ;; esac
  # A LIVE HOLDER IS NOT TAKEN OVER AND NOT ERASED (25/11, Fable's G). It used to be: a second deploy (one that a
  # lock or a preflight turned away, or a hand-run one) rewrote the file with its own pid, so the sessions paused on
  # the FIRST deploy were released while it was still installing.
  local holder
  holder="$(wa_deploy_alive_holder "$1")"
  if [ -n "$holder" ] && [ "$holder" != "$$" ]; then
    printf 'refused(deploy_alive_held): pid %s is running a deploy and holds %s; this one did not take it over\n' \
      "$holder" "$(wa_deploy_alive_path "$1")" >&2
    return 3
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$path.tmp.$$"
  pid_start="$(wa_deploy_alive_start_time "$$" 2>/dev/null)"
  printf '{"pid":%s,"since":%s,"bound_seconds":%s,"pid_start":%s,"commit":"%s","by":"%s"}\n' \
    "$$" "$(date +%s)" "$bound" "${pid_start:-null}" "${3:-unknown}" "${4:-deploy.sh}" > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# CLEARED ONLY BY ITS OWN WRITER (25/11, Fable's G). The trap used to remove the file unconditionally, so a deploy
# refused at the lock - or any other process that happened to exit through it - erased the RUNNING deploy's record
# and released the sessions it was holding.
wa_deploy_alive_clear() { # <data-dir>
  local path text pid
  path="$(wa_deploy_alive_path "$1")"
  [ -r "$path" ] || return 0
  text="$(cat "$path" 2>/dev/null)" || return 0
  pid="$(printf '%s' "$text" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p' | head -1)"
  if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
    return 0
  fi
  rm -f "$path" "$path".tmp.* 2>/dev/null || true
}

