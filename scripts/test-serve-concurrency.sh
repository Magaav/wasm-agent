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
# So: start a turn that takes a while, and check the page assets and every read
# needed to rehydrate a chat. They must answer before the turn finishes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
PORT="${1:-8891}"
CLIENT_PORT=$((PORT + 1))
WORK="$(mktemp -d /tmp/wa-conc-XXXXXX)"
cleanup() {
  local status=$?
  # Only jobs owned by this fixture; wait for them so locked Windows databases do
  # not turn cleanup into a product failure. Never kill by image name.
  # A fixture that is still shutting down holds its own database, so the removal has to wait for
  # the kill to take effect: removing first failed on a locked pool.db, and because this runs as an
  # EXIT trap under `set -o pipefail`, that failure became the script's exit status - a harness
  # race reported as a product failure. Kill, wait, then remove, and never let the cleanup decide
  # the verdict.
  local pids=("${SERVER:-}" "${WEDGE:-}" "${POOL:-}" "${TURNS:-}" "${BRIDGE:-}" "${MOCK_PID:-}")
  kill "${pids[@]}" 2>/dev/null
  for _ in $(seq 1 20); do
    local alive=0
    for pid in "${pids[@]}"; do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = "0" ] && break
    sleep 0.1
  done
  for pid in "${pids[@]}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  if [ "$status" != "0" ]; then
    echo "  fixture logs retained at $WORK" >&2
  else
    case "$WORK" in /tmp/wa-conc-??????) rm -rf -- "$WORK" 2>/dev/null || true ;; esac
  fi
  return "$status"
}
trap cleanup EXIT

if [ "${WEDGE_ONLY:-0}" = "1" ]; then
  # Hermetic smoke must not load the operator's node key, provider selection or
  # rendezvous/relay configuration merely because its DB path is separate.
  while IFS= read -r variable; do
    case "$variable" in WASM_AGENT_*|WA_SCRIPT|OPENAI_API_KEY|OPENCODE_GO_API_KEY) unset "$variable" ;; esac
  done < <(compgen -e)
  mkdir -p "$WORK/home"
  if command -v cygpath >/dev/null 2>&1; then
    export WASM_AGENT_HOME="$(cygpath -w "$WORK/home")"
    export WASM_AGENT_LUA_ROOT="$(cygpath -w "$ROOT")"
  else
    export WASM_AGENT_HOME="$WORK/home" WASM_AGENT_LUA_ROOT="$ROOT"
  fi
  export WASM_AGENT_LLM_MODEL=fixture
fi

# Every fixture needs its own database. Omitting --db here used the operator's
# live memory.db: a smoke run migrated its schema before the compatible binary
# was deployed, then the still-running node failed on the renamed column.

if [ ! -x "$BIN" ]; then echo "no binary at $BIN" >&2; exit 1; fi

"$BIN" --db "$WORK/serve.db" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
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
    "http://127.0.0.1:$PORT/chat" > "$WORK/run.txt" 2>&1
) &
TURN=$!

sleep 2
# A page reloaded in the middle of this turn needs /me, /models, /sessions,
# /session and /health. /health and the assets bypass Lua, but the other reads
# need a worker; checking only static files would miss a blank, "connecting" UI.
reload_started="$(date +%s%3N)"
for route in me models sessions; do
  read_code="$(curl -s -m 2 -o "$WORK/$route.json" -w '%{http_code}' "http://127.0.0.1:$PORT/$route" 2>/dev/null)"
  if [ "$read_code" != "200" ]; then
    echo "  FAIL: /$route did not answer during a running turn (HTTP ${read_code:-none})"; exit 1
  fi
done
thread_id="$(grep -oE '"id":"[0-9a-f-]{36}"' "$WORK/sessions.json" | head -1 | cut -d '"' -f 4)"
if [ -z "$thread_id" ]; then echo '  FAIL: /sessions did not list the running thread'; exit 1; fi
read_code="$(curl -s -m 2 -o "$WORK/session.json" -w '%{http_code}' "http://127.0.0.1:$PORT/session?id=$thread_id" 2>/dev/null)"
if [ "$read_code" != "200" ] || ! grep -q '"state":{' "$WORK/session.json"; then
  echo "  FAIL: /session did not return the nested state contract during a running turn"; exit 1
fi
reload_ms="$(( $(date +%s%3N) - reload_started ))"
if [ "$reload_ms" -ge 3000 ] || ! kill -0 "$TURN" 2>/dev/null; then
  echo "  FAIL: reload reads took ${reload_ms}ms or the turn finished before they completed"; exit 1
fi
echo "  ok: /me, /models, /sessions and /session loaded in ${reload_ms}ms during the turn"

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

