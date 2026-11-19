#!/usr/bin/env bash
# Is the running node the binary this install restored?
#
# A rollback's last step used to be 'systemctl start' and its last line 'rollback ok' whatever the start
# did - measured 19/11: the service was dead and the operator read a success line. The question is not
# what the start command returned, it is which bytes the node is executing. That is /proc/<pid>/exe,
# compared with the restored file by device and inode - a path is a name, and the question is identity.
#
# Three answers, and the third one is why this file exists:
#   ok <path>        the process is executing the restored file
#   mismatch <why>   it is executing something else (or a deleted copy of the name)
#   unknown <why>    the question cannot be answered here (no pid, no /proc, an unreadable link)
#
# A caller must never treat unknown as ok: scripts/rollback-node.sh refuses its success claim on it.
#
#   . scripts/lib/rollback-verify.sh
#   wa_running_binary_verdict <pid> <restored file>

# The pid the supervisor reports for the node, or nothing. systemd's MainPID is the one authority on a
# systemd node; anywhere else the answer is 'unknown' rather than a guess from a process list.
wa_supervised_pid() { # [unit] -> prints the pid, or nothing
  local unit=${1:-wa-sentinel.service} pid
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user show-environment >/dev/null 2>&1 || return 0
  pid="$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null | tr -d '[:space:]')"
  case "$pid" in ''|0) return 0 ;; esac
  printf '%s' "$pid"
}

wa_running_binary_verdict() { # <pid> <restored file> -> 'ok|mismatch|unknown <detail>'
  local pid=${1-} want=${2-} running a b
  [ -n "$want" ] || { printf 'unknown restored_file_not_given'; return 0; }
  [ -f "$want" ] || { printf 'unknown restored_file_missing:%s' "$want"; return 0; }
  [ -n "$pid" ] || { printf 'unknown no_pid_reported'; return 0; }
  [ -d "/proc/$pid" ] || { printf 'unknown no_proc_entry:%s' "$pid"; return 0; }
  [ -e "/proc/$pid/exe" ] || { printf 'unknown no_proc_exe:%s' "$pid"; return 0; }
  running="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [ -n "$running" ] || { printf 'unknown exe_unreadable:%s' "$pid"; return 0; }
  # A replaced or deleted file reads as '<path> (deleted)': those are not the restored bytes, whatever
  # the path says. This is the 19/11 shape - the name is right and the executing bytes are not.
  case "$running" in *' (deleted)') printf 'mismatch deleted:%s' "$running"; return 0 ;; esac
  a="$(stat -Lc '%d:%i' "/proc/$pid/exe" 2>/dev/null || true)"
  b="$(stat -c '%d:%i' "$want" 2>/dev/null || true)"
  if [ -z "$a" ] || [ -z "$b" ]; then printf 'unknown stat_failed:%s:%s' "$a" "$b"; return 0; fi
  if [ "$a" = "$b" ]; then printf 'ok %s' "$running"
  else printf 'mismatch running=%s restored=%s' "$running" "$want"; fi
}

