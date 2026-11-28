#!/usr/bin/env bash
# TURNING THE NODE INSTANCE ON MUST MAKE IT REACHABLE (Victor, 29/11).
#
# MEASURED on work (a docker container): it restarted at 10:31Z and NOTHING ran - no watcher, no node - until a person
# typed `wa` at 11:54Z. The lifetime lock was free; sentinel.pid still said `16` from the container before; and in the NEW
# pid namespace pid 16 was alive again, almost certainly the entrypoint's own `wa-sentinel start` (its third child). A bare
# liveness probe called that "a watcher" and refused:
#   "unverified live pid 16; refusing a second watcher; inspect service/task outside the node"
# A pid file outlives a pid namespace; its NUMBER does not. The fallback now needs the pid to be (a) not our own process
# and (b) really a `wa-sentinel ... watch` process, read from /proc/<pid>/exe and cmdline.
#
# WA_SENTINEL_SUPERVISOR=none keeps every case inside this fixture: without it `start` may hand the verb to the unit
# manager, and a row must never touch the watcher the operator is running. WASM_AGENT_IN_TURN is dropped for the same
# reason `start` refuses inside a node turn: the verb belongs to the process OUTSIDE the node.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${WA_SENTINEL_BIN:-$root/rust/wa-sentinel/target/debug/wa-sentinel}
[ -x "$bin" ] || { echo "sentinel-boot-reachable: SKIP (no sentinel binary at $bin)"; exit 0; }
work=$(mktemp -d)
home=$work/home
mkdir -p "$home/.wasm-agent/sentinel"
pidfile=$home/.wasm-agent/sentinel/sentinel.pid
sleeper=
fail() { echo "sentinel-boot-reachable: $1" >&2; echo "--- start said: ${out:-}" >&2; exit 1; }
ask() { env -u WASM_AGENT_IN_TURN WASM_AGENT_HOME=$home WA_SENTINEL_SUPERVISOR=none timeout 30 "$bin" "$@" 2>&1; }
cleanup() {
  ask stop >/dev/null 2>&1
  [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
# A stop is a request: the watcher exits on its own schedule, and a start before that is refused by name
# ("watcher is stopping; wait for exit before explicit start"). Waiting is part of the case, not a sleep.
wait_stopped() {
  local waited=0
  while [ $waited -lt 15 ]; do
    case "$(ask status)" in
      *"sentinel:"*"up"*) sleep 1; waited=$((waited + 1)) ;;
      *) return 0 ;;
    esac
  done
  return 0
}

# 1. THE STALE NUMBER, ALIVE, BUT NOT A WATCHER: a live process that is not wa-sentinel holds the number the stale file
#    names - the container case in miniature.
sleep 300 & sleeper=$!
printf '%s\n' "$sleeper" > "$pidfile"
out=$(ask start); rc=$?
[ $rc -eq 0 ] || fail "a stale pid file naming a live process that is not a watcher refused the start (rc=$rc)"
case $out in *"unverified live pid"*) fail "the start was refused for a pid that is not a watcher" ;; esac
status=$(ask status)
case $status in
  *"sentinel:"*"up"*) ;;
  *) fail "the start returned but nothing is watching this home: $status" ;;
esac
now=$(cat "$pidfile" 2>/dev/null || true)
[ -n "$now" ] && [ "$now" != "$sleeper" ] || fail "the pid file still names the stale pid ($sleeper), so the watcher never claimed it"
ask stop >/dev/null 2>&1
wait_stopped

# 2. OUR OWN PID: in a fresh namespace the number the stale file carries IS the new process's own number, and a process
#    cannot be a second copy of itself.
printf '%s\n' "$$" > "$pidfile"
out=$(ask start); rc=$?
[ $rc -eq 0 ] || fail "a pid file naming this very process refused the start (rc=$rc)"
case $out in *"unverified live pid"*) fail "the start was refused for a pid that is ours" ;; esac
ask stop >/dev/null 2>&1

# A real watcher is still respected by the lifetime lock itself, which this row does not re-test: a spawned `watch` in a
# fixture home exits at once because there is no node to serve, so the case would measure the fixture, not the rule.
kill "$sleeper" 2>/dev/null; sleeper=
echo "sentinel-boot-reachable ok (a stale pid naming a live process that is not a watcher, or our own pid, no longer refuses the start - the watcher comes up and claims the pid file)"