run_bytes="$(wc -c < "$WORK/run.txt" | tr -d ' ')"
echo
echo "  probes while the turn streamed: $probes   answered: $ok   blocked: $fail"
echo "  run streamed $run_bytes bytes"
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
  "$BIN" --db "$WORK/wedge.db" serve --port "$WEDGE_PORT" --client-port "$WEDGE_CLIENT" --ui "$ROOT/ui" > "$WORK/wedge.log" 2>&1 &
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
# The bound an in-flight `bash`/`shell` call is shown against. It must be the number the host
# enforces, reported rather than guessed, so a window can say "42s of 300s" without waiting for the
# tool event - and so a client never invents a different deadline from the one that kills the call.
case "$health" in
  *'"exec_timeout_seconds":300'*) echo "  ok: /health reports the exec deadline" ;;
  *) echo "  FAIL: /health must report exec_timeout_seconds=300, got: $health"; exit 1 ;;
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
  "$BIN" --db "$WORK/pool.db" serve --port "$POOL_PORT" --client-port "$POOL_CLIENT" --ui "$ROOT/ui" > "$WORK/pool.log" 2>&1 &
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
# `/tools` is a read too, and it was not on the read-route list: with a run holding worker 0 it
# returned no bytes, which is how the engine's tool panel hung behind a turn. A missing entry here is
# a performance bug, so it is measured rather than assumed.
tools_code="$(curl -s -m 5 -o "$WORK/pool-tools.json" -w '%{http_code}' "http://127.0.0.1:$POOL_PORT/tools" 2>/dev/null)"
# `/efficiency` is the route the window's `/efficiency_report` calls. It was dropped by a merge that
# applied cleanly and recorded its branch as a parent while bringing none of its content, and the gate
# stayed green because nothing asserted it. A 404 here is that bug; a non-200 under a wedged worker 0
# is the read-route bug.
efficiency_code="$(curl -s -m 5 -o "$WORK/pool-efficiency.json" -w '%{http_code}' "http://127.0.0.1:$POOL_PORT/efficiency" 2>/dev/null)"
write_code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$POOL_PORT/diff" 2>/dev/null)"
grown_health="$(curl -s -m 3 "http://127.0.0.1:$POOL_PORT/health" 2>/dev/null)"
# Now leave it alone: the worker that answered that read has nothing to do, and must go away again.
sleep 6
shrunk_health="$(curl -s -m 3 "http://127.0.0.1:$POOL_PORT/health" 2>/dev/null)"
# The worker that just retired is replaced by a *new* interpreter in the same index. It must not
# inherit the dead worker's last beat: selection would read that stale age, call the fresh worker
# wedged, and answer a plain read `503 worker_stalled`. This is the pool's whole promise - a read is
# served without waiting - so a respawn must start the replacement's liveness clock at zero.
respawn_code="$(curl -s -m 5 -o "$WORK/pool-respawn.json" -w '%{http_code}' "http://127.0.0.1:$POOL_PORT/sessions" 2>/dev/null)"
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
case "$tools_code" in
  200) echo "  ok: /tools is answered while a turn holds worker 0" ;;
  *) echo "  FAIL: /tools queued behind the turn (got ${tools_code:-none}) - it is a read"; exit 1 ;;
esac
case "$efficiency_code" in
  200) echo "  ok: /efficiency exists and is a read" ;;
  404) echo "  FAIL: /efficiency has no handler - a merge dropped the route and the gate did not notice"; exit 1 ;;
  *) echo "  FAIL: /efficiency was not answered as a read (got ${efficiency_code:-none})"; exit 1 ;;
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
echo "  pool: a read after that worker retired -> $respawn_code"
case "$respawn_code" in
  200) echo "  ok: the replacement did not inherit the retired worker's stall" ;;
  *) echo "  FAIL: a fresh read worker was mistaken for the dead one it replaced (got ${respawn_code:-none})"; exit 1 ;;
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
  "$BIN" --db "$WORK/turns.db" serve --port "$TURN_PORT" --client-port "$TURN_CLIENT" --ui "$ROOT/ui" > "$WORK/turns.log" 2>&1 &
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
curl -s -N -m 20 -X POST -H 'content-type: application/json' \
  --data '{"text":"reply with the single word: ok","thread":"turn-session-a"}' "http://127.0.0.1:$TURN_PORT/chat" > "$WORK/turn-a.txt" 2>&1 &
sleep 3
turns_health="$(curl -s -m 3 "http://127.0.0.1:$TURN_PORT/health" 2>/dev/null)"
# The same session again: it must land on the worker already running it, not on a third one.
curl -s -N -m 20 -X POST -H 'content-type: application/json' \
  --data '{"text":"reply with the single word: ok","thread":"turn-session-a"}' "http://127.0.0.1:$TURN_PORT/chat" > "$WORK/turn-a2.txt" 2>&1 &
