#!/usr/bin/env bash
# The mission loop as one entry point: stage -> start -> status -> report -> verify -> clean.
#
#   scripts/mission.sh stage  <name> <base> <brief>  # mission dir, worktree, env, prompt.md, run.sh
#   scripts/mission.sh start  <name>                 # ONE fresh session, detached; never a resume
#   scripts/mission.sh status [name]                 # every mission, or one: the node's run, counts
#   scripts/mission.sh report <name>                 # status + the evidence a handover needs
#   scripts/mission.sh verify <name> <cmd...>        # run <cmd> in the worktree, record its rc
#   scripts/mission.sh clean  <name> [--force]       # drop the worktree, keep the evidence
#
# Every rule below is a mechanism here because of a measured failure (measurements: docs/MISSIONS.md):
#   * LIVENESS IS THE NODE'S RUN, NOT THE LAUNCHER'S PID. Measured 18/11 on this node: session
#     830fa92f printed "provider_stalled" and its CLI exited rc=1, while the node-side run kept
#     writing; the relaunch from that rc made TWO writers in one worktree. So a launch is decided from
#     the node's own word - "wa sessions" for the sessions this mission owns, the run lease
#     "wa steer <session> --status --json" for whether one is in flight, the boot lease for whether its
#     owner still exists - and from the node's session_presence row for the process working in the
#     mission directory. A pid is used for one thing only: the local launcher that has not named its
#     session yet, a window of a few hundred milliseconds after a launch.
#   * ONE ANSWER: settled, or no launch (round 4). "start" launches when, and only when, no launcher is
#     alive, no process the node records is working in the mission's directory, and the node says every
#     session of this mission is settled. Every other answer - alive, unknown, unreachable, starting (a
#     session with no run row or no boot claim yet), held, stale - REFUSES by name, with the reason and
#     the manual command that clears it. There is no --force: unknown is never free and a leftover is
#     not a launch permission (rounds 3-4).
#   * ONE START AT A TIME (round 4). The check and the launch are one step under "flock -n" on one lock
#     file, held until the launch has a run.pid. The kernel drops it when the shell exits, so a start
#     that dies leaves nothing to clear, and two starts cannot both get past the check (round 3's mkdir
#     lock plus a dead-owner "rm -rf" could: the clearer and the taker raced each other).
#   * THE LOCK BELONGS TO THAT RUN. run.lock is taken before the CLI asks the node for a session and
#     released when the NODE says the run settled - never because a process exited. Every take, bind,
#     cli-exit and release is a line in lease.log.
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

say() { printf '%s\n' "$*"; }
die() { printf 'mission: %s\n' "$*" >&2; exit 1; }
# Every refusal is one shape: the state by name, the reason, and the command that clears it by hand.
# Round 4: 'start' has exactly one permitting answer (mission_run: released), so every other state comes
# through here - alive, held, stale, starting, unknown, unreachable.
refuse() { # <state> <reason> <command that clears it by hand>
  printf 'mission: refusing [%s]: %s\n' "$1" "$2" >&2
  printf 'mission: clear it by hand: %s\n' "$3" >&2
  exit 1
}
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

# The writer the mission never recorded. The node keeps, per session, the OS process serving it and a
# heartbeat ('session_presence' in memory.db: session_id, pid, boot, heartbeat_at), and that process's
# own cwd is the node's answer to "which directory is this session working in": the runner cds to the
# mission dir before it starts the CLI, so a session working for this mission has the mission dir or its
# worktree as its cwd. Measured on this node, 18/11: session 6cdf7ddf, pid 1758185, heartbeat 0s old,
# /proc/1758185/cwd = /home/victor/Work/missions/mission-fabric - a writer in the very directory this
# mission launches into that no run.lock named and no title marker matched, because the harness started
# it rather than 'mission.sh stage/start'.
# Round 4 asks ONE question here and no age: the process exists (its cwd reads), so it is a writer. A
# heartbeat age was a guess, and a guess that let a quiet writer through once.
# Sets MR_W_SESSION MR_W_PID MR_W_AGE MR_W_CWD; rc 0 when it found a writer, rc 1 when it found none.
writers_check() { # <mission dir>
  local M=$1 wt out sid pid age cwd
  MR_W_SESSION=''; MR_W_PID=''; MR_W_AGE='-'; MR_W_CWD=''
  wt=$(wt_of "$M")
  out=$(node_presence "$M" "$wt") || return 1        # cannot tell: the node's own reads decide
  [ -n "$out" ] || return 1
  while IFS=$'\t' read -r sid pid age cwd; do
    [ -n "$sid" ] || continue
    MR_W_SESSION=$sid; MR_W_PID=$pid; MR_W_AGE=${age:--1}; MR_W_CWD=$cwd
    return 0
  done <<<"$out"
  return 1
}

