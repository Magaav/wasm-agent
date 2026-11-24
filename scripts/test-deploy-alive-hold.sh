#!/usr/bin/env bash
# AN INSTALL HOLDS A SESSION ONCE, FROM ITS FIRST PAUSE UNTIL THE NODE IS BACK (r8c G blocker, Fable 24/11).
#
# MEASURED on this node (24/11 21:15-21:27Z, ~/.wasm-agent/sentinel/deploy.out): the sentinel claimed the request for
# 39e862d6 and started scripts/deploy.sh DETACHED, moving the request to done/ 8 s after the claim. deploy.sh fetched
# and COMPILED for 430 s; the deploy-pending marker (scripts/upgrade.sh, after the build) was written only then. In
# between no request, no claimed request and no marker said an install was coming, so release_due released, the
# resumed sessions found installed.txt unchanged and were told "[deploy] the update did not happen", and the marker
# then paused them again for a second release: two sessions paid two turns each for one install.
#
# This row reproduces that timeline on a real scratch node - a deploy that claims and is moved to done/ at once, then
# COMPILES WITH NO MARKER for 60 s, then swaps - with the deploy's own running state (scripts/lib/deploy-alive.sh)
# written by the deploy process itself, and counts every model request at the loopback stub:
#
#   (1) a Rust-like install, 60 s compile, three sessions mid-turn: ONE resume each, first line
#       "[deploy] installed: ...", ZERO deliveries between the pause and the release;
#   (2) the same install KILLED during the compile: ONE resume each, "[deploy] the update did not happen";
#   (3) a scripts-only install (no compile at all): still ONE resume (no regression);
#   (4) two requests back to back: the second does not release the first's hold early.
#
# Fences: HOME and WASM_AGENT_HOME are the scratch dir (the marker, the running state, the ledger and installed.txt are
# all written THERE), the vault and provider variables are cleared, only this row's port is bound, and the only pids
# signalled are the ones it started.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "deploy-alive-hold: SKIP (no wa binary: set WA_BIN)" >&2; exit 0; }
command -v node >/dev/null 2>&1 || { echo "deploy-alive-hold: SKIP (node is not on PATH)" >&2; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { echo "deploy-alive-hold: SKIP (sqlite3 is not on PATH, so the ledger cannot be read back)" >&2; exit 0; }

PORT="${1:-$((9100 + RANDOM % 200))}"
[ "$PORT" = "8799" ] && PORT=9123
CP=$((PORT + 1)); MP=$((PORT + 2))
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-alive-XXXXXX")" || WORK=""
# A fixture that could not be created must stop the row, not fill $HOME with its files (measured on this row's
# first run: an empty WORK turned every path into /model.mjs and /home/.wasm-agent).
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "deploy-alive-hold: FAIL no scratch directory (TMPDIR=${TMPDIR:-unset})" >&2; exit 1; }
SERVER=""; MODEL=""; DEPLOY=""
cleanup() {
  local status=$?
  for pid in "$DEPLOY" "$SERVER" "$MODEL"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  [ "$status" != "0" ] && echo "  fixture kept at $WORK" >&2
  [ "$status" = "0" ] && rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/home/.wasm-agent/components"
DATA="$WORK/home/.wasm-agent"
INSTALL="$WORK/home/.local/bin"
MARKER="$DATA/deploy-pending.json"
ALIVE="$DATA/deploy-alive.json"
BOX="$DATA/sentinel/requests"
CLAIMED="$DATA/sentinel/claimed"
DONE="$DATA/sentinel/done"
mkdir -p "$BOX" "$CLAIMED" "$DONE" "$INSTALL"
LEDGER="file:$DATA/memory.db?mode=ro"
ledger() { sqlite3 "$LEDGER" "$1" 2>/dev/null; }
requests() { wc -l < "$COUNT" | tr -d ' '; }

# ---------------------------------------------------------------------------------------- the loopback model
# Every request is counted. The answer keeps each turn going for a SECOND round (a bash tool that sleeps 3 s), because
# a turn pauses at a step boundary and round 1 has none: with a tool result as the last message the turn is answered
# and ends. That is what makes a pause observable as "one request, then no more".
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
    // A RESUME TURN IS ANSWERED IN ONE ROUND, so its cost is exactly one request: the first thing it reads is the
    // release's own line, which starts '[deploy'. Every other turn gets a tool call, so it reaches a step boundary
    // where a waiting build can pause it.
    let lastRole = '', lastText = '';
    try {
      const parsed = JSON.parse(body);
      const messages = parsed.messages || [];
      const last = messages[messages.length - 1] || {};
      lastRole = last.role || '';
      // A content may be a string or a list of parts (the client's own shape): read the text out of both.
      if (typeof last.content === 'string') lastText = last.content;
      else if (Array.isArray(last.content)) lastText = last.content.map((part) => (part && part.text) || '').join(' ');

    } catch {}
    // A WAKE'S TURN IS THE RESUME, and its words are the wake's own: the row's prompt, whose first line is the
    // release's '[deploy] ...' (a wake turn reads '[self-wake · <reason>]\n<the row's prompt>').
    const resume = /^\[self-wake/.test(lastText.trim()) || lastText.includes('[deploy] ');
    // THE RESUMED PROMPT ITSELF IS RECORDED (Fable 24/11, row (iii)): the release line is counted in the BYTES the
    // stub was sent, not only in the ledger, so a second copy prepended by a later tick would show up here.
    if (resume) appendFileSync(process.argv[4], lastText + '\n');
    const head = { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' };
    const send = (payload) => response.write('data: ' + JSON.stringify(payload) + '\n\n');
    response.writeHead(200, head);
    if (lastRole !== 'tool' && !resume) {
      send({ id: 'stub', object: 'chat.completion.chunk', model: 'stub-model',
        choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'call_1', type: 'function',
          function: { name: 'bash', arguments: JSON.stringify({ command: 'sleep 3' }) } }] }, finish_reason: null }],
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
RESUMED="$WORK/resumed-prompts.txt"; : > "$RESUMED"
node "$WORK/model.mjs" "$MP" "$COUNT" "$RESUMED" > "$WORK/model.log" 2>&1 & MODEL=$!
for _ in $(seq 1 60); do grep -q listening "$WORK/model.log" 2>/dev/null && break; sleep 0.1; done
wait_requests() { # <n> <seconds>
  local want=$1 budget=$2
  for _ in $(seq 1 "$((budget * 10))"); do [ "$(requests)" -ge "$want" ] && return 0; sleep 0.1; done
  return 1
}

# ---------------------------------------------------------------------------------------- the stub deploy
# The REAL timeline, in the real scripts' own functions: the deploy states that it is running with the product's own
# writer (scripts/lib/deploy-alive.sh), compiles (a sleep - the thing that took 430 s), THEN writes the installer's
# marker with the product's own writer (scripts/lib/deploy-signal.sh), swaps installed.txt, and clears both on the way
# out. A row cannot compile this tree; this is the deploy's ORDER and its files, not a compile.
cat > "$WORK/deploy.sh" <<'JS'
#!/usr/bin/env bash
set -uo pipefail
ROOT=$1; DATA=$2; COMMIT=$3; COMPILE=$4; TREE=$5; INSTALL=$6
. "$ROOT/scripts/lib/deploy-alive.sh"
. "$ROOT/scripts/lib/deploy-signal.sh"
wa_deploy_alive_write "$DATA" 1800 "$COMMIT" "stub deploy" || exit 1
trap 'wa_deploy_alive_clear "$DATA"' EXIT
sleep "$COMPILE"
wa_deploy_signal_write "$DATA" "old-tree" "$COMMIT" 1800 "stub upgrade" || exit 1
sleep 4   # the installer waits for the node to go idle before the swap (upgrade.sh does)
printf 'commit=%s\nlua_tree=%s\nat=%s\n' "$COMMIT" "$TREE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL/installed.txt"
sleep 3
wa_deploy_signal_clear "$DATA"
sleep 1
JS
chmod +x "$WORK/deploy.sh"

record() { # <commit> <tree> - the shape scripts/deploy.sh:1975 writes
  printf 'commit=%s\nlua_tree=%s\nlua_fast_path=1\nat=%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL/installed.txt"
}
request() { # <id> <commit>
  printf '{"verb":"deploy","target_commit":"%s","queued_at":%s,"reason":"r8c: the install this row is about"}\n' \
    "$2" "$(date +%s)" > "$BOX/$1.json"
}
# THE SENTINEL'S OWN MOVES: a request is renamed into claimed/ before it is performed, and this sentinel starts the
# deploy DETACHED and moves the request to done/ within seconds (8 s measured).
claim() { mv "$BOX/$1.json" "$CLAIMED/$1.json" 2>/dev/null; }
finish() { mv "$CLAIMED/$1.json" "$DONE/$1.json" 2>/dev/null; }
start_deploy() { # <commit> <compile-seconds> <tree>
  "$WORK/deploy.sh" "$ROOT" "$DATA" "$1" "$2" "$3" "$INSTALL" >> "$WORK/deploy.log" 2>&1 & DEPLOY=$!
}
start_turn() { # <thread> - the turn is IN FLIGHT: its first answer asks for a 3 s tool
  ( curl -sN -m 120 -X POST --data "{\"text\":\"finish the install-aware request\",\"thread\":\"$1\"}" \
      "http://127.0.0.1:$PORT/chat" > "$WORK/turn-$1.txt" 2>&1 ) & TURNS="$TURNS $!"
}
wait_turns() { for pid in $TURNS; do wait "$pid" 2>/dev/null; done; TURNS=""; }
paused() { grep -q "deploy pending\|deploy waiting\|paused after" "$WORK/turn-$1.txt"; }
resumes_of() { ledger "SELECT prompt FROM self_wakes WHERE session_id=(SELECT session_id FROM messages WHERE content LIKE '%install-aware request%' LIMIT 1) AND reason='deploy pending: resume after the node swap' ORDER BY created_at;" | wc -l | tr -d ' '; }
rows_for() { # <thread> -> the resume rows of the session that thread created
  ledger "SELECT id, status, substr(replace(prompt,char(10),' '),1,60) FROM self_wakes WHERE reason='deploy pending: resume after the node swap' ORDER BY created_at;"
}

# ---------------------------------------------------------------------------------------- the scratch node
export HOME="$WORK/home" WASM_AGENT_HOME="$WORK/home" WASM_AGENT_LUA_ROOT="$ROOT"
unset WA_INSTALL_DIR
export WA_COMPONENTS_DIR="$WORK/home/.wasm-agent/components"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WASM_AGENT_PROVIDER=opencode-go WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MP/v1"
export WASM_AGENT_LLM_API_KEY=stub-key-not-a-secret WASM_AGENT_LLM_MODEL=stub-model
unset WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL OPENAI_API_KEY OPENCODE_GO_API_KEY

record 1111222233334444 1111222233334444
"$BIN" --db "$DATA/memory.db" serve --port "$PORT" --client-port "$CP" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 & SERVER=$!
code=""
for _ in $(seq 1 160); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { echo "  FAIL: the scratch node did not come up on $PORT"; tail -12 "$WORK/serve.log"; exit 1; }
echo "deploy-alive-hold (node on $PORT, home $WORK/home)"
TURNS=""

# ===================================================================================== (1) a Rust-like install
# Three sessions mid-turn, the request CLAIMED and moved to done/ at once (the sentinel detaches), a 60 s compile with
# NO marker, then the marker and the swap. Every session: ONE pause request, ONE resume request, nothing in between.
T0_COUNT=$(requests)
for thread in alive-a1 alive-a2 alive-a3; do start_turn "$thread"; done
wait_requests "$((T0_COUNT + 3))" 60 || { echo "  FAIL: the three turns never reached the model"; exit 1; }
request req-a bbbb5555eeee6666
# THE INCIDENT'S OWN FIRST PAUSE: the request WAITS for a moment before the sentinel claims it, and the sessions
# reach their step boundary in that window and pause for it. (Claiming it first would let the pause happen only
# because the fix's running state exists - which is not the sequence 21:15Z recorded.)
sleep 4
claim req-a
start_deploy bbbb5555eeee6666 60 bbbb5555eeee6666
finish req-a
wait_turns
for thread in alive-a1 alive-a2 alive-a3; do paused "$thread" || { echo "  FAIL: $thread did not pause for the claimed request"; tail -2 "$WORK/turn-$thread.txt"; exit 1; }; done
paused_count=$(requests)
[ "$paused_count" = "$((T0_COUNT + 3))" ] || { echo "  FAIL: the pauses spent $((paused_count - T0_COUNT)) requests, expected 3 (one round each)"; exit 1; }
echo "  ok: three sessions paused for the claimed request (3 model requests, one round each)"

# THE HOLE: no request, no claimed request, no marker - only the deploy's own running state. The node's tick runs
# every 2 s, so 30 s of it is 15 ticks.
sleep 30
mid_count=$(requests)
[ "$mid_count" = "$paused_count" ] || { echo "  FAIL: $((mid_count - paused_count)) model request(s) were spent while the deploy compiled with no marker (the hole)"; ledger "SELECT id, status, substr(prompt,1,60) FROM self_wakes;"; exit 1; }
[ -f "$ALIVE" ] || { echo "  FAIL: the deploy's running state is not there while it compiles"; exit 1; }
[ ! -f "$MARKER" ] || { echo "  FAIL: the marker exists during the compile; the hole this row is about is not being reproduced"; exit 1; }
[ -z "$(ls -A "$BOX" 2>/dev/null)" ] && [ -z "$(ls -A "$CLAIMED" 2>/dev/null)" ] || { echo "  FAIL: a request file is still in the box during the compile"; exit 1; }
echo "  ok: 30 s of the compile spent ZERO model requests with no request, no claimed request and no marker"

just_before=$(requests)
wait_requests "$((just_before + 3))" 60 || { echo "  FAIL: the release never resumed the three sessions"; tail -6 "$WORK/serve.log"; ledger "SELECT id, status FROM self_wakes;"; exit 1; }
sleep 4
final_count=$(requests)
[ "$final_count" = "$((T0_COUNT + 6))" ] || { echo "  FAIL: $((final_count - T0_COUNT)) requests in total, expected 6 (3 pauses + exactly ONE resume each)"; exit 1; }
echo "  ok: exactly ONE resume turn per session (3 pauses + 3 resumes = 6 requests, no delivery in between)"
LINE1=$(ledger "SELECT prompt FROM self_wakes WHERE reason='deploy pending: resume after the node swap' ORDER BY created_at LIMIT 1;")
case "$LINE1" in
  "[deploy] installed"*) : ;;
  *) echo "  FAIL: the first line of the resumed turn is not '[deploy] installed': $(printf '%s' "$LINE1" | head -c 120)"; exit 1 ;;
