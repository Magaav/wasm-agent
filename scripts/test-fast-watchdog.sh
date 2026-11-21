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

# A scratch root OUTSIDE the operator store: this node sets TMPDIR inside ~/.wasm-agent (item 4 of the
# node-ops round, measured 19/11), so a plain mktemp -d would put this test's fixtures in the real node.
. "$ROOT/scripts/lib/scratch-home.sh"
scratch_root="$(wa_scratch_root wa-fast-watchdog-test)" || exit 2
WORK="$(mktemp -d "$scratch_root/wa-fast-watchdog-test-XXXXXX")" || exit 2
# This test writes only under WORK, and it says so in the one way that can be checked.
# WASM_AGENT_HOME IS THE USER HOME (rust/wa-host-support/src/paths.rs:12), not the node's state
# directory: this used to hand over "$WORK/home/.wasm-agent", which made the node write
# "$WORK/home/.wasm-agent/.wasm-agent" - a store root one level too deep. The guard is the shared rule,
# and it refuses the real home, the real store and anything inside or above either.
# The guard runs BEFORE HOME is replaced below: it compares against the operator's real home, and after
# the export that home would be this scratch one.
wa_scratch_home_guard "$WORK/home" || exit 2
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home"
mkdir -p "$WASM_AGENT_HOME" || fail 'cannot create the scratch home'
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

# 5. The runner's own exec path, RUN - not grepped. Two halves, because they answer different questions:
#
#    (a) THE CALL fast.sh MAKES, with a stand-in binary that prints the argv and the environment it was
#        handed. That is the ONLY way to see what the runner really passes: 'env' cannot exec a shell
#        function (exit 127 on every row, measured 19/11) and an empty cleared-array expands to one empty
#        word (the same 127 on a process with no WASM_AGENT_* to clear). Both are exercised here.
#    (b) A REAL ROW through the same function, when a 'wa' binary is on this machine: the row prints what
#        its node sees, and that is what is asserted - never the runner's intention.
fakebin="$WORK/fakebin/wa"
mkdir -p "$WORK/fakebin"
cat > "$fakebin" <<'FAKEBIN'
#!/bin/sh
# A stand-in for the node: it answers with the argv and the environment it was really given.
printf 'argv: %s\n' "$*"
printf 'WASM_AGENT_HOME=%s\n' "${WASM_AGENT_HOME-<unset>}"
printf 'WASM_AGENT_LUA_ROOT=%s\n' "${WASM_AGENT_LUA_ROOT-<unset>}"
printf 'WASM_AGENT_MANAGED=%s\n' "${WASM_AGENT_MANAGED-<unset>}"
printf 'WASM_AGENT_VAULT_URL=%s\n' "${WASM_AGENT_VAULT_URL-<unset>}"
printf 'WASM_AGENT_DB=%s\n' "${WASM_AGENT_DB-<unset>}"
printf 'WA_SCRIPT=%s\n' "${WA_SCRIPT-<unset>}"
printf 'WA_FAST_ROW_ENV=%s\n' "${WA_FAST_ROW_ENV-<unset>}"
exit "${FAKE_EXIT:-0}"
FAKEBIN
chmod +x "$fakebin" || fail 'cannot make the stand-in binary executable'
printf -- '-- a row the stand-in answers; it is never run by a node\n' > "$WORK/row-fixture.lua"

# The driver: the runner's own functions, sourced the way fast.sh sources them, with only the globals
# lua_run needs. It is a separate process so the variables it inherits are the ones the assertions set.
cat > "$WORK/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -uo pipefail
ROOT=$1; BIN=$2; ROW=$3; WORKDIR=$4
. "$ROOT/scripts/lib/fast-watchdog.sh"
. "$ROOT/scripts/lib/fast-row-exec.sh"
FAST_BIN=$BIN; FAST_ROOT=$ROOT/lua; FAST_WORK=$WORKDIR; FAST_COMPONENT_SOURCE=
FAST_COMPONENT_NAMES=; WA_FAST_CLEARED=
export FAST_BIN FAST_ROOT FAST_WORK FAST_COMPONENT_SOURCE FAST_COMPONENT_NAMES WA_FAST_CLEARED
home="$WORKDIR/h.1"; mkdir -p "$home"
lua_run "$ROW" "$home"
DRIVE
chmod +x "$WORK/drive.sh" || fail 'cannot make the driver executable'

