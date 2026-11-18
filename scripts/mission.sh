#!/usr/bin/env bash
# The mission loop as one entry point: stage -> start -> status -> report -> verify -> clean.
#
#   scripts/mission.sh stage  <name> <base> <brief>  # mission dir, worktree, env, prompt.md, run.sh
#   scripts/mission.sh start  <name> [--force]       # ONE fresh session, detached; never a resume
#   scripts/mission.sh status [name]                 # every mission, or one: the node's run, counts
#   scripts/mission.sh report <name>                 # status + the evidence a handover needs
#   scripts/mission.sh verify <name> <cmd...>        # run <cmd> in the worktree, record its rc
#   scripts/mission.sh clean  <name> [--force]       # drop the worktree, keep the evidence
#
# Every rule below is a mechanism here because of a measured failure (measurements: docs/MISSIONS.md):
#   * LIVENESS IS THE NODE'S RUN, NOT THE LAUNCHER'S PID. Measured 18/11 on this node: session
#     830fa92f printed "provider_stalled" and its CLI exited rc=1, while the node-side run kept
#     writing; the relaunch from that rc made TWO writers in one worktree. So "start" asks the node -
#     "wa sessions" for the sessions this mission owns, and the run lease "wa steer <session>
#     --status --json" for whether one is in flight - and refuses while a session is unfinished with a
#     boot lease the node still holds, or unfinished and recently active, naming the session id. A pid is
#     used for one thing only: the local launcher that has not named its session yet, a window of a few
#     hundred milliseconds after a launch.
#   * CANNOT TELL IS NEVER FREE (round 3). If "wa sessions" prints nothing, or the boot lease cannot be
#     probed, "start" refuses and names the recorded session; --force passes an unanswerable node only
#     when no session was ever recorded. Nothing here answers "released" for want of an answer.
#   * A HELD BOOT LEASE IS ALWAYS ACTIVE (round 3). The MISSION_ACTIVE_SECONDS window may never release a
#     session whose boot lease the node holds: it called a live run stale at 969 s, and --force launched
#     past it. Stale means the lease could be TAKEN, which is the owner saying it exited.
#   * ONE START AT A TIME (round 3). The check and the launch are one step: mkdir $M/start.lock is
#     atomic and held until the launch has a run.pid, so two starts a breath apart make one launch.
#   * THE LOCK BELONGS TO THAT RUN. run.lock is taken before the CLI asks the node for a session and
#     released when the NODE says the run settled - never because a process exited. Every take, bind,
#     cli-exit and release is a line in lease.log.
#   * --force NEVER KILLS AND NEVER CANCELS. There is no wa verb that cancels a run (wa help), so
#     force skips only the local launcher check and a lease the node itself reports as not moving; it
#     never starts alongside a run the node reports active.
#   * the session id is read where the CLI prints it - STDERR ("wa: session <id> ok",
#     lua/core/chat.lua) - with stdout left as the run's own output. Round 1 read stdout, which on a
#     real launch never carries the id.
#   * toolchain on PATH, and only on THIS node - a mission on a node without cargo wrote "items 6-8
#     are not delivered: needs cargo" (harness-fixes-rust, 18/11);
#   * codemode - WASM_AGENT_RAW_CODE=codemode is exported by the runner, not remembered by the operator;
#   * cd into the mission dir - a session whose cwd is the canonical checkout writes into the tree a
#     deploy ships from (docs/FACTORY.md: runtime-worktree.txt named the wrong tree);
#   * its own CARGO_TARGET_DIR - one shared target dir is how two missions overwrite each other's work;
#   * one fresh session per launch, no resume - the runner is a single "wa chat --once";
#   * a done marker with the rc - a launch that finished and a launch that died read the same in a log;
#   * status counts "^! run_failed" - a real failure line (lua/core/run_failure.lua), not the word;
#   * no pgrep -f / pkill -f - measured on this node: a shell whose own command line carries the
#     pattern matches it, and nothing here is ever killed by pattern.
set -uo pipefail

REPO=${MISSION_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
MISSIONS=${MISSIONS_DIR:-$HOME/Work/missions}
TOOLCHAIN=${MISSIONS_TOOLCHAIN:-$HOME/wasm-agent/toolchain}
TARGET_ROOT=${MISSIONS_TARGET_ROOT:-$HOME/wasm-agent/target}
WA_BIN=${WA_BIN:-}
NODE_NAME=$(hostname -s 2>/dev/null || uname -n)
# How recently a run must have moved for an unfinished session to count as a writer that blocks a
# launch. The node moves a run's updated_at at every context boundary, so this is a gap between
# boundaries, not the length of a run (lua/core/session_watch.lua uses the same idea at 90 s for
# "alive without a live witness"). Override with MISSION_ACTIVE_SECONDS.
ACTIVE_SECONDS=${MISSION_ACTIVE_SECONDS:-300}

say() { printf '%s\n' "$*"; }
die() { printf 'mission: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

m_dir() { printf '%s/%s' "$MISSIONS" "$1"; }

check_name() { # <name>: a mission name is a directory name and a branch suffix
  case ${1-} in
    ''|*/*|*..*|*' '*) die "name must be one word, no '/' or '..': [$1]" ;;
  esac
  case $1 in [!a-zA-Z0-9]*) die "name must start with a letter or digit: [$1]" ;; esac
}

wa_bin() {
  if [ -n "$WA_BIN" ]; then printf '%s' "$WA_BIN"; else command -v wa || true; fi
}

# A session id, and nothing else, is handed to SQL. The id comes out of a FILE - run.lock, or the line the
# CLI printed ("wa: session <id> ok") - so it is text an edit, a stray echo or a truncated write can change,
# and one quote in it turns node_boot_lease's query into a different query. The node's ids are 36
# characters of [0-9a-f-] (measured: this session's own ids, the "wa sessions" rows, the claims.sqlite
# keys), so that is what passes here and nothing else does (review round 3, item 6).
session_id_ok() { # <candidate>
  case ${1-} in ''|*[!0-9a-f-]*) return 1 ;; esac
  [ ${#1} -eq 36 ]
}

# ---------------------------------------------------------------- the node's word
# The marker is the FIRST LINE of prompt.md, which is what the node shows as the session title
# (lua/core/memory.lua title_from: first line, markdown furniture stripped, 60 chars, then an
# ellipsis). It names the mission and the worktree in plain words, so a session can be matched back
# to its mission after the launcher that started it is long gone.
marker_of() { # <name> <worktree>
  printf 'mission %s in %s' "$1" "$2"
}

wt_of() { # <mission dir>
  local wt=''
  [ -f "$1/env" ] && wt=$(sed -n "s/^WT='\(.*\)'$/\1/p" "$1/env")
  [ -n "$wt" ] || wt=$1/wt
  printf '%s' "$wt"
}

lock_field() { # <mission dir> <KEY>
  [ -s "$1/run.lock" ] || return 0
  sed -n "s/^$2='\(.*\)'$/\1/p" "$1/run.lock" | tail -1
}

# The session id the CLI named for this mission. It prints "wa: session <id> ok" on STDERR, so that
# log is read first; out.log is checked too, because a stub (and an older launch) may put it there.
recorded_session() { # <mission dir>
  local id=''
  [ -s "$1/err.log" ] && id=$(sed -n 's/^wa: session \([^ ]*\) .*/\1/p' "$1/err.log" | tail -1)
  if [ -z "$id" ] && [ -s "$1/out.log" ]; then
    id=$(sed -n 's/^wa: session \([^ ]*\) .*/\1/p' "$1/out.log" | tail -1)
  fi
  # A line that does not carry a session id is not a session id: the log is a file, not the node's word
  # (review round 3, item 6). An unreadable id is dropped, which leaves the title match and the presence
  # read to decide - both of those are the node's own answer.
  session_id_ok "$id" || id=''
  printf '%s' "$id"
}

detail_age() { # "12m" -> seconds
  local n=${1%?} u=${1#"${1%?}"}
  case $u in
    s) printf '%s' "$n" ;;
    m) printf '%s' $((n * 60)) ;;
    h) printf '%s' $((n * 3600)) ;;
    d) printf '%s' $((n * 86400)) ;;
    *) printf '%s' -1 ;;
  esac
}