esac
case "$LINE1" in
  *bbbb5555eeee*) : ;;
  *) echo "  FAIL: the installed line does not name the tree the install put there: $LINE1"; exit 1 ;;
esac
RESUMES=$(ledger "SELECT COUNT(*) FROM self_wakes WHERE reason='deploy pending: resume after the node swap';")
[ "${RESUMES:-0}" = "3" ] || { echo "  FAIL: the ledger has $RESUMES resume rows, expected 3 (one per paused session, none armed twice)"; exit 1; }
echo "  ok: the first line is '[deploy] installed', naming bbbb5555eeee; three sessions, three resume rows"
# ONE LINE PER RESUME, COUNTED IN THE BYTES THE MODEL WAS SENT and in the row that produced them.
AT_STUB=$(grep -o '\[deploy\] installed' "$RESUMED" 2>/dev/null | wc -l | tr -d ' ')
[ "${AT_STUB:-0}" = "3" ] || { echo "  FAIL: the stub was sent $AT_STUB '[deploy] installed' line(s) for three resumed requests, expected 3"; exit 1; }
TWICE=$(ledger "SELECT COUNT(*) FROM self_wakes WHERE reason='deploy pending: resume after the node swap' AND (length(prompt)-length(replace(prompt,'[deploy] installed',''))) > length('[deploy] installed');")
[ "${TWICE:-x}" = "0" ] || { echo "  FAIL: $TWICE resume row(s) carry the release line more than once"; exit 1; }
echo "  ok: each resumed request carries ONE '[deploy] installed' line (counted at the stub and in the ledger)"

