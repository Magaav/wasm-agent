#!/usr/bin/env bash
# A deploy request that is only WAITING already stops this node from starving it (22/11).
#
#   bash scripts/test-deploy-wait.sh
#
# MEASURED twice on this laptop (22/11, ~/.wasm-agent/sentinel/sentinel.log): the deploy for 8082b42e was held
# from 10:01:24Z to 10:31:48Z - thirty minutes - with three workers running, and `wa-sentinel status` named
# nobody. The pause signal that existed was the INSTALLER's marker, written only after the request had been
# performed, so the wait itself was covered by nothing: a running turn was never asked to pause, every resume
# wake was released at once ("the marker is gone"), and every new `wa chat --once`, wake or child kept the node
# busy for another turn.
#
# This is the cross-process proof of the fix - five processes, one scratch home:
#
#   1. a real node (this tree's Lua over its own `wa serve`) is asked for a turn while nothing waits: the stub
#      model answers, so the fixture is proved before anything is claimed about it;
#   2. the request arrives: a served turn is refused with `deploy_waiting ... waiting for the install of <sha>`
#      and the stub model is NOT called - a refusal that still spent a model call would be no fix at all;
#   3. a real `wa chat --once` process - the shape the workers of the incident were - is refused with exit 2, the
#      same sentence, no model call and no message written;
#   4. a turn already RUNNING when the request arrives pauses at its next step boundary, by itself, and schedules
#      its resume;
#   5. the node's own tick holds that resume while the request waits and while the installer's marker is up, and
#      performs it exactly once when the deploy ends - the paused process does not have to exist any more;
#   6. nothing is lost: every refused turn wrote nothing, and the resumed turn runs.
#
# Hermetic: its own WASM_AGENT_HOME under $TMPDIR, its own ports (never 8799), a stub model on 127.0.0.1, no
# rendezvous, no relay, no provider, and only PIDs this script started are ever signalled.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then
  for candidate in "${CARGO_TARGET_DIR:-$ROOT/rust/target}/release/wa" "${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa" \
                   "$ROOT/rust/target/release/wa" "$ROOT/rust/target/debug/wa" \
                   "$(command -v wa 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { BIN="$candidate"; break; }
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "deploy wait: SKIP (no wa binary: set WA_BIN, or build rust/wa-host)" >&2
  exit 0
