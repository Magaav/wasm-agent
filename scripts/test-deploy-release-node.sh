#!/usr/bin/env bash
# THE RELEASE LINE ON A REAL SCRATCH NODE, BOTH WAYS (r8c 1, Fable 24/11).
#
# Everything here is the product's own, on a node of its own: a scratch `wa serve` (own HOME, own port, own ledger), a
# REAL session paused by a REAL deploy-pending marker written into THAT node's data dir, and then two endings of the
# same pause:
#
#   1. A SCRIPTS-ONLY INSTALL: `installed.txt`'s `lua_tree=` moves (the binary's commit, `host.build_identity`, does
#      NOT - measured 24/11: 9a0c589a before and after ffb5153e). The pause was taken on the old tree, the record was
#      then rewritten the way a scripts-only deploy writes it, and the marker goes with the install done: the node's
#      own tick must release ONE resume turn and its ledger row must carry "[deploy] installed", naming the NEW tree
#      commit - not "nothing was installed".
#   2. A MARKER REMOVED WITH NO INSTALL: the record does not move. The same tick must release ONE resume turn whose
#      row carries "[deploy] the update did not happen".
#
# Both lines are read back from the node's OWN ledger with sqlite3, not from a variable in this row, and every turn is
# counted at the loopback model: one request per turn, no more.
#
# Fences: the real ~/.wasm-agent is never touched (HOME and WASM_AGENT_HOME are the scratch dir, the record is written
# THERE), the vault and provider variables are cleared, only this row's port is bound, and the only pids signalled are
# the ones it started.
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
# The node's OWN install directory (`update.install_dir()`: WA_INSTALL_DIR, else <home>/.local/bin) - inside the scratch
# home, never the machine's.
INSTALL="$WORK/home/.local/bin"
record() { # <commit> <lua_tree> - the shape scripts/deploy.sh:1975 writes
  mkdir -p "$INSTALL"
  printf 'commit=%s\nlua_tree=%s\nlua_fast_path=1\nat=%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL/installed.txt"
}
LEDGER="file:$DATA/memory.db?mode=ro"
ledger() { sqlite3 "$LEDGER" "$1" 2>/dev/null; }

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
    appendFileSync(count, Date.now() + ' request\n');
    const n = Number(readFileSync(count, 'utf8').trim().split('\n').filter(Boolean).length);
    const head = { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' };
    const send = (payload) => response.write('data: ' + JSON.stringify(payload) + '\n\n');
    response.writeHead(200, head);
    if (n === 1 || n === 3) {
      // ONE IN-FLIGHT TURN PER PAUSE, NOT A REFUSED ONE: a turn that has not started is REFUSED by a waiting build
      // (that is `deploy_waiting`, measured here first), and the pause is the rule for a turn already running. A slow
      // tool gives this row a window to write the marker between two step boundaries.
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'call_1', type: 'function',
          function: { name: 'bash', arguments: JSON.stringify({ command: 'sleep 8' }) } }] }, finish_reason: null }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 } });
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
    } else {
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: { role: 'assistant', content: 'ok' }, finish_reason: null }],
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
requests() { wc -l < "$COUNT" | tr -d ' '; }
wait_requests() { # <n> <seconds>
  local want=$1 budget=$2
  for _ in $(seq 1 "$((budget * 2))"); do [ "$(requests)" -ge "$want" ] && return 0; sleep 0.1; done
  return 1
}

# ---------------------------------------------------------------------------------------- the scratch node
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home" WASM_AGENT_LUA_ROOT="$ROOT"
unset WA_INSTALL_DIR
export WA_COMPONENTS_DIR="$WORK/home/.wasm-agent/components"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WASM_AGENT_PROVIDER=opencode-go WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MP/v1"
export WASM_AGENT_LLM_API_KEY=stub-key-not-a-secret WASM_AGENT_LLM_MODEL=stub-model
unset WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL OPENAI_API_KEY OPENCODE_GO_API_KEY

# THE PAUSE IS TAKEN ON THIS RECORD: the bytes and the tree the node installs now.
record 42507780 42507780
"$BIN" --db "$DATA/memory.db" serve --port "$PORT" --client-port "$CP" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 & SERVER=$!
code=""
for _ in $(seq 1 160); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "  FAIL: the scratch node did not come up on $PORT"; tail -12 "$WORK/serve.log"; exit 1; }

echo "deploy-release-node (node on $PORT, home $WORK/home, record $INSTALL/installed.txt)"

# ---------------------------------------------------------------------------------------- 1. a SCRIPTS-ONLY install
# The turn is IN FLIGHT first (a turn that has not started is REFUSED by a waiting build - `deploy_waiting` - and the
# pause is the rule for a turn already running), then the marker appears mid-turn.
# WHAT HAPPENED, printed when a case fails: the turn's own bytes, the node's ledger rows and the log this row writes.
dump() {
  echo "    turn: $(head -c 200 "$WORK/turn-$1.txt" 2>/dev/null | tr '\n' ' ')"
  echo "    wakes: $(ledger "SELECT id||' '||status||' '||substr(replace(prompt,char(10),' '),1,60) FROM self_wakes ORDER BY created_at;" | tr '\n' '|')"
  echo "    sessions: $(ledger "SELECT id||' '||substr(objective,1,12)||' '||created_at FROM sessions ORDER BY created_at;" | tr '\n' '|')"
  echo "    requests: $(requests) -> $(tr '\n' '|' < "$COUNT")"
  echo "    log: $(grep -iE 'deploy|pause|refus' "$WORK/serve.log" | tail -6 | tr '\n' '|')"
}

