#!/usr/bin/env bash
# Does the node answer its own UI while a turn is streaming?
#
#   bash scripts/test-serve-concurrency.sh [port]
#
# The failure this exists for: the UI and the agent share one process and one
# thread, so while a turn is in flight the node answers nothing else - not
# /health, not app.js. The window's fetches pile up, Chromium gives up, and the
# user sees "TypeError: Failed to fetch" from a node that is local and alive. A
# reload cannot help either, because the reload needs the same blocked server.
#
# So: start a turn that takes a while, and hammer /health and a static asset while
# it runs. Both must keep answering.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
PORT="${1:-8891}"
CLIENT_PORT=$((PORT + 1))
WORK="$(mktemp -d /tmp/wa-conc-XXXXXX)"
trap 'kill "${SERVER:-}" "${WEDGE:-}" "${POOL:-}" "${TURNS:-}" "${MOCK_PID:-}" 2>/dev/null; rm -rf "$WORK"' EXIT

if [ ! -x "$BIN" ]; then echo "no binary at $BIN" >&2; exit 1; fi

"$BIN" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
SERVER=$!

for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then echo "  server did not come up (see $WORK/serve.log)" >&2; exit 1; fi

# WEDGE_ONLY=1 skips the model half. The suite runs it that way: the wedge check needs
# no model, no provider and no network, so it has no business behind one.
if [ "${WEDGE_ONLY:-0}" != "1" ]; then
# A turn with several rounds, so it runs for a while.
(
  curl -sN -m 180 -X POST \
    --data "Find the caching parameters in lua/core/provider.lua, the retry loop in lua/core/nodes.lua, the tool budget in lua/core/agent.lua and the session states in lua/core/memory.lua. Then summarise each in one line." \
    "http://127.0.0.1:$PORT/chat" > "$WORK/turn.txt" 2>&1
) &
TURN=$!

sleep 2
ok=0
fail=0
probes=0
while kill -0 "$TURN" 2>/dev/null; do
  probes=$((probes + 1))
  health_code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  asset_code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/app.js" 2>/dev/null)"
  if [ "$health_code" = "200" ] && [ "$asset_code" = "200" ]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    printf '  probe %d: health=%s app.js=%s\n' "$probes" "${health_code:-none}" "${asset_code:-none}"
  fi
  sleep 1
done
wait "$TURN" 2>/dev/null

turn_bytes="$(wc -c < "$WORK/turn.txt" | tr -d ' ')"
echo
echo "  probes while the turn streamed: $probes   answered: $ok   blocked: $fail"
echo "  turn streamed $turn_bytes bytes"
if [ "$probes" -eq 0 ]; then echo "  the turn finished before a single probe: test inconclusive"; exit 1; fi
if [ "$fail" -gt 0 ]; then
  echo "  FAIL: the node stopped answering its own UI while a turn was running"
  exit 1
fi
echo "  ok: the node served its UI throughout a running turn"
fi

kill "$SERVER" 2>/dev/null
wait "$SERVER" 2>/dev/null

# ---------------------------------------------------------------------------
# The other half of the same design, and why /health cannot be trusted alone: the
# accept thread answers /health WITHOUT the interpreter, so a node whose Lua worker is
# stuck reports healthy forever while every endpoint that needs Lua hangs with zero
# bytes. Not hypothetical - a run found a node wedged for nine hours, with the
# write-ahead log's last write as the timestamp proving when it stopped.
#
# So: stall the worker on purpose, shrink the threshold to a second, and require the
# node to say so instead of going quiet.
WEDGE_PORT=$((PORT + 10))
WEDGE_CLIENT=$((WEDGE_PORT + 1))
WASM_AGENT_TEST_STALL_WORKER=1 \
WASM_AGENT_WORKER_STALL_SECONDS=1 \
WASM_AGENT_WORKER_STALL_EXIT_SECONDS=0 \
  "$BIN" serve --port "$WEDGE_PORT" --client-port "$WEDGE_CLIENT" --ui "$ROOT/ui" > "$WORK/wedge.log" 2>&1 &
WEDGE=$!

for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$WEDGE_PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then echo "  FAIL: the wedge-test server did not come up"; exit 1; fi

# Stall it: any request that needs the interpreter trips the hook.
curl -s -o /dev/null -m 3 "http://127.0.0.1:$WEDGE_PORT/sessions" 2>/dev/null
sleep 2

health="$(curl -s -m 3 "http://127.0.0.1:$WEDGE_PORT/health" 2>/dev/null)"
code="$(curl -s -m 5 -o "$WORK/stalled.json" -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$WEDGE_PORT/diff" 2>/dev/null)"
body="$(cat "$WORK/stalled.json" 2>/dev/null)"
kill "$WEDGE" 2>/dev/null

