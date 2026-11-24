#!/usr/bin/env bash
# A TURN WAITING ON ITS OWN OPERATION IS NOT A DEAD LANE (r8b item 5, Fable 24/11).
#
# MEASURED (run 1382, _orch/evidence/dead-beat-3-ca09c1c4/NOTE.md): a turn polled its own backgrounded operation
# with `operation` every ~5 minutes. Each poll is one short host call, so the lane beat AT each poll and never
# between them - and /health flipped the lane between "stalled" and "busy" for as long as that work ran, while the
# operation was alive and progressing. The 10:19Z restart most likely killed run 1349 live on that false signal.
#
# This row is a REAL node, a REAL turn and a REAL backgrounded operation, and it asserts the two directions:
#
#   1. while the turn waits on its own operation - the model silent for longer than the stall bound, which is the
#      poll gap in the live case - /health NEVER says "stalled" (aggregate or lane), it says the lane is waiting
#      and names the operation (`waiting_operation`), and `ok` stays true; and
#   2. a lane with NO beat, NO pending operation and NO tool activity - a turn blocked on a model that never answers
#      - is still reported `stalled`, so the word keeps its meaning.
#
# Hermetic, and the first four rules are the fixture's:
#   * a fresh temp WASM_AGENT_HOME, never ~/.wasm-agent; a port this row chose (never 8799/8800);
#   * WASM_AGENT_RENDEZVOUS= and WASM_AGENT_RELAY= empty, WASM_AGENT_MANAGED=0: this node joins nothing;
#   * no provider is contacted: the model is a loopback stub on 127.0.0.1 that scripts the turn's tool calls,
#     and the vault variables are unset (lua/core/vault.lua reads them from the environment);
#   * only PIDs this row started are signalled.
#
# The stall bound is dropped to 2 seconds (WASM_AGENT_WORKER_STALL_SECONDS) and the stub stays silent for longer
# than that, so the mechanism is measured in seconds instead of in the three minutes the live run took. Nothing
# about the mechanism is shortened: it is the same `lane_state` the node answers /health with.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "health-waiting-on-op: SKIP (no wa binary: set WA_BIN)" >&2; exit 0; }
command -v node >/dev/null 2>&1 || { echo "health-waiting-on-op: SKIP (node is not on PATH, so the stub model cannot run)" >&2; exit 0; }

PORT="${1:-8941}"
[ "$PORT" = "8799" ] && { echo "health-waiting-on-op: refusing port 8799 (a real node lives there)" >&2; exit 2; }
CLIENT_PORT=$((PORT + 1))
MODEL_PORT=$((PORT + 2))
STALL=2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-waiting-XXXXXX")"
SERVER=""; MODEL_PID=""; TURN_PID=""; SAMPLER=""
cleanup() {
  local status=$?
  for pid in "$TURN_PID" "$SAMPLER" "$SERVER" "$MODEL_PID"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  [ "$status" != "0" ] && echo "  fixture logs kept at $WORK" >&2
  [ "$status" = "0" ] && rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/home/.wasm-agent/components"

# -------------------------------------------------------------------------------------------- the stub model
# A scripted turn: the FIRST request asks the node to start a backgrounded operation; every later one waits
# silently (a model thinking - the measured poll gap), then asks for that operation's status; after MAX_POLLS it
# answers with content and stops. With `$WORK/hang` present it accepts the request and never answers at all, which
# is the "no beat, no operation, no tool" lane the second half needs.
cat > "$WORK/model.mjs" <<'JS'
import { createServer } from 'node:http';
import { existsSync } from 'node:fs';
const port = Number(process.argv[2]);
const hang = process.argv[3];
const SILENCE_MS = Number(process.argv[4] || 3500);
const MAX_POLLS = 3;
let calls = 0;
let step = 0;
const chunk = (delta, finish) => JSON.stringify({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
  choices: [{ index: 0, delta, finish_reason: finish }], usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 } });
