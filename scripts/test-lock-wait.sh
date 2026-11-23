#!/usr/bin/env bash
# THE RUNNER'S OWN LINE ABOUT THE QUEUE (item 1, 23/11).
#
# scripts/lib/lock-wait.sh is what a suite runner writes into its log when it has to wait for the suite lock:
# "waiting on a file lock: <file> (<mode>) is held by pid <pid> (<command>); that process started <dur> ago,
# so the lock has been held at most that long". This row holds a REAL flock(2) on a real file and asks the
# helper, because what is being tested is a fact read from the kernel - a fixture string would prove only
# that awk can print.
#
# Hermetic: its own scratch directory, its own lock file, no suite lock, no fleet, no node. Everything it
# starts is a pid it remembers and kills, and the trap kills the holder's CHILDREN too (a `kill` of the
# `flock` wrapper alone leaves the `sleep` it started, which is exactly the leak that held the real suite
# lock for ten minutes on 20/11). Nothing is matched by name (rule 17).
set -uo pipefail
root=$(mktemp -d "${TMPDIR:-/tmp}/wa-lock-wait-XXXXXX") || { echo 'lock-wait: refused(scratch_unavailable): no temporary directory' >&2; exit 2; }
work=$root/work
mkdir -p "$work" || { echo 'lock-wait: refused(scratch_unavailable): cannot create a working directory' >&2; exit 2; }
lock=$work/suite.lock
: >"$lock" || { echo 'lock-wait: refused(scratch_unavailable): cannot create a lock file' >&2; exit 2; }
holder=''
fails=0
note() { printf '%s\n' "$*" >&2; }
ok() { :; }
bad() { fails=$((fails + 1)); note "FAIL: $*"; }
cleanup() {
  local kids=''
  if [ -n "$holder" ]; then
    kids=$(pgrep -P "$holder" 2>/dev/null || true)
    kill "$holder" 2>/dev/null || true
    [ -n "$kids" ] && kill $kids 2>/dev/null
    wait "$holder" 2>/dev/null
  fi
  rm -rf "$root"
}
trap cleanup EXIT

# shellcheck disable=SC1091
. "$(dirname -- "$0")/lib/lock-wait.sh" || { echo 'lock-wait: refused(lib_missing): scripts/lib/lock-wait.sh did not load' >&2; exit 2; }

# 1. NOBODY HOLDS IT: the helper says nothing and answers 1. A runner must not invent a queue.
free_out=$(wa_lock_wait_note "$lock"); free_rc=$?
[ "$free_rc" -eq 1 ] || bad "an unlocked file answers 1, got $free_rc (out: ${free_out:-<empty>})"
[ -z "$free_out" ] || bad "an unlocked file prints nothing, got: $free_out"

# 2. A REAL HOLDER: flock(2) held by a process of this row's own, running a known command.
flock "$lock" sleep 20 &
holder=$!
sleep 0.4
held_out=$(wa_lock_wait_note "$lock"); held_rc=$?
[ "$held_rc" -eq 0 ] || bad "a held lock answers 0, got $held_rc (out: ${held_out:-<empty>})"
case "$held_out" in
  "waiting on a file lock: $lock (FLOCK WRITE) is held by pid $holder ("*) ok ;;
  *) bad "the line names the file, the mode and the holding pid $holder, got: $held_out" ;;
esac
case "$held_out" in
  *"sleep 20"*) ok ;;
  *) bad "the line names the holder's command, got: $held_out" ;;
esac
case "$held_out" in
  *"that process started "*" ago, so the lock has been held at most that long") ok ;;
  *) bad "the line says how long it has been held, and that the number is an upper bound, got: $held_out" ;;
esac

# 3. THE ROLE, NOT THE NAME: once the holder is gone the same file answers 1 again, so a runner that keeps
#    printing the old line is reporting a lock nobody holds.
kids=$(pgrep -P "$holder" 2>/dev/null || true)
kill "$holder" 2>/dev/null
[ -n "$kids" ] && kill $kids 2>/dev/null
wait "$holder" 2>/dev/null
holder=''
sleep 0.2
after_out=$(wa_lock_wait_note "$lock"); after_rc=$?
[ "$after_rc" -eq 1 ] || bad "after the holder exited it answers 1 again, got $after_rc (out: ${after_out:-<empty>})"

# 4. A MISSING FILE IS NOT A HELD LOCK: the helper answers 2 (cannot tell) rather than claiming either.
missing_out=$(wa_lock_wait_note "$work/absent.lock"); missing_rc=$?
[ "$missing_rc" -eq 2 ] || bad "a file that is not there answers 2 (cannot tell), got $missing_rc (out: ${missing_out:-<empty>})"
[ -z "$missing_out" ] || bad "and it prints no claim about it, got: $missing_out"

if [ "$fails" -ne 0 ]; then
  echo "lock wait: $fails check(s) failed" >&2
  exit 1
fi
echo 'lock wait ok'
