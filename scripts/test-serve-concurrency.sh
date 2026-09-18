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
trap 'kill "$SERVER" "$WEDGE" 2>/dev/null; rm -rf "$WORK"' EXIT

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
code="$(curl -s -m 5 -o "$WORK/stalled.json" -w '%{http_code}' "http://127.0.0.1:$WEDGE_PORT/models" 2>/dev/null)"
body="$(cat "$WORK/stalled.json" 2>/dev/null)"
kill "$WEDGE" 2>/dev/null

echo
echo "  wedged node: /health -> $health"
echo "  wedged node: /models -> $code $body"
case "$health" in
  *'"ok":false'*'"worker":"stalled"'*) echo "  ok: /health admits the worker is stalled" ;;
  *) echo "  FAIL: /health kept claiming the node was fine"; exit 1 ;;
esac
case "$code:$body" in
  503:*worker_stalled*) echo "  ok: a blocked request is refused with a reason, not left hanging" ;;
  *) echo "  FAIL: expected 503 worker_stalled, got $code $body"; exit 1 ;;
esac
echo "  ok: a stalled worker is visible, and survivable"