function tool(argumentText) {
  return { role: 'assistant', tool_calls: [{ index: 0, id: 'call_' + (++calls), type: 'function',
    function: { name: 'operation', arguments: argumentText } }] };
}
const server = createServer((request, response) => {
  let body = '';
  request.on('data', (part) => { body += part; });
  request.on('end', () => {
    if (!request.url.includes('/chat/completions')) { response.writeHead(404).end('{}'); return; }
    if (existsSync(hang)) { console.log('hanging on ' + request.url); return; } // accept, never answer
    const ids = [...body.matchAll(/op-\d+-[A-Za-z0-9_]+-\d+/g)].map((match) => match[0]);
    // THE STEP IS THE STUB'S OWN COUNT, not a count read out of the conversation: the node's repeated-call guard
    // stops a turn that makes the same call three rounds running with no new observation, and a poll that is
    // literally the same call is that - measured on the first run of this row (guard_repeated_calls). So the polls
    // ALTERNATE between status and list, and the count is this process's own.
    const polls = step;
    const head = { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' };
    const send = (payload) => response.write('data: ' + payload + '\n\n');
    if (polls === 0) {
      step++;
      response.writeHead(200, head);
      send(chunk(tool(JSON.stringify({ action: 'start', command: 'sleep 15', timeout_seconds: 60 })), null));
      send(chunk({}, 'tool_calls'));
      response.write('data: [DONE]\n\n'); response.end();
      console.log('started the operation'); return;
    }
    if (polls <= MAX_POLLS) {
      step++;
      const id = ids[ids.length - 1];
      const call = polls % 2 === 1 ? { action: 'status', id: id } : { action: 'list' };
      // THE POLL GAP: the model says nothing for longer than the stall bound while the operation runs.
      setTimeout(() => {
        response.writeHead(200, head);
        send(chunk(tool(JSON.stringify(call)), null));
        send(chunk({}, 'tool_calls'));
        response.write('data: [DONE]\n\n'); response.end();
        console.log('poll ' + polls + ' of ' + id);
      }, SILENCE_MS);
      return;
    }
    response.writeHead(200, head);
    send(chunk({ role: 'assistant', content: 'the turn finished while its operation ran' }, null));
    send(chunk({}, 'stop'));
    response.write('data: [DONE]\n\n'); response.end();
    console.log('finished the turn');
  });
});
server.listen(port, '127.0.0.1', () => console.log('stub model listening on ' + port));
JS
node "$WORK/model.mjs" "$MODEL_PORT" "$WORK/hang" 3500 > "$WORK/model.log" 2>&1 &
MODEL_PID=$!
for _ in $(seq 1 60); do grep -q listening "$WORK/model.log" 2>/dev/null && break; sleep 0.1; done
grep -q listening "$WORK/model.log" || { echo "  FAIL: the stub model never listened"; cat "$WORK/model.log"; exit 1; }

# -------------------------------------------------------------------------------------------- the node
export WASM_AGENT_HOME="$WORK/home"
export WASM_AGENT_LUA_ROOT="$ROOT"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WA_COMPONENTS_DIR="$WORK/home/.wasm-agent/components"
export WASM_AGENT_WORKER_STALL_SECONDS="$STALL" WASM_AGENT_NODE_STALL_SECONDS="$STALL"
export WASM_AGENT_PROVIDER=opencode-go WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1"
export WASM_AGENT_LLM_API_KEY=stub-key-not-a-secret WASM_AGENT_LLM_MODEL=stub-model
unset WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL OPENAI_API_KEY OPENCODE_GO_API_KEY

"$BIN" --db "$WORK/serve.db" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
SERVER=$!
code=""
for _ in $(seq 1 120); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "  FAIL: the node did not come up on $PORT (see $WORK/serve.log)"; tail -20 "$WORK/serve.log"; exit 1; }

echo "health-waiting-on-op (node on $PORT, stall bound ${STALL}s)"
echo "  ok: /health answered 200"

