# Which running turn, if any, is this script inside of? Sourced by deploy.sh and upgrade.sh.
#
# The rule they enforce is "a node cannot replace itself": the stop is the last thing a turn running on
# that node would ever do. It used to be enforced by the environment marker WASM_AGENT_IN_TURN alone,
# which (a) a detached `setsid nohup env ...` could lose or strip, and was (28/10), and (b) also refused a
# turn running in a `wa` CLI - a different process from the node, which a sentinel can replace safely
# while the CLI waits (the CLI then restarts itself into its session when idle).
#
# So the process tree decides, where there is one (/proc): an ancestor `wa serve` means this command
# runs inside a node turn and must refuse, whatever the environment says; an ancestor `wa` CLI (chat)
# with a sentinel supervising the node means it may go on. Without /proc the marker decides, as before.
turn_owner() {
  [ -r /proc/self/status ] || { [ "${WASM_AGENT_IN_TURN:-}" = "1" ] && echo unknown; return 0; }
  local pid cmd base found=""
  pid=$(awk '/^PPid:/{print $2}' /proc/$$/status 2>/dev/null)
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    base=$(basename "${cmd%% *}" 2>/dev/null)
    if [ "$base" = "wa" ] || [ "$base" = "wa.exe" ]; then
      case " $cmd " in
        *" serve "*) echo node; return 0 ;;
        *) found=cli ;;
      esac
    fi
    pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
  done
  if [ -n "$found" ]; then echo "$found"; elif [ "${WASM_AGENT_IN_TURN:-}" = "1" ]; then echo unknown; fi
}

# Is a sentinel watcher supervising this install's node? ($1 = the install dir holding wa-sentinel)
sentinel_supervises() {
  local sentinel="$1/wa-sentinel"
  [ -x "$sentinel" ] || return 1
  "$sentinel" status 2>/dev/null | grep -q '^ *sentinel: *up'
}