# (a) A row through the runner's exec path. The parent exports a vault and a ledger on purpose: the runner
# promises both are gone by the time the row runs, and this is where that promise is measured.
set +e
out="$(env WASM_AGENT_VAULT_URL=http://127.0.0.1:1 WASM_AGENT_DB=/nonexistent/real.db \
  WASM_AGENT_VAULT_PASSPHRASE=secret \
  bash "$WORK/drive.sh" "$ROOT" "$fakebin" "$WORK/row-fixture.lua" "$WORK/run-a" 2>&1)"
code=$?
set -e
[ "$code" = 0 ] || fail "a row the node answers with 0 came back as $code: this is the exec path fast.sh uses. Output: $out"
case "$out" in
  *'argv: --db '*"/h.1/t.db"*) ;;
  *) fail "the row was not run against its own ledger: expected '--db <home>/t.db' in the argv, got: $out" ;;
esac
case "$out" in
  *"WA_SCRIPT=$WORK/row-fixture.lua"*) ;;
  *) fail "the row was not told which script it is: WA_SCRIPT did not arrive. Output: $out" ;;
esac
case "$out" in
  *'WASM_AGENT_VAULT_URL=<unset>'*) ;;
  *) fail "the operator's vault reached the row: the runner must clear WASM_AGENT_VAULT_URL. Output: $out" ;;
esac
case "$out" in
  *'WASM_AGENT_DB=<unset>'*) ;;
  *) fail "the node's real ledger reached the row: the runner must clear WASM_AGENT_DB. Output: $out" ;;
esac
case "$out" in
  *"WASM_AGENT_HOME=$WORK/run-a/h.1"*) ;;
  *) fail "the row did not get its own scratch home. Output: $out" ;;
esac
case "$out" in
  *'WASM_AGENT_MANAGED=0'*) ;;
  *) fail "the row was not marked unmanaged (WASM_AGENT_MANAGED=0). Output: $out" ;;
esac

# The row's own failure is the row's: the exec path must not rewrite it.
set +e
env FAKE_EXIT=7 bash "$WORK/drive.sh" "$ROOT" "$fakebin" "$WORK/row-fixture.lua" "$WORK/run-b" >/dev/null 2>&1
code=$?
set -e
[ "$code" = 7 ] || fail "a row that exited 7 came back through the runner as $code; a verdict must not be rewritten"

# An EMPTY cleared-array is empty, not one empty word. With no WASM_AGENT_* in the environment at all the
# old 'env "\$arr"' expansion asked env to run the empty string - exit 127 with the row never starting.
# This runs the driver under 'env -i', which is exactly that process.
set +e
out="$(env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="${TMPDIR:-/tmp}" \
  bash "$WORK/drive.sh" "$ROOT" "$fakebin" "$WORK/row-fixture.lua" "$WORK/run-c" 2>&1)"
code=$?
set -e
[ "$code" = 0 ] || fail "with no WASM_AGENT_* variable to clear, the runner exited $code instead of running the row (the empty-array expansion): $out"
case "$out" in
  *'argv: --db '*) ;;
  *) fail "with nothing to clear, the row never reached the node: $out" ;;
esac