# One read of "wa sessions", normalized to lines of "<id> TAB <state> TAB <title> TAB <age-seconds>",
# age -1 when the node printed no detail line (it prints one only for an unfinished thread). Cached per
# process: status asks the node once, whatever it needs from it.
NODE_LOADED=''
NODE_ROWS=''
NODE_ANSWER=''      # yes: the node answered (even with no rows). no: nothing came back.
load_node() {
  [ "$NODE_LOADED" = yes ] && return 0
  NODE_LOADED=yes
  NODE_ROWS=''
  local wa out line id state title age i row
  wa=$(wa_bin)
  [ -n "$wa" ] || return 1
  out=$("$wa" sessions 100 2>/dev/null) || out=''
  [ -n "$out" ] || return 1
  # The node answered. That is a different fact from "no session is listed", and mission_run says so:
  # a fresh mission whose first launch is being checked has no rows and is not a refusal, while a node
  # that printed nothing at all is (review round 3, item 1).
  NODE_ANSWER=yes
  local ids=() states=() titles=() ages=()
  while IFS= read -r line; do
    case $line in
      '') continue ;;
      [[:space:]]*)
        # the detail line of the row above: its trailing ", <n><unit> ago" is that row's age
        if [ ${#ids[@]} -gt 0 ]; then
          age=$(printf '%s' "$line" | sed -n 's/.*, \([0-9][0-9]*[smhd]\) ago$/\1/p')
          [ -n "$age" ] && ages[$(( ${#ids[@]} - 1 ))]=$(detail_age "$age")
        fi
        continue ;;
    esac
    id=${line%%  *}
    case $id in *[!0-9a-f-]*) continue ;; esac   # a note from the node, not a session row
    state=$(printf '%s' "$line" | sed -n 's/.*messages=[0-9][0-9]*  *\([a-z][a-z]*\)  .*/\1/p')
    title=$(printf '%s' "$line" | sed -n 's/.*messages=[0-9][0-9]*  *[a-z][a-z]*  *//p')
    [ -n "$state" ] || continue
    ids+=("$id"); states+=("$state"); titles+=("$title"); ages+=("-1")
  done <<<"$out"
  for i in "${!ids[@]}"; do
    printf -v row '%s\t%s\t%s\t%s' "${ids[$i]}" "${states[$i]}" "${titles[$i]}" "${ages[$i]}"
    NODE_ROWS="$NODE_ROWS$row"$'\n'
  done
  return 0
}

# The run lease the node keeps for one session (lua/core/steering.lua):
# "<state> <updated_at> <run_id>". "none - -" means the node has no row for it - the honest answer for
# a session that never ran on this node. Measured shapes: active right after a boundary; settled once
# the run finished, with updated_at at the settle.
steer_row() { # <session id>
  local wa out target state upd run
  wa=$(wa_bin)
  [ -n "$wa" ] || return 1
  out=$("$wa" steer "$1" --status --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  target=$(printf '%s' "$out" | sed -n 's/.*"target":\({[^}]*}\).*/\1/p')
  if [ -z "$target" ]; then printf '%s' 'none - -'; return 0; fi
  state=$(printf '%s' "$target" | sed -n 's/.*"state":"\([a-z_]*\)".*/\1/p')
  upd=$(printf '%s' "$target" | sed -n 's/.*"updated_at":\([0-9][0-9]*\(\.[0-9]*\)\?\).*/\1/p')
  run=$(printf '%s' "$target" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')
  printf '%s %s %s' "${state:-none}" "${upd:--}" "${run:--}"
}

# The node's own lease for the boot that serves one session: the claim in resources/claims.sqlite names
# the boot, and the process serving that boot holds BEGIN EXCLUSIVE on resources/<boot>.lease.sqlite for
# its whole life - so a lock this script CAN take is that process's statement that it exited, and a held
# one is its statement that it has not (rust/wa-capabilities/src/resources.rs: "a claim is only
# reclaimed when the owner is provably gone"). Measured on this node, 18/11, by the other session on
# this mission: of eight session claims, five boots were held and three free, and the three free ones
# were exactly the sessions whose process had exited. The probe is a read: BEGIN EXCLUSIVE then ROLLBACK
# writes nothing.
# Prints "held <why>", "free <why>" or "unknown <why>": "no owner" and "cannot tell" are different
# answers, and they are never collapsed into one.
node_boot_lease() { # <session id>
  local home store boot file
  session_id_ok "${1-}" || { printf 'unknown not a session id, so no claim can be looked up for it: [%s]' "${1-}"; return 0; }
  home=${MISSION_NODE_HOME:-$HOME/.wasm-agent}
  store=$home/resources/claims.sqlite
  command -v sqlite3 >/dev/null 2>&1 || { printf 'unknown no sqlite3 on PATH'; return 0; }
  [ -r "$store" ] || { printf 'unknown no readable %s' "$store"; return 0; }
  boot=$(sqlite3 -readonly "$store" "select boot from claims where key='session:$1' order by rowid desc limit 1" 2>/dev/null) \
    || { printf 'unknown the claim store could not be read'; return 0; }
  [ -n "$boot" ] || { printf 'free no claim is recorded for this session'; return 0; }
  file=$home/resources/$boot.lease.sqlite
  [ -e "$file" ] || { printf 'free boot %s has no lease file' "$boot"; return 0; }
  if sqlite3 "$file" 'BEGIN EXCLUSIVE; ROLLBACK;' >/dev/null 2>&1; then
    printf 'free boot %s is gone (its lease was takeable)' "$boot"
  else
    printf 'held boot %s is serving the session now' "$boot"
  fi
}

age_of() { # <epoch seconds, maybe fractional> -> whole seconds ago, or -1
  case ${1-} in ''|*[!0-9.]*|-*) printf '%s' -1; return 0 ;; esac
  printf '%s' $(( $(date +%s) - ${1%%.*} ))
}

# The writer the mission never recorded. The node keeps, per session, the OS process serving it and a
# heartbeat ('session_presence' in memory.db: session_id, pid, boot, heartbeat_at), and that process's
# own cwd is the node's answer to "which directory is this session working in": the runner cds to the
# mission dir before it starts the CLI, so a session working for this mission has the mission dir or its
# worktree as its cwd. Measured on this node, 18/11: session 6cdf7ddf, pid 1758185, heartbeat 0s old,
# /proc/1758185/cwd = /home/victor/Work/missions/mission-fabric - a writer in the very directory this
# mission launches into that no run.lock named and no title marker matched, because the harness started
# it rather than 'mission.sh stage/start'.
# rc 2 when the node's memory db cannot be read: "no writer" and "cannot tell" are never collapsed.
node_presence() { # <mission dir> <worktree> -> lines "<session><TAB><pid><TAB><age><TAB><cwd>"
  local home db rows sid pid age cwd
  home=${MISSION_NODE_HOME:-$HOME/.wasm-agent}
  db=$home/memory.db
  command -v sqlite3 >/dev/null 2>&1 || return 2
  [ -r "$db" ] || return 2
  rows=$(sqlite3 -readonly "$db" \
    "select session_id, pid, cast(strftime('%s','now')-heartbeat_at as int) from session_presence" 2>/dev/null) || return 2
  [ -n "$rows" ] || return 0
  while IFS='|' read -r sid pid age; do
    [ -n "$sid" ] && [ -n "$pid" ] || continue
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue   # the process is gone: no writer
    case $cwd in
      "$1"|"$1"/*|"$2"|"$2"/*) printf '%s\t%s\t%s\t%s\n' "$sid" "$pid" "${age:--1}" "$cwd" ;;
    esac
  done <<<"$rows"
  return 0
}

# Refuse on a writer the recorded session does not cover. Called wherever the RECORDED session has
# settled: one session can be over while another still works in the same directory - the case measured
# here on 18/11, where the mission dir's own session was 'failed' and a second session was writing in it.
# rc 0 when it decided (MR_VERDICT active or stale), rc 1 when it found no such writer.
writers_check() { # <mission dir>
  local M=$1 wt out sid pid age cwd
  local qsid='' qpid='' qage='' qcwd='' qboot='' qsboot=''
  wt=$(wt_of "$M")
  out=$(node_presence "$M" "$wt") || return 1          # cannot tell: the recorded answer stands
  [ -n "$out" ] || return 1
  while IFS=$'\t' read -r sid pid age cwd; do
    [ -n "$sid" ] || continue
    [ "$sid" = "$MR_SESSION" ] && continue             # the recorded session was already ruled on
    if [ "${age:--1}" -ge 0 ] && [ "$age" -le "$ACTIVE_SECONDS" ]; then
      MR_VERDICT=active; MR_SESSION=$sid
      MR_WHY="session $sid: the node records pid $pid serving it, that process's cwd is $cwd - this mission's own directory - and its last heartbeat was ${age}s ago, so a launch now is a second writer in $wt"
      return 0
    fi
    # Quiet is not gone. A heartbeat older than the window can still belong to a process whose boot
    # lease the node holds - and a lease this script CANNOT take is that process saying it is still
    # there (review round 3, item 2: the 300 s window alone called a live run stale at 969 s). So the
    # lease decides here too, and the age is only what the message reports.
    qboot=$(node_boot_lease "$sid")
    case $qboot in
      held*)
        MR_VERDICT=active; MR_SESSION=$sid
        MR_WHY="session $sid: the node records pid $pid serving it with cwd $cwd - this mission's own directory - and $qboot, so a launch now is a second writer in $wt (its heartbeat was ${age}s ago: quiet, not gone)"
        return 0 ;;
      free*) : ;;
      *)
        # Cannot tell whether the owner is alive: a refusal, never a release (round 3, item 3).
        MR_VERDICT=active; MR_SESSION=$sid
        MR_WHY="session $sid: pid $pid still has $cwd as its cwd and $qboot, so nothing here can show the owner is gone; a launch now could be a second writer in $wt"
        return 0 ;;
    esac
    [ -n "$qsid" ] || { qsid=$sid; qpid=$pid; qage=$age; qcwd=$cwd; qsboot=$qboot; }
  done <<<"$out"
  [ -n "$qsid" ] || return 1
  MR_VERDICT=stale; MR_SESSION=$qsid
  MR_WHY="session $qsid: pid $qpid still has $qcwd as its cwd but its last heartbeat was ${qage}s ago (> ${ACTIVE_SECONDS}s), and $qsboot: a leftover process, not a moving run"
  return 0
}

# The verdict this script believes, and the only liveness it has:
#   MR_VERDICT  active   a run is in flight and recently moved: a launch now is a second writer
#               stale    the node still lists the run active, but it has not moved for ACTIVE_SECONDS
#               released the node says the run settled, or no run exists: nothing is writing
#               unknown  the node could not be asked, or no session is recorded for this mission
#   MR_SESSION, MR_RUN, MR_AGE, MR_WHY
mission_run() { # <mission dir>
  MR_VERDICT=unknown; MR_SESSION='-'; MR_RUN='-'; MR_AGE='-'; MR_BOOT='-'
  MR_WHY='no session is recorded for this mission (no run.lock, and no "wa: session" line in its logs)'
  local M=$1 name wt marker sid lease state upd run age boot id rowstate rowtitle rowage found='' agedesc=''
  name=$(basename "$M"); wt=$(wt_of "$M"); marker=$(marker_of "$name" "$wt")
  sid=$(lock_field "$M" SESSION)
  [ -n "$sid" ] || sid=$(recorded_session "$M")
  [ -n "$sid" ] && MR_SESSION=$sid
  load_node || { MR_WHY='the node could not be asked: "wa sessions" printed nothing (no wa on PATH?)'; return 1; }

  # How the two node reads combine. The run lease says a run is in flight; the boot lease says whether
  # the process that owns that run is still there. Both are the node's own facts, and neither is a pid
  # this script remembers:
  #   run active + boot held     -> active, whatever the age says. A long tool call moves nothing for
  #                                 minutes and is still a writer: measured on this node 18/11, a live
  #                                 run whose last boundary was 969 s old, and an age window alone
  #                                 would have let a second launch in.
  #   run active + boot gone     -> stale: the row is a leftover of a process that exited
  #   run active + cannot tell   -> active: nothing can show the owner is gone, so a launch is refused
  #   run settled/cancelled/...  -> released, boot or no boot
  if [ -n "$sid" ]; then
    lease=$(steer_row "$sid")
    state=${lease%% *}
    upd=$(printf '%s' "$lease" | cut -d' ' -f2)
    run=$(printf '%s' "$lease" | cut -d' ' -f3)
    boot=$(node_boot_lease "$sid")
    MR_RUN=$run; MR_AGE=$(age_of "$upd"); MR_BOOT=$boot
    case $state in
      active)
        case $boot in
          held*)
            MR_VERDICT=active
            MR_WHY="session $sid: the node's run $run is in flight and $boot (last boundary ${MR_AGE}s ago)"
            return 0 ;;
          free*)
            MR_VERDICT=stale
            MR_WHY="session $sid: the node still lists run $run as active, but $boot, so the row is a leftover"
            return 0 ;;
          *)
            # Cannot tell whether the owner is alive. This is a refusal, not a release: the age is NOT
            # evidence here. Measured by the other session on this mission, 18/11: a live run 25 minutes
            # in reported state=active with updated_at 1533 s old (it is the run's start, not its last
            # context boundary), so any "active but older than N seconds means gone" rule releases a run
            # that is writing right now. Only a lease that can be TAKEN says the owner exited.
            MR_VERDICT=active
            MR_WHY="session $sid: the node reports run $run in flight and $boot, so nothing here can show the owner is gone (updated_at ${MR_AGE}s ago is the run's start, not its recency)"
            return 0 ;;
        esac ;;
      settled|failed|cancelled)
        writers_check "$M" && return 0
        MR_VERDICT=released
        MR_WHY="the node says run $run is $state (${MR_AGE}s ago, session $sid): no writer is left"
        return 0 ;;
      *)
        # The run lease answered nothing usable for the recorded session: 'none - -' is the node's word
        # for "no row", 'unknown' is it saying it cannot tell, an empty answer is the read failing. None
        # of them is a release - the boot lease is asked, and only a lease the probe can TAKE lets the
        # session list decide (round 3, items 2-3).
        case $boot in
          held*)
            MR_VERDICT=active
            MR_WHY="session $sid: the run lease answered '$state' but $boot, so the owner is still there"
            return 0 ;;
          free*) : ;;
          *)
            MR_VERDICT=active
            MR_WHY="session $sid: the run lease answered '$state' and $boot, so nothing here can show the owner is gone"
            return 0 ;;
        esac ;;
    esac
  fi

  # 2. no lease row: the session list's own state, with the age it printed beside it. A session that is
  #    unfinished and moved recently is a writer whether or not it kept a run row.
  while IFS=$'\t' read -r id rowstate rowtitle rowage; do
    [ -n "$id" ] || continue
    if [ -n "$sid" ]; then
      [ "$id" = "$sid" ] || continue
    else
      # matched by the title the marker gave it: the node truncates at 60 chars, so the title is a
      # prefix of the marker minus its ellipsis, and the marker is what carries name and worktree.
      [ "${#rowtitle}" -ge 20 ] || continue
      case $marker in "${rowtitle%…}"*) : ;; *) continue ;; esac
      [ -n "$found" ] && continue          # the list is newest first: the first match is the newest
      found=$id; MR_SESSION=$id
    fi
    case $rowstate in
      unfinished)
        boot=$(node_boot_lease "$id"); MR_BOOT=$boot
        if [ "$rowage" -lt 0 ]; then agedesc='the node printed no age for it'
        else agedesc="its last message was ${rowage}s ago"; fi
        case $boot in
          held*)
            # A HELD BOOT LEASE IS ALWAYS ACTIVE, at any age. The age window is a guess about the gap
            # between context boundaries; the lease is the owner's own statement that it has not exited.
            # Measured on this node, 18/11: a live run whose last boundary was 969 s old, which a 300 s
            # window called stale - and --force then launched past a live writer (round 3, item 2).
            MR_VERDICT=active; MR_AGE=$rowage
            MR_WHY="session $id is unfinished, $agedesc, and $boot: quiet is not gone, so a launch now is a second writer in $wt"
            return 0 ;;
          free*)
            # The probe could TAKE the boot lease, which is the owner's statement that it exited: the row
            # is a leftover. Stale, never released on the transcript age alone.
            MR_VERDICT=stale; MR_AGE=$rowage
            MR_WHY="session $id is unfinished, $agedesc, and $boot: a leftover row, not a moving run"
            return 0 ;;
          *)
            # Cannot tell whether the owner is alive: a refusal, never a release (review round 3, item 3).
            # An unreadable store or no sqlite3 used to answer 'released' right here.
            MR_VERDICT=active; MR_AGE=$rowage
            MR_WHY="session $id is unfinished, $agedesc, and $boot, so nothing here can show the owner is gone"
            return 0 ;;
        esac
        ;;
      *)
        writers_check "$M" && return 0
        MR_VERDICT=released; MR_AGE=$rowage
        MR_WHY="session $id is $rowstate: no run is in flight"
        return 0
        ;;
    esac
  done <<<"$NODE_ROWS"
  [ -n "$found" ] || {
    writers_check "$M" && return 0
    if [ "$NODE_ANSWER" = yes ]; then
      # The node answered and lists no session for this mission: with nothing recorded and nothing listed
      # there is no run of this mission to be a second writer of a launch now. (No answer at all stays
      # 'unknown' and refuses - see cmd_start.)
      MR_VERDICT=released
      MR_WHY="the node answered and lists no session for this mission (no run.lock, no 'wa: session' line, no title match)"
      return 0
    fi
    return 0
  }
  writers_check "$M" && return 0
  MR_VERDICT=released
  MR_WHY="session $found: the node lists no run in flight"
  return 0
}

# The lock is released by an OBSERVER of the node's word - status, start, clean - never by a process
# exiting. Removing it and writing the reason is one act, so lease.log always explains a missing lock.
release_lock() { # <mission dir> <by> <why>
  [ -f "$1/run.lock" ] || return 0
  local sid; sid=$(lock_field "$1" SESSION)
  rm -f "$1/run.lock"
  printf 'release %s session=%s by=%s: %s\n' "$(date -u +%FT%TZ)" "${sid:--}" "$2" "$3" >>"$1/lease.log"
  return 0
}

# A launcher is not a run: it is the local process that has not named its session yet, or the CLI of a
# run the node has already settled. It closes the window in which two starts could both find no
# session. It is never the reason a mission is called running, and it is never killed.
alive_launcher() { # <mission dir>
  local pid cwd
  [ -s "$1/run.pid" ] || return 1
  pid=$(cat "$1/run.pid" 2>/dev/null) || return 1
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 0
  [ "$cwd" = "$1" ]
}

# The environment a launch and a verify share, so there is one place for it: the mission's env file.
source_env() { # <mission dir>
  [ -f "$1/env" ] || die "no env file: $1/env (stage the mission again)"
  set +u; . "$1/env"; set -u
}
enter() { # source_env + export + cd, in this shell
  source_env "$1"
  export WASM_AGENT_RAW_CODE=codemode
  if [ -d "$TOOLCHAIN/cargo/bin" ]; then
    export RUSTUP_HOME="$TOOLCHAIN/rustup" CARGO_HOME="$TOOLCHAIN/cargo"
    export PATH="$TOOLCHAIN/cargo/bin:$PATH"
  fi
  export CARGO_TARGET_DIR="$TARGET"
  [ -d "$WT" ] || die "no worktree at $WT (cleaned? not staged?)"
  cd "$WT" || die "cannot cd $WT"
}

# ---------------------------------------------------------------- stage
cmd_stage() {
  local name=${1-} base=${2-} brief=${3-}
  [ -n "$name" ] && [ -n "$base" ] && [ -n "$brief" ] || die "usage: mission.sh stage <name> <base> <brief>"
  check_name "$name"
  local M wt text wa
  M=$(m_dir "$name"); wt=$M/wt
  if [ "$brief" = - ]; then text=$(cat); else text=$(cat "$brief" 2>/dev/null); fi
  [ -n "$text" ] || die "no brief at $brief - a mission with no brief has no scope"
  [ -e "$wt" ] && die "already staged: $wt exists (clean it, or pick another name)"
  wa=$(wa_bin); [ -n "$wa" ] || die "no 'wa' on PATH (set WA_BIN): a mission that cannot launch is not staged"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"

  mkdir -p "$M" || die "cannot create $M"
  git -C "$REPO" fetch -q origin "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null || true
  local branch="change/$name" base_sha
  git -C "$REPO" show-ref --verify -q "refs/heads/$branch" \
    && die "branch $branch already exists - one branch per mission: clean the old worktree or pick another name"
  base_sha=$(git -C "$REPO" rev-parse --verify "$base^{commit}" 2>/dev/null) \
    || die "base does not resolve to a commit: $base"
  git -C "$REPO" worktree add -q -b "$branch" "$wt" "$base_sha" \
    || die "git worktree add failed for $wt (a branch another worktree holds cannot be checked out twice)"

  printf '%s\n' \
    "NAME='$name'" "BRANCH='$branch'" "BASE='$base'" "BASE_SHA='$base_sha'" \
    "NODE='$NODE_NAME'" "WT='$wt'" "TOOLCHAIN='$TOOLCHAIN'" "TARGET='$TARGET_ROOT/m-$name'" \
    "WA='$wa'" > "$M/env" || die "cannot write $M/env"

  # The prompt: the marker first - it becomes the session's title, which is how the node's session is
  # matched back to this mission - then the brief, then where the session is.
  {
    printf '%s\n\n' "$(marker_of "$name" "$wt")"
    printf '%s\n\n' "$text"
    printf '## Where you are\n'
    printf 'Your code is the git worktree %s (branch %s, base %s); use absolute paths and cd there in\n' "$wt" "$branch" "$base"
    printf 'shell commands; do not use session_worktree. Build and test HERE on this node (%s): cargo is on\n' "$NODE_NAME"
    printf 'PATH from %s/cargo/bin, CARGO_TARGET_DIR=%s is this mission'"'"'s only build dir. Never build,\n' "$TOOLCHAIN" "$TARGET_ROOT/m-$name"
    printf 'test or sync code on another node. Run long commands once in the foreground with a long timeout;\n'
    printf 'never poll an operation in a loop (the progress guard ends a turn that repeats one). Before calling\n'
    printf 'a test failure yours, run it on the base (git stash) and name pre-existing failures in REPORT.md.\n'
    printf 'Write REPORT.md in the worktree root. Commit locally; never push.\n'
    if [ -s "$M/note.md" ]; then printf '\n## Note from the orchestrator\n'; cat "$M/note.md"; fi
  } > "$M/prompt.md"

  # One static runner: start launches it, and nothing rewrites it per launch.
  cat > "$M/run.sh" <<'RUNNER'
#!/usr/bin/env bash
# generated by scripts/mission.sh stage - re-stage to regenerate; do not edit.
set -uo pipefail
M=$(cd "$(dirname "$0")" && pwd -P) || exit 97
. "$M/env" || exit 98
cd "$M" || exit 96                       # the mission dir, never the repo's tree
[ "$(hostname -s 2>/dev/null || uname -n)" = "$NODE" ] || { echo "mission: launched on the wrong node (want $NODE)" >&2; exit 95; }
export WASM_AGENT_RAW_CODE=codemode
export RUSTUP_HOME="$TOOLCHAIN/rustup" CARGO_HOME="$TOOLCHAIN/cargo"
export PATH="$TOOLCHAIN/cargo/bin:$PATH"
export CARGO_TARGET_DIR="$TARGET"        # this mission's own build dir, never a shared one
# run.pid is this launch's, so the previous launch's is cleared before anything else: a stale pid file
# let "start" return before this runner had taken the lock (measured by this fixture).
rm -f "$M/done" "$M/run.pid"
date -u +%FT%TZ > "$M/started"
printf -- '--- launch %s %s from %s target=%s\n' "$(date -u +%FT%TZ)" "$BRANCH" "$BASE" "$CARGO_TARGET_DIR" >> "$M/out.log"
# The lock is taken BEFORE the node is asked for a session, and it names the session as soon as the CLI
# says it. Its owner is the node's run: this shell exiting is not a release. Measured 18/11 - the CLI
# exited rc=1 while the node kept writing, and that is exactly how a second writer got started.
printf '%s\n' "MISSION='$NAME'" "SESSION=''" "WORKTREE='$WT'" "NODE='$NODE'" "LAUNCHER='$$'" "LOCKED='$(date -u +%FT%TZ)'" > "$M/run.lock"
printf 'take %s launcher=%s session=- (before the node is asked for one)\n' "$(date -u +%FT%TZ)" "$$" >> "$M/lease.log"
# Only the lines THIS launch appends may name its session: err.log already carries the ids of every
# earlier launch, and a tail of the whole file bound the lock to the previous launch's session.
errlines=0
[ -f "$M/err.log" ] && errlines=$(wc -l < "$M/err.log" 2>/dev/null)
errlines=${errlines:-0}
"$WA" chat --once "$(cat "$M/prompt.md")" >> "$M/out.log" 2>> "$M/err.log" &
cli=$!
echo "$cli" > "$M/run.pid"
i=0
while [ "$i" -lt 300 ]; do
  sid=$(sed -n 's/^wa: session \([^ ]*\) .*/\1/p' "$M/err.log" 2>/dev/null | tail -n +$((errlines + 1)) | tail -1)
  # A session id is 36 characters of [0-9a-f-]; this one goes into run.lock, which start reads and hands
  # to SQL. A line that is not a session id is nothing, not a session (review round 3, item 6).
  case $sid in ''|*[!0-9a-f-]*) sid='' ;; *) [ "${#sid}" -eq 36 ] || sid='' ;; esac
  [ -n "$sid" ] && break
  kill -0 "$cli" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
if [ -n "${sid:-}" ]; then
  printf '%s\n' "MISSION='$NAME'" "SESSION='$sid'" "WORKTREE='$WT'" "NODE='$NODE'" "LAUNCHER='$$'" "LOCKED='$(date -u +%FT%TZ)'" > "$M/run.lock"
  printf "bind %s session=%s (the node named it; the lock is the run's)\n" "$(date -u +%FT%TZ)" "$sid" >> "$M/lease.log"
fi
wait "$cli"; rc=$?
printf 'rc=%s %s\n' "$rc" "$(date -u +%FT%TZ)" > "$M/done"
# The CLI's exit is not the run's end: the lock stays until an observer asks the NODE and finds the run
# settled. Saying so in lease.log is the only claim this shell makes about the run.
printf "cli-exit %s rc=%s session=%s (the lock stays: the node's run is not this pid)\n" "$(date -u +%FT%TZ)" "$rc" "${sid:--}" >> "$M/lease.log"
exit "$rc"
RUNNER
  chmod +x "$M/run.sh" || die "cannot chmod $M/run.sh"
  say "staged $name: $wt on $branch at $(git -C "$wt" log -1 --format=%h) (base $base_sha)"
  say "target $TARGET_ROOT/m-$name; brief '$brief' -> $M/prompt.md"
  say "start it: scripts/mission.sh start $name"
}

# ---------------------------------------------------------------- start
cmd_start() {
  local name=${1-} force=no
  [ -n "$name" ] || die "usage: mission.sh start <name> [--force]"
  shift || true
  case ${1-} in --force|-f) force=yes ;; esac
  check_name "$name"
  local M; M=$(m_dir "$name")
  [ -f "$M/env" ] || die "not staged: $M/env missing (stage $name <base> <brief>)"
  [ -d "$M/wt" ] || die "no worktree at $M/wt - clean and re-stage"
  [ -x "$M/run.sh" ] || die "no runner at $M/run.sh - re-stage"
  source_env "$M"
  [ "$NODE_NAME" = "$NODE" ] || die "staged on '$NODE', this is '$NODE_NAME': build where the mission was staged"

  # 0. ONE start at a time, and the check plus the launch is ONE step. Measured with the fixture (round
  #    3, item 4): two starts a breath apart both read "nothing running" and both launched, and run.lock
  #    was taken twice - each launcher's '>' overwrote the other's claim - so two writers landed in one
  #    worktree. mkdir is atomic on every filesystem this runs on; the loser never reaches mission_run,
  #    and --force does not step past it either, because a launch already in this window is exactly what
  #    force cannot know anything about. The lock is held until the launch has a run.pid and never after.
  local STARTLOCK=$M/start.lock owner i=0
  if ! mkdir "$STARTLOCK" 2>/dev/null; then
    # The holder writes its pid immediately after creating the directory, so a loser that reads an empty
    # pid is not looking at a dead start: measured here, it read '' inside that instant and took the
    # directory over. Wait for the pid before deciding - 1 s, after which it is a start that died.
    while [ "$i" -lt 20 ] && [ ! -s "$STARTLOCK/pid" ] && [ -d "$STARTLOCK" ]; do
      sleep 0.05; i=$((i + 1))
    done
    owner=$(cat "$STARTLOCK/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      die "refusing: another 'start' of $name is in this moment checking the node and launching (pid $owner holds $STARTLOCK). Two starts must not both get past that check: wait for this one to name its session (scripts/mission.sh status $name) and for $M/done, then start again. --force does not help: the launch it would race is already happening."
    fi
    # No holder alive: the window it named is over, so the directory is a leftover, not a launch in flight.
    # (It may also have been released while we waited, in which case there is nothing left to remove.)
    rm -rf "$STARTLOCK"
    mkdir "$STARTLOCK" 2>/dev/null || die "cannot take $STARTLOCK (another start took it in this instant)"
  fi
  printf '%s' "$$" > "$STARTLOCK/pid"
  trap 'rm -rf "$STARTLOCK"' EXIT

  # 1. The node's word first, and that is the one that cannot be forced: a run in flight is a writer.
  mission_run "$M"
  case $MR_VERDICT in
    active)
      die "refusing: $MR_WHY. One launch at a time - a second launch now is a second writer in $WT (measured 18/11). --force does not help: there is no wa verb that cancels a run, so nothing here can end it; 'wa steer $MR_SESSION --status' shows the run, and the lock is released when the node reports it settled." ;;
    stale)
      if [ "$force" != yes ]; then
        die "refusing: $MR_WHY. One launch at a time: wait for it to move or settle, or --force on the node's word that nothing is moving"
      fi
      say "--force: $MR_WHY"
      release_lock "$M" start "forced past a stale lease: $MR_WHY"
      ;;
    released)
      if [ -f "$M/run.lock" ]; then
        release_lock "$M" start "$MR_WHY"
        say "released a lock the node says is settled: $MR_WHY"
      fi
      ;;
    unknown)
      # "Cannot tell" is not "free". Measured in the fixture (round 3, item 1): a 'wa sessions' that
      # printed nothing left mission_run at 'unknown', this branch did nothing without --force, and
      # start launched - step 2 only refuses while the launcher pid lives, and the launcher of the
      # previous launch had already exited. So unknown REFUSES and names any recorded session; --force
      # passes it only when no session was ever recorded, because then there is nothing a second writer
      # could be a duplicate of.
      if [ "$force" = yes ] && [ "$MR_SESSION" = '-' ]; then
        say "--force: no node answer and no session was ever recorded for this mission - $MR_WHY"
        [ -f "$M/run.lock" ] && release_lock "$M" start "forced with no node answer and no session recorded"
      elif [ "$MR_SESSION" = '-' ]; then
        die "refusing: the node could not be asked ($MR_WHY), so nothing here can show that no writer is left, and no session is recorded that could be checked by hand. Get the node to answer ('wa sessions' on $NODE_NAME) and start again."
      else
        die "refusing: the node could not be asked ($MR_WHY), and this mission has recorded session $MR_SESSION, which nothing here can show is over: a launch now could be a second writer in $WT. --force does not help - there is no wa verb that cancels a run, so nothing here can end session $MR_SESSION; 'wa steer $MR_SESSION --status' shows it, and a launch is allowed again once the node answers and reports it settled."
      fi
      ;;
  esac

  # 2. The local launcher window: the milliseconds between "run.sh starts" and "the node named the
  #    session". Only --force steps past it, and it says so.
  if [ -f "$M/run.lock" ] && alive_launcher "$M"; then
    if [ "$force" = yes ]; then
      say "--force: a launcher (pid $(cat "$M/run.pid")) is still standing in $M; starting anyway"
    else
      die "refusing: a launch is starting in $M (launcher pid $(cat "$M/run.pid")) and has not named its session yet: wait for $M/done, or for 'mission.sh status $name' to show the run"
    fi
  fi

  [ -f "$M/done" ] && say "previous launch finished: $(cat "$M/done") - this is a NEW session (wa chat --once), not a resume"
  # The previous launch's pid file is cleared here, not by the runner it is about to start: a stale one
  # satisfied the wait below and let start return before the new runner had taken the lock.
  rm -f "$M/run.pid"
  local pid
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$M/run.sh" >>"$M/out.log" 2>>"$M/err.log" </dev/null &
  else
    nohup bash "$M/run.sh" >>"$M/out.log" 2>>"$M/err.log" </dev/null &
  fi
  pid=$!
  local i=0
  while [ "$i" -lt 50 ]; do [ -s "$M/run.pid" ] && break; sleep 0.1; i=$((i + 1)); done
  # The launch has its run.pid: the check+launch window is over, and the run's own lock (run.lock, owned
  # by the node's run) is what holds from here.
  rm -rf "$STARTLOCK"; trap - EXIT
  say "started $name (launcher pid $pid); the run is the node's - watch: scripts/mission.sh status $name"
}

