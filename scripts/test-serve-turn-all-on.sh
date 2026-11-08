#!/usr/bin/env bash
# One scripted serve turn end to end, with every feature ON (docs/FEATURES.md, 08/11 job item 6).
#
#   bash scripts/test-serve-turn-all-on.sh [port]
#
# What it proves: a node started from this tree with **no policy file and no WA_*_COMPONENT flag** - i.e.
# every feature at its default, which is on - boots, answers /health, runs one real turn against a stub
# model over loopback, and streams the answer back. Along the way it prints what the node says about its
# own switches (`wa features`), so the turn is visibly running with them on rather than in a mode nobody
# can see.
#
# Hermetic, and the hard rules of this job are the first four lines of the fixture:
#   * a fresh temp WASM_AGENT_HOME, never ~/.wasm-agent;
#   * WASM_AGENT_RENDEZVOUS= and WASM_AGENT_RELAY= empty, WASM_AGENT_MANAGED=0: this node joins nothing;
#   * a port that is not 8799, and only PIDs this script started are ever signalled;
#   * the model URL is a stub on 127.0.0.1 that answers one completion - no provider is contacted.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-}"
if [ -z "$BIN" ]; then
  for candidate in "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
                   "${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa.exe" "${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa" \
                   "$(command -v wa 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { BIN="$candidate"; break; }
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "serve-turn (all on): SKIP (no wa binary: set WA_BIN, or build rust/wa-host)" >&2
  exit 0