# ===================================================================================== (2) the deploy is KILLED
# Same timeline, and the deploy dies during the compile: the running state's pid is gone, so the NEXT tick releases,
# with the did-not-happen line (nothing was installed).
BEFORE=$(requests)
record 1111222233334444 1111222233334444
start_turn killed-b1
wait_requests "$((BEFORE + 1))" 60 || { echo "  FAIL: the killed-case turn never reached the model"; exit 1; }
request req-b cccc7777dddd8888
# THE INCIDENT'S OWN FIRST PAUSE: the request WAITS for a moment before the sentinel claims it, and the sessions
# reach their step boundary in that window and pause for it. (Claiming it first would let the pause happen only
# because the fix's running state exists - which is not the sequence 21:15Z recorded.)
sleep 4
claim req-b
start_deploy cccc7777dddd8888 60 cccc7777dddd8888
finish req-b
wait_turns
paused "killed-b1" || { echo "  FAIL: the session did not pause for the killed case"; tail -2 "$WORK/turn-killed-b1.txt"; exit 1; }
sleep 5
kill -9 "$DEPLOY" 2>/dev/null; DEPLOY=""
killed_at=$(date +%s)
wait_requests "$((BEFORE + 2))" 40 || { echo "  FAIL: a killed deploy never released the session"; ledger "SELECT id, status FROM self_wakes;"; exit 1; }
released_in=$(( $(date +%s) - killed_at ))
[ "$released_in" -le 30 ] || { echo "  FAIL: the release came ${released_in}s after the kill, expected within 30 s"; exit 1; }
sleep 3
killed_total=$(requests)
[ "$killed_total" = "$((BEFORE + 2))" ] || { echo "  FAIL: the killed case spent $((killed_total - BEFORE)) requests, expected 2 (one pause + one resume)"; exit 1; }
LINE2=$(ledger "SELECT prompt FROM self_wakes WHERE reason='deploy pending: resume after the node swap' ORDER BY created_at DESC LIMIT 1;")
case "$LINE2" in
  *"[deploy] the update did not happen"*) : ;;
  *) echo "  FAIL: after a killed deploy the line is not 'the update did not happen': $(printf '%s' "$LINE2" | head -c 140)"; exit 1 ;;
