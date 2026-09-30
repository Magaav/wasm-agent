#!/usr/bin/env bash
# Item 2 (the falsification half): would the delivery's new checks fail if the printed sentence and
# the behaviour drifted apart again? This never touches the reviewed tree: it exports the reviewed
# lua/ bytes with `git archive` into a throwaway root, mutates the COPY, and drives the same two
# commands the new test section drives.
#
# The new section itself hardcodes `shape noroot`; the mutation is therefore driven through
# WASM_AGENT_LUA_ROOT (the shape where the door is loaded from disk), so the binary's door code is
# identical to the tip's and only the mutated module differs. That difference is named in the verdict.
set -uo pipefail
BIN="${1:?usage: falsify-sentence-drift.sh <wa binary>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="$(mktemp -d)"
export WASM_AGENT_HOME="$WORK/home"; mkdir -p "$WASM_AGENT_HOME"
export WASM_AGENT_PI_AUTH="$WORK/no-such-pi-auth.json"

cleanup() { [ -n "${MOCK_PID:-}" ] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

node "$ROOT/scripts/lib/openai-sub-auth-mock.mjs" --dir "$WORK/mock" >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do grep -q '^ready ' "$WORK/mock.log" && break; sleep 0.2; done
BASE="http://127.0.0.1:$(sed -n 's/^ready //p' "$WORK/mock.log" | head -1)"

# the reviewed bytes, exported, then mutated - never the checkout
mkdir -p "$WORK/M1" "$WORK/M2"
git -C "$ROOT" archive HEAD lua | tar -x -C "$WORK/M1"
git -C "$ROOT" archive HEAD lua | tar -x -C "$WORK/M2"
echo "exported from HEAD=$(git -C "$ROOT" rev-parse HEAD)"
echo "the fix line in the export: [$(grep -n 'options.code and not options.mode' "$WORK/M1/lua/core/openai_sub_login.lua")]"

# M1: the behaviour drifts - the one line that makes a bare --code mean the browser flow is removed.
# The printed sentence is untouched, exactly the drift the new checks exist for.
sed -i '/if options.code and not options.mode then options.mode = "browser" end/d' "$WORK/M1/lua/core/openai_sub_login.lua"
# M2: the sentence drifts - the door now prints the *other* spelling (`--browser --code`) while the
# behaviour is left alone.
sed -i 's/re-run with --code <the address you landed on>/re-run with --browser --code <the address you landed on>/' \
  "$WORK/M2/lua/core/openai_sub_login.lua"

drive() { # drive <luaroot> <label>
  local root="$1"
  local label="$2"
  local store="$WORK/$label/credentials.json"
  local db="$WORK/db-$label"
  local out="" state="" pasted="" out2=""
  out="$(WASM_AGENT_LUA_ROOT="$root" WASM_AGENT_OPENAI_SUB_STORE="$store" \
    WASM_AGENT_OPENAI_SUB_AUTH_BASE="$BASE" "$BIN" --db "$db" subscription login --browser 2>&1)"
  echo
  echo "--- $label: wa subscription login --browser"
  printf '%s\n' "$out"
  echo "  check 2 (the door prints the instruction this section is about): $(printf '%s' "$out" | grep -c 're-run with --code <the address you landed on>') match(es)"
  state="$(printf '%s\n' "$out" | sed -n 's/.*[?&]state=\([0-9a-f]\{32\}\).*/\1/p' | head -1)"
  pasted="http://localhost:1455/auth/callback?code=PASTED-CODE&state=$state"
  echo "  check 3 (what is pending): $(grep -oE 'flow.{1,4}browser' "$WORK/$label/login-flow.json" 2>/dev/null || echo 'no flow file')"
  out2="$(WASM_AGENT_LUA_ROOT="$root" WASM_AGENT_OPENAI_SUB_STORE="$store" \
    WASM_AGENT_OPENAI_SUB_AUTH_BASE="$BASE" "$BIN" --db "$db" subscription login --code "$pasted" 2>&1)"
  echo "--- $label: the sentence that door printed, run verbatim"
  printf '%s\n' "$out2"
  echo "  check 5 (the BROWSER flow completed): source=$(grep -oE 'source.{1,4}[a-z:]+' "$store" 2>/dev/null | head -1)  [login:browser would pass]"
  echo "  check 8 (no device-code line): $(printf '%s' "$out2" | grep -c 'codex/device') device-code line(s)  [0 would pass]"
}

drive "$WORK/M1" M1
drive "$WORK/M2" M2