echo
echo "  wedged node: /health -> $health"
echo "  wedged node: a write that needs worker 0 -> $code $body"
case "$health" in
  *'"ok":false'*'"worker":"stalled"'*) echo "  ok: /health admits the worker is stalled" ;;
  *) echo "  FAIL: /health kept claiming the node was fine"; exit 1 ;;
esac
case "$code:$body" in
  503:*worker_stalled*) echo "  ok: a blocked request is refused with a reason, not left hanging" ;;
  *) echo "  FAIL: expected 503 worker_stalled, got $code $body"; exit 1 ;;
esac
echo "  ok: a stalled worker is visible, and survivable"

# ---------------------------------------------------------------------------
# The pool, hot-swappable: a read must not wait for a turn, and the interpreter that made that possible
# must not stay behind once the load is gone.
#
# No warm read workers are asked for (the default), so the worker that answers the read below does not exist
# until the read needs it. That is the whole design: an idle node runs one interpreter, and a node under load
# grows to meet the load and shrinks back.
POOL_PORT=$((PORT + 20))
POOL_CLIENT=$((POOL_PORT + 1))
WASM_AGENT_TEST_STALL_WORKER=1 \
WASM_AGENT_WORKER_STALL_SECONDS=1 \
WASM_AGENT_WORKER_STALL_EXIT_SECONDS=0 \
WASM_AGENT_WORKERS_IDLE_SECONDS=2 \
  "$BIN" serve --port "$POOL_PORT" --client-port "$POOL_CLIENT" --ui "$ROOT/ui" > "$WORK/pool.log" 2>&1 &
POOL=$!

for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$POOL_PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then echo "  FAIL: the pool server did not come up (see $WORK/pool.log)"; exit 1; fi

# Trip the hook on worker 0 with a request that is not a read. /diff is a write route, and an unknown turn
# makes it do nothing - which is all this needs, because the hook stalls before the route runs.
curl -s -o /dev/null -m 3 -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$POOL_PORT/diff" 2>/dev/null
sleep 2

before_health="$(curl -s -m 3 "http://127.0.0.1:$POOL_PORT/health" 2>/dev/null)"
read_code="$(curl -s -m 5 -o "$WORK/pool-read.json" -w '%{http_code}' "http://127.0.0.1:$POOL_PORT/sessions" 2>/dev/null)"
write_code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$POOL_PORT/diff" 2>/dev/null)"
grown_health="$(curl -s -m 3 "http://127.0.0.1:$POOL_PORT/health" 2>/dev/null)"
# Now leave it alone: the worker that answered that read has nothing to do, and must go away again.
sleep 6
shrunk_health="$(curl -s -m 3 "http://127.0.0.1:$POOL_PORT/health" 2>/dev/null)"
kill "$POOL" 2>/dev/null

echo
echo "  pool: before any read -> $before_health"
echo "  pool: read /sessions while worker 0 is stalled -> $read_code"
echo "  pool: write /diff, which needs worker 0 -> $write_code"
echo "  pool: after the read -> $grown_health"
echo "  pool: after 6s idle -> $shrunk_health"
case "$before_health" in
  *'"workers_count":1'*) echo "  ok: an idle node runs one interpreter, as it always did" ;;
  *) echo "  FAIL: the pool existed before it was needed"; exit 1 ;;
esac
case "$read_code" in
  200) echo "  ok: a read is answered while a turn holds worker 0" ;;
  *) echo "  FAIL: the read queued behind the turn (got ${read_code:-none})"; exit 1 ;;
esac
case "$write_code" in
  503) echo "  ok: a request that needs the stalled worker is refused, not left hanging" ;;
  *) echo "  FAIL: expected 503 for the stalled worker, got ${write_code:-none}"; exit 1 ;;
esac
case "$grown_health" in
  *'"workers_count":2'*'"workers_spawned":1'*|*'"workers_spawned":1'*'"workers_count":2'*)
    echo "  ok: the read worker was created on demand, and /health says so" ;;
  *) echo "  FAIL: expected a second interpreter, spawned once, got: $grown_health"; exit 1 ;;
esac
case "$shrunk_health" in
  *'"workers_count":1'*) echo "  ok: the idle read worker retired itself" ;;
  *) echo "  FAIL: the pool did not shrink back, got: $shrunk_health"; exit 1 ;;
esac
case "$shrunk_health" in
  *'"workers_retired":1'*) echo "  ok: and the retirement is visible, not silent" ;;
  *) echo "  FAIL: the retirement was not reported, got: $shrunk_health"; exit 1 ;;
esac
echo "  ok: the pool grows on demand and shrinks when the load is gone"


