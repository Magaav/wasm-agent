#!/usr/bin/env bash
# The per-row watchdog: a hung row is NAMED, and every process it started dies with it.
#
# MEASURED 18/11 on avell: a row's own child (`sleep 600` in a fixture) outlived the row in every case -
# `timeout 120` ends the command it was given and nothing else - so a fixture that forked a child and then
# hung left that child holding a file, a pipe or a lock for the rest of the run, and the next row failed for
# a reason three rows away. A hung row also reported only `exit 124` with an empty verdict line.
#
#   bash scripts/test-fast-watchdog.sh
#
# What it proves, in this order (scratch home under /tmp; no node, no network, nothing of the operator's):
#   1. a row that hangs is killed WITH ITS CHILDREN, and the line names the row and the group it killed;
#   2. the hang is exit 124 (scripts/fast.sh reads that as `hung`, never as a verdict on the code);
#   3. a row's own exit code is passed through untouched - 0 for a pass, 7 for a failure;
#   4. a watchdog asked for a nonsense deadline, or given no command, refuses by name and runs nothing.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2

fail() { printf 'test-fast-watchdog: %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-fast-watchdog-test-XXXXXX")" || exit 2
# This test writes only under WORK, and it says so in the one way that can be checked: its own HOME and
# the node's home both point inside it, and a real ~/.wasm-agent is never read or written.
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home/.wasm-agent"
mkdir -p "$WASM_AGENT_HOME" || fail 'cannot create the scratch home'
case "$(CDPATH= cd -- "$WASM_AGENT_HOME" && pwd)" in
  "$WORK"/*) ;;
  *) fail "refused(real_node_home): the scratch home resolved outside $WORK, so this test would act on a real node's state" ;;
esac
pids=()
cleanup() {
  # Nothing this test started may outlive it, including a child the assertion already killed.
  # The trap's own last command becomes the script's exit status, and a kill of an already-dead child
  # fails by definition - so errexit is off here and the status that entered the trap is the one raised.
  local status=$?
  set +e
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

. scripts/lib/fast-watchdog.sh
command -v pgrep >/dev/null 2>&1 || fail 'SKIP test-fast-watchdog: pgrep is not on PATH, so a leaked child cannot be measured'

# 1 + 2. A hung row is named, its whole process group dies, and the verdict is 124.
child_file="$WORK/child.pid"
set +e
out="$(wa_fast_watchdog 3 "fixture row that hangs" -- bash -c 'sleep 600 & echo $! > "$0"; sleep 600' "$child_file" 2>&1)"
code=$?
set -e
[ "$code" = 124 ] || fail "a row that never produced a verdict exited $code, not 124 (hung); fast.sh would report it as the code failing. Output: $out"
case "$out" in
  *"produced no verdict within 3s"*) ;;
  *) fail "the hung row was not named: expected a line saying it produced no verdict within 3s, got: $out" ;;
esac
case "$out" in
  *'fixture row that hangs'*) ;;
  *) fail "the verdict line does not name the row: $out" ;;
esac
[ -s "$child_file" ] || fail 'the fixture never recorded its child pid; the leak assertion cannot be made'
child="$(cat "$child_file")"
pids+=("$child")
sleep 1
if kill -0 "$child" 2>/dev/null; then
  fail "the row's own child (pid $child, sleep 600) survived the watchdog: this is the leak measured 18/11"
fi
wa_watchdog_hung 124 || fail 'wa_watchdog_hung does not recognise 124 as the watchdog'"'"'s own exit'

# 3. The command's own exit is passed through, both ways.
wa_fast_watchdog 10 "passing row" -- bash -c 'exit 0' || fail "a passing row was reported as failed (exit $?)"
set +e
wa_fast_watchdog 10 "failing row" -- bash -c 'exit 7'
code=$?
set -e
[ "$code" = 7 ] || fail "a row that failed with 7 was reported as $code; the watchdog must not rewrite a verdict"
stderr="$(wa_fast_watchdog 10 "quiet row" -- bash -c 'exit 0' 2>&1 >/dev/null)"
[ -z "$stderr" ] || fail "a passing row wrote to stderr: $stderr"

# 4. A nonsense deadline and a missing command refuse by name, and run nothing.
set +e
msg="$(wa_fast_watchdog abc "row" -- bash -c 'exit 0' 2>&1)"; code=$?
set -e
[ "$code" = 2 ] || fail "a non-numeric deadline exited $code, not 2"
case "$msg" in
  *watchdog_seconds_invalid*) ;;
  *) fail "a non-numeric deadline was not refused by name: $msg" ;;
esac
set +e
msg="$(wa_fast_watchdog 10 "row" 2>&1)"; code=$?
set -e
[ "$code" = 2 ] || fail "a watchdog with no command exited $code, not 2"
case "$msg" in
  *watchdog_command_missing*) ;;
  *) fail "a watchdog with no command was not refused by name: $msg" ;;
esac

# 5. The runner actually USES it, and a hang is never guessed from an exit code alone. This is a source
# assertion on purpose and it says so: it cannot prove the row path runs, only that the one command the
# Lua rows run goes through the watchdog and that the classifier needs the watchdog's own line.
grep -q 'timeout 120 "$FAST_BIN"' scripts/fast.sh && fail 'scripts/fast.sh still runs a Lua row under a bare timeout, so a hung row leaves its children behind'
grep -q 'wa_fast_watchdog .*-- "$FAST_BIN" --db' scripts/fast.sh || fail 'scripts/fast.sh does not run a Lua row through wa_fast_watchdog'
grep -q 'then kind=hung' scripts/fast.sh || fail 'scripts/fast.sh never classifies a row as hung'
# The other direction, which is the one that matters when a row fails for a real reason: no watchdog line,
# no hang. The classifier reads the line, so a row that merely exits 124 stays a code failure.
out="$WORK/quiet-failure.log"; printf 'assertion failed: expected 3, got 4\n' > "$out"
grep -q '^watchdog: ' "$out" && fail 'a plain failing log was read as a hang'
printf 'watchdog: %s produced no verdict within 3s: killed the group\n' 'row' > "$out"
grep -q '^watchdog: ' "$out" || fail 'a watchdog line was not recognised'

printf 'test-fast-watchdog: ok (hung row named and its group killed, exits passed through, refusals named)\n'
exit 0
