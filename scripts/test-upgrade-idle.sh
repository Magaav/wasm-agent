#!/usr/bin/env bash
# The idle wait is bounded by *lack of progress*, not by wall time.
#
# The failure this exists for: a legitimate 40-minute turn made every queued upgrade
# wait `IDLE_TIMEOUT` (900s), fail, and be retried while the node stayed busy. A run
# whose worker is alive is doing work; only a worker that has stopped reporting may be
# given up on.
#
# `health()` is stubbed through PATH (upgrade.sh asks the node with `curl`), and the
# candidate is pre-proved by hash so the scratch-port step is skipped. So this exercises
# the wait loop in a second or two, with no node, no network, and no touch of the
# operator's install or the real sentinel.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/wa-upgidle-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# THE REAL DATA DIR IS THE ONE THING THIS ROW MUST NOT TOUCH (24/11). upgrade.sh writes the
# deploy-pending signal BEFORE it waits - `DEPLOY_SIGNAL_DIR="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-
# $HOME}/.wasm-agent}"` (upgrade.sh:648) - and every running session on this machine reads it and pauses
# after its step. Run with the inherited environment, this row wrote
# ~/.wasm-agent/deploy-pending.json with `to: unknown` and stopped the whole factory's turns, twice, and
# nothing on the node resumed them. So the real file's state is captured here, the row runs with its own
# data dir, and the file is compared afterwards: a row that touches it is red.
REAL_HOME="$HOME"
REAL_SIGNAL="$REAL_HOME/.wasm-agent/deploy-pending.json"
signal_state() {
  if [ -e "$REAL_SIGNAL" ]; then
    printf 'present:%s
' "$(stat -c '%s:%Y' "$REAL_SIGNAL" 2>/dev/null || echo unknown)"
  else
    printf 'absent
'
  fi
}
REAL_BEFORE="$(signal_state)"

INST="$WORK/install"
mkdir -p "$INST/scripts"
case "$(uname -s 2>/dev/null)" in
  CYGWIN*|MINGW*|MSYS*) WA_NAME=wa.exe ;;
  *) WA_NAME=wa ;;
esac
NEW="$WORK/candidate-${WA_NAME}"
# The candidate NAMES ITS OWN BUILD (round-3 item 8: upgrade.sh asks the candidate's bytes, not the checkout's
# HEAD - and a candidate that cannot answer is refused as candidate_commit_unknown, before it waits for
# anything). A stub that only exits 0 would be refused here, which is the rule working.
cat > "$NEW" <<'WASH'
#!/bin/sh
case "$1" in
  --build-info) printf 'version=9.9.9\ncommit=1111111111111111111111111111111111111111\ntree=2222222222222222222222222222222222222222\ndirty=false\nsource=git\nbuilt_epoch=1795000000\nancestors=1\nancestors_complete=true\n' ;;
  --version) echo 'wasm-agent 9.9.9' ;;
  *) exit 0 ;;
esac
WASH
chmod +x "$NEW"
cp -f "$NEW" "$INST/$WA_NAME"
HASH="$(sha256sum < "$NEW" | awk '{print $1}')"
# The record is the binary's own answer (and its sha256 is the binary's), so the running commit IS known: the
# candidate is the same commit, so no ancestry question is asked and the wait is reached immediately.
printf 'commit=1111111111111111111111111111111111111111\ntree=2222222222222222222222222222222222222222\ndirty=false\nsha256=%s\n' "$HASH" > "$INST/installed.txt"
# The proof cache is the candidate's hash: a build that already answered is not proved again, so the
# wait is reached immediately instead of after a scratch node starts.
printf '%s\n' "$HASH" > "$INST/.upgrade-proof"

# Stub `curl`: the wait loop's only source of truth about the node.
STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/curl" <<'SH'
#!/bin/sh
# The wait's only source of truth about the node AND the moment the deploy-pending signal is on disk:
# upgrade.sh clears it when the wait ends, so a check after the run cannot see it. The first health call
# copies it aside, as the witness that the writer aimed at THIS data dir.
if [ ! -f "$WA_TEST_DATA/.witness" ] && [ -f "$WA_TEST_DATA/deploy-pending.json" ]; then
  cp -f "$WA_TEST_DATA/deploy-pending.json" "$WA_TEST_DATA/.witness" 2>/dev/null || true
fi
printf '%s' "$WA_TEST_HEALTH"
SH
chmod +x "$STUB/curl"

# Its own home, its own data dir, its own HOME: the three the installer resolves its state from.
mkdir -p "$WORK/home" "$WORK/data"
run() { # state idle_timeout idle_max
  # The real turn guard belongs to the caller. This scratch upgrade is testing
  # idle waiting, so it must not inherit that guard from an in-turn smoke run.
  env -u WASM_AGENT_IN_TURN -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY \
    HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home" WASM_AGENT_DATA="$WORK/data" \
    WA_TEST_HEALTH="$1" WA_TEST_DATA="$WORK/data" WA_INSTALL_DIR="$INST" WA_PORT=1 \
    WA_IDLE_TIMEOUT="$2" WA_IDLE_MAX_SECONDS="$3" \
    PATH="$STUB:$PATH" bash "$ROOT/scripts/upgrade.sh" "$NEW" 2>&1
}

echo "--- a live worker: waited on, stopped only by the wall-clock cap ---"
alive="$(run '{"current":{"label":"POST /chat"},"worker":"alive","queue":1}' 1 2)"
printf '%s\n' "$alive" | sed 's/^/    /'
case "$alive" in
  *"WA_IDLE_MAX_SECONDS"*) echo "  ok: a live worker is waited on past the stall deadline" ;;
  *) echo "  FAIL: expected the wall-clock cap to stop it, got the above"; exit 1 ;;
esac
case "$alive" in
  *"has not reported progress"*) echo "  FAIL: a live worker was mistaken for a stalled one"; exit 1 ;;
  *) echo "  ok: it was not mistaken for a stalled worker" ;;
esac

echo "--- a stalled worker: given up on after the stall deadline ---"
stalled="$(run '{"current":{"label":"POST /chat"},"worker":"stalled","queue":1}' 1 0)"
printf '%s\n' "$stalled" | sed 's/^/    /'
case "$stalled" in
  *"has not reported progress"*) echo "  ok: a stalled worker is given up on" ;;
  *) echo "  FAIL: expected the stall deadline, got the above"; exit 1 ;;
esac

# The assertion the leak earns: the real signal is exactly as it was.
REAL_AFTER="$(signal_state)"
if [ "$REAL_BEFORE" != "$REAL_AFTER" ]; then
  echo "  FAIL: this row touched $REAL_SIGNAL ($REAL_BEFORE -> $REAL_AFTER); upgrade.sh writes the deploy-pending" >&2
  echo "        signal into the inherited data dir, and every session on this machine would pause for it" >&2
  exit 1
fi
# ...and its own data dir DID get the signal, so the row is exercising the writer and not skipping it.
[ -f "$WORK/data/.witness" ] || { echo "  FAIL: the scratch data dir never received the deploy-pending signal" >&2; exit 1; }
echo "  ok: the real data dir was not touched, and the scratch one received the signal"

echo "upgrade idle-wait ok"