# ---------------------------------------------------------------------------
# Concurrent turns, routed by session.
#
# The pool protected reads first. Turns stayed on worker 0, which is what made "one writer per session" true
# without a lock - and also meant two conversations could not run at once. A turn is now routed by session:
# the same session goes to the worker already running it (so its turns stay ordered and it keeps one writer),
# and a session nobody is running goes to an idle worker or gets one. Two conversations at once, and never
# two writers on one conversation.
TURN_PORT=$((PORT + 30))
TURN_CLIENT=$((TURN_PORT + 1))
MOCK_PORT=$((PORT + 40))
node scripts/mock-provider.cjs "$MOCK_PORT" > "$WORK/mock.log" 2>&1 &
MOCK_PID=$!
sleep 1
if ! kill -0 "$MOCK_PID" 2>/dev/null || ! curl -fsS -m 2 "http://127.0.0.1:$MOCK_PORT/" >/dev/null; then
  echo "  FAIL: local mock provider did not start"; exit 1
fi
WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
WASM_AGENT_LLM_API_KEY=test-only \
WASM_AGENT_TEST_STALL_WORKER=1 \
WASM_AGENT_WORKER_STALL_SECONDS=1 \
WASM_AGENT_WORKER_STALL_EXIT_SECONDS=0 \
  "$BIN" serve --port "$TURN_PORT" --client-port "$TURN_CLIENT" --ui "$ROOT/ui" > "$WORK/turns.log" 2>&1 &
TURNS=$!
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$TURN_PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then echo "  FAIL: the turn-test server did not come up"; exit 1; fi

# Occupy worker 0 with the hook, using a write route so the hook trips on it.
curl -s -o /dev/null -m 3 -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$TURN_PORT/diff" 2>/dev/null
sleep 2

# A turn for a session nobody is running: it must not wait behind the wedged worker.
curl -s -N -m 20 -X POST -H 'content-type: text/plain' -H 'x-wa-session: turn-session-a' \
  --data 'reply with the single word: ok' "http://127.0.0.1:$TURN_PORT/chat" > "$WORK/turn-a.txt" 2>&1 &
sleep 3
turns_health="$(curl -s -m 3 "http://127.0.0.1:$TURN_PORT/health" 2>/dev/null)"
# The same session again: it must land on the worker already running it, not on a third one.
curl -s -N -m 20 -X POST -H 'content-type: text/plain' -H 'x-wa-session: turn-session-a' \
  --data 'reply with the single word: ok' "http://127.0.0.1:$TURN_PORT/chat" > "$WORK/turn-a2.txt" 2>&1 &
sleep 3
affinity_health="$(curl -s -m 3 "http://127.0.0.1:$TURN_PORT/health" 2>/dev/null)"
# A different session: a second conversation, which is the point.
curl -s -N -m 20 -X POST -H 'content-type: text/plain' -H 'x-wa-session: turn-session-b' \
  --data 'reply with the single word: ok' "http://127.0.0.1:$TURN_PORT/chat" > "$WORK/turn-b.txt" 2>&1 &
TURN_B=$!
sleep 4
concurrent_health="$(curl -s -m 3 "http://127.0.0.1:$TURN_PORT/health" 2>/dev/null)"
wait "$TURN_B"
kill "$TURNS" 2>/dev/null

echo
echo "  turns: after a turn for session A -> $turns_health"
echo "  turns: after the same session again -> $affinity_health"
echo "  turns: after a turn for session B -> $concurrent_health"
case "$turns_health" in
  *'"session":"turn-session-a"'*)
    echo "  ok: a turn for a new session got its own worker, while worker 0 was wedged" ;;
  *) echo "  FAIL: the turn did not get a worker of its own"; exit 1 ;;
esac
if printf '%s' "$turns_health" | grep -q '"current":null'; then
  echo '  FAIL: health must not advertise idle while a secondary worker runs a turn'; exit 1
fi
case "$affinity_health" in
  *'"workers_count":2'*)
    echo "  ok: the same session did not open a second worker" ;;
  *) echo "  FAIL: the same session opened another worker - two writers on one conversation"; exit 1 ;;
esac
# Require an actual mock answer, not merely a routed request or a nonempty error.
# Worker 0 remains wedged throughout; the turn must finish on another worker.
b_bytes="$(wc -c < "$WORK/turn-b.txt" | tr -d " ")"
if grep -q '"reply":"ok"' "$WORK/turn-b.txt" && printf "%s" "$concurrent_health" | grep -q "\"id\":0[^}]*\"state\":\"stalled\""; then
  echo "  ok: a second conversation was answered while worker 0 was still wedged ($b_bytes bytes of reply)"
else
  echo "  FAIL: a second concurrent conversation did not return the mock answer ($b_bytes bytes)"
  head -c 500 "$WORK/turn-b.txt"; echo
  tail -8 "$WORK/turns.log"
  exit 1
fi
echo "  ok: turns are routed by session - concurrent across sessions, ordered within one"
