#!/usr/bin/env bash
# A parked session stays stopped, across processes (Fable 22/11).
#
#   bash scripts/test-session-park.sh
#
# Measured 22/11: mission flaky-rel-native-poll was stopped on purpose (unit stopped 00:10Z, HOLD file
# written) and its session kept working - 196 messages at the stop, 263 an hour later - because each
# local install had written a "deploy pending: resume after the node swap" wake and the node's tick
# performed it. Nothing in the node knew the session was parked, and no verb could say so.
#
# This script is the operator's half of that fix, run as separate processes against one ledger:
#
#   1. the fixture starts two sessions, each with a due wake (the deploy-pause row, and one named by a
#      mission directory);
#   2. `wa session park <id>` - the verb a stop recipe runs - parks the first; `wa session park
#      --mission <name>` parks the second, from the mission directory's own record;
#   3. `wa session status` says `parked` and `wakes held`, and a tick (`scripts/lib/session-park-e2e.lua`,
#      the node's own `selfloop.tick`) dispatches 0 and reports the wake held - with no new message in
#      the session;
#   4. `wa chat --resume <id>` is REFUSED by name, exit 2, naming `wa session release <id>`;
#   5. `wa session release <id>` makes the wake due, the next tick runs it exactly once, and the second
#      tick runs nothing;
#   6. releasing what is not parked is a refusal (exit 1), not a claim of an effect.
#
# Hermetic: its own scratch home and ledger under $TMPDIR, no rendezvous, no relay, no model, no
# network, and it signals no process (it starts none that outlives a command).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then
  for candidate in "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
                   "${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa.exe" "${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa" \
                   "$(command -v wa 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { BIN="$candidate"; break; }
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "session park: SKIP (no wa binary: set WA_BIN, or build rust/wa-host)" >&2
  exit 0
fi
case "$BIN" in /*|[A-Za-z]:*) ;; *) BIN="$ROOT/$BIN" ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-session-park-XXXXXX")"
HOME_DIR="$WORK/home"
DB="$WORK/ledger.sqlite"
mkdir -p "$HOME_DIR" "$WORK/missions/hold-mission"
trap 'rm -rf "$WORK"' EXIT
# This node joins nothing and contacts nobody: no rendezvous, no relay, no managed mode.
export WASM_AGENT_HOME="$HOME_DIR"
export WASM_AGENT_LUA_ROOT="$ROOT"
export GATE_ROOT="$WORK"
export MISSION_ROOT="$WORK/missions"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
unset WA_SESSION_ID WASM_AGENT_DB

fails=0
step() { printf '  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
# The ledger word for word: run a command and keep its output and its exit code.
last_out=""; last_code=0
run() { last_out="$("$BIN" --db "$DB" "$@" 2>&1)"; last_code=$?; }
want() { case "$last_out" in *"$1"*) ;; *) fail "$2: expected '$1' in: $last_out" ;; esac; }
want_code() { [ "$last_code" = "$1" ] || fail "$2: expected exit $1, got $last_code: $last_out"; }
lua_step() {
  local mode="$1"
  last_out="$(PARK_MODE="$mode" WA_SCRIPT="$ROOT/scripts/lib/session-park-e2e.lua" \
    "$BIN" --db "$DB" 2>&1 | grep -v 'served natively')"
  last_code=$?
}

step "fixture: two sessions, each with a due wake"
lua_step fixture
want "fixture ok" "the fixture starts the sessions"
LEADER="$(printf '%s' "$last_out" | sed -n 's/.*leader=\([^ ]*\).*/\1/p')"
NAMED="$(printf '%s' "$last_out" | sed -n 's/.*mission=\([^ ]*\).*/\1/p')"
[ -n "$LEADER" ] && [ -n "$NAMED" ] || { echo "FAIL fixture printed no session ids: $last_out"; exit 1; }
# The mission directory records the session the way a stopped mission does (mission.recorded_session reads
# exactly this line out of out.log), so `--mission` is tested on the factory's own record and not on a table
# built for the test.
printf 'wa: session %s chat --once\n' "$NAMED" > "$WORK/missions/hold-mission/out.log"
sleep 2