# A hung row through the SAME call: the watchdog is the outermost command, so the deadline kills the node
# AND the child it forked, and fast.sh reads the 124 as 'hung'. A watchdog inside 'env' could not do this.
cat > "$WORK/hangbin" <<'HANGBIN'
#!/bin/sh
sleep 600 & echo $! > "$HANG_CHILD_FILE"
sleep 600
HANGBIN
chmod +x "$WORK/hangbin"
hang_child="$WORK/hang-child.pid"
set +e
out="$(env HANG_CHILD_FILE="$hang_child" WA_FAST_ROW_SECONDS=3 \
  bash "$WORK/drive.sh" "$ROOT" "$WORK/hangbin" "$WORK/row-fixture.lua" "$WORK/run-d" 2>&1)"
code=$?
set -e
[ "$code" = 124 ] || fail "a hung row through the runner's exec path came back as $code, not 124 (hung): $out"
case "$out" in
  *'produced no verdict within 3s'*) ;;
  *) fail "the hung row through the runner's exec path was not named by the watchdog: $out" ;;
esac
if [ -s "$hang_child" ]; then
  child="$(cat "$hang_child")"; pids+=("$child")
  sleep 1
  kill -0 "$child" 2>/dev/null && fail "the hung row's child (pid $child) outlived the runner's exec path: the watchdog did not own the process group"
fi


# A COMMAND THAT EXITS 124 ITSELF IS NOT A HANG (item 8 of the node-ops round). The watchdog answers 124
# for its own deadline, and a `timeout` inside the command answers 124 too; a runner that read the NUMBER
# alone would call a real assertion failure a hang. The distinction the runner reads is the watchdog's own
# line, so a command exiting 124 by itself must come back 124 with NO watchdog line - and that is what is
# asserted here, on the same exec path a Lua row takes.
cat > "$WORK/own124" <<'OWN124'
#!/bin/sh
# A command whose own exit is 124: no deadline was reached, so nothing may be reported as hung.
echo 'assertion failed: this command decided to answer 124'
exit 124
OWN124
chmod +x "$WORK/own124"
set +e
out="$(env WA_FAST_ROW_SECONDS=30 bash "$WORK/drive.sh" "$ROOT" "$WORK/own124" "$WORK/row-fixture.lua" "$WORK/run-e" 2>&1)"
code=$?
set -e
[ "$code" = 124 ] || fail "a command that exits 124 by itself came back as $code: $out"
case "$out" in
  *'watchdog: '*) fail "a command that exits 124 by itself was reported as a watchdog HANG: $out" ;;
esac
# (b) A REAL row, when this machine has a node to run one: the row prints what its node sees, and the
# assertions are on that print. No binary means this half is SKIPPED by name and the run says so - the
# call above is already proven, and a skip is never reported as a pass.
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "${CARGO_TARGET_DIR:-}/debug/wa" \
         "$ROOT/rust/target/debug/wa" "$ROOT/rust/target/release/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ]; then
  printf 'SKIP test-fast-watchdog: no wa binary (WA_BIN, PATH, rust/target/{debug,release}), so the real-row half of the exec path cannot run\n'
else
  cat > "$WORK/real-row.lua" <<'REALROW'
-- Answers with what the node really sees, so the assertion is on the node, not on the runner's intention.
print('real row reached the node')
-- WA_SCRIPT is consumed by the host (harness-fixes-2, c2e060e7): the node answers it as a process fact.
print('script_run=' .. tostring(host.script_run and host.script_run()) .. ' env=' .. tostring(host.getenv('WA_SCRIPT')))
print('home=' .. tostring(host.getenv('WASM_AGENT_HOME')))
print('managed=' .. tostring(host.getenv('WASM_AGENT_MANAGED')))
print('vault=' .. tostring(host.getenv('WASM_AGENT_VAULT_URL')))
REALROW
  set +e
  out="$(env WASM_AGENT_VAULT_URL=http://127.0.0.1:1 \
    bash "$WORK/drive.sh" "$ROOT" "$bin" "$WORK/real-row.lua" "$WORK/run-e" 2>&1)"
  code=$?
  set -e
  [ "$code" = 0 ] || fail "a real Lua row through the runner's exec path exited $code: this is the 127 the wrong order gave every row. Output: $out"
  case "$out" in
    *'real row reached the node'*) ;;
    *) fail "the real row never reached its node. Output: $out" ;;
  esac
  case "$out" in
    *"script_run=true env=nil"*) ;;
    *) fail "the real row is not a script run with WA_SCRIPT consumed (host.script_run true, the variable gone). Output: $out" ;;
  esac
  case "$out" in
    *"home=$WORK/run-e/h.1"*) ;;
    *) fail "the real row did not see its own scratch home. Output: $out" ;;
  esac
  case "$out" in
    *'managed=0'*) ;;
    *) fail "the real row was not unmanaged. Output: $out" ;;
  esac
  case "$out" in
    *'vault=nil'*) ;;
    *) fail "the operator's vault reached the real row. Output: $out" ;;
  esac
