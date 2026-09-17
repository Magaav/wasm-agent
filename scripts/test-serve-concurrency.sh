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
trap 'kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT

if [ ! -x "$BIN" ]; then echo "no binary at $BIN" >&2; exit 1; fi

"$BIN" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
SERVER=$!

for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then echo "  server did not come up (see $WORK/serve.log)" >&2; exit 1; fi

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
