#!/usr/bin/env bash
# ONE TURN, ONE PROVIDER REQUEST (r8a/4, Fable 24/11). The instrument every later assertion needs: a model turn that
# starts and finishes against a provider this row controls, so the number of PAID turns is a number the row reads.
#
# WHAT WAS MEASURED TO GET HERE, AND THE CAUSE, WHICH I FIRST GOT WRONG. A first attempt drove `wa chat --once` with
# WASM_AGENT_LLM_BASE_URL pointing at the stub and saw requests=0 while a real model answered (the greeting is not a
# string in this tree): that turn was PAID FOR (~7.7k in / 14 out tokens). I first blamed the CLI attaching to the
# running node; it does not. The cause is the VAULT, read from the ENVIRONMENT and therefore NOT escapable by a
# scratch home: lua/core/vault.lua:23-33 (`M.url` reads WASM_AGENT_VAULT_URL / WASM_AGENT_OPENCODE_GO_VAULT_URL from
# the environment), and lua/core/provider.lua:56-62 (`base_url = vaulted_go or env(WASM_AGENT_LLM_BASE_URL)` - the
# vault wins over the base-URL env, and api_key becomes the vault placeholder). So a row must UNSET those two
# variables, which this one does; `--offline` additionally keeps the turn in this process.
#
# This row asserts the instrument: exactly ONE request at the stub for one turn. The multi-wake shape (a pause plus
# two re-arms plus a CLI resume) is written in scripts/lib/one-turn.lua and rides on this same stub.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "one turn: no wa binary (set WA_BIN)" >&2; exit 1; }
# The scratch comes from the runner's TMPDIR (test-tmp-cleanliness, half A) and is removed on every exit path.
S="$(mktemp -d "${TMPDIR:-/tmp}/one-turn-XXXXXX")"
mkdir -p "$S/home/.wasm-agent"
COUNT="$S/requests.txt"
: > "$COUNT"
cleanup() { pkill -f "stub-provider.py" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
STUB_PORT=0 STUB_COUNT_FILE="$COUNT" STUB_SLEEP_SECONDS="${STUB_SLEEP_SECONDS:-0}" STUB_REPLY="stub reply" \
  python3 "$ROOT/scripts/lib/stub-provider.py" > "$S/port.txt" 2>&1 &
for _ in $(seq 1 60); do grep -q listening "$S/port.txt" 2>/dev/null && break; sleep 0.1; done
PORT=$(grep -o '[0-9]*$' "$S/port.txt" | tail -1)
[ -n "$PORT" ] || { echo "FAIL: the stub never listened"; cat "$S/port.txt"; exit 1; }
OUT=$(env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL \
  WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_HOME="$S/home" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_DB= \
  WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$PORT" WASM_AGENT_LLM_API_KEY=stub-key WASM_AGENT_MODEL=stub-model \
  WASM_AGENT_PROVIDER=opencode-go \
  timeout 120 "$BIN" chat --once --offline "say hi" --db "$S/x.db" 2>&1)
echo "$OUT" | tail -3 | sed 's/^/  /'
REQUESTS=$(wc -l < "$COUNT")
if [ "$REQUESTS" != "1" ]; then
  echo "FAIL: one turn spent $REQUESTS request(s) at the provider, expected exactly 1"
  echo "$OUT" | tail -20
  exit 1
fi
echo "one turn ok (one turn = 1 request at the stub; the stub answered it)"