fi

# 6. The runner's own wiring, asserted on its source in the ONE place a run cannot reach: which call the

# row path makes and that a hang is never guessed from an exit code alone. The exec path itself is RUN

# above; this is the extra fact that fast.sh is a user of it and still classifies a hang by the line.

grep -q 'timeout 120 "$FAST_BIN"' scripts/fast.sh scripts/lib/fast-row-exec.sh && fail 'a Lua row still runs under a bare timeout, so a hung row leaves its children behind'

grep -q 'wa_fast_row_exec "${WA_FAST_ROW_SECONDS:-120}"' scripts/lib/fast-row-exec.sh || fail 'lua_run does not run its row through wa_fast_row_exec (scripts/lib/fast-row-exec.sh)'
grep -q 'scripts/lib/fast-row-exec.sh' scripts/fast.sh || fail 'scripts/fast.sh does not source scripts/lib/fast-row-exec.sh, so the row path it runs is not the one tested here'

grep -q 'then kind=hung' scripts/fast.sh || fail 'scripts/fast.sh never classifies a row as hung'

# The other direction, which is the one that matters when a row fails for a real reason: no watchdog line,

# no hang. The classifier reads the line, so a row that merely exits 124 stays a code failure.

out="$WORK/quiet-failure.log"; printf 'assertion failed: expected 3, got 4\n' > "$out"

grep -q '^watchdog: ' "$out" && fail 'a plain failing log was read as a hang'

printf 'watchdog: %s produced no verdict within 3s: killed the group\n' 'row' > "$out"

grep -q '^watchdog: ' "$out" || fail 'a watchdog line was not recognised'

# THE WATCHDOG DOES NOT ROUND A ROW UP TO A WHOLE SECOND (change/gate-fast, 21/11). It polled with
# `sleep 1`, so a row that answers in 150 ms cost 1000 ms (measured: 1.04 s, and 2.03 s for a 1.2 s row),
# on every one of ~170 rows of every run. With the tenth-of-a-second poll the same row is measured at
# 0.25 s. The best of three, so a loaded host has to be slow three times running to fail this; the old
# poll could not pass it once, because its first look after the start was a whole second later.
best=999999
for attempt in 1 2 3; do
  started=$(date +%s%N)
  wa_fast_watchdog 10 "quick row" -- sleep 0.15 || fail "a 150 ms row was reported as failed (exit $?)"
  took=$(( ($(date +%s%N) - started) / 1000000 ))
  [ "$took" -lt "$best" ] && best=$took
done
[ "$best" -lt 800 ] || fail "assertion failed: a 150 ms row took ${best} ms through the watchdog (best of three): the poll is rounding rows up to whole seconds again"
# And the deadline is still seconds, never tenths of them: a 2 s deadline does not fire on a 1.2 s row.
wa_fast_watchdog 2 "row inside its deadline" -- sleep 1.2 || fail "assertion failed: a 1.2 s row was ended by a 2 s deadline (exit $?): the deadline is being counted in the wrong unit"

printf 'test-fast-watchdog: ok (hung row named and its group killed, exits passed through, refusals named, a command own 124 is NOT a hang, and a row really runs through the runner exec path)\n'
exit 0