# ---------------------------------------------------------------- status
one_status() { # <name>
  local name=$1 M; M=$(m_dir "$name")
  [ -d "$M" ] || die "no mission at $M"
  local branch=- base=- base_sha=- wt=-
  if [ -f "$M/env" ]; then
    branch=$(sed -n "s/^BRANCH='\(.*\)'$/\1/p" "$M/env")
    base=$(sed -n "s/^BASE='\(.*\)'$/\1/p" "$M/env")
    base_sha=$(sed -n "s/^BASE_SHA='\(.*\)'$/\1/p" "$M/env")
    wt=$(sed -n "s/^WT='\(.*\)'$/\1/p" "$M/env")
  fi
  if [ "$wt" = - ] && [ -d "$M/wt" ] && git -C "$M/wt" rev-parse --git-dir >/dev/null 2>&1; then
    # staged before this script wrote an env file: read the facts off the worktree instead of printing '-'
    wt="$M/wt"
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')
    base='origin/main (merge-base; no env file)'
    base_sha=$(git -C "$wt" merge-base origin/main HEAD 2>/dev/null || echo '-')
    [ "$base_sha" = '-' ] && base_sha=$(git -C "$wt" rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
  fi
  local commits=- files=- dirty=-
  if [ -n "$wt" ] && [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    commits=$(git -C "$wt" rev-list --count "$base_sha"..HEAD 2>/dev/null || echo '?')
    files=$(git -C "$wt" diff --name-only "$base_sha" HEAD 2>/dev/null | wc -l)
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
  fi

  # The run's real state is the node's answer, and a lock the node says is settled is released here by
  # the observer that read it - one line in lease.log, so a missing lock always has an explained why.
  mission_run "$M"
  local lockstate='none'
  if [ -f "$M/run.lock" ]; then
    lockstate="held (session $(lock_field "$M" SESSION), taken $(lock_field "$M" LOCKED))"
    if [ "$MR_VERDICT" = released ]; then
      release_lock "$M" status "$MR_WHY"
      lockstate="released by this read: $MR_WHY"
    fi
  fi
  local launcher='none recorded'
  if [ -s "$M/run.pid" ]; then
    launcher="pid $(cat "$M/run.pid") (the CLI process; not liveness - the node's run outlives it)"
  fi

  local done='-' failures=0 last='' boot='-'
  [ -f "$M/done" ] && done=$(cat "$M/done")
  if [ -s "$M/out.log" ]; then
    failures=$(grep -c '^! run_failed' "$M/out.log" 2>/dev/null)
    failures=${failures:-0}
    last=$(grep '^! run_failed' "$M/out.log" 2>/dev/null | tail -1)
  fi
  local session='-'
  session=$(lock_field "$M" SESSION)
  [ -n "$session" ] || session=$(recorded_session "$M")
  # The third source is the one the node's own title gave us (a mission with no lock and no log line
  # still has a session, and mission_run matched it): saying '-' there hid the fact it was found.
  [ -n "$session" ] || session=$MR_SESSION
  [ -n "$session" ] || session='-'
  [ "$session" != '-' ] && boot=$(node_boot_lease "$session")
  printf '%-10s %s\n' name "$name"
  printf '%-10s %s\n' dir "$M"
  printf '%-10s %s\n' worktree "$wt"
  printf '%-10s %s\n' branch "$branch"
  printf '%-10s %s\n' base "$base @ $base_sha"
  printf '%-10s %s\n' commits "$commits"
  printf '%-10s %s\n' files "$files"
  printf '%-10s %s\n' dirty "$dirty"
  printf '%-10s %s\n' run "$MR_VERDICT: $MR_WHY"
  printf '%-10s %s\n' session "$session"
  # 'session' is the id this mission records; 'writer' is the session the node says is working in the
  # mission's directory when that is somebody else - the two are different facts and both are printed.
  if [ -n "$MR_SESSION" ] && [ "$MR_SESSION" != '-' ] && [ "$MR_SESSION" != "$session" ]; then
    printf '%-10s %s\n' writer "$MR_SESSION (the session the node shows working in this mission's directory)"
  fi
  printf '%-10s %s\n' boot "$boot"
  printf '%-10s %s\n' lock "$lockstate"
  printf '%-10s %s\n' launcher "$launcher"
  printf '%-10s %s\n' done "$done"
  printf '%-10s %s\n' failures "$failures"
  [ -n "$last" ] && printf '%-10s %s\n' last "$last"
  [ -n "$wt" ] && [ -f "$wt/REPORT.md" ] && printf '%-10s %s\n' report "$wt/REPORT.md ($(wc -c <"$wt/REPORT.md") bytes)"
  return 0
}

cmd_status() {
  local name=${1-} d n=0
  if [ -n "$name" ]; then check_name "$name"; one_status "$name"; return 0; fi
  for d in "$MISSIONS"/*/; do
    { [ -f "$d/env" ] || [ -d "$d/wt" ]; } || continue
    n=$((n + 1)); [ "$n" -gt 1 ] && say ''
    one_status "$(basename "$d")"
  done
  [ "$n" -eq 0 ] && say "no missions under $MISSIONS"
  return 0
}

# ---------------------------------------------------------------- report
cmd_report() {
  local name=${1-}; [ -n "$name" ] || die "usage: mission.sh report <name>"
  check_name "$name"
  local M; M=$(m_dir "$name")
  one_status "$name"
  say ''
  say '-- failures (^! run_failed, newest last)'
  if [ -s "$M/out.log" ] && grep -q '^! run_failed' "$M/out.log"; then
    grep '^! run_failed' "$M/out.log" | tail -5
  else
    say 'none'
  fi
  say ''
  say '-- lease (take / bind / cli-exit / release, newest last)'
  if [ -s "$M/lease.log" ]; then tail -6 "$M/lease.log"; else say 'no lease recorded (staged or launched before this script kept one)'; fi
  say ''
  say '-- verify'
  if [ -s "$M/verify.log" ]; then tail -8 "$M/verify.log"; else say 'no verify run yet (mission.sh verify <name> <cmd...>)'; fi
  say ''
  say '-- handover'
  local wt base_sha sid
  wt=$(sed -n "s/^WT='\(.*\)'$/\1/p" "$M/env" 2>/dev/null)
  base_sha=$(sed -n "s/^BASE_SHA='\(.*\)'$/\1/p" "$M/env" 2>/dev/null)
  if [ -n "$wt" ] && [ -f "$wt/REPORT.md" ]; then
    say "REPORT.md $(wc -c <"$wt/REPORT.md") bytes; commits since base: $(git -C "$wt" log --oneline "$base_sha"..HEAD 2>/dev/null | wc -l)"
    sed -n '1,12p' "$wt/REPORT.md"
  else
    say 'no REPORT.md in the worktree yet'
  fi
  say ''
  say '-- errors (err.log, last 5)'
  if [ -s "$M/err.log" ]; then tail -5 "$M/err.log"; else say 'empty'; fi
  local done='-' rc=''
  if [ -f "$M/done" ]; then done=$(cat "$M/done"); rc=${done#rc=}; rc=${rc%% *}; fi
  say ''
  if [ -n "$rc" ] && [ "$rc" != 0 ]; then
    sid=$(lock_field "$M" SESSION); [ -n "$sid" ] || sid=$(recorded_session "$M")
    say "rc=$rc: the CLI exited, which is not the same as the run ending - read the run line above."
    say "A continuation is a RESUME of that one session, once, by hand: wa resume --session ${sid:-<id>} --once \"<what to do next>\""
  else
    say 'rc=0 or not finished: no resume needed'
  fi
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  local name=${1-}; [ -n "$name" ] || die "usage: mission.sh verify <name> <cmd...>"
  shift || true
  [ "$#" -gt 0 ] || die "usage: mission.sh verify <name> <cmd...>"
  check_name "$name"
  local M; M=$(m_dir "$name")
  mission_run "$M"
  [ "$MR_VERDICT" = active ] && die "a run is in flight ($MR_WHY): verify after it settles, or it competes for the worktree"
  enter "$M"                            # cd $WT, toolchain, codemode, this mission's target dir
  local log="$M/verify.log" rc
  printf -- '--- verify %s %s (cwd %s)\n' "$(date -u +%FT%TZ)" "$*" "$PWD" >>"$log"
  ( "$@" ) 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  printf 'rc=%s %s\n' "$rc" "$(date -u +%FT%TZ)" >>"$log"
  return "$rc"
}

# ---------------------------------------------------------------- clean
cmd_clean() {
  local name=${1-} force=no
  [ -n "$name" ] || die "usage: mission.sh clean <name> [--force]"
  case ${2-} in --force|-f) force=yes ;; esac
  check_name "$name"
  local M wt; M=$(m_dir "$name")
  [ -d "$M" ] || die "no mission at $M"
  mission_run "$M"
  [ "$MR_VERDICT" = active ] && die "a run is in flight ($MR_WHY): wait for the node to settle it; nothing here kills a process"
  wt=$(sed -n "s/^WT='\(.*\)'$/\1/p" "$M/env" 2>/dev/null)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    local dirty; dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
    if [ "$dirty" -gt 0 ] && [ "$force" != yes ]; then
      die "$wt has $dirty uncommitted path(s): commit them (they are the mission's work) or clean --force to discard"
    fi
    if [ "$force" = yes ]; then
      git -C "$REPO" worktree remove --force "$wt" || die "git worktree remove --force failed for $wt"
    else
      git -C "$REPO" worktree remove "$wt" || die "git worktree remove failed for $wt (dirty? use --force)"
    fi
    say "removed worktree $wt"
  else
    say "no worktree at ${wt:-$M/wt} (already clean)"
  fi
  release_lock "$M" clean "$MR_WHY"
  rm -f "$M/run.sh" "$M/run.pid"
  rm -rf "$M/start.lock"
  git -C "$REPO" worktree prune 2>/dev/null || true
  say "kept: $M (env, brief, prompt.md, out.log, err.log, lease.log, started, done, verify.log) and branch $(sed -n "s/^BRANCH='\(.*\)'$/\1/p" "$M/env" 2>/dev/null || echo '?') - its commits are the mission's result"
}

case ${1-} in
  stage) shift; cmd_stage "$@" ;;
  start) shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  report) shift; cmd_report "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  clean) shift; cmd_clean "$@" ;;
  ''|-h|--help|help) usage ;;
  *) usage >&2; die "unknown command: $1" ;;
esac