pause_a_turn() { # <case> <thread>
  local before; before=$(requests)
  local body; body=$(printf '{"text":"finish the release check","thread":"%s"}' "$2")
  curl -sN -m 90 -X POST --data "$body" "http://127.0.0.1:$PORT/chat" > "$WORK/turn-$1.txt" 2>&1 & TURN=$!
  wait_requests "$((before + 1))" 60 || { echo "  FAIL: the turn never reached the model"; tail -5 "$WORK/turn-$1.txt"; exit 1; }
  local now; now=$(date +%s)
  printf '{"to":"deadbeefcafe","state":"deploy_pending","since":%s,"bound_seconds":120,"by":"scripts/test-deploy-release-node.sh"}' \
    "$now" > "$MARKER"
  echo "  ok: the marker appeared mid-turn on thread $2 (since $now)"
  wait "$TURN" 2>/dev/null; TURN=""
  grep -q "deploy pending\|deploy waiting\|paused after" "$WORK/turn-$1.txt" \
    || { echo "  FAIL: the in-flight turn did not pause when the marker appeared"; dump "$1"; exit 1; }
  local spent; spent=$(requests)
  [ "$spent" = "$((before + 1))" ] || { echo "  FAIL: the paused turn spent $((spent - before)) model request(s), expected 1 (its first round)"; exit 1; }
}
pause_a_turn a release-case-a
echo "  ok: the in-flight turn paused for the marker (1 model request, its first round)"
sleep 1

# THE INSTALL THAT DID HAPPEN, AND ONLY SWAPPED THE TREE: the bytes' commit does not move (42507780 before and after),
# the Lua tree does - which is exactly the scripts-only install whose release used to say "nothing was installed".
record 42507780 bbbb5555eeee6666
rm -f "$MARKER"
wait_requests 2 60 || { echo "  FAIL: the pause was never released (no resume turn in 60 s)"; tail -12 "$WORK/serve.log"; exit 1; }
sleep 4
spent=$(requests)
[ "$spent" = "2" ] || { echo "  FAIL: the release spent $spent model request(s) in total, expected 2 (the paused round + exactly ONE resume turn)"; exit 1; }
echo "  ok: the release ran exactly ONE resume turn (1 new request at the model)"
LINE=$(ledger "SELECT prompt FROM self_wakes WHERE reason='deploy pending: resume after the node swap' ORDER BY created_at DESC LIMIT 1;")
case "$LINE" in
  *"[deploy] installed"*) : ;;
  *) echo "  FAIL: the released row does not say the build is installed: $(printf '%s' "$LINE" | head -c 160)"; exit 1 ;;
esac
case "$LINE" in
  *"nothing was installed"*) echo "  FAIL: after a real scripts-only install the row says nothing was installed"; exit 1 ;;
esac
case "$LINE" in
  *bbbb5555eeee*) : ;;
  *) echo "  FAIL: the installed line does not name the tree the install put there (bbbb5555eeee): $(printf '%s' "$LINE" | head -c 160)"; exit 1 ;;
esac
echo "  ok: the ledger row says '[deploy] installed', naming the new tree commit bbbb5555eeee (and not 'nothing was installed')"

# ---------------------------------------------------------------------------------------- 2. a marker with NO install
pause_a_turn b release-case-b
echo "  ok: a second turn paused for a second marker (1 model request)"
sleep 1
# THE UPDATE THAT DID NOT HAPPEN: the marker goes, the installed record does NOT move.
rm -f "$MARKER"
wait_requests 4 60 || { echo "  FAIL: the second pause was never released"; tail -12 "$WORK/serve.log"; exit 1; }
sleep 4
spent=$(requests)
[ "$spent" = "4" ] || { echo "  FAIL: the row spent $spent model request(s) in total, expected 4 (two paused rounds + one resume each)"; exit 1; }
echo "  ok: the second release also ran exactly ONE resume turn (1 new request)"
LINE=$(ledger "SELECT prompt FROM self_wakes WHERE reason='deploy pending: resume after the node swap' ORDER BY created_at DESC LIMIT 1;")
case "$LINE" in
  *"[deploy] the update did not happen"*) : ;;
  *) echo "  FAIL: a marker removed with no install did not say the update did not happen: $(printf '%s' "$LINE" | head -c 160)"; exit 1 ;;
esac
case "$LINE" in
  *deadbeefcafe*) : ;;
  *) echo "  FAIL: the did-not-happen line does not name the target the marker carried: $(printf '%s' "$LINE" | head -c 160)"; exit 1 ;;
esac
echo "  ok: the ledger row says '[deploy] the update did not happen', naming the marker's target"
echo "deploy-release-node ok: a real scratch node decides the release line from the INSTALLED RECORD - installed after a scripts-only install, did-not-happen when the marker goes and nothing was installed"

