#!/usr/bin/env bash
# DOES /health NAME THE RELEASE THAT IS INSTALLED (mission fonts-install item 4, 21/11)?
#
# The failure, measured on the canary: an upgrade starts the new node over a fresh binary and writes
# installed.txt only AFTER that node answers /health. The node composed its label ONCE, at boot, from a record
# that did not name it yet - so serve 10:19:13 read a record written 10:19:15 and reported the PREVIOUS release
# for the rest of its life: /health said "node-7ddbfa98036a" while the bytes were node-bfad4f8fbe59. Only a
# second restart would ever have corrected it, and nothing in the deploy does one.
#
# WHAT THIS PROVES, in two independent ways:
#
#   1. the source shape - /health's label comes from the per-request reader, not the OnceLock written at boot,
#      and the binary registers how to compose it (a check that fails on the code before this change);
#   2. the behaviour, with a REAL node: start this build against a scratch home and install dir, read /health,
#      then write the record naming a release and read /health AGAIN - same process, no restart. It must answer
#      the release it has just been told about, and follow a second change too.
#
# Hermetic: a mktemp tree, a scratch HOME and WASM_AGENT_HOME, a free port, its own db and ui, and the node is
# killed by the pid this script started (never by a name pattern).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/wa-healthlabel-XXXXXX)"
NODE_PID=""
cleanup() {
  [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

checks=0; failed=0
ok()  { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }

# The scratch-home rule, in the one place every test agrees on it.
. "$ROOT/scripts/lib/scratch-home.sh"
SCRATCH_HOME="$WORK/home"
mkdir -p "$SCRATCH_HOME"
wa_scratch_home_guard "$SCRATCH_HOME" || exit 2
case "${WASM_AGENT_HOME:-}" in
  ''|"${HOME}") echo "REFUSED healthlabel: WASM_AGENT_HOME must be a scratch home" >&2; exit 2 ;;
esac

echo "--- 1. the source: /health reads the install's name NOW, and the binary registers the recipe ---"
if grep -q '"build": crate::host::live_build_label()' "$ROOT/rust/wa-capabilities/src/serve.rs"; then
  ok "/health's build field is composed per request (live_build_label)"
else
  bad "/health still reports the label captured once at boot (line: $(grep -n '"build":' "$ROOT/rust/wa-capabilities/src/serve.rs" | head -1))"
fi
if grep -q 'set_live_build_label' "$ROOT/rust/wa-host/src/main.rs"; then
  ok "the binary registers how to compose that name from the install's own records"
else
  bad "nothing registers a live label, so /health can only answer the boot label"
fi

echo "--- 2. the behaviour, on a real node: the record lands AFTER the node is serving ---"
WA_BIN="${WA_BIN:-}"
if [ -z "$WA_BIN" ] || [ ! -x "$WA_BIN" ]; then
  for candidate in "$ROOT/rust/target/release/wa" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa"; do
    [ -x "$candidate" ] && WA_BIN="$candidate" && break
  done
fi
if [ -z "$WA_BIN" ] || [ ! -x "$WA_BIN" ]; then
  # NOT A PASS: a build this script cannot find is a row that proved nothing, and it says so as a skip with the
  # reason, never as an ok.
  echo "  skip the node-level row: no binary at $WA_BIN (build it, or set WA_BIN)"
  checks=$((checks + 1))
else
  INSTALL="$WORK/install"
  mkdir -p "$INSTALL"
  cp -f "$WA_BIN" "$INSTALL/wa"
  chmod +x "$INSTALL/wa"
  cp -R "$ROOT/ui" "$INSTALL/ui"
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  [ -n "$PORT" ] || { echo "REFUSED healthlabel: no free port could be measured" >&2; exit 2; }
  ( cd /tmp && env -u WA_UI_DIR -u WASM_AGENT_LUA_ROOT -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY \
      WA_INSTALL_DIR="$INSTALL" WASM_AGENT_HOME="$SCRATCH_HOME" \
      "$INSTALL/wa" --db "$SCRATCH_HOME/node.db" serve --port "$PORT" --client-port "$((PORT + 1))" \
      --ui "$INSTALL/ui" >"$WORK/serve.log" 2>&1 ) &
  NODE_PID=$!
  # Wait for the node's OWN answer, not for a sleep: the record is written only once this succeeds.
  READY=0
  for _ in $(seq 1 200); do
    if curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then READY=1; break; fi
    sleep 0.1
  done
  if [ "$READY" != "1" ]; then
    bad "the scratch node did not answer /health; its log: $(tail -3 "$WORK/serve.log" 2>/dev/null)"
  else
    health_build() { curl -s -m 2 "http://127.0.0.1:$PORT/health" | sed -n 's/.*"build":"\([^"]*\)".*/\1/p'; }
    BEFORE="$(health_build)"
    # THE RECORD LANDS AFTER THE NODE IS SERVING, exactly as an upgrade writes it.
    printf 'binary_release=node-aaaaaaaaaaaa\n' > "$INSTALL/installed.txt"
    AFTER="$(health_build)"
    if [ "$AFTER" = "node-aaaaaaaaaaaa" ]; then
      ok "/health names the release installed two seconds AFTER this node started, with no restart (was: $BEFORE)"
    else
      bad "/health still says '$AFTER' after installed.txt began naming node-aaaaaaaaaaaa (it said '$BEFORE' before) - the label is the boot snapshot"
    fi
    printf 'binary_release=node-bbbbbbbbbbbb\n' > "$INSTALL/installed.txt"
    LATER="$(health_build)"
    if [ "$LATER" = "node-bbbbbbbbbbbb" ]; then
      ok "and it follows a later record too, still without a restart"
    else
      bad "/health says '$LATER' after the record changed to node-bbbbbbbbbbbb"
    fi
    # A RECORD THAT NAMES NOTHING IS NOT A NAME: the label falls back to the bytes' own, never to an empty string.
    : > "$INSTALL/installed.txt"
    EMPTY="$(health_build)"
    if [ -n "$EMPTY" ]; then ok "an empty record still answers a name ('$EMPTY'), never nothing"; else bad "/health answered an empty build label"; fi
  fi
fi

rm -rf "$WORK"
trap - EXIT
[ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
if [ "$failed" -eq 0 ]; then echo "health build label: ok ($checks checks)"; exit 0; fi
echo "health build label: FAILED ($checks checks, $failed failed)"
exit 1
