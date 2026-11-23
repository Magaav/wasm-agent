#!/usr/bin/env bash
# THE SENTENCE A QUEUED SUITE RUNNER WRITES: who holds the lock it is waiting for (item 1, 23/11).
#
# The measured complaint: a mission's suite queued behind another mission's ~/Work/missions/.suite.lock for
# 20-50 minutes, and neither the runner's own log nor the operation's await said whose suite it was waiting
# for, so the worker spent its turns running ps (ledger notes 0, 1, 3, 189, 244, 264, 269). The kernel
# already knows, and the same three facts are what rust/wa-operation/src/blocked.rs reads for an operation:
#
#   * /proc/locks lists the lock, with the owning pid and every waiting pid (a waiting row is marked '->');
#   * the owner's command line is /proc/<pid>/cmdline;
#   * how long it has been held is bounded by when the owner STARTED (/proc/<pid>/stat field 22 plus btime).
#     The kernel does not publish the instant of the lock, so the sentence says "at most that long" - a
#     number a reader can act on, labelled as what it is.
#
# WHAT IT DOES NOT DO: it never waits for the lock itself and never takes it. It reads and prints, so a
# caller keeps its own `flock -o` line unchanged:
#
#   . scripts/lib/lock-wait.sh
#   if ! flock -n -o "$LOCK" true 2>/dev/null; then
#     wa_lock_wait_note "$LOCK" >> "$LOG" || true     # the queue, said in the runner's own log
#   fi
#   flock -o "$LOCK" <the suite>
#
# Answers 0 with one line on stdout when somebody holds it, 1 when nobody does (nothing is printed), and 2
# when the question cannot be answered on this host (no /proc/locks, no stat) - a caller decides what to say
# about that, because a runner that cannot name the holder is not a runner that may claim there is none.

wa_lock_wait_note() { # <lock file>
  local lock=${1-} inode fields pid kind rw command_line duration line age
  [ -n "$lock" ] || return 2
  [ -r /proc/locks ] || return 2
  inode=$(stat -c '%i' -- "$lock" 2>/dev/null) || return 2
  case "$inode" in ''|*[!0-9]*) return 2 ;; esac
  # The owning row (no arrow) for this inode. The device is NOT compared: measured 23/11 on this node, a
  # file under ~/.wasm-agent reports st_dev 0x36 while /proc/locks prints the same file as 00:1e (btrfs
  # subvolume), so a device comparison would refuse to name a lock it has already found (rust/wa-operation/
  # src/blocked.rs records the same measurement).
  fields=$(awk -v want="$inode" '
    {
      if ($2 == "->") { off = 3 } else { off = 2 }   # a waiting row carries one more field
      n = split($(off + 4), parts, ":")              # dev:inode, and the device has a colon of its own
      if (parts[n] != want) next
      if ($2 == "->") { waiter = 1; next }
      printf "owner %s %s %s\n", $(off + 3), $off, $(off + 2)
      found = 1
      exit
    }
    END { if (!found && waiter) printf "waiter\n" }' /proc/locks 2>/dev/null)
  case "$fields" in
    '') # NOBODY HOLDS IT: no row for this inode at all, so there is nothing to say.
      return 1 ;;
    waiter) # SOMEONE IS QUEUED but no owning row of this inode is visible in this namespace: the lock is
            # held and this node cannot name the holder. Saying so is the honest answer; a pid here would
            # be a guess, and no line at all would read as "nobody holds it".
      printf 'waiting on a file lock: %s is held by a process this node cannot name (no owning row for it in /proc/locks)\n' "$lock"
      return 0 ;;
  esac
  read -r _ pid kind rw <<<"$fields"
  command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed -e 's/[[:space:]]*$//')
  [ ${#command_line} -gt 160 ] && command_line="${command_line:0:157}..."
  line=$(cat "/proc/$pid/stat" 2>/dev/null)
  # comm may contain spaces and parentheses, so the fields are counted from the LAST ')': after it comes
  # state, then ppid..starttime, which is field 22 of the line and the 20th of this tail.
  tail=${line##*\) }
  read -r -a fields <<<"$tail"
  duration=''
  if [ ${#fields[@]} -ge 20 ]; then
    hz=$(getconf CLK_TCK 2>/dev/null) || hz=100
    btime=$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)
    case "${fields[19]}$hz$btime" in ''|*[!0-9]*) ;; *)
      age=$(( $(date +%s) - btime - fields[19] / hz ))
      [ "$age" -lt 0 ] && age=0
      if [ "$age" -lt 60 ]; then duration="${age}s"
      elif [ "$age" -lt 3600 ]; then duration="$((age / 60))m $((age % 60))s"
      else duration="$((age / 3600))h $(((age % 3600) / 60))m"
      fi ;;
    esac
  fi
  if [ -n "$duration" ]; then
    printf 'waiting on a file lock: %s (%s %s) is held by pid %s (%s); that process started %s ago, so the lock has been held at most that long\n' \
      "$lock" "$kind" "$rw" "$pid" "$command_line" "$duration"
  else
    printf 'waiting on a file lock: %s (%s %s) is held by pid %s (%s)\n' "$lock" "$kind" "$rw" "$pid" "$command_line"
  fi
  return 0
}
