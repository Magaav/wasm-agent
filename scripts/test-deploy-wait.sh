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

# THIS ROW NEVER READS ITS CALLER'S STDIN. `wa chat --once` treats a stdin that is not a terminal as a queue of
# prompts (docs/SCRIPTED-RUNS.md), so a child that inherited the caller's stdin ATE THE REST OF IT - measured
# 22/11 by scripts/test-discriminates.sh, whose row list arrives on stdin: six tests were listed and three ran,
# the other three consumed as extra prompts by this row's `wa chat --once`. One line, before anything starts a CLI.
exec </dev/null

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
# A hole this row names itself, in the ONE spelling both judges read (`SKIP ` at the start of a line):
# scripts/fast.sh collects `^SKIP ` to print it, and scripts/test-discriminates.sh records it as a named
# non-judgment instead of reading exit 0 as "it passed on the old code".
skip() { printf 'SKIP test-deploy-wait: %s\n' "$*"; exit 0; }

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  skip "no wa binary: set WA_BIN, or build rust/wa-host"
fi
case "$BIN" in /*|[A-Za-z]:*) ;; *) BIN="$ROOT/$BIN" ;; esac
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# The claim is about processes and a node, so the row needs node for its stub model: an honest skip, not a pass.
command -v node >/dev/null 2>&1 || skip "no node on this host: the stub model is a node script"
command -v curl >/dev/null 2>&1 || skip "no curl: the node is asked over HTTP"

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
mkdir -p "$HOME_DIR/.wasm-agent/components" || skip "no scratch home"
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
# Two readers for the /health samples of steps 2c and 2d: one dotted field, and the sum of the per-node-thread
# `queued` counts. Both answer an empty string for a document that does not parse - a sample that says nothing is
# never read as a zero.
pick() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v=null;try{v=JSON.parse(s)}catch{};for(const k of String(process.argv[1]||"").split(".")){v=v==null?null:(typeof v==="object"?v[k]:null)};console.log(v==null?"":(typeof v==="object"?JSON.stringify(v):String(v)))})' "$2" < "$1"; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
threads_queued() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const h=JSON.parse(s);console.log(String((h.node_threads||[]).reduce((a,t)=>a+(Number(t.queued)||0),0)))}catch{console.log("")}})' < "$1"; }

# The request must arrive while the turn is INSIDE its first model call: before that the turn has not passed its
# own gate (and would be refused by it, which is a different subject), after it the turn has already paused or
# ended. "Its first completion reached the stub" is the exact evidence, so it is waited for instead of guessed
# with a sleep (measured 23/11: 0.8 s was enough until the two queue steps above moved the fixture's start-up,
# and then this turn was refused at its gate instead of pausing at its boundary).
inside_first_call() { # <calls-before>
  local before="$1"
  for _ in $(seq 1 120); do
    [ "$(calls)" -gt "$before" ] && return 0
    sleep 0.05
  done
  return 1
}

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

step "2. the request arrives: the WINDOW'S OWN turn still runs, and an automatic served turn is refused"
write_request
# 2a. A PERSON'S TURN (review MUST 1): the window says so itself - `operator: true` in the body, which is what
# ui/app.js sends - and the node serves it while a deploy waits. Refusing it would be the node telling its own
# reader to come back later for up to the request's bound.
before="$(calls)"
turn="$(curl -sN -m 60 -X POST --data '{"text":"say something from the window","operator":true}' "http://127.0.0.1:$PORT/chat" 2>&1)"
want "$turn" "stub-ok" "the window's turn is answered while a deploy waits"
unwant "$turn" "deploy_waiting" "and is not refused"
neq "$(calls)" "$before" "the model was asked for it"

# 2b. AN AUTOMATIC SERVED TURN: a client that does not say a person is behind it is refused by name, before a
# single model call. Scheduling, not a security boundary - and the default, because the node cannot invent a
# person.
before="$(calls)"
turn="$(curl -sN -m 60 -X POST --data 'say something else' "http://127.0.0.1:$PORT/chat" 2>&1)"
want "$turn" "deploy_waiting" "the automatic turn is refused by name"
want "$turn" "waiting for the install of 8082b42e1111" "and says which commit is coming"
want "$turn" "wa-sentinel request withdraw $REQUEST_ID" "and names the way out"
case "$turn" in *stub-ok*) fail "a refused turn still reached the model" ;; *) ok "the model was not called" ;; esac
same "$(calls)" "$before" "no completion was spent"


step "2c. the node NAMES the turns it has admitted and not started (23/11)"
# ONE CONVERSATION, deliberately: a node runs conversations in parallel on their own node-threads, so a queue
# only forms behind a turn in the SAME conversation (measured on this fixture's first run: three turns of three
# conversations all ran at once and the queue stayed at 0). The incident's pile-up was one conversation's worth of
# automated turns behind another - which is what `thread` here reproduces.
THREAD="2c2c2c2c-1111-2222-3333-444455556666"
# MEASURED (~/.wasm-agent/sentinel/sentinel.log, 23/11): the deploy for e9a42d20 was held behind `10 turn(s)
# admitted and not started` - a count, and a count cannot be asked whether it paused, so the sentinel could
# neither verify it nor pass over it and the deploy waited out its bound. The queue is a real state of a real
# node (a long turn in flight), so it is produced here and read back from /health: WHO is queued, for how long,
# and on which node-thread.
clear_request
printf '2500' > "$WORK/delay"
curl -sN -m 60 -X POST --data "{\"text\":\"hold the node while the queue forms\",\"operator\":true,\"thread\":\"$THREAD\"}" \
  "http://127.0.0.1:$PORT/chat" > "$WORK/holder-2c.txt" 2>&1 &
HOLDER_PID=$!
sleep 0.2
curl -sN -m 60 -X POST --data "{\"text\":\"queued turn one\",\"thread\":\"$THREAD\"}" \
  "http://127.0.0.1:$PORT/chat" > "$WORK/queued-1.txt" 2>&1 &
Q1=$!
curl -sN -m 60 -X POST --data "{\"text\":\"queued turn two\",\"thread\":\"$THREAD\"}" \
  "http://127.0.0.1:$PORT/chat" > "$WORK/queued-2.txt" 2>&1 &
Q2=$!
queued_max=0; named_max=0; threads_mismatch=0
for _ in $(seq 1 8); do
  sleep 0.15
  curl -s -m 2 "http://127.0.0.1:$PORT/health" > "$WORK/health-2c.json" 2>/dev/null
  q="$(num "$(pick "$WORK/health-2c.json" queue)")"
  n="$(num "$(pick "$WORK/health-2c.json" queue_sessions.named)")"
  t="$(num "$(threads_queued "$WORK/health-2c.json")")"
  [ "$q" -gt "$queued_max" ] && queued_max="$q"
  [ "$n" -gt "$named_max" ] && named_max="$n"
  [ "$t" = "$q" ] || threads_mismatch=1
done
wait "$Q1" 2>/dev/null; wait "$Q2" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null
printf '0' > "$WORK/delay"
if [ "$queued_max" -ge 2 ]; then ok "the node reported $queued_max turn(s) admitted and not started"; else
  fail "the queue never formed (max $queued_max): $(cat "$WORK/health-2c.json" 2>/dev/null | cut -c1-300)"
fi
if [ "$named_max" -ge 2 ]; then ok "and NAMED $named_max of them (queue_sessions)"; else
  fail "the queue named nobody: a deploy would be told a count and no session ($(cat "$WORK/health-2c.json" 2>/dev/null | cut -c1-300))"
fi
if [ "$threads_mismatch" = "0" ]; then ok "the per-node-thread counts add up to the queue"; else
  fail "the per-node-thread queued counts and /health queue disagree"
fi

step "2d. a deploy that waits refuses a turn at the DOOR: nothing is admitted behind it (23/11)"
write_request
printf '2500' > "$WORK/delay"
# Measured BEFORE the operator's turn starts: that turn is the only one in this step that is allowed to reach the
# model, and the stub makes it two rounds (its first answer asks for a tool), so exactly two calls are its own.
before="$(calls)"
curl -sN -m 60 -X POST --data "{\"text\":\"a person keeps working while the deploy waits\",\"operator\":true,\"thread\":\"$THREAD\"}" \
  "http://127.0.0.1:$PORT/chat" > "$WORK/holder-2d.txt" 2>&1 &
HOLDER_PID=$!
sleep 0.2
DOOR_PIDS=()
for i in 1 2 3; do
  ( curl -s -o "$WORK/door-$i.body" -w '%{http_code}' -m 20 -X POST \
      --data "{\"text\":\"door turn $i\",\"thread\":\"$THREAD\"}" \
      "http://127.0.0.1:$PORT/chat" > "$WORK/door-$i.code" 2>&1 ) &
  DOOR_PIDS+=("$!")
done
door_max=0
for _ in $(seq 1 8); do
  sleep 0.15
  curl -s -m 2 "http://127.0.0.1:$PORT/health" > "$WORK/health-2d.json" 2>/dev/null
  q="$(num "$(pick "$WORK/health-2d.json" queue)")"
  [ "$q" -gt "$door_max" ] && door_max="$q"
done
# 2e. THE SAME DOOR, ASKED BY A CALLER THAT PROVED NOTHING (23/11, Fable's review 2). The refusal is answered
# before the credential is resolved, so the body is scoped to what the caller has proved: the reason, that nothing
# ran, and when to look again - never the commit, the request id or which lane of the box the request is in.
code=$(curl -s -o "$WORK/door-anon.body" -w '%{http_code}' -m 20 -X POST   -H 'x-wa-session: not-a-session'   --data "{\"text\":\"door turn anon\",\"thread\":\"$THREAD\"}"   "http://127.0.0.1:$PORT/chat" 2>/dev/null)
body="$(cat "$WORK/door-anon.body" 2>/dev/null)"
if [ "$code" = "503" ]; then ok "an unauthenticated turn is refused with 503"; else
  fail "an unauthenticated turn answered HTTP ${code:-nothing} (body: $(printf '%s' "$body" | cut -c1-200))"
fi
want "$body" '"not_started":true' "and says it did not start"
want "$body" 'deploy_waiting' "and names the refusal"
want "$body" 'retry_after_seconds' "and when to look again"
unwant "$body" '8082b42e1111' "but NOT the commit it would install"
unwant "$body" '"target"' "no target field"
unwant "$body" '"request"' "no request id"
unwant "$body" '"source"' "and no lane of the box"
# ... while the callers this node's own user makes (the three turns above, no credential header at all) get the
# full sentence: the two scopes are asserted against each other, so a later change cannot quietly give both the
# same body.
want "$(cat "$WORK/door-1.body")" '8082b42e1111' "an authenticated caller is told which install is coming"

for pid in "${DOOR_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
wait "$HOLDER_PID" 2>/dev/null
printf '0' > "$WORK/delay"
for i in 1 2 3; do
  code="$(cat "$WORK/door-$i.code" 2>/dev/null)"
  body="$(cat "$WORK/door-$i.body" 2>/dev/null)"
  if [ "$code" = "503" ]; then ok "turn $i was refused with 503"; else
    fail "turn $i answered HTTP ${code:-nothing}, not the named refusal (body: $(printf '%s' "$body" | cut -c1-200))"
  fi
  want "$body" '"not_started":true' "turn $i says it did not start"
  want "$body" 'deploy_waiting' "turn $i names the refusal"
  want "$body" 'retry_after_seconds' "and says when to look again"
  # The stub's own answer, in the body, is the proof that a turn RAN: a refusal that still reached the model
  # would be no refusal at all, and this is asserted per turn rather than on a count of completions (the
  # operator's turn in this step shares its conversation, so its own number of rounds is not a constant).
  unwant "$body" 'stub-ok' "turn $i never reached the model"
done
if [ "$door_max" = "0" ]; then ok "no turn was admitted while the deploy waited"; else
  fail "$door_max turn(s) were admitted and queued behind the waiting deploy (the pile-up this row is about)"
fi
neq "$(calls)" "$before" "the operator's turn did reach the model, so the fixture was a live node, not an idle one"

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
before="$(calls)"
DW_REQUEST="$BOX/$REQUEST_ID.json" DW_TURN_PROMPT='wake me when the deploy is done' \
  WA_SCRIPT="scripts/lib/deploy-wait-e2e.lua" DW_MODE=turn "$BIN" --db "$DB" > "$WORK/turn.log" 2>&1 &
TURN_PID=$!
inside_first_call "$before" || fail "the turn never reached its first model call"
write_request
wait "$TURN_PID" 2>/dev/null
TURN_RC=$?
turn="$(cat "$WORK/turn.log")"
want "$turn" "session=" "the turn ran in a session"
want "$turn" "deploy waiting: waiting for the install of 8082b42e1111" "the turn paused at its step boundary"
want "$turn" "paused after its step and scheduled a resume" "and says it scheduled its resume"
# A PAUSED TURN IS NOT A REFUSED ONE (orchestrator, 23/11 ~16:40Z). MEASURED that day: four workers
# (project-instructions-once, release-linux-reads-the-receipt, graph-one-store-per-root, and the mission that
# wrote this row) ended rc=2 because their turn did NOT start while a deploy waited. A turn that is ALREADY
# RUNNING is a different answer: it pauses at its own step boundary, writes its checkpoint and its one resume
# wake, and ends CLEANLY - `0`, never `2` - so the runner does not treat the pause as a refusal and the work
# continues after the swap (step 5 performs that resume). Asserted here because exit 2 is what killed them.
if [ "$TURN_RC" = "0" ]; then ok "the paused turn ended rc=0, not a refusal"
else fail "a turn that paused for the deploy ended rc=$TURN_RC: it must end cleanly, never as a refusal"; fi
PAUSED_SESSION="$(printf '%s' "$turn" | sed -n 's/^session=//p' | tail -1)"
[ -n "$PAUSED_SESSION" ] || fail "the turn printed no session id"
if [ -s "$HOME_DIR/.wasm-agent/deploy-paused/$PAUSED_SESSION.json" ]; then
  ok "the pause is recorded where the sentinel reads it"
else
  fail "no pause record for $PAUSED_SESSION"
fi
neq "$(counts)" "$before_counts" "the pause wrote into the ledger (a checkpoint and a wake)"

step "4b. an operator's served turn IN FLIGHT is not cut by a merely WAITING request"
# Review MUST 2: the request needs the node to stop STARTING turns, not to end the turn a person is in the
# middle of - that would cut their multi-step work after every step for as long as the wait lasts. So this turn
# starts with no request, the request arrives while its first model call is in flight, and it must still reach
# its own answer.
clear_request
paused_records() { ls -1 "$HOME_DIR/.wasm-agent/deploy-paused/"*.json 2>/dev/null | wc -l | tr -d ' '; }
before_paused="$(paused_records)"
printf '2500' > "$WORK/delay"
before="$(calls)"
curl -sN -m 60 -X POST --data '{"text":"wake me and keep going","operator":true}' \
  "http://127.0.0.1:$PORT/chat" > "$WORK/operator-stream.txt" 2>&1 &
OPERATOR_PID=$!
inside_first_call "$before" || fail "the operator's turn never reached its first model call"
write_request
wait "$OPERATOR_PID" 2>/dev/null
operator_turn="$(cat "$WORK/operator-stream.txt")"
want "$operator_turn" "stub-ok" "the operator's turn reached its own answer while the request waited"
unwant "$operator_turn" "deploy waiting" "and was not paused or cut by the waiting request"
unwant "$operator_turn" "deploy_waiting" "nor refused"
neq "$(calls)" "$before" "it went on to the model, as a turn that keeps working does"
same "$(paused_records)" "$before_paused" "and it recorded no pause, so the sentinel names it working, not paused"

step "5. the node's own tick holds the due wakes while the deploy is waiting, and while it installs"
# A wake of a session that is not paused, due now: the loop that starved the deploy on 22/11 was exactly this.
out="$(lua due)"
want "$out" "due ok" "a worker's own wake is due"
sleep 2
tick="$(lua tick)"
want "$tick" "dispatched=0" "a due wake does not run while a deploy waits"
want "$tick" "deploy_waiting=1" "and the tick says the deploy is waiting"
# ONE OR MORE, not exactly one: the operator's in-flight turn of step 4b scheduled a wake of its own through the
# stub's tool call, and it is due too - counting it as an oddity would make this row fail for the right reason
# in the wrong place.
held_due="$(field "$tick" deploy_wait_due)"
if [ "${held_due:-0}" -ge 1 ]; then ok "naming the $held_due due wake(s) it held"; else fail "the tick named no due wake: $tick"; fi
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

step "7b. a pause whose RESUME WAS LOST is re-armed and resumed: three session kinds, both endings"
# THE G BLOCKER (Fable, 23/11 ~22:00Z). MEASURED on this laptop: session 603425eb paused at 19:29:43Z and sat TWO
# HOURS, and 66c0d5c1 paused at 20:19:38Z and sat the same - each had scheduled its resume, the request it paused
# for reached the sentinel's `done/`, and `wa session status` then answered `0 wakes pending`: the resume row was
# cut by the very install it paused for and left `unknown` (never replayed). Nothing but the factory's watchdog
# brought those sessions back, and a fleet node or a person's own chat has no watchdog, which is why G cannot
# roll without this. The three kinds differ only in who owns the process (a served chat, a `wa chat --once`
# worker, a self-wake); the pause record and the resume row are the same for all three, so one guarantee covers
# them - and it is asserted for each, under BOTH endings: the install finished, and the request was withdrawn.
for ending in install withdraw; do
  for kind in served worker selfwake; do
    clear_request; marker_down 2>/dev/null || true
    out="$(DW_KIND="$kind" DW_COUNT=1 lua pause-lost)"
    session="$(printf '%s' "$out" | sed -n 's/^sessions=//p' | cut -d, -f1)"
    if [ -n "$session" ]; then ok "$kind/$ending: a paused session whose resume row is unknown";
    else fail "$kind/$ending: the fixture wrote no paused session: $out"; fi
    write_request
    [ "$ending" = "install" ] && marker_up
    tick="$(lua tick)"
    same "$(field "$tick" dispatched)" "0" "$kind/$ending: nothing runs while the deploy waits"
    same "$(field "$tick" rearmed)" "0" "$kind/$ending: and nothing is re-armed while it waits"
    [ "$ending" = "install" ] && marker_down
    clear_request
    tick="$(lua tick)"
    same "$(field "$tick" rearmed)" "1" "$kind/$ending: the lost resume is re-armed by the NODE, with no watchdog"
    # The re-armed row is scheduled one second out (`selfloop.schedule` never arms a past time), so the tick that
    # re-arms it RELEASES it and the next one dispatches it: measured `rearmed=1 dispatched=0`, then
    # `dispatched=1 released=1`. The guarantee is the resume, not which tick of the 200 ms loop performs it.
    [ "$(field "$tick" dispatched)" = "0" ] && tick="$(lua tick)"
    neq "$(field "$tick" dispatched)" "0" "$kind/$ending: and the resumed turn is dispatched"
    tick2="$(lua tick)"
    same "$(field "$tick2" rearmed)" "0" "$kind/$ending: once, not once per tick"
  done
done
marker_down 2>/dev/null || true
clear_request

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