sleep 3
affinity_health="$(curl -s -m 3 "http://127.0.0.1:$TURN_PORT/health" 2>/dev/null)"
# A different session: a second conversation, which is the point.
curl -s -N -m 20 -X POST -H 'content-type: application/json' \
  --data '{"text":"reply with the single word: ok","thread":"turn-session-b"}' "http://127.0.0.1:$TURN_PORT/chat" > "$WORK/turn-b.txt" 2>&1 &
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

# ---------------------------------------------------------------------------
# The client bridge must not be wedgeable by a peer that says nothing.
#
# The failure this exists for: the bridge served one connection at a time on its
# accept loop and read requests with no timeout at all, so a single connection
# that was opened and then left silent blocked every later poll *forever*. The
# listener stayed bound, the log stayed quiet, and the only symptom was
# `client_not_connected` - which blamed the window, which was healthy. A real run
# lost five minutes to it, and the diagnosis it printed was wrong.
BRIDGE_PORT=$((PORT + 20))
BRIDGE_CLIENT=$((BRIDGE_PORT + 1))
"$BIN" --db "$WORK/bridge.db" serve --port "$BRIDGE_PORT" --client-port "$BRIDGE_CLIENT" --ui "$ROOT/ui" > "$WORK/bridge.log" 2>&1 &
BRIDGE=$!
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$BRIDGE_PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then echo "  bridge fixture did not come up (see $WORK/bridge.log)" >&2; exit 1; fi
echo
echo "bridge: the client port is $BRIDGE_CLIENT"

health="$(curl -s -m 3 "http://127.0.0.1:$BRIDGE_PORT/health" 2>/dev/null)"
case "$health" in
  *'"client":{'*) echo "  ok: /health carries the client block" ;;
  *) echo "  FAIL: /health has no client block, so a wedged bridge is invisible until a call fails"; exit 1 ;;
esac

# A connection that is opened and never finished. Held open for the rest of this
# section: everything below must work *while* it sits there.
exec 3<>"/dev/tcp/127.0.0.1/$BRIDGE_CLIENT" || { echo "  FAIL: could not open a connection to the client port"; exit 1; }
printf 'GET /client/poll HTTP/1.1\r\n' >&3

# 1. A fresh connection is still served. Before the fix this hung until curl gave up.
fresh="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$BRIDGE_CLIENT/" 2>/dev/null)"
[ "$fresh" = "404" ] || { echo "  FAIL: a silent connection blocked a fresh one (http_code=$fresh)"; exec 3<&-; exit 1; }
echo "  ok: a fresh connection was served ($fresh) while a silent one was held"

# 2. A poll is still answered, and it counts as a poll: the old handler never got
#    as far as mark_poll, which is why the window looked disconnected.
poll="$(curl -s -o /dev/null -m 26 -w '%{http_code}' -X POST -H 'content-type: application/json' \
  -d '{"v":2,"state":{"client":{"actions":0}}}' "http://127.0.0.1:$BRIDGE_CLIENT/client/poll" 2>/dev/null)"
[ "$poll" = "200" ] || { echo "  FAIL: the poll was not answered (http_code=$poll)"; exec 3<&-; exit 1; }
seen="$(curl -s -m 3 "http://127.0.0.1:$BRIDGE_PORT/health" 2>/dev/null)"
case "$seen" in
  *'"connected":true'*) echo "  ok: the poll was answered and registered as a client" ;;
  *) echo "  FAIL: the poll was answered but the bridge did not register it: $seen"; exec 3<&-; exit 1 ;;
esac
# What the client volunteers on the poll is readable from the node, which is what
# makes "what is this client doing" cost no round trip.
case "$seen" in
  *'"age_ms"'*) echo "  ok: the state a client posts on its poll is visible at /health" ;;
  *) echo "  FAIL: the polled state did not reach /health: $seen"; exec 3<&-; exit 1 ;;
esac
exec 3<&-

# 3. The node can tell whether its own bridge is answering, without a call failing.
for _ in $(seq 1 20); do
  health="$(curl -s -m 3 "http://127.0.0.1:$BRIDGE_PORT/health" 2>/dev/null)"
  case "$health" in *'"health":"ok"'*) break ;; esac
  sleep 1
done
case "$health" in
  *'"health":"ok"'*) ;;
  *) echo "  FAIL: the bridge never reported itself healthy: $health"; exit 1 ;;
esac
echo "  ok: the bridge answers its own probe, so a wedge is reportable as one"
echo "  ok: the client bridge survived a connection that said nothing"
