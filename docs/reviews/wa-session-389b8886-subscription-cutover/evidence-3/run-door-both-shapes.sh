#!/usr/bin/env bash
# Item 3 spot-check: the door in BOTH shapes (status and login, with and without a Lua root), raw.
set -uo pipefail
BIN="${1:?usage: run-door-both-shapes.sh <wa binary>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="$(mktemp -d)"
export WASM_AGENT_HOME="$WORK/home"; mkdir -p "$WASM_AGENT_HOME"
export WASM_AGENT_PI_AUTH="$WORK/no-such-pi-auth.json"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

shape() { # shape <noroot|root> <store dir> <label> <args...>
  local which="$1" dir="$2" label="$3"; shift 3
  if [ "$which" = noroot ]; then
    env -u WASM_AGENT_LUA_ROOT WASM_AGENT_OPENAI_SUB_STORE="$dir/credentials.json" \
      "$BIN" --db "$WORK/db-$which-$label" subscription "$@" >"$WORK/out-$which-$label" 2>&1
  else
    WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_OPENAI_SUB_STORE="$dir/credentials.json" \
      "$BIN" --db "$WORK/db-$which-$label" subscription "$@" >"$WORK/out-$which-$label" 2>&1
  fi
  local status=$?
  echo "--- [$which] wa subscription $* -> exit=$status"
  sed -e 's/code_challenge=[^&]*/code_challenge=<fresh>/' -e 's/&state=[0-9a-f]*/\&state=<fresh>/' \
    "$WORK/out-$which-$label"
}

# status: the SAME store dir in both shapes, so nothing but the shape differs (as the door test does).
shape noroot "$WORK/status" status status
shape root   "$WORK/status" status status
echo "status byte-identical in both shapes: $(cmp -s "$WORK/out-noroot-status" "$WORK/out-root-status" && echo yes || echo no)"

shape noroot "$WORK/login-noroot" login login --browser
shape root   "$WORK/login-root"   login login --browser
echo
echo "normalised login --browser, no root (unique lines):"; sed -e 's/code_challenge=[^&]*/code_challenge=<fresh>/' -e 's/&state=[0-9a-f]*/\&state=<fresh>/' -e 's#^.*oauth/authorize#  oauth/authorize#' "$WORK/out-noroot-login" | sort -u
echo "normalised login --browser, with root (unique lines):"; sed -e 's/code_challenge=[^&]*/code_challenge=<fresh>/' -e 's/&state=[0-9a-f]*/\&state=<fresh>/' -e 's#^.*oauth/authorize#  oauth/authorize#' "$WORK/out-root-login" | sort -u

echo
echo "--- the WA_SCRIPT= spelling, both shapes (scripts/openai-sub-login.lua wrapper, --browser)"
echo "    (a bare 'status' through this spelling would run the wrapper's own login policy, so the"
echo "     spelling is exercised the way the credential lane's LOGIN_COMMAND names it: --browser)"
for which in noroot root; do
  if [ "$which" = noroot ]; then
    out="$(timeout 60 env -u WASM_AGENT_LUA_ROOT WA_SCRIPT="$ROOT/scripts/openai-sub-login.lua" \
      WASM_AGENT_OPENAI_SUB_STORE="$WORK/ws-$which/credentials.json" \
      "$BIN" --db "$WORK/db-ws-$which" --browser 2>&1)"; st=$?
  else
    out="$(timeout 60 env WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT="$ROOT/scripts/openai-sub-login.lua" \
      WASM_AGENT_OPENAI_SUB_STORE="$WORK/ws-$which/credentials.json" \
      "$BIN" --db "$WORK/db-ws-$which" --browser 2>&1)"; st=$?
  fi
  echo "[$which] WA_SCRIPT --browser -> exit=$st"
  printf '%s\n' "$out" | sed -e 's/code_challenge=[^&]*/code_challenge=<fresh>/' -e 's/&state=[0-9a-f]*/\&state=<fresh>/' | grep -v '^\[lua\]'
done
