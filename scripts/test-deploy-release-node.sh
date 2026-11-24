#!/usr/bin/env bash
# A REAL SCRATCH NODE RELEASES A PAUSE THAT NEVER HAPPENED (r8c 1, the row Fable asked for).
#
# Everything here is the product's own, on a node of its own: a scratch `wa serve` (own HOME, own port, own ledger),
# a REAL session paused by a REAL deploy-pending marker written into THAT node's data dir, the marker then REMOVED
# with no swap - the shape a failed install leaves (measured 24/11: seven sessions sat 20-37 minutes; the 16:48Z
# and 17:06Z signals were a test leak writing the real marker, not an install).
#
# What it asserts, end to end through the node's own placement tick:
#   * while the marker is live the turn PAUSES and spends no model request;
#   * when the marker goes with nothing installed, the pause is RELEASED: exactly ONE resume turn runs (one request
#     at the loopback model), and the ledger row it came from carries the machine's own line,
#     "[deploy] the update did not happen" - read back from the node's ledger, not from a variable in the row.
#
# Fences: the real ~/.wasm-agent is never touched (HOME and WASM_AGENT_HOME are the scratch dir, and the marker is
# written THERE); the vault and provider variables are cleared; the only port bound is this row's; the only pids
# signalled are the ones it started.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "deploy-release-node: SKIP (no wa binary: set WA_BIN)" >&2; exit 0; }
command -v node >/dev/null 2>&1 || { echo "deploy-release-node: SKIP (node is not on PATH)" >&2; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { echo "deploy-release-node: SKIP (sqlite3 is not on PATH, so the ledger cannot be read back)" >&2; exit 0; }

PORT="${1:-$((9100 + RANDOM % 200))}"
[ "$PORT" = "8799" ] && PORT=9123
CP=$((PORT + 1)); MP=$((PORT + 2))
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-release-XXXXXX")"
SERVER=""; MODEL=""; TURN=""
cleanup() {
  local status=$?
  for pid in "$TURN" "$SERVER" "$MODEL"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  [ "$status" != "0" ] && echo "  fixture kept at $WORK" >&2
  [ "$status" = "0" ] && rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/home/.wasm-agent/components"
DATA="$WORK/home/.wasm-agent"
MARKER="$DATA/deploy-pending.json"

# ---------------------------------------------------------------------------------------- the loopback model
# One answer per request, and every request is APPENDED to a file: the count is the number of turns that reached
# the model, which is what "one resume turn" means here.
cat > "$WORK/model.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
const port = Number(process.argv[2]);
const count = process.argv[3];
createServer((request, response) => {
  let body = '';
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    if (!request.url.includes('/chat/completions')) { response.writeHead(404).end('{}'); return; }
    appendFileSync(count, 'request\n');
    const n = Number(readFileSync(count, 'utf8').trim().split('\n').filter(Boolean).length);
    const head = { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' };
    const send = (payload) => response.write('data: ' + JSON.stringify(payload) + '\n\n');
    response.writeHead(200, head);
    if (n === 1) {
      // ONE IN-FLIGHT TURN, NOT A REFUSED ONE: a turn that has not started is REFUSED by a waiting build (that is
      // `deploy_waiting`, measured here first), and the pause is the rule for a turn already running. A slow tool
      // gives the row a window to write the marker between two step boundaries.
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'call_1', type: 'function',
          function: { name: 'bash', arguments: JSON.stringify({ command: 'sleep 3' }) } }] }, finish_reason: null }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 } });
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
    } else {
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: { role: 'assistant', content: 'resumed' }, finish_reason: null }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 } });
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] });
    }
    response.write('data: [DONE]\n\n'); response.end();
  });
}).listen(port, '127.0.0.1', () => console.log('listening'));
JS
COUNT="$WORK/requests.txt"; : > "$COUNT"
node "$WORK/model.mjs" "$MP" "$COUNT" > "$WORK/model.log" 2>&1 & MODEL=$!
for _ in $(seq 1 60); do grep -q listening "$WORK/model.log" 2>/dev/null && break; sleep 0.1; done

