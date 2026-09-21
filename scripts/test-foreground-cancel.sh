#!/usr/bin/env bash
# Foreground SILENT-provider cancellation, through HTTP, with a real node.
#
#   bash scripts/test-foreground-cancel.sh [port]
#
# The failure this proves fixed: a foreground run blocked on a provider that has
# sent nothing (no headers, or headers and no body) could not be cancelled until
# the read timeout, because the cancel path only reached the next streamed chunk.
# A cancel must now `shutdown` the exact run's socket within seconds, while
# another conversation keeps making progress and a healthy delayed first token is
# not cut short.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
PORT="${1:-$(node scripts/free-test-port-block.cjs 3)}"
CLIENT_PORT=$((PORT + 1))
MOCK_PORT=$((PORT + 2))
WORK="$(mktemp -d /tmp/wa-fgcancel-XXXXXX)"
# Safe standalone as well as under the gate: never inherit an operator home,
# credentials, approved profiles, peer binding, or provider configuration.
while IFS= read -r variable; do
  case "$variable" in
    WASM_AGENT_IN_TURN) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)
mkdir -p "$WORK/home"
if command -v cygpath >/dev/null 2>&1; then
  NATIVE_HOME="$(cygpath -w "$WORK/home")"
  NATIVE_ROOT="$(cygpath -w "$ROOT")"
  NATIVE_DB="$(cygpath -w "$WORK/cancel.db")"
  NATIVE_UI="$(cygpath -w "$ROOT/ui")"
else
  NATIVE_HOME="$WORK/home" NATIVE_ROOT="$ROOT" NATIVE_DB="$WORK/cancel.db" NATIVE_UI="$ROOT/ui"
fi
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export HTTP_PROXY="" HTTPS_PROXY="" ALL_PROXY="" NO_PROXY=127.0.0.1,localhost,::1

PIDS=()
fail() { echo "  FAIL: $*" >&2; exit 1; }
cleanup() {
  local status=$?
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null; done
  for _ in $(seq 1 20); do
    local alive=0
    for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = "0" ] && break
    sleep 0.1
  done
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  if [ "$status" != "0" ]; then echo "  fixture logs retained at $WORK" >&2; else
    case "$WORK" in /tmp/wa-fgcancel-??????) rm -rf -- "$WORK" 2>/dev/null || true ;; esac
  fi
  return "$status"
}
trap cleanup EXIT

[ -x "$BIN" ] || fail "no binary at $BIN (build first)"

now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }
# The mock counts each shape separately, so the wait below is about *this* run's
# provider call, not some other conversation's.
kind_count() { curl -s -m 2 "http://127.0.0.1:$MOCK_PORT/calls" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s)[process.argv[1]]||0)))' "$1"; }
wait_for_kind() {
  local kind="$1" target="$2"
  for _ in $(seq 1 160); do [ "$(kind_count "$kind")" -ge "$target" ] && return 0; sleep 0.05; done
  return 1
}
health() { curl -s -m 3 "http://127.0.0.1:$PORT/health"; }
runs_for() {
  health | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const h=JSON.parse(s);const rows=(h.runs||[]).filter(r=>r.conversation===process.argv[1]);
      console.log(rows.length?"yes":"");
    });' "$1"
}
runs_status() {
  curl -s -m 3 -X POST -H 'content-type: application/json' \
    -d "{\"action\":\"status\",\"thread\":\"$1\"}" "http://127.0.0.1:$PORT/runs"
}
run_id_for() {
  runs_status "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const rs=JSON.parse(s).runs||[];const r=rs.find(x=>x.state==="running")||rs.find(x=>x.state==="queued");console.log(r?r.run_id:"")})'
}
runs_cancel() {
  curl -s -m 3 -X POST -H 'content-type: application/json' \
    -d "{\"action\":\"cancel\",\"thread\":\"$1\",\"run_id\":$2}" "http://127.0.0.1:$PORT/runs"
}
chat() {
  local file="$1" thread="$2" marker="$3"
  curl -sN -m 60 -X POST -H 'content-type: application/json' -H 'accept: text/event-stream' \
    -d "{\"text\":\"answer with the literal text $marker\",\"thread\":\"$thread\"}" \
    "http://127.0.0.1:$PORT/chat" > "$file" 2>&1
}
# Wait until a run for the conversation exists (admitted), up to ~6s.
await_admission() {
  for _ in $(seq 1 60); do [ -n "$(runs_for "$1")" ] && return 0; sleep 0.1; done
  return 1
}

node scripts/mock-provider-silent.cjs "$MOCK_PORT" > "$WORK/mock.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 40); do curl -fsS -m 2 "http://127.0.0.1:$MOCK_PORT/" >/dev/null 2>&1 && break; sleep 0.1; done

WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
WASM_AGENT_LLM_API_KEY=test-only \
WASM_AGENT_LLM_MODEL=fixture \
WASM_AGENT_WORKERS_MAX=4 \
WASM_AGENT_HOME="$NATIVE_HOME" \
WASM_AGENT_LUA_ROOT="$NATIVE_ROOT" \
  "$BIN" --db "$NATIVE_DB" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$NATIVE_UI" > "$WORK/serve.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { tail -20 "$WORK/serve.log" >&2; fail "the node did not come up"; }