fi
case "$BIN" in /*|[A-Za-z]:*) ;; *) BIN="$ROOT/$BIN" ;; esac
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# The claim is about processes and a node, so the row needs node for its stub model: an honest skip, not a pass.
command -v node >/dev/null 2>&1 || { echo "deploy wait: SKIP (no node on this host: the stub model is a node script)" >&2; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "deploy wait: SKIP (no curl: the node is asked over HTTP)" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-wait-XXXXXX")"
SERVER_PID=""
MODEL_PID=""
cleanup() {
  local status=$?
  for pid in "$SERVER_PID" "$MODEL_PID"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  for pid in "$SERVER_PID" "$MODEL_PID"; do
    [ -n "$pid" ] || continue
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$pid" 2>/dev/null
  done
  wait 2>/dev/null || true
  [ "$status" != "0" ] && echo "  fixture logs kept at $WORK" >&2
  [ "$status" = "0" ] && rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT

fails=0
step() { printf '  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
ok()   { printf '    ok: %s\n' "$*"; }
want() { case "$1" in *"$2"*) ok "$3" ;; *) fail "$3: expected '$2' in: $1" ;; esac; }
unwant() { case "$1" in *"$2"*) fail "$3: unexpected '$2' in: $1" ;; *) ok "$3" ;; esac; }
# Two different questions, and a check that answers the wrong one passes for the wrong reason (the first run of
# this row did exactly that: a `must not change` assertion written with the `changed` helper reported "ok" for
# a number that had doubled).
neq() { if [ "$1" = "$2" ]; then fail "$3: still $1"; else ok "$3 ($2 -> $1)"; fi; }
same() { if [ "$1" = "$2" ]; then ok "$3 (still $1)"; else fail "$3: expected $2, got $1"; fi; }

PORT="${WA_TEST_PORT:-$(( 9000 + (RANDOM % 400) ))}"
CLIENT_PORT=$((PORT + 1))
MODEL_PORT=$((PORT + 2))
[ "$PORT" = "8799" ] && PORT=8801

HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/.wasm-agent/components" || { echo "deploy wait: SKIP (no scratch home)" >&2; exit 0; }
export WASM_AGENT_HOME="$(native "$HOME_DIR")"
export WASM_AGENT_LUA_ROOT="$(native "$ROOT")"
export WA_COMPONENTS_DIR="$(native "$HOME_DIR/.wasm-agent/components")"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export GATE_ROOT="$WORK"
unset WASM_AGENT_DB WASM_AGENT_IN_TURN OPENAI_API_KEY OPENCODE_GO_API_KEY WASM_AGENT_VAULT_URL
DB="$WORK/serve.db"

SENT_DIR="$HOME_DIR/.wasm-agent/sentinel"
BOX="$SENT_DIR/requests"
CLAIMED="$SENT_DIR/claimed"
SIGNAL="$HOME_DIR/.wasm-agent/deploy-pending.json"
SHA="8082b42e11112222333344445555666677778888"
REQUEST_ID="1795341684727384607-2971842-00000000000000000000"

# ------------------------------------------------------------------------------ the stub model (loopback only)
# It counts every completion it is asked for, delays the FIRST one when the harness asks it to, and asks for a
# tool (`wake`) on the first round so a turn is two rounds long - a turn that needs a second step is what makes
# a step boundary observable at all (`deploy_pause.at_boundary` runs at round > 1).
cat > "$WORK/model.mjs" <<'JS'
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const port = Number(process.argv[2]);
const countFile = process.argv[3];
const delayFile = process.argv[4];
writeFileSync(countFile, '');
const delayMs = () => { try { return Number(readFileSync(delayFile, 'utf8').trim()) || 0; } catch { return 0; } };
const usedTools = (body) => (Array.isArray(body.messages) ? body.messages : []).some((m) => m && (m.role === 'tool' || (m.tool_calls && m.tool_calls.length)));
function answer(text, wantsTools) {
  const chunk = (delta, finish) => 'data: ' + JSON.stringify({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
    choices: [{ index: 0, delta, finish_reason: finish }], usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 } }) + '\n\n';
  let body = '';
  if (wantsTools) {
    body += chunk({ role: 'assistant', tool_calls: [{ index: 0, id: 'call-wake-1', type: 'function', function: { name: 'wake', arguments: JSON.stringify({ in_seconds: 3600, reason: 'stub' }) } }] }, null);
    body += chunk({}, 'tool_calls');
  } else {
    body += chunk({ role: 'assistant', content: text }, null);
    body += chunk({}, 'stop');
  }
  return body + 'data: [DONE]\n\n';
}
const server = createServer((request, response) => {
  let raw = '';
  request.on('data', (chunk) => { raw += chunk; });
  request.on('end', () => {
    let body = {};
    try { body = JSON.parse(raw || '{}'); } catch { body = {}; }
    const delay = delayMs();
    if (delay) writeFileSync(delayFile, '0');
    appendFileSync(countFile, '1\n');
    const wantsTools = !usedTools(body);
    const send = () => {
      response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      response.end(answer('stub-ok', wantsTools));
    };
    if (delay) setTimeout(send, delay); else send();
  });
});
server.listen(port, '127.0.0.1');
JS
printf '0' > "$WORK/delay"
node "$WORK/model.mjs" "$MODEL_PORT" "$WORK/model.calls" "$WORK/delay" > "$WORK/model.log" 2>&1 &
MODEL_PID=$!

step "a stub model on 127.0.0.1:$MODEL_PORT, and this tree's wa: $BIN"
for _ in $(seq 1 60); do
  case "$(cat "$WORK/model.calls" 2>/dev/null)" in '') sleep 0.1 ;; *) break ;; esac
done
export WASM_AGENT_PROVIDER=opencode-go
export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1"
export WASM_AGENT_LLM_API_KEY=stub-key-not-a-secret
export WASM_AGENT_LLM_MODEL=deepseek-v4.1-flash
unset WASM_AGENT_LLM_SUMMARY_MODEL
calls() { local n; n=$(wc -l < "$WORK/model.calls" 2>/dev/null | tr -d ' '); echo "${n:-0}"; }
lua() { # <mode> [extra env...]
  DW_MODE="$1" WA_SCRIPT="scripts/lib/deploy-wait-e2e.lua" "$BIN" --db "$DB" 2>&1 | grep -v 'served natively'
}
counts() { lua count | sed -n 's/.*\(sessions=[0-9]* messages=[0-9]* resume_wakes=[0-9]*\).*/\1/p' | tail -1; }
field() { printf '%s' "$1" | sed -n "s/.*$2=\\([0-9]*\\).*/\\1/p"; }

