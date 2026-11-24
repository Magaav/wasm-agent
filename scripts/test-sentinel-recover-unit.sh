#!/usr/bin/env bash
# RECOVER A NODE THE OS OWNS, WITH NO HUMAN STEP (r8b (i) row, Fable 24/11).
#
# MEASURED on this laptop before the fix: the node is run by a systemd --user unit, so the pid on the port is not
# the pid the sentinel recorded - it never started it - and `wa-sentinel request recover` died with "refusing to
# stop pid N ... it is not the node this sentinel started (record pid M)". The remedy was a human
# `systemctl --user restart`.
#
# This row builds that shape for real, on a scratch node of its own:
#   * a transient USER unit (`systemd-run --user --unit=wa-serve-r8b-<n>`) runs this tree's `wa serve` on its own
#     port, with its own HOME, XDG dirs and ledger. `wa-serve.service` and the real node are never touched, and
#     nothing here is signalled except pids read from THAT unit;
#   * the node is then WEDGED the way a hung lane wedges it: SIGSTOP on the unit's MainPID. It still holds the
#     port and answers nothing;
#   * `wa-sentinel request recover` + one pass of the watcher must bring it back - through the unit - with no
#     human command and no pid proof, and health must answer again.
#
# The vault and provider variables are cleared: a row may not reach a real provider.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "sentinel-recover-unit: SKIP (no wa binary: set WA_BIN)" >&2; exit 0; }
SENTINEL="${WA_SENTINEL_BIN:-$(dirname "$BIN")/wa-sentinel}"
[ -x "$SENTINEL" ] || { echo "sentinel-recover-unit: SKIP (no wa-sentinel beside $BIN: set WA_SENTINEL_BIN)" >&2; exit 0; }
command -v systemctl >/dev/null 2>&1 || { echo "sentinel-recover-unit: SKIP (no systemctl on PATH)" >&2; exit 0; }

N="$RANDOM$$"
UNIT="wa-serve-r8b-$N"
PORT="${1:-$((9000 + RANDOM % 400))}"
[ "$PORT" = "8799" ] && PORT=9001
CP=$((PORT + 1))
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sentinel-recover-XXXXXX")"
cleanup() {
  local status=$?
  systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT

mkdir -p "$WORK/home" "$WORK/rt" "$WORK/install" "$WORK/home/.wasm-agent/components"
chmod 700 "$WORK/rt"
cp "$BIN" "$WORK/install/wa"
INSTALLED="$WORK/install/wa"

# The node as its own user unit. `--collect` so a stopped unit leaves nothing behind, and the environment is the
# unit's own: a scratch home, no rendezvous, no relay, and no vault anywhere in reach.
systemd-run --user --collect --unit="$UNIT" \
  --setenv=HOME="$WORK/home" --setenv=WASM_AGENT_HOME="$WORK/home" --setenv=WASM_AGENT_LUA_ROOT="$ROOT" \
  --setenv=WASM_AGENT_RENDEZVOUS= --setenv=WASM_AGENT_RELAY= --setenv=WASM_AGENT_MANAGED=0 \
  --setenv=WA_COMPONENTS_DIR="$WORK/home/.wasm-agent/components" \
  "$INSTALLED" --db "$WORK/home/serve.db" serve --port "$PORT" --client-port "$CP" --ui "$ROOT/ui" \
  > "$WORK/unit.log" 2>&1 || { echo "  FAIL: systemd-run --user refused the unit"; cat "$WORK/unit.log"; exit 1; }

echo "sentinel-recover-unit (unit $UNIT, node on $PORT)"
code=""
for _ in $(seq 1 160); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "  FAIL: the unit-owned node did not answer /health (systemctl --user status $UNIT)"; systemctl --user status "$UNIT" --no-pager 2>&1 | tail -5; exit 1; }
PID_BEFORE="$(systemctl --user show "$UNIT" -p MainPID --value)"
echo "  ok: the node is up under $UNIT (MainPID $PID_BEFORE)"

# THE WEDGE: the process is frozen - it still holds the port and answers nothing, which is the shape a hung lane
# leaves the supervisor with.
kill -STOP "$PID_BEFORE"
sleep 1
if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/health"; then
  echo "  FAIL: the node still answers after SIGSTOP, so nothing was wedged"; exit 1
fi
echo "  ok: the node is wedged (SIGSTOP on $PID_BEFORE, no answer on /health)"

# THE RECOVERY: ask the watcher, then give it one pass. Nothing here stops a pid or restarts the unit by hand.
# XDG_RUNTIME_DIR IS THE SESSION'S, NOT A SCRATCH ONE (measured writing this row): `systemctl --user` reaches the
# user manager through it, so a scratch value cut the watcher off from the very manager the unit lives in and
# `owning_unit` answered "no unit" for a unit that systemd-run had just started. What is scratch here is the
# UNIT'S NAME, its HOME, its port and its ledger - the manager is the session's, and the real node's unit is
# never named or touched.
SENTINEL_ENV=(env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL
  HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home"
  WASM_AGENT_PORT="$PORT" WASM_AGENT_CLIENT_PORT="$CP"
  WA_INSTALL_DIR="$WORK/install" WA_SERVICE_UNIT="$UNIT" WASM_AGENT_LUA_ROOT="$ROOT")
if ! "${SENTINEL_ENV[@]}" "$SENTINEL" request recover --reason "r8b row: a wedged unit-owned node" > "$WORK/request.log" 2>&1; then
  echo "  FAIL: the watcher refused to queue the recovery"; cat "$WORK/request.log"; exit 1
fi
"${SENTINEL_ENV[@]}" "$SENTINEL" once > "$WORK/once.log" 2>&1 || true
echo "  note: watcher said: $(grep -iE 'recover|unit' "$WORK/once.log" | tail -2 | tr '\n' ' ')"

back=""
for _ in $(seq 1 120); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && back=yes && break
  sleep 0.25
done
if [ -z "$back" ]; then
  echo "  FAIL: the node did not come back after the watcher's recovery"
  sed -n '1,12p' "$WORK/once.log"; exit 1
fi
PID_AFTER="$(systemctl --user show "$UNIT" -p MainPID --value)"
if [ -z "$PID_AFTER" ] || [ "$PID_AFTER" = "0" ]; then
  echo "  FAIL: the unit reports no MainPID after recovery"; exit 1
fi
if [ "$PID_AFTER" = "$PID_BEFORE" ]; then
  echo "  FAIL: the unit still reports the wedged pid $PID_BEFORE - the process was resumed, not replaced"; exit 1
fi
echo "  ok: the node is back (MainPID $PID_AFTER, was $PID_BEFORE), through the unit, with no human step"
if grep -qiE "refusing to (stop|recover) pid" "$WORK/once.log"; then
  echo "  FAIL: the watcher took the pid path instead of the unit"; grep -i "refusing" "$WORK/once.log" | head -2; exit 1
fi
echo "sentinel-recover-unit ok: a unit-owned wedged node is recovered by the watcher itself"