# ---------------------------------------------------------------------------
# 1. A foreground run silently waiting for response headers is cancelled within
#    seconds, while a second conversation completes normally.
echo
echo "foreground cancel: a silent header read is interrupted, not timed out"
chat "$WORK/headers.sse" "fg-headers" "RUN-MARKER-SILENT-HEADERS" &
H=$!
await_admission "fg-headers" || fail "the silent-headers run was never admitted"
wait_for_kind headers 1 || fail "the silent-headers run never reached the provider"
# A healthy second conversation, with a long first-token pause, must still run.
chat "$WORK/delayed.sse" "fg-delayed" "RUN-MARKER-DELAYED" &
D=$!
sleep 0.3
run_id="$(run_id_for fg-headers)"
[ -n "$run_id" ] || fail "no run id for the silent-headers run"
started="$(now_ms)"
runs_cancel "fg-headers" "$run_id" > "$WORK/headers-cancel.json"
wait "$H"
elapsed=$(( $(now_ms) - started ))
[ "$elapsed" -lt 10000 ] || fail "silent-header cancel took ${elapsed}ms (must be under 10s)"
grep -q 'run_cancelled' "$WORK/headers.sse" || fail "the silent-header run did not settle as run_cancelled: $(head -c 300 "$WORK/headers.sse")"
[ "$(grep -c '"type":"done"' "$WORK/headers.sse")" = "1" ] || fail "the cancelled run must emit exactly one terminal event"
runs_status "fg-headers" | grep -q '"state":"cancelled"' || fail "the run was not reported cancelled after it stopped"
wait "$D"
grep -q 'RUN-MARKER-DELAYED' "$WORK/delayed.sse" || fail "the healthy delayed run was cut short: $(head -c 300 "$WORK/delayed.sse")"
[ "$(grep -c '"type":"done"' "$WORK/delayed.sse")" = "1" ] || fail "the healthy run must emit exactly one terminal event"
echo "  ok: silent headers cancelled in ${elapsed}ms; the other session completed with its marker"

# ---------------------------------------------------------------------------
# 2. A foreground run silently waiting for the response body is cancelled too.
echo
echo "foreground cancel: a silent body read is interrupted, not timed out"
chat "$WORK/body.sse" "fg-body" "RUN-MARKER-SILENT-BODY" &
B=$!
await_admission "fg-body" || fail "the silent-body run was never admitted"
wait_for_kind body 1 || fail "the silent-body run never reached the provider"
run_id="$(run_id_for fg-body)"
[ -n "$run_id" ] || fail "no run id for the silent-body run"
started="$(now_ms)"
runs_cancel "fg-body" "$run_id" > "$WORK/body-cancel.json"
wait "$B"
elapsed=$(( $(now_ms) - started ))
[ "$elapsed" -lt 10000 ] || fail "silent-body cancel took ${elapsed}ms (must be under 10s)"
grep -q 'run_cancelled' "$WORK/body.sse" || fail "the silent-body run did not settle as run_cancelled: $(head -c 300 "$WORK/body.sse")"
[ "$(grep -c '"type":"done"' "$WORK/body.sse")" = "1" ] || fail "the cancelled run must emit exactly one terminal event"
runs_status "fg-body" | grep -q '"state":"cancelled"' || fail "the run was not reported cancelled after it stopped"
echo "  ok: silent body cancelled in ${elapsed}ms"

# ---------------------------------------------------------------------------
# 3. Cancelling a silent run cannot close the next queued run's socket: its
#    slot is the cancelled run's own, and the queued run then completes.
echo
echo "foreground cancel: a later queued run is not affected by the earlier cancel"
chat "$WORK/q1.sse" "fg-queue" "RUN-MARKER-SILENT-BODY" &
Q1=$!
await_admission "fg-queue" || fail "the first queued run was never admitted"
queue_body_before="$(kind_count body)"
wait_for_kind body "$((queue_body_before + 1))" || fail "the first queued run never reached the provider"
chat "$WORK/q2.sse" "fg-queue" "RUN-MARKER-QUEUED-OK" &
Q2=$!
for _ in $(seq 1 40); do run_id_for fg-queue | grep -q '^[0-9]' && break; sleep 0.05; done
q1_id="$(run_id_for fg-queue)"
[ -n "$q1_id" ] || fail "no run id for the running run"
runs_cancel "fg-queue" "$q1_id" > "$WORK/queue-cancel.json"
wait "$Q1"; wait "$Q2"
grep -q 'run_cancelled' "$WORK/q1.sse" || fail "the running run did not settle as cancelled"
grep -q 'RUN-MARKER-QUEUED-OK' "$WORK/q2.sse" || fail "the queued run's socket was closed by the earlier cancel: $(head -c 300 "$WORK/q2.sse")"
[ "$(grep -c '"type":"done"' "$WORK/q2.sse")" = "1" ] || fail "the queued run must emit exactly one terminal event"
echo "  ok: the queued run completed after the earlier run's socket was shut down"

echo
echo "foreground cancel ok"
