#!/usr/bin/env bash
# Item 1: the sentence the door itself prints, run verbatim, in the installed shape.
# WASM_AGENT_LUA_ROOT is unset for every door invocation below; the auth host is the delivery's own
# stand-in (a local node server) so the browser flow can actually complete without the live provider.
set -uo pipefail
BIN="${1:?usage: run-printed-sentence.sh <wa binary>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="$(mktemp -d)"
export WASM_AGENT_HOME="$WORK/home"; mkdir -p "$WASM_AGENT_HOME"
export WASM_AGENT_PI_AUTH="$WORK/no-such-pi-auth.json"
STORE="$WORK/sentence/credentials.json"
DB="$WORK/db-noroot"

cleanup() { [ -n "${MOCK_PID:-}" ] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

node "$ROOT/scripts/lib/openai-sub-auth-mock.mjs" --dir "$WORK/mock" >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do grep -q '^ready ' "$WORK/mock.log" && break; sleep 0.2; done
BASE="http://127.0.0.1:$(sed -n 's/^ready //p' "$WORK/mock.log" | head -1)"
echo "auth stand-in: $BASE   (WASM_AGENT_OPENAI_SUB_AUTH_BASE; not the live provider)"

door() { # door <args...>  -> runs with WASM_AGENT_LUA_ROOT UNSET, both streams captured
  env -u WASM_AGENT_LUA_ROOT \
    WASM_AGENT_OPENAI_SUB_STORE="$STORE" \
    WASM_AGENT_PI_AUTH="$WASM_AGENT_PI_AUTH" \
    WASM_AGENT_OPENAI_SUB_AUTH_BASE="$BASE" \
    "$BIN" --db "$DB" subscription "$@"
}

echo
echo "### step 1: wa subscription login --browser   (no Lua root)"
OUT="$(door login --browser 2>&1)"; STATUS=$?
printf '%s\n' "$OUT"
echo "exit=$STATUS"

SENTENCE="$(printf '%s\n' "$OUT" | grep -o 're-run with --code <the address you landed on>' | head -1)"
echo
echo "the printed sentence, verbatim: [$SENTENCE]"
STATE="$(printf '%s\n' "$OUT" | sed -n 's/.*[?&]state=\([0-9a-f]\{32\}\).*/\1/p' | head -1)"
echo "state from the printed authorize URL: $STATE"
echo "flow file while pending: $(cat "$WORK/sentence/login-flow.json" 2>/dev/null)"
PASTED="http://localhost:1455/auth/callback?code=PASTED-CODE&state=$STATE"

echo
echo "### step 2: the printed sentence, verbatim -> wa subscription login --code <the address you landed on>"
echo "     with <the address you landed on> = $PASTED"
OUT2="$(door login --code "$PASTED" 2>&1)"; STATUS2=$?
printf '%s\n' "$OUT2"
echo "exit=$STATUS2"

echo
echo "### step 3: what the store now holds, and what the door says"
echo "credentials.json source: $(grep -oE 'source.{1,4}[a-z:]+' "$STORE" 2>/dev/null | head -1)"
echo "device-code line printed anywhere above: $(printf '%s\n%s\n' "$OUT" "$OUT2" | grep -c 'codex/device')"
OUT3="$(door status 2>&1)"; STATUS3=$?
printf '%s\n' "$OUT3"
echo "exit=$STATUS3"