# ---------------------------------------------------------------------------------------- the scratch node
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home" WASM_AGENT_LUA_ROOT="$ROOT"
export WA_COMPONENTS_DIR="$WORK/home/.wasm-agent/components"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WASM_AGENT_PROVIDER=opencode-go WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MP/v1"
export WASM_AGENT_LLM_API_KEY=stub-key-not-a-secret WASM_AGENT_LLM_MODEL=stub-model
unset WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL OPENAI_API_KEY OPENCODE_GO_API_KEY

"$BIN" --db "$DATA/memory.db" serve --port "$PORT" --client-port "$CP" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 & SERVER=$!
code=""
for _ in $(seq 1 160); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "  FAIL: the scratch node did not come up on $PORT"; tail -12 "$WORK/serve.log"; exit 1; }

echo "deploy-release-node (node on $PORT, home $WORK/home, marker $MARKER)"
# THE TURN IS IN FLIGHT FIRST (a turn that has not started is REFUSED by a waiting build - `deploy_waiting` -
# and the pause is the rule for a turn already running), then the marker appears mid-turn.
curl -sN -m 90 -X POST --data "finish the release check" "http://127.0.0.1:$PORT/chat" > "$WORK/turn.txt" 2>&1 & TURN=$!
for _ in $(seq 1 60); do [ "$(wc -l < "$COUNT" | tr -d ' ')" -ge 1 ] && break; sleep 0.5; done
NOW=$(date +%s)
printf '{"to":"deadbeefcafe","state":"deploy_pending","since":%s,"bound_seconds":120,"by":"scripts/test-deploy-release-node.sh"}' \
  "$NOW" > "$MARKER"
wait "$TURN" 2>/dev/null; TURN=""
paused=$(grep -c "deploy pending\|deploy waiting\|paused after" "$WORK/turn.txt" || true)
[ "$paused" -ge 1 ] || { echo "  FAIL: the in-flight turn did not pause when the marker appeared"; tail -3 "$WORK/turn.txt"; exit 1; }
spent=$(wc -l < "$COUNT" | tr -d ' ')
[ "$spent" = "1" ] || { echo "  FAIL: the paused turn spent $spent model request(s), expected 1 (its first round)"; exit 1; }
echo "  ok: the in-flight turn paused for the marker (1 model request, its first round)"
sleep 3

# THE INSTALL THAT NEVER HAPPENED: the marker goes, nothing was installed. The node's own tick must release the
# pause - one resume turn, which reaches the model exactly once.
rm -f "$MARKER"
released=""
for _ in $(seq 1 60); do
  n=$(wc -l < "$COUNT" | tr -d ' ')
  if [ "$n" -ge 2 ]; then released="yes"; break; fi
  sleep 1
done
[ -n "$released" ] || { echo "  FAIL: the pause was never released (no resume turn in 60 s)"; tail -12 "$WORK/serve.log"; exit 1; }
sleep 4
spent=$(wc -l < "$COUNT" | tr -d ' ')
if [ "$spent" != "2" ]; then
  echo "  FAIL: the release spent $spent model request(s) in total, expected 2 (the paused round + exactly ONE resume turn)"
  grep -c "kept\|deploy" "$WORK/serve.log" >/dev/null 2>&1 || true
  exit 1
fi
echo "  ok: the release ran exactly ONE resume turn (1 new request at the model)"

# THE MACHINE'S OWN LINE, read back from the node's ledger (not from a variable in this row).
LINE=$(sqlite3 "file:$DATA/memory.db?mode=ro" "SELECT COUNT(*) FROM self_wakes WHERE prompt LIKE '%the update did not happen%';" 2>/dev/null)
if [ "${LINE:-0}" -lt 1 ]; then
  echo "  FAIL: no wake row in the node's ledger carries the line 'the update did not happen'"
  sqlite3 "file:$DATA/memory.db?mode=ro" "SELECT reason, substr(prompt,1,60) FROM self_wakes ORDER BY created_at DESC LIMIT 3;" 2>/dev/null | sed 's/^/    /'
  exit 1
fi
echo "  ok: the ledger row carries the machine line 'the update did not happen' ($LINE row(s))"
echo "deploy-release-node ok: a scratch node releases a pause whose update did not happen, with one resume turn that says so"