# The verdict this script believes, and the only liveness it has. Round 4 keeps four names and ONE rule:
# only 'released' permits a launch, and every other answer refuses with MR_CLEAR - the exact command an
# operator runs to clear it by hand.
#   released  every session this mission owns is settled by the node's own word, and no process the node
#             records is working in the mission's directory: a launch cannot duplicate a writer
#   active    a live process the node records is working in this mission's directory, or a run is in
#             flight with its boot lease held: the owner has not exited
#   stale     the node lists a run in flight and the boot lease can be TAKEN: the owner exited, the row
#             is a leftover. A leftover is refused too, and cleared by hand - never forced past
#   unknown   the node could not be asked, a session has no run row yet (it is starting: no claim row,
#             no lease file), or a lease cannot be probed: "cannot tell" is never free
# MR_SESSION, MR_RUN, MR_AGE, MR_BOOT, MR_WHY, MR_CLEAR
mission_run() { # <mission dir>
  MR_VERDICT=unknown; MR_SESSION='-'; MR_RUN='-'; MR_AGE='-'; MR_BOOT='-'
  MR_WHY='the node could not be asked: "wa sessions" printed nothing (no wa on PATH, or no answer)'
  MR_CLEAR="make the node answer ('wa sessions 100' on $NODE_NAME), then 'scripts/mission.sh status $name' once; a launch is allowed when it answers and every session of this mission is settled"
  local M=$1 name wt marker sid id rowstate rowtitle rowage lease state upd run boot ids=() i nodehome
  nodehome=${MISSION_NODE_HOME:-$HOME/.wasm-agent}
  name=$(basename "$M"); wt=$(wt_of "$M"); marker=$(marker_of "$name" "$wt")
  sid=$(lock_field "$M" SESSION)
  [ -n "$sid" ] || sid=$(recorded_session "$M")
  if [ -n "$sid" ] && ! session_id_ok "$sid"; then
    MR_VERDICT=unknown
    MR_WHY="the session this mission records is not a session id: [$sid] (36 characters of [0-9a-f-], or nothing)"
    MR_CLEAR="read $M/run.lock: if its SESSION line is not a session id, remove that file once you have checked it (rm $M/run.lock)"
    return 0
  fi
  [ -n "$sid" ] && MR_SESSION=$sid

  # 1. The node's own record of what is writing WHERE. This read is memory.db, not the CLI, so it also
  #    answers when the node cannot be asked at all (round 4: unknown, plus a writer the harness started).
  writers_check "$M" && {
    MR_VERDICT=active; MR_SESSION=$MR_W_SESSION
    MR_WHY="session $MR_W_SESSION is served by pid $MR_W_PID, whose cwd is $MR_W_CWD - this mission's own directory - and whose last heartbeat was ${MR_W_AGE}s ago: a launch now is a second writer in $wt"
    MR_CLEAR="look at it (ps -o pid=,cmd= -p $MR_W_PID; wa steer $MR_W_SESSION --status) and let it exit - nothing here kills a process; a launch is allowed when that process is gone"
    return 0
  }

  # 2. The node's word about every session this mission owns: the one it recorded, and every session the
  #    node lists under this mission's title (the first line of prompt.md, which the node shows as the
  #    title - lua/core/memory.lua title_from). ONE criterion decides a session: its run lease says the
  #    run is over. Nothing else is settled: not an age, not a pid, not a lease the probe can take.
  if ! load_node; then                   # MR_VERDICT=unknown, with MR_WHY/MR_CLEAR set above
    [ -n "$sid" ] && MR_WHY="$MR_WHY, and this mission records session $sid, which nothing here can show is over"
    return 0
  fi
  [ -n "$sid" ] && ids+=("$sid")
  while IFS=$'\t' read -r id rowstate rowtitle rowage; do
    [ -n "$id" ] || continue
    [ "$id" = "$sid" ] && continue
    [ "${#rowtitle}" -ge 20 ] || continue
    case $marker in "${rowtitle%…}"*) ids+=("$id") ;; esac    # the node truncates at 60 chars
  done <<<"$NODE_ROWS"
  if [ ${#ids[@]} -eq 0 ]; then
    MR_VERDICT=released
    MR_WHY="the node answered and lists no session for this mission (no run.lock, no 'wa: session' line, no title match)"
    return 0
  fi
  for i in "${ids[@]}"; do
    lease=$(steer_row "$i"); state=${lease%% *}
    case $state in settled|failed|cancelled) continue ;; esac  # the node's word: that run is over
    upd=$(printf '%s' "$lease" | cut -d' ' -f2); run=$(printf '%s' "$lease" | cut -d' ' -f3)
    MR_SESSION=$i; MR_RUN=$run; MR_AGE=$(age_of "$upd")
    boot=$(node_boot_lease "$i"); MR_BOOT=$boot
    case $state in
      active)
        case $boot in
          held*)
            MR_VERDICT=active
            MR_WHY="session $i: the node's run $run is in flight and $boot (last boundary ${MR_AGE}s ago), so a launch now is a second writer in $wt"
            MR_CLEAR="wait for that run to end (wa steer $i --status shows it; nothing here cancels a run). If you have checked that its process is gone, settle the leftover row: sqlite3 $nodehome/memory.db \"update steering_runs set state='settled' where session_id='$i'\"" ;;
          free*)
            MR_VERDICT=stale
            MR_WHY="session $i: the node still lists run $run in flight, but $boot - the owner exited, so this row is a leftover, not a launch permission: a launch now would be a launch beside a record nothing here can settle"
            MR_CLEAR="the owner has exited, so this row is a leftover: finish that one session by hand (wa resume --session $i --once \"<what is left>\") or settle its row (sqlite3 $nodehome/memory.db \"update steering_runs set state='settled' where session_id='$i'\"); then rm $M/run.lock once you have checked it" ;;
          *)
            MR_VERDICT=unknown
            MR_WHY="session $i: the node reports run $run in flight and $boot, so nothing here can show the owner is gone, and a launch now could be a second writer in $wt"
            MR_CLEAR="probe the boot lease by hand (sqlite3 -readonly $nodehome/resources/claims.sqlite \"select boot from claims where key='session:$i'\", then 'BEGIN EXCLUSIVE; ROLLBACK;' on $nodehome/resources/<boot>.lease.sqlite) and read again: a lease that can be taken means the owner exited" ;;
        esac ;;
      *)
        MR_VERDICT=unknown
        MR_WHY="session $i: the run lease answered '$state' - a session with no run row yet is a session that is STARTING (no claim row, no lease file yet), and nothing here can show it is settled: a launch now could be a second writer in $wt"
        MR_CLEAR="wait a moment and read it again (wa steer $i --status; scripts/mission.sh status $name). If that session belongs to no run here, remove the record once you have checked it (rm $M/run.lock)" ;;
    esac
    return 0
  done
  MR_VERDICT=released
  MR_WHY="the node says every session of this mission is settled (${ids[*]}) and no process the node records is working in $M"
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
# A launch happens here and only here, and only on one answer (mission_run): everything settled. There is
# no --force - a state this script cannot prove free is a state an operator clears by hand.
cmd_start() {
  local name=${1-}
  [ -n "$name" ] || die "usage: mission.sh start <name>"
  shift || true
  [ "$#" -eq 0 ] || die "start takes a name and nothing else: there is no --force (a launch is refused on the node's word; a stuck mission is cleared by hand - docs/MISSIONS.md)"
  check_name "$name"
  local M; M=$(m_dir "$name")
  [ -f "$M/env" ] || die "not staged: $M/env missing (stage $name <base> <brief>)"
  [ -d "$M/wt" ] || die "no worktree at $M/wt - clean and re-stage"
  [ -x "$M/run.sh" ] || die "no runner at $M/run.sh - re-stage"
  command -v flock >/dev/null 2>&1 || die "no flock on PATH (util-linux): one start at a time is a kernel lock, not a directory this script has to clean up"
  source_env "$M"
  [ "$NODE_NAME" = "$NODE" ] || die "staged on '$NODE', this is '$NODE_NAME': build where the mission was staged"

  # 0. ONE start at a time, and the check plus the launch is ONE step. flock -n on one file, held by this
  #    shell until the launch has a run.pid and closed then. The kernel drops it when the holder exits, so
  #    a start that dies leaves NOTHING to clear by hand, and two starts cannot both get past the check
  #    (round 3 measured 10 of 10 simultaneous pairs launching, each writing run.lock with '>'; the mkdir
  #    lock that followed could be cleared by one start while another took it - round 4, item 2).
  local LOCK=$M/start.flock pid lpid wt i=0
  wt=$(wt_of "$M")
  exec 9>>"$LOCK" || die "cannot open $LOCK"
  flock -n 9 || die "refusing: another 'start' of $name is inside its check-and-launch right now (flock -n on $LOCK). Wait for it: 'scripts/mission.sh status $name' names the session once the launch has one, and $M/done says it finished. There is nothing to clear - the kernel releases that lock when that start exits."
  # 1. THE ONE GATE: a launcher still standing, or any verdict but 'released', refuses by name. Unknown is
  #    never free: an answer this script cannot get is an answer it cannot act on.
  if alive_launcher "$M"; then
    lpid=$(cat "$M/run.pid" 2>/dev/null)
    refuse launcher \
      "a launch is standing in $M (launcher pid $lpid) and has not named its session yet, so a launch now is a second writer in $wt" \
      "wait for $M/done, or for 'scripts/mission.sh status $name' to name that session; if 'ps -o pid=,cmd= -p $lpid' shows that pid is not this mission's runner, remove the stale pid file (rm $M/run.pid) and start again"
  fi
  mission_run "$M"
  [ "$MR_VERDICT" = released ] || refuse "$MR_VERDICT" "$MR_WHY" "$MR_CLEAR"

  [ -f "$M/done" ] && say "previous launch finished: $(cat "$M/done") - this is a NEW session (wa chat --once), not a resume"
  if [ -f "$M/run.lock" ]; then
    release_lock "$M" start "$MR_WHY"
    say "released a lock the node says is settled: $MR_WHY"
  fi
  # The previous launch's pid file is cleared here, not by the runner it is about to start: a stale one
  # satisfied the wait below and let start return before the new runner had taken the lock.
  rm -f "$M/run.pid"
  # 9>&- : the launcher must not inherit the start lock, or the lock would live as long as the run.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$M/run.sh" >>"$M/out.log" 2>>"$M/err.log" </dev/null 9>&- &
  else
    nohup bash "$M/run.sh" >>"$M/out.log" 2>>"$M/err.log" </dev/null 9>&- &
  fi
  pid=$!
  while [ "$i" -lt 50 ]; do [ -s "$M/run.pid" ] && break; sleep 0.1; i=$((i + 1)); done
  # The launch has its run.pid: the check-and-launch window is over, and the run's own lock (run.lock,
  # owned by the node's run) is what holds from here.
  exec 9>&-
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
  # The handover file, where a session is told to write it (REPORT.md in the worktree root)
  # and where the repo keeps a round report for a branch that has already landed
  # (docs/missions/reports/<name>.md). Either one is the handover.
  if [ -n "$wt" ] && [ -f "$wt/REPORT.md" ]; then
    printf '%-10s %s\n' report "$wt/REPORT.md ($(wc -c <"$wt/REPORT.md") bytes)"
  elif [ -n "$wt" ] && [ -f "$wt/docs/missions/reports/$name.md" ]; then
    printf '%-10s %s\n' report "$wt/docs/missions/reports/$name.md ($(wc -c <"$wt/docs/missions/reports/$name.md") bytes)"
  fi
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
  rm -f "$M/start.flock"   # the file may stay; the LOCK is the kernel's, not the file's
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