# ---- WHICH UNIT RUNS THE NODE, AND WHICH PROCESS SERVES IT (item 5 of the node-ops round, 19/11) --------
#
# MEASURED on avell: the node runs `wa-serve.service` (`ExecStart=%h/.local/bin/wa serve --port 8799 ...`),
# and `wa-sentinel.service` is `inactive`. The verifier only ever asked the SENTINEL for its MainPID, so on
# this node it answered `rollback_unverified` while the node was serving happily - the check could not fail
# honestly, it could only be blind. The unit therefore has to be DETECTED, not assumed:
#
#   * a unit whose MainPID executes `wa` with `serve` in its argv serves directly (wa-serve.service);
#   * a unit whose MainPID executes `wa-sentinel` SUPERVISES: the serving process is the `wa ... serve`
#     process in that unit's cgroup, not the sentinel;
#   * anything else is not the node, and it is skipped rather than guessed at.
#
# It prints one line per candidate that is running, `unit<TAB>pid<TAB>how`, best first; the caller takes the
# first. `how` says `serves` (the unit's own process serves) or `supervises` (its child does).
# Classify ONE process: does it serve, supervise, or neither? Pure: it reads /proc and nothing else, so a
# test can drive it with two real processes instead of a scratch systemd unit.
#   serves      this process is `wa ... serve`
#   supervises  this process is a sentinel; the serving process is printed as the second line, or nothing
#   not-a-node  anything else
wa_unit_role() { # <pid> -> 'serves' | 'supervises'; a supervising pid prints its serving child after
  local pid=${1-} exe cmdline candidate
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || { printf 'not-a-node'; return 0; }
  # The RAW link, with the kernel's ' (deleted)' suffix stripped: readlink -f resolves through the path
  # and answers nothing once the file has been replaced on disk, which is exactly the moment this
  # question is asked (a rollback swaps the binary while the old process is still serving from it -
  # measured with the fake supervisor: exe came back empty and the unit was not recognised as the node).
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  exe="${exe% (deleted)}"
  case "$(basename "${exe:-}")" in
    wa-sentinel|wa-sentinel.exe)
      printf 'supervises\n'
      # The serving process is the one whose argv says `serve` and whose exe is a wa binary, in this
      # unit's cgroup. The child list first (the common case), the cgroup second (an older sentinel that
      # re-execs itself and so is not the parent of the node).
      for candidate in $(cat "/proc/$pid/task/$pid/children" 2>/dev/null); do
        cmdline="$(tr '\0' ' ' < "/proc/$candidate/cmdline" 2>/dev/null || true)"
        case "$cmdline" in *'serve'*) printf '%s' "$candidate"; return 0 ;; esac
      done
      # The unit this pid belongs to, so the scan cannot pick up a process of another unit (or of the
      # caller) that happens to say `serve`.
      local unit_name=""
      [ -r "/proc/$pid/cgroup" ] && unit_name="$(sed -n 's|.*/\([^/]*\.service\)$|\1|p' "/proc/$pid/cgroup" 2>/dev/null | head -1)"
      for candidate in /proc/[0-9]*; do
        [ "${candidate#/proc/}" = "$pid" ] && continue
        [ -n "$unit_name" ] && [ -r "$candidate/cgroup" ] || continue
        grep -qF -- "/$unit_name" "$candidate/cgroup" 2>/dev/null || continue
        cmdline="$(tr '\0' ' ' < "$candidate/cmdline" 2>/dev/null || true)"
        case "$cmdline" in *'serve'*) ;; *) continue ;; esac
        local child_exe; child_exe="$(readlink "$candidate/exe" 2>/dev/null)"; child_exe="${child_exe% (deleted)}"
        case "$(basename "${child_exe:-}")" in wa|wa.exe) ;; *) continue ;; esac
        [ "${candidate#/proc/}" = "$pid" ] && continue
        printf '%s' "${candidate#/proc/}"
        return 0
      done
      return 0 ;;
    wa|wa.exe)
      cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
      case "$cmdline" in *'serve'*) printf 'serves' ;; *) printf 'not-a-node' ;; esac
      return 0 ;;
  esac
  printf 'not-a-node'
}

# Every running unit whose main process is a node, best first: 'unit<TAB>pid<TAB>how'. A unit can be named
# in WA_NODE_UNITS (space separated) to check one by name instead of scanning every unit.
wa_node_units() { # -> 'unit<TAB>serving-pid<TAB>how' per running candidate
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user show-environment >/dev/null 2>&1 || return 0
  local unit main role child
  { [ -n "${WA_NODE_UNITS:-}" ] && printf '%s\n' $WA_NODE_UNITS
    printf '%s\n' wa-serve.service wa-sentinel.service
    systemctl --user list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}'
  } | awk 'NF && !seen[$0]++' | while IFS= read -r unit; do
    main="$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null | tr -d '[:space:]')"
    case "$main" in ''|0) continue ;; esac
    role="$(wa_unit_role "$main")"
    case "${role%%$'\n'*}" in
      serves) printf '%s\t%s\tserves\n' "$unit" "$main" ;;
      supervises)
        child="$(printf '%s' "$role" | sed -n '2p')"
        [ -n "$child" ] && printf '%s\t%s\tsupervises\n' "$unit" "$child" ;;
    esac
  done
}

# The first line of wa_node_units, or nothing - the unit a restart must be asked of.
wa_node_unit() {
  wa_node_units 2>/dev/null | head -1 | cut -f1
}

# The pid that SERVES - not the one that supervises. This is the process whose /proc/<pid>/exe answers
# 'which bytes are answering requests'.
wa_serving_pid() {
  wa_node_units 2>/dev/null | head -1 | cut -f2
}

# The Lua tree a DIRECTORY holds, as the identity a deploy writes into it: source_commit and the
# lua_inputs digest (scripts/lib/lua-tree.sh writes <install>/lua-core/manifest.txt). Prints
# 'source_commit|lua_inputs', or nothing when the tree carries no manifest.
wa_lua_tree_identity() { # <tree dir> (a directory that holds manifest.txt)
  local manifest="${1%/}/manifest.txt"
  [ -f "$manifest" ] || return 0
  local commit inputs
  commit="$(sed -n 's/^source_commit=//p' "$manifest" 2>/dev/null | head -1 | tr -d '[:space:]')"
  inputs="$(sed -n 's/^lua_inputs=//p' "$manifest" 2>/dev/null | head -1 | tr -d '[:space:]')"
  printf '%s|%s' "$commit" "$inputs"
}

