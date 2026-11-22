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
#     mission directory. A pid is used for one thing only, twice: the local launcher that has not named
#     its session yet (run.pid: a window of a few hundred milliseconds after a launch), and the runner
#     start recorded in launch.pid before it could write anything (round 6: at the 10-minute cap that
#     runner was named nowhere, and the next start launched a second one beside it).
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
#   * codemode - run(code=...) is the ONE execution path (Victor 21/11), so no launcher exports a
#     switch and every launcher CLEARS an inherited WASM_AGENT_RAW_CODE: a mission that inherited one
#     would be refused by name instead of running;
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
# THREE answers, never two (round 5): rc 0 with the writers, rc 1 with nothing (the processes are gone), rc 2
# with NP_WHY - the node's memory db cannot be read, or a live pid's cwd cannot be read. writers_check passes
# rc 2 through and mission_run calls it 'unknown', because "no writer" and "cannot tell" are never collapsed:
# before round 5 that rc 2 became "no writer", the verdict became 'released', and start launched past a read
# this script could not make.
# The reason travels on STDOUT, not in a variable: its caller reads it through $( ), and a global set inside a
# command substitution never reaches that caller (measured while writing this round: the refusal printed
# "cannot be read:  - so ...", with the reason gone). A reason line starts with '! cannot-tell ', so it can
# never be mistaken for a writer row - those start with the session id.
cannot_tell() { printf '! cannot-tell %s\n' "$1"; }
node_presence() { # <mission dir> <worktree> -> lines "<session><TAB><pid><TAB><age><TAB><cwd>"
  local home db rows sid pid age cwd mdir wtdir why=''
  home=${MISSION_NODE_HOME:-$HOME/.wasm-agent}
  db=$home/memory.db
  command -v sqlite3 >/dev/null 2>&1 || {
    cannot_tell "no sqlite3 on PATH, so $db and its session_presence rows cannot be read"; return 2; }
  [ -r "$db" ] || {
    cannot_tell "$db is missing or unreadable, so which process serves which session cannot be told"; return 2; }
  rows=$(sqlite3 -readonly "$db" \
    "select session_id, pid, cast(strftime('%s','now')-heartbeat_at as int) from session_presence" 2>/dev/null) || {
    cannot_tell "$db could not be queried for session_presence (locked, or no such table)"; return 2; }
  [ -n "$rows" ] || return 0
  # THE PATHS THIS READ COMPARES ARE RESOLVED FIRST (round 7). /proc/<pid>/cwd reports where a process really
  # is, so a mission tree reached through a symlink (MISSIONS_DIR a link, or one under a linked directory) read
  # back as the path it points at, the bare string compare below said "another directory", and a writer was
  # scored as no writer at all: a launch beside it. 'cd ... && pwd -P' asks the kernel the same question the
  # kernel answered.
  mdir=$(cd "$1" 2>/dev/null && pwd -P) || mdir=$1
  wtdir=$(cd "$2" 2>/dev/null && pwd -P) || wtdir=$2
  while IFS='|' read -r sid pid age; do
    [ -n "$sid" ] || continue
    case $pid in
      '')
        # A row the node keeps with no process in it. Which process serves that session - and so WHERE it
        # works - cannot be told, and "no pid" is not "no writer": round 6 measured that '|| continue' here
        # skipped such a row, node_presence answered "no writer", mission_run answered 'released', and
        # start launched beside a session the node still records. Round 7: the row is REMEMBERED and the scan
        # goes ON - a row this read cannot place must not hide the writer rows further down the table.
        why="$why session $sid has a session_presence row with an empty pid, so the process serving it - and the directory it works in - cannot be told;"
        continue ;;
      *[!0-9]*)
        why="$why session $sid has a session_presence row whose pid is not a number [$pid], so the process serving it cannot be looked up at all;"
        continue ;;
    esac
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    if [ -z "$cwd" ]; then
      # NOT the same fact as "the process is gone". /proc/<pid> still there means the process is running and
      # its cwd is the one thing that says WHERE it works; unreadable (another user's process, hidepid, a
      # kernel without /proc/<pid>/cwd) leaves it working somewhere this read cannot see - which is 'unknown',
      # not 'no writer' (round 5: '|| continue' let such a live process through as if it had exited).
      if [ -d "/proc/$pid" ]; then
        why="$why pid $pid (session $sid) is running and /proc/$pid/cwd cannot be read - another user's process, or hidepid - so the directory it works in cannot be told;"
      fi
      continue                        # the process is gone: no writer
    fi
    case $cwd in
      "$mdir"|"$mdir"/*|"$wtdir"|"$wtdir"/*) printf '%s\t%s\t%s\t%s\n' "$sid" "$pid" "${age:--1}" "$cwd" ;;
    esac
  done <<<"$rows"
  # EVERY ROW READ, then one answer for the rows that could not be placed (round 7). Returning 2 at the first
  # of them answered 'unknown' for a read that had a writer further down the table - and that writer is the
  # node's own word about a live process working in this mission's directory, so 'unknown' threw away the one
  # fact the read did get.
  [ -z "$why" ] || { cannot_tell "${why# }"; return 2; }
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
# Round 5: rc 0 with a writer, rc 1 with none, and rc 2 (with NP_WHY) when the node's own record could not be
# read. The three are never collapsed here: a caller that reads rc 2 as "no writer" launches beside a process
# it cannot see, which is exactly what this round fixes.
# Sets MR_W_SESSION MR_W_PID MR_W_AGE MR_W_CWD; on rc 2 it leaves them empty and sets NP_WHY, taken from the
# '! cannot-tell' line node_presence printed.
writers_check() { # <mission dir>
  local M=$1 wt out line sid pid age cwd wrc=0
  MR_W_SESSION=''; MR_W_PID=''; MR_W_AGE='-'; MR_W_CWD=''
  wt=$(wt_of "$M")
  out=$(node_presence "$M" "$wt"); wrc=$?
  # A writer row is read FIRST, whatever else the read said (round 6, item 3). One read can name a writer AND
  # meet a row it cannot place (an empty pid, or a live pid whose cwd will not read); the writer is the node's
  # own word about a live process working in this mission's directory, it refuses a launch either way, and
  # answering 'unknown' there would throw away the one fact the read did get. Round 5 sent that read's rc 2
  # straight to 'unknown'. A reason line starts with '! cannot-tell ' and is never mistaken for a writer row -
  # those start with the session id.
  while IFS= read -r line; do
    case $line in '! cannot-tell '*) continue ;; esac
    IFS=$'\t' read -r sid pid age cwd <<<"$line"
    [ -n "$sid" ] || continue
    MR_W_SESSION=$sid; MR_W_PID=$pid; MR_W_AGE=${age:--1}; MR_W_CWD=$cwd
    return 0
  done <<<"$out"
  if [ "$wrc" -eq 2 ]; then
    NP_WHY=$(printf '%s\n' "$out" | sed -n 's/^! cannot-tell //p' | head -1)
    [ -n "$NP_WHY" ] || NP_WHY="the node's session_presence read failed and said no reason"
    return 2
  fi
  return 1                        # no writer row, and the read answered: nothing the node records works here
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
  #    Round 5: three answers here, not two. A writer is 'active'; no writer sends the question on to the run
  #    leases; and a presence read that could not be made (memory.db missing or unreadable, a live pid whose cwd
  #    cannot be read) is 'unknown' - the same never-free answer the other two reads already give.
  local wrc=0
  writers_check "$M"; wrc=$?
  if [ "$wrc" -eq 0 ]; then
    MR_VERDICT=active; MR_SESSION=$MR_W_SESSION
    MR_WHY="session $MR_W_SESSION is served by pid $MR_W_PID, whose cwd is $MR_W_CWD - this mission's own directory - and whose last heartbeat was ${MR_W_AGE}s ago: a launch now is a second writer in $wt"
    MR_CLEAR="look at it (ps -o pid=,cmd= -p $MR_W_PID; wa steer $MR_W_SESSION --status) and let it exit - nothing here kills a process; a launch is allowed when that process is gone"
    return 0
  fi
  # 1b. The launch this mission's own start started, recorded in launch.pid before the runner could write
  #     run.pid (round 6, item 1). One live runner is one writer of the worktree whatever the node has been
  #     told yet, and the 10-minute cap below is exactly the moment nothing else names it. This branch is for
  #     the window BEFORE run.pid exists and nothing else: once the runner has written it, alive_launcher
  #     (the CLI whose cwd is the mission dir) and the node's word decide, exactly as before.
  local lrc=0 lpid=''
  if [ ! -s "$M/run.pid" ]; then
    launch_alive "$M"; lrc=$?
    [ -s "$M/launch.pid" ] && lpid=$(cat "$M/launch.pid" 2>/dev/null)
    if [ "$lrc" -eq 0 ]; then
      MR_VERDICT=active
      MR_WHY="the launch this mission recorded in $M/launch.pid is still running (pid $lpid, 'bash $M/run.sh'): it has launched or is about to, so a launch now would be a second runner in $wt"
      MR_CLEAR="wait for it ('scripts/mission.sh status $name'; $M/done is written when its CLI exits); if 'ps -o pid=,cmd= -p $lpid' shows a program that is not $M/run.sh, that number was re-used and the file is stale: rm $M/launch.pid"
      return 0
    fi
    if [ "$lrc" -ne 1 ]; then
      MR_VERDICT=unknown
      MR_WHY="the launch this mission recorded in $M/launch.pid is a live pid ($lpid) whose cmdline and cwd cannot be read, so whether it is $M/run.sh - a runner about to write in $wt - cannot be told"
      MR_CLEAR="read it by hand (ps -o pid=,cmd= -p $lpid), then 'scripts/mission.sh status $name' once it is gone; or rm $M/launch.pid once you have checked that pid is not $M/run.sh"
      return 0
    fi
  fi
  if [ "$wrc" -ne 1 ]; then
    MR_VERDICT=unknown
    MR_WHY="the node's own record of which process works where cannot be read: $NP_WHY - so whether a process is writing in $wt cannot be told, and a launch now could be a second writer there"
    [ -n "$sid" ] && MR_WHY="$MR_WHY; this mission records session $sid"
    MR_CLEAR="read that record by hand (sqlite3 -readonly $nodehome/memory.db \"select session_id, pid from session_presence\", then readlink /proc/<pid>/cwd) and run 'scripts/mission.sh status $name' once it answers; nothing here launches past a read it could not make"
    return 0
  fi

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
  local pid cwd mdir
  [ -s "$1/run.pid" ] || return 1
  pid=$(cat "$1/run.pid" 2>/dev/null) || return 1
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 0
  # /proc reports the directory a process is really in, and $1 may be that same directory reached through a
  # symlink. Resolved before the compare, or a launcher standing in the mission dir reads as some other
  # process and the launch beside it goes ahead (round 7).
  mdir=$(cd "$1" 2>/dev/null && pwd -P) || mdir=$1
  [ "$cwd" = "$mdir" ]
}

# The launch THIS mission's start started, recorded as $! before the runner could write anything. The runner
# writes run.pid only once its CLI is up, and until round 6 the window before that was recorded nowhere: at
# the 10-minute cap start closed the start lock and refused, and the next start found no run.pid, no presence
# row and no session - all three answered "nothing is writing here" - so it called the mission released and
# started a SECOND runner beside a live one. launch.pid is that runner's pid.
# The cmdline decides when it can be read: start launches `bash <mission>/run.sh`, so a runner always names
# it, and that is what protects a mission from a number the kernel handed out again - a READABLE cmdline naming
# another program is a stale file, even when that process happens to work in the mission dir. The cwd is the
# second witness, reached only when the cmdline cannot be read at all.
#   rc 0  a live pid that is this mission's runner ($1/run.sh in its cmdline, or - cmdline unreadable - the
#         mission dir as its cwd)
#   rc 1  no launch.pid, the pid is gone, or the number now belongs to another program (a recycled pid: the
#         file is stale, and a stale number must not refuse a launch forever)
#   rc 2  a live pid whose cmdline AND cwd cannot be read: whether it is this mission's runner cannot be told
launch_alive() { # <mission dir>
  local pid cmd cwd mdir
  [ -s "$1/launch.pid" ] || return 1
  pid=$(cat "$1/launch.pid" 2>/dev/null) || return 1
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  # Both witnesses are compared with the resolved directory as well as the given one (round 7): the runner's
  # cmdline names the path start was handed, /proc reports the path that points at, and a mission tree reached
  # through a symlink is one directory with two spellings.
  mdir=$(cd "$1" 2>/dev/null && pwd -P) || mdir=$1
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case $cmd in *"$1/run.sh"*|*"$mdir/run.sh"*) return 0 ;; esac
  [ -n "$cmd" ] && return 1        # alive, but another program holds that number: the file is stale
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  case $cwd in "$1"|"$mdir") return 0 ;; esac
  return 2
}

# The environment a launch and a verify share, so there is one place for it: the mission's env file.
source_env() { # <mission dir>
  [ -f "$1/env" ] || die "no env file: $1/env (stage the mission again)"
  set +u; . "$1/env"; set -u
}
enter() { # source_env + export + cd, in this shell
  source_env "$1"
  unset WASM_AGENT_RAW_CODE  # native run(code=...) is the one execution path (Victor 21/11); never inherit another
  if [ -d "$TOOLCHAIN/cargo/bin" ]; then
    export RUSTUP_HOME="$TOOLCHAIN/rustup" CARGO_HOME="$TOOLCHAIN/cargo"
    export PATH="$TOOLCHAIN/cargo/bin:$PATH"
  fi
  # THE SAME BUILD RECORD EVERY OTHER ENTRY POINT READS (item 6 of the node-ops round). A mission that
  # ignored <home>/.wasm-agent/build.env built with a different zig, wasi-sdk or target policy than
  # deploy.sh and fast.sh on the same node - two answers to one question. An entry that names a directory
  # that is not there is refused by name here, with the one line that fixes it.
  local record_lib="$WT/scripts/lib/build-requirements.sh"
  if [ -f "$record_lib" ]; then
    . "$record_lib"
    # THE AUDIT TOO (item 8 of the node-ops round): a key nothing reads is refused by name here exactly as
    # scripts/fast.sh and scripts/deploy.sh refuse it, so one record has one answer on this node.
    if ! audit_note="$(wa_build_env_audit 2>&1)"; then
      printf '%s\n' "$audit_note" >&2
      die "the build record names a setting no build reads; remove that line, or add it to WA_BUILD_ENV_KEYS with the face that consumes it"
    fi
    wa_build_env || die "the build record names a directory that is not there; the refusal above names it and the one line that fixes it"
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
unset WASM_AGENT_RAW_CODE  # native run(code=...) is the one execution path (Victor 21/11); never inherit another
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
wait "$cli"; rc=$?
# A REFUSED TURN IS NOT A FAILED RUN (22/11, review MUST 3). While a deploy waits for or installs on this node
# the CLI refuses a NEW turn by name and exits 2 (`deploy_waiting: waiting for the install of <sha>`,
# docs/SCRIPTED-RUNS.md). Nothing was asked and nothing answered, so the launch waits and asks again - up to
# WA_DEPLOY_WAIT_LIMIT seconds in WA_DEPLOY_WAIT_STEP steps - instead of writing rc=2 into `done`, which is the
# factory reading a mission that never ran as one whose turn failed. Past the limit the refusal stands as
# itself: rc=2 in `done` and the give-up line below, because a wait that never ends must be visible.
step=${WA_DEPLOY_WAIT_STEP:-15}; case "$step" in ''|*[!0-9]*|0) step=15 ;; esac
limit=${WA_DEPLOY_WAIT_LIMIT:-900}; case "$limit" in ''|*[!0-9]*) limit=900 ;; esac
waited=0
while [ "$rc" -eq 2 ] && tail -c 4000 "$M/out.log" 2>/dev/null | grep -q deploy_waiting; do
  if [ "$waited" -ge "$limit" ]; then
    printf 'deploy-wait %s gave up after %ss: the node is still waiting for or installing a build, so this turn never started (nothing ran)\n' "$(date -u +%FT%TZ)" "$waited" >> "$M/out.log"
    break
  fi
  sleep "$step"
  waited=$((waited + step))
  printf 'deploy-wait %s the node is waiting for or installing a build: asking again (%ss of %ss)\n' "$(date -u +%FT%TZ)" "$waited" "$limit" >> "$M/out.log"
  printf 'deploy-wait %s refused (nothing ran; asking again in %ss)\n' "$(date -u +%FT%TZ)" "$step" >> "$M/lease.log"
  "$WA" chat --once "$(cat "$M/prompt.md")" >> "$M/out.log" 2>> "$M/err.log" &
  cli=$!
  echo "$cli" > "$M/run.pid"
  i=0
  while [ "$i" -lt 300 ]; do
    sid=$(sed -n 's/^wa: session \([^ ]*\) .*/\1/p' "$M/err.log" 2>/dev/null | tail -n +$((errlines + 1)) | tail -1)
    case $sid in ''|*[!0-9a-f-]*) sid='' ;; *) [ "${#sid}" -eq 36 ] || sid='' ;; esac
    [ -n "$sid" ] && break
    kill -0 "$cli" 2>/dev/null || break
    sleep 0.1; i=$((i + 1))
  done
  wait "$cli"; rc=$?
