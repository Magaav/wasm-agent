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