# A request in the box, and the installer's own marker file: the two states a deploy goes through.
write_request() {
  mkdir -p "$BOX"
  printf '{"verb":"deploy","target_commit":"%s","queued_at":%s,"reason":"land the fix Victor is waiting for"}\n' \
    "$SHA" "$(date +%s)" > "$BOX/$REQUEST_ID.json"
}
clear_request() { rm -f "$BOX"/*.json "$CLAIMED"/*.json 2>/dev/null; }
claim_request() { mkdir -p "$CLAIMED"; mv "$BOX/$REQUEST_ID.json" "$CLAIMED/$REQUEST_ID.json" 2>/dev/null; }
marker_up()   { . scripts/lib/deploy-signal.sh; wa_deploy_signal_write "$HOME_DIR/.wasm-agent" "aaaaaaa" "$SHA" 1800 "upgrade.sh"; }
marker_down() { . scripts/lib/deploy-signal.sh; wa_deploy_signal_clear "$HOME_DIR/.wasm-agent"; }

# ------------------------------------------------------------------------------------------------ the node
step "the node boots on 127.0.0.1:$PORT"
"$BIN" --db "$DB" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
SERVER_PID=$!
code=""
for _ in $(seq 1 120); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then
  fail "the node did not come up on $PORT"
  tail -15 "$WORK/serve.log" | sed 's/^/      /'
  echo "deploy wait: $fails failure(s)" >&2
  exit 1
fi
ok "/health answered 200"

step "1. nothing waits: a served turn runs, so the fixture itself is proved"
before="$(calls)"
turn="$(curl -sN -m 60 -X POST --data 'say something' "http://127.0.0.1:$PORT/chat" 2>&1)"
want "$turn" "stub-ok" "the stub model's answer is in the turn"
neq "$(calls)" "$before" "the model was asked"

step "2. the request arrives: a NEW served turn is refused, and costs no model call"
write_request
before="$(calls)"
turn="$(curl -sN -m 60 -X POST --data 'say something else' "http://127.0.0.1:$PORT/chat" 2>&1)"
want "$turn" "deploy_waiting" "the turn is refused by name"
want "$turn" "waiting for the install of 8082b42e1111" "and says which commit is coming"
want "$turn" "wa-sentinel request withdraw $REQUEST_ID" "and names the way out"
case "$turn" in *stub-ok*) fail "a refused turn still reached the model" ;; *) ok "the model was not called" ;; esac
same "$(calls)" "$before" "no completion was spent"

step "3. a real `wa chat --once` - the worker shape of the incident - is refused, exit 2, nothing written"
before_counts="$(counts)"
before_calls="$(calls)"
out="$("$BIN" --db "$DB" chat --once 'carry on with the load test' 2>&1)"
code=$?
if [ "$code" = "2" ]; then ok "exit 2 (refused, nothing ran)"; else fail "expected exit 2, got $code: $out"; fi
want "$out" "deploy_waiting" "the refusal is named"
want "$out" "waiting for the install of 8082b42e1111" "and names the install"
same "$(calls)" "$before_calls" "the CLI turn spent no completion"
same "$(counts)" "$before_counts" "and wrote nothing into the ledger"

step "4. a turn ALREADY RUNNING pauses at its next step, by itself"
clear_request
printf '2500' > "$WORK/delay"
DW_REQUEST="$BOX/$REQUEST_ID.json" DW_TURN_PROMPT='wake me when the deploy is done' \
  WA_SCRIPT="scripts/lib/deploy-wait-e2e.lua" DW_MODE=turn "$BIN" --db "$DB" > "$WORK/turn.log" 2>&1 &
TURN_PID=$!
sleep 0.8
write_request
wait "$TURN_PID" 2>/dev/null
TURN_RC=$?
turn="$(cat "$WORK/turn.log")"
want "$turn" "session=" "the turn ran in a session"
want "$turn" "deploy waiting: waiting for the install of 8082b42e1111" "the turn paused at its step boundary"
want "$turn" "paused after its step and scheduled a resume" "and says it scheduled its resume"
PAUSED_SESSION="$(printf '%s' "$turn" | sed -n 's/^session=//p' | tail -1)"
[ -n "$PAUSED_SESSION" ] || fail "the turn printed no session id"
if [ -s "$HOME_DIR/.wasm-agent/deploy-paused/$PAUSED_SESSION.json" ]; then
  ok "the pause is recorded where the sentinel reads it"
else
  fail "no pause record for $PAUSED_SESSION"
fi
neq "$(counts)" "$before_counts" "the pause wrote into the ledger (a checkpoint and a wake)"

step "5. the node's own tick holds the due wakes while the deploy is waiting, and while it installs"
# A wake of a session that is not paused, due now: the loop that starved the deploy on 22/11 was exactly this.
out="$(lua due)"
want "$out" "due ok" "a worker's own wake is due"
sleep 2
tick="$(lua tick)"
want "$tick" "dispatched=0" "a due wake does not run while a deploy waits"
want "$tick" "deploy_waiting=1" "and the tick says the deploy is waiting"
want "$tick" "deploy_wait_due=1" "naming the wake it held"
marker_up
if [ -s "$SIGNAL" ]; then ok "the installer's marker is up"; else fail "the marker was not written"; fi
tick="$(lua tick)"
same "$(field "$tick" dispatched)" "0" "an installing node dispatches no wake"
claim_request
if [ -s "$CLAIMED/$REQUEST_ID.json" ]; then ok "the request is claimed (the install is under way)"; else fail "the request was not claimed"; fi
tick="$(lua tick)"
same "$(field "$tick" dispatched)" "0" "a CLAIMED request holds the wakes too: the gap before the installer writes its marker"

step "6. the deploy ends: the node performs the held wakes, the resume among them, exactly once"
marker_down
clear_request
tick="$(lua tick)"
neq "$(field "$tick" dispatched)" "0" "the held wakes run once the deploy ends"
if [ "$(field "$tick" runs)" = "$(field "$tick" dispatched)" ]; then ok "each dispatch reached the scheduler"; else fail "dispatch and runs disagree: $tick"; fi
tick="$(lua tick)"
same "$(field "$tick" dispatched)" "0" "and exactly once: a second tick dispatches nothing"
same "$(field "$(lua count)" resume_wakes)" "0" "the resumed session's wake is settled, not left pending"

step "7. nothing was lost: the workers' next turn runs again, and reaches the model"
before="$(calls)"
out="$("$BIN" --db "$DB" chat --once 'carry on with the load test' 2>&1)"
code=$?
if [ "$code" = "0" ]; then ok "the CLI turn runs again by itself"; else fail "expected exit 0, got $code: $out"; fi
want "$out" "stub-ok" "and its answer is the model's (the same request the refused attempt carried)"
neq "$(calls)" "$before" "with a completion spent, as a real turn does"

if [ "$fails" -ne 0 ]; then
  echo "deploy wait: $fails failure(s)" >&2
  exit 1
fi
echo "deploy wait ok"