done
# THE LOCK IS BOUND AFTER THE WAIT, not before it (22/11, review MUST 3): a refused attempt names no session -
# nothing started - so a bind written next to the first ask would bind nothing and the launch would look
# sessionless in `status` while its turn has actually run.
if [ -n "${sid:-}" ]; then
  printf '%s\n' "MISSION='$NAME'" "SESSION='$sid'" "WORKTREE='$WT'" "NODE='$NODE'" "LAUNCHER='$$'" "LOCKED='$(date -u +%FT%TZ)'" > "$M/run.lock"
  printf "bind %s session=%s (the node named it; the lock is the run's)\n" "$(date -u +%FT%TZ)" "$sid" >> "$M/lease.log"
fi
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
  # The previous launch's pid files are cleared here - AFTER the gate above has read them - and not by the
  # runner this start is about to launch: a stale run.pid satisfied the wait below and let start return before
  # the new runner had taken the lock, and a stale launch.pid would be read as a runner that is still standing.
  rm -f "$M/run.pid" "$M/launch.pid"
  # 9>&- : the launcher must not inherit the start lock, or the lock would live as long as the run.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$M/run.sh" >>"$M/out.log" 2>>"$M/err.log" </dev/null 9>&- &
  else
    nohup bash "$M/run.sh" >>"$M/out.log" 2>>"$M/err.log" </dev/null 9>&- &
  fi
  pid=$!
  # The runner's own pid, recorded before it can write anything: from here on this mission has a launcher even
  # while no run.pid, no presence row and no session name one, and mission_run answers 'active' for it (round 6,
  # item 1). Refusing to go on without that record is the honest answer: a launched runner nobody can name is
  # exactly the state that let a second start launch beside it.
  if ! printf '%s\n' "$pid" > "$M/launch.pid" 2>/dev/null; then
    exec 9>&-
    refuse launcher \
      "the runner of $name was started (pid $pid) but its pid could not be recorded in $M/launch.pid, so no later start could tell that a launch is standing here" \
      "watch it (ps -o pid=,cmd= -p $pid; tail -5 $M/out.log; tail -5 $M/err.log), then run 'scripts/mission.sh start $name' once it is gone"
  fi
  # THE WINDOW CLOSES WHEN THE RUNNER HAS ITS run.pid, never on a clock (round 5). While that runner lives this
  # start waits and keeps the flock: a runner that is slow to write run.pid has launched nothing yet, and
  # printing "started" for it is a launch that did not happen. A runner that ENDS without writing one (95 wrong
  # node, 96 cannot cd, 97 no mission dir, 98 no env) launched nothing at all, so its own exit is the refusal.
  # Measured 18/11: the 5 s cap printed "started" and returned 0 for such a runner, and the mission looked
  # launched while nothing was writing in its worktree.
  # MISSION_START_WAIT_SECONDS (default 600 = 10 min) is a seam for scripts/test-mission.sh, which cannot wait
  # ten minutes for that cap. It can only SHORTEN this wait, and a shorter wait permits nothing: it arrives
  # sooner at the refusal below, where the runner is named by launch.pid, and a runner that has ended is a
  # refusal either way.
  local cap=${MISSION_START_WAIT_SECONDS:-600}
  while [ ! -s "$M/run.pid" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1; i=$((i + 1))
    [ "$i" -lt $((cap * 10)) ] || break
  done
  if [ ! -s "$M/run.pid" ]; then
    exec 9>&-
    if kill -0 "$pid" 2>/dev/null; then
      refuse launcher \
        "the runner of $name is alive (pid $pid) but has written no $M/run.pid in ${cap}s, so this start cannot say that a launch happened, and a launch beside it would be a second writer in $wt. That pid is recorded in $M/launch.pid, so a new start refuses [active] until this process is gone" \
        "look at it (ps -o pid=,cmd= -p $pid) and at what it printed (tail -5 $M/out.log; tail -5 $M/err.log); nothing here kills a process"
    fi
    local wrc=0
    wait "$pid" 2>/dev/null; wrc=$?
    refuse launcher \
      "the runner of $name ended rc=$wrc before it wrote $M/run.pid, so this was NOT a launch: no session was named and nothing is writing in $wt (95 = wrong node, 96 = cannot cd to the mission dir, 97 = cannot find it, 98 = no env file; any other rc means it was killed before its first write)" \
      "read what it said (tail -5 $M/err.log; tail -5 $M/out.log) and fix what it names, then run 'scripts/mission.sh start $name' again - there is no lock or pid file to clear, the run never began"
  fi
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
  elif launch_alive "$M"; then
    launcher="pid $(cat "$M/launch.pid") (the runner this mission's start launched; it has written no run.pid yet, and it is not liveness either)"
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
  # ONE ANSWER HERE TOO (round 7). verify runs a command in the worktree, so it competes with a writer exactly
  # as a launch does, and 'active' was its only refusal: an 'unknown' read (a presence row that cannot be
  # placed, a node that could not be asked) and a 'stale' leftover both ran cargo beside a possible writer in
  # that worktree. Unknown is never yes - the same rule start and clean already keep.
  [ "$MR_VERDICT" = released ] || refuse "$MR_VERDICT" \
    "a verify runs a command in $M/wt, and this mission's run is not released: $MR_WHY" \
    "$MR_CLEAR"
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
  # ONE CLEAN AT A TIME, AND NEVER BESIDE A START (round 7). clean deleted the worktree and the mission's files
  # while a start could be inside its check-and-launch on the same mission: that start's gate had already read
  # the files this removal then took away, and it launched into a tree being cleaned. The same kernel lock
  # start uses is taken first, over the whole check-and-remove, and a held lock refuses.
  command -v flock >/dev/null 2>&1 || die "no flock on PATH (util-linux): a clean beside a start is a kernel lock, not a guess"
  local LOCK=$M/start.flock
  exec 9>>"$LOCK" || die "cannot open $LOCK"
  flock -n 9 || die "refusing: another 'start' or 'clean' of $name is inside its check-and-launch right now (flock -n on $LOCK). Wait for it: 'scripts/mission.sh status $name' shows what that run did, and the kernel releases that lock when that start exits. There is nothing to clear."
  mission_run "$M"
  # ONE answer permits a clean - released - and every other one refuses by name (round 5). 'active' was the
  # only refusal, so a 'stale' row (a leftover record) and 'unknown' (a read that could not be made) went
  # straight to 'git worktree remove': a clean retired a mission that might still have had a writer, which is
  # the same guess this round removes from 'start'. A leftover is settled by hand first, and the refusal names
  # the command; --force still discards uncommitted work, and still decides nothing about the run.
  [ "$MR_VERDICT" = released ] || refuse "$MR_VERDICT" \
    "a clean removes the worktree and retires this mission, and its run is not released: $MR_WHY" \
    "$MR_CLEAR"
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
  rm -f "$M/run.sh" "$M/run.pid" "$M/launch.pid"
  # start.flock is NOT removed: this clean HOLDS that lock (fd 9 above), and deleting the file it holds leaves
  # the next start locking a different inode - no exclusion at all. The file may stay; the lock is the kernel's,
  # not the file's, and the kernel drops it when this clean exits (round 7).
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