esac
echo "  ok: a deploy killed mid-compile released the session in ${released_in}s, ONE resume, '[deploy] the update did not happen'"

# ===================================================================================== (3) scripts-only install
# No compile at all: the marker and the swap happen at once. Still ONE resume (the running state costs nothing here).
BEFORE=$(requests)
record 1111222233334444 1111222233334444
start_turn scripts-c1
wait_requests "$((BEFORE + 1))" 60 || { echo "  FAIL: the scripts-only turn never reached the model"; exit 1; }
request req-c eeee9999aaaa0000
# THE INCIDENT'S OWN FIRST PAUSE: the request WAITS for a moment before the sentinel claims it, and the sessions
# reach their step boundary in that window and pause for it. (Claiming it first would let the pause happen only
# because the fix's running state exists - which is not the sequence 21:15Z recorded.)
sleep 4
claim req-c
start_deploy eeee9999aaaa0000 0 eeee9999aaaa0000
finish req-c
wait_turns
paused "scripts-c1" || { echo "  FAIL: the session did not pause for the scripts-only install"; exit 1; }
wait_requests "$((BEFORE + 2))" 60 || { echo "  FAIL: the scripts-only install never resumed the session"; exit 1; }
sleep 3
scripts_total=$(requests)
[ "$scripts_total" = "$((BEFORE + 2))" ] || { echo "  FAIL: the scripts-only case spent $((scripts_total - BEFORE)) requests, expected 2"; exit 1; }
LINE3=$(ledger "SELECT prompt FROM self_wakes WHERE reason='deploy pending: resume after the node swap' ORDER BY created_at DESC LIMIT 1;")
case "$LINE3" in
  "[deploy] installed"*) : ;;
  *) echo "  FAIL: the scripts-only install did not say 'installed': $(printf '%s' "$LINE3" | head -c 120)"; exit 1 ;;