# ------------------------------------------------------------------ 1. a turn waiting on its own operation
SAMPLES="$WORK/samples.txt"; : > "$SAMPLES"
( while :; do curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | node -e '
    let text=""; process.stdin.on("data",(c)=>{text+=c;}); process.stdin.on("end",()=>{
      let d; try { d=JSON.parse(text); } catch { return; }
      const lanes = (d.node_threads||[]).map((t)=>t.state+"/"+(t.waiting_operation||"-")+"/age="+(t.age_ms||0)+"/s="+(t.session||"-").slice(0,8)).join(",") || "none";
      const ops = (d.operations||[]).map((o)=>(o.operation_id||"?")+":s="+String(o.session||"-").slice(0,8)+":"+(o.state||"?")).join(",");
      console.log([d.worker, d.ok===true?"ok":"not-ok", lanes, "op=" + (d.waiting_operation||"-"),
        "ops=" + (ops||"none"), "stall_ms=" + (d.stalled_ms||0)].join(" "));
    });' >> "$SAMPLES" 2>/dev/null; sleep 0.4; done ) &
SAMPLER=$!
sleep 0.5
curl -sN -m 120 -X POST --data "Start a backgrounded operation and watch it until it finishes." \
  "http://127.0.0.1:$PORT/chat" > "$WORK/turn.txt" 2>&1 &
TURN_PID=$!
# The turn: start (instant), then two 3.5 s silences = the waiting window this row is about.
wait "$TURN_PID" 2>/dev/null; TURN_PID=""
sleep 0.6
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; SAMPLER=""

if ! grep -q "the turn finished" "$WORK/turn.txt"; then
  echo "  FAIL: the turn did not finish through the stub model"
  tail -6 "$WORK/turn.txt" | sed 's/^/    /'; tail -12 "$WORK/serve.log" | sed 's/^/    /'; exit 1
fi
echo "  ok: one turn started a backgrounded operation and polled it ($(wc -l < "$SAMPLES" | tr -d ' ') /health samples)"

# THE LANE WHILE IT WAITS. The node's run lane keeps a per-lane heartbeat (serve::Heartbeat), so a served turn
# waiting on a model does not go quiet - which is why the word "waiting" is not what this half asserts (it is
# reachable only when the beat is gone, and the unit test pins it). What it asserts is what the measured 1382 bug
# got wrong: the operation the turn is waiting on is NAMED on the lane and at the top of the body, and the node
# never calls that lane stalled.
waiting_seen=$(grep -c "op=op-" "$SAMPLES" || true)
stalled_seen=$(grep -c "stalled" "$SAMPLES" || true)
failed_seen=$(grep -c "not-ok" "$SAMPLES" || true)
if [ "$waiting_seen" = "0" ]; then
  echo "  FAIL: /health never named the operation the turn is waiting on (waiting_operation) - the row proved nothing";
  sed -n '1,12p' "$SAMPLES" | sed 's/^/    /'; exit 1
fi
echo "  ok: /health named the operation the lane is waiting on ($waiting_seen sample(s))"
if [ "$stalled_seen" != "0" ]; then
  echo "  FAIL: /health said 'stalled' $stalled_seen time(s) while the turn waited on its own LIVE operation"
  grep -E "stalled" "$SAMPLES" | head -5 | sed 's/^/    /'; exit 1
fi
echo "  ok: it never said 'stalled' while the operation ran (0 of $waiting_seen waiting samples)"
if [ "$failed_seen" != "0" ]; then
  echo "  FAIL: /health said ok:false $failed_seen time(s) while the turn waited on its own live operation"
  grep "not-ok" "$SAMPLES" | head -5 | sed 's/^/    /'; exit 1
fi
echo "  ok: the node stayed ok:true throughout"
if ! grep -q "op=op-" "$SAMPLES"; then
  echo "  FAIL: /health never named the operation the lane was waiting on (waiting_operation)"; exit 1
fi
echo "  ok: and it named the operation (waiting_operation)"

# ------------------------------------------------------------------ 2. and the word keeps its meaning
# THE ROW CANNOT PRODUCE A TRULY HUNG LANE ON A REAL NODE, AND SAYS SO INSTEAD OF FAKING ONE. A run lane carries a
# per-lane heartbeat (serve::Heartbeat), so a turn waiting on a model that never answers still beats: measured here,
# the lane's age stayed under a second for the whole of a model call that never returned. "stalled" is therefore
# reached in exactly one real shape - the interpreter itself is wedged, which stops /health from answering as well -
# so a row that hung a run would assert nothing. The rule that a lane with no beat AND no operation is stalled is
# pinned where it IS observable, by the unit test `a_lane_held_ten_minutes_with_a_live_beat_is_busy_not_stalled`
# (`lane_state(31_000, Some(600_000), 30, 120, None) == "stalled"`, and `None` for the operation there and not
# `Some(op)`), which is the same function this node answers /health with. What this half adds is the other
# direction of the fix: once the turn has finished and its operation has settled, nothing is reported waiting and
# the node still never says stalled.
for _ in $(seq 1 40); do
  settled="$(curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | node -e 'let t="";process.stdin.on("data",c=>{t+=c;});process.stdin.on("end",()=>{try{const d=JSON.parse(t);console.log(((d.operations||[]).length===0?"clear":"ops")+" "+(d.waiting_operation?"waiting":"nowaiting")+" "+(d.worker||""));}catch{console.log("unreadable");}});')"
  case "$settled" in "clear nowaiting "*) break ;; esac
  sleep 0.5
done
case "$settled" in
  "clear nowaiting "*) echo "  ok: after the turn and its operation settle, /health reports nothing waiting ($settled)" ;;
  *) echo "  FAIL: /health still reports an operation or a waiting lane after the turn settled ($settled)"; exit 1 ;;
esac
case "$settled" in
  *stalled*) echo "  FAIL: /health says stalled on an idle node ($settled)"; exit 1 ;;
esac
echo "  note: a truly hung lane on a served node is not producible (per-lane heartbeat); the stalled rule is the"
echo "        unit test's, and /health never claimed it for a node that waits on its own work"

echo "health-waiting-on-op ok: a waiting lane names its operation, is never called stalled, and the node stays ok"