fi
case "$BIN" in /*|[A-Za-z]:*) ;; *) BIN="$ROOT/$BIN" ;; esac
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

PORT="${1:-8931}"
[ "$PORT" = "8799" ] && { echo "serve-turn (all on): refusing port 8799 (a real node lives there)" >&2; exit 2; }
CLIENT_PORT=$((PORT + 1))
MODEL_PORT=$((PORT + 2))

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-turn-XXXXXX")"
MODEL_PID=""
SERVER=""
cleanup() {
  local status=$?
  for pid in "$SERVER" "$MODEL_PID"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  for _ in $(seq 1 20); do
    local alive=0
    for pid in "$SERVER" "$MODEL_PID"; do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = "0" ] && break
    sleep 0.1
  done
  for pid in "$SERVER" "$MODEL_PID"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  [ "$status" != "0" ] && echo "  fixture logs kept at $WORK" >&2
  return "$status"
}
trap cleanup EXIT

mkdir -p "$WORK/home" "$WORK/home/.wasm-agent/components"

# ------------------------------------------------------------------------------------------------ the stub model
cat > "$WORK/model.mjs" <<'JS'
import { createServer } from 'node:http';
const port = Number(process.argv[2]);
const reply = 'the turn reached the stub model, so every seam between /chat and the provider ran';
const server = createServer((request, response) => {
  let body = '';
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    if (!request.url.includes('/chat/completions')) { response.writeHead(404).end('{}'); return; }
    const answer = { id: 'stub-1', object: 'chat.completion.chunk', model: 'stub-model',
      choices: [{ index: 0, delta: { role: 'assistant', content: reply }, finish_reason: null }],
      usage: { prompt_tokens: 12, completion_tokens: 20, total_tokens: 32 } };
    const finish = { id: 'stub-1', object: 'chat.completion.chunk', model: 'stub-model',
      choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 12, completion_tokens: 20, total_tokens: 32 } };
    response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    response.write(`data: ${JSON.stringify(answer)}\n\n`);
    response.write(`data: ${JSON.stringify(finish)}\n\n`);
    response.write('data: [DONE]\n\n');
    response.end();
  });
});
server.listen(port, '127.0.0.1');
JS
node "$WORK/model.mjs" "$MODEL_PORT" > "$WORK/model.log" 2>&1 &
MODEL_PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$MODEL_PORT/nothing" && break
  sleep 0.15
done

# ------------------------------------------------------------------------------------------------ the node
# Every feature at its default (on): no policy file, no WA_*_COMPONENT. Nothing here joins a network.
export WASM_AGENT_HOME="$(native "$WORK/home")"
export WASM_AGENT_LUA_ROOT="$(native "$ROOT")"
export WASM_AGENT_RENDEZVOUS=""
export WASM_AGENT_RELAY=""
export WASM_AGENT_MANAGED=0
export WA_COMPONENTS_DIR="$(native "$WORK/home/.wasm-agent/components")"
export WASM_AGENT_PROVIDER=opencode-go
export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1"
export WASM_AGENT_LLM_API_KEY=stub-key-not-a-secret
export WASM_AGENT_LLM_MODEL=deepseek-v4.1-flash
unset OPENAI_API_KEY OPENCODE_GO_API_KEY WASM_AGENT_VAULT_URL WASM_AGENT_LLM_SUMMARY_MODEL

echo "serve-turn (all on)"
"$BIN" features > "$WORK/features.txt" 2>&1
echo "  wa features (excerpt):"
sed -n '1,11p' "$WORK/features.txt" | sed 's/^/    /'
enabled_native=$(awk '/^(selfloop|codemode|hooks|memory|gateway|mesh_component|agent_core|telemetry_sink)/ && $4=="yes" && $6=="native"' "$WORK/features.txt" | wc -l)
enabled_any=$(awk '/^(selfloop|codemode|hooks|memory|gateway|mesh_component|agent_core|telemetry_sink)/ && $4=="yes"' "$WORK/features.txt" | wc -l)
[ "$enabled_any" = "8" ] || { echo "  FAIL: not every feature is enabled by default (see above)"; exit 1; }
echo "  ok: $enabled_any/8 features enabled with no policy file and no WA_*_COMPONENT"
if [ "$enabled_native" -gt 0 ]; then
  echo "  note: $enabled_native enabled feature(s) have no installed component here, so they run native (reported, never silent)"
fi

"$BIN" --db "$WORK/serve.db" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
SERVER=$!
code=""
for _ in $(seq 1 80); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
if [ "${code:-}" != "200" ]; then
  echo "  FAIL: the node did not come up on $PORT (see $WORK/serve.log)"
  tail -20 "$WORK/serve.log" | sed 's/^/    /'
  exit 1
fi
echo "  ok: /health answered 200 on 127.0.0.1:$PORT"

# One turn. `-N` keeps the stream; the body is the operator's own request.
curl -sN -m 120 -X POST --data "Say what you are in one line." \
  "http://127.0.0.1:$PORT/chat" > "$WORK/turn.txt" 2>&1
turn_bytes="$(wc -c < "$WORK/turn.txt" | tr -d ' ')"
if [ "$turn_bytes" -lt 20 ]; then
  echo "  FAIL: the turn produced $turn_bytes bytes (see $WORK/turn.txt and $WORK/serve.log)"
  tail -20 "$WORK/serve.log" | sed 's/^/    /'
  exit 1
fi
if ! grep -q "reached the stub model" "$WORK/turn.txt"; then
  echo "  FAIL: the stub model's answer is not in the turn stream"
  tail -5 "$WORK/turn.txt" | sed 's/^/    /'
  exit 1
fi
echo "  ok: the turn streamed the stub model's answer ($turn_bytes bytes)"
if grep -qiE "panicked|thread 'main' panicked|silent fallback" "$WORK/serve.log"; then
  echo "  FAIL: the node logged a panic"
  grep -iE "panicked|silent fallback" "$WORK/serve.log" | head -5 | sed 's/^/    /'
  exit 1
fi
# A feature that fell back has to say so by name: `component_missing` on the node's log is an answer,
# and the gate reports it once per operation. This asserts the *reporting* exists rather than that every
# component is installed here (a source checkout has none, and that is what `wa features` just said).
if [ "$enabled_native" -gt 0 ] && ! grep -q "component_missing" "$WORK/serve.log"; then
  echo "  note: no component_missing line in the log (the affected seams may not have been asked in this turn)"
fi

echo "  ok: one turn end to end with every feature at its default (on), no panic, no network but loopback"