esac
echo "  ok: a scripts-only install is still ONE resume, '[deploy] installed' (no regression)"

# ===================================================================================== (4) two requests back to back
# The second request's whole life (queued, claimed, moved to done/ by the sentinel) happens while the FIRST deploy is
# still compiling. The second must not release the first's hold early: the session gets ONE resume, at the END.
BEFORE=$(requests)
record 1111222233334444 1111222233334444
start_turn back-to-back-d1
wait_requests "$((BEFORE + 1))" 60 || { echo "  FAIL: the back-to-back turn never reached the model"; exit 1; }
request req-d1 1234123412341234
# THE INCIDENT'S OWN FIRST PAUSE: the request WAITS for a moment before the sentinel claims it, and the sessions
# reach their step boundary in that window and pause for it. (Claiming it first would let the pause happen only
# because the fix's running state exists - which is not the sequence 21:15Z recorded.)
sleep 4
claim req-d1
start_deploy 1234123412341234 30 1234123412341234
finish req-d1
wait_turns
paused "back-to-back-d1" || { echo "  FAIL: the session did not pause for the first request"; exit 1; }
# the second request arrives and lives its whole 8 s sentinel life inside the first deploy's compile
request req-d2 5678567856785678
sleep 2
claim req-d2
sleep 2
finish req-d2
hold_count=$(requests)
[ "$hold_count" = "$((BEFORE + 1))" ] || { echo "  FAIL: the second request's cycle released the first's hold ($((hold_count - BEFORE - 1)) early request(s))"; exit 1; }
wait_requests "$((BEFORE + 2))" 90 || { echo "  FAIL: the first deploy's end never resumed the session"; exit 1; }
sleep 3
back_total=$(requests)
[ "$back_total" = "$((BEFORE + 2))" ] || { echo "  FAIL: back-to-back requests spent $((back_total - BEFORE)) requests, expected 2"; exit 1; }
echo "  ok: a second request's cycle inside the first deploy's compile released nothing; ONE resume at the end"

echo "deploy-alive-hold ok: one install holds a session once (compile, kill, scripts-only, back-to-back), every resume counted at the stub"