step "before the park: the wake is due and pending"
lua_step read
want "parked=false" "nothing is parked yet"
want "pending=1" "the session has one pending wake"

step "wa session park <id>"
run session park "$LEADER" --reason "HOLD written: mission stopped"
want_code 0 "park succeeds"
want "parked $LEADER" "the verb names what it parked"
want "no turn runs for this session" "the verb says what was done"
want "wa session release $LEADER" "and names the release command"

step "wa session status <id>: the wake is held, by a park"
run session status "$LEADER"
want_code 0 "status answers"
want "parked since" "status says the session is parked"
want "1 wake held" "status says the wake is held"
run session status
want "$LEADER" "the whole-node listing names the parked session"

step "wa chat --resume <id>: refused by name, exit 2"
run chat --resume "$LEADER"
want_code 2 "a parked session is not opened"
want "is parked" "the refusal says so"
want "release it with: wa session release $LEADER" "and names the release command"

step "wa session park --mission <name>: the factory's stop recipe, one line"
run session park --mission hold-mission --reason "HOLD written: mission stopped"
want_code 0 "the mission form parks"
want "parked $NAMED" "the session the mission directory names"
run session status "$NAMED"
want "parked since" "and the status verb sees it"

step "the node's tick: nothing runs, both wakes held, no new message"
lua_step tick
want "dispatched=0" "a parked session's due wake is not dispatched"
want "runs=0" "and nothing is handed to the scheduler"
want "pending=1" "the wake is still pending (nothing dropped)"
want "messages=0" "and the session has no new message"
held_now="$(printf '%s' "$last_out" | sed -n 's/.*held=\([0-9]*\).*/\1/p')"
[ "${held_now:-0}" -ge 2 ] || fail "the tick reported $held_now held wake(s), not both parked sessions' wakes"

step "wa session release <id>: the wake is due again, and runs exactly once"
run session release "$LEADER"
want_code 0 "release succeeds"
want "released $LEADER" "the verb names what it released"
want "1 wake pending again" "and the wake is pending again"
lua_step tick
want "dispatched=1" "the released wake runs"
want "runs=1" "once"
lua_step tick
want "runs=0" "a second tick runs nothing: the wake ran exactly once"

step "release of something that is not parked: a refusal, not a claim"
run session release "$LEADER"
want_code 1 "releasing an unparked session is refused"
want "is not parked" "the refusal says so"

step "wa session release --mission <name>"
run session release --mission hold-mission
want_code 0 "the mission form releases"
want "released $NAMED" "the session the mission directory names"

step "and nothing is parked any more"
run session status
want "no session is parked" "the whole-node listing is empty again"

step "wa chat --continue: a parked newest thread is refused too"
# Its own ledger, because --continue picks the NEWEST thread and this file already wrote three. The
# fixture leaves one thread, parked, with a message in it: the exact shape a stopped session has.
CONTINUE_DB="$WORK/continue.sqlite"
LAST_OUT="$(PARK_MODE=solo WA_SCRIPT="$ROOT/scripts/lib/session-park-e2e.lua"   "$BIN" --db "$CONTINUE_DB" 2>&1 | grep -v 'served natively')"
case "$LAST_OUT" in *"solo ok"*) ;; *) fail "the solo fixture did not run: $LAST_OUT" ;; esac
last_out="$("$BIN" --db "$CONTINUE_DB" chat --continue 2>&1)"; last_code=$?
want_code 2 "--continue does not open a parked thread"
want "release it with: wa session release park-solo" "and names the release command"

if [ "$fails" -ne 0 ]; then
  echo "session park: $fails failure(s)" >&2
  exit 1
fi
echo "session park ok"
