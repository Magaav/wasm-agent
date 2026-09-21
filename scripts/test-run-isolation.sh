#!/usr/bin/env bash
# Concurrent-session isolation: per-run streams, atomic conversation ownership, lanes.
#
#   bash scripts/test-run-isolation.sh [port]
#
# Every assertion here is model-free and account-free. The provider is a local fixture that
# echoes `RUN-MARKER-<word>` from the request and streams it one character at a time, so:
#
#   * two overlapping runs are told apart by their *content*, not merely by counting events -
#     a stream shared between runs carries the other run's marker, and
#   * the streams genuinely interleave, which is when a shared sink is visible.
#
# It also proves the admission rules that a single run cannot exercise: one owner per
# conversation, same-conversation runs ordered, a bounded conversation backlog, a background
# lane that cannot take the interactive reserve, and a background marker that cannot promote.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
PORT="${1:-8961}"
CLIENT_PORT=$((PORT + 1))
MOCK_PORT=$((PORT + 2))
WORK="$(mktemp -d /tmp/wa-iso-XXXXXX)"

PIDS=()
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
  if [ "$status" != "0" ]; then
    echo "  fixture logs retained at $WORK" >&2
  else
    case "$WORK" in /tmp/wa-iso-??????) rm -rf -- "$WORK" 2>/dev/null || true ;; esac
  fi
  return "$status"
}
trap cleanup EXIT

fail() { echo "  FAIL: $*" >&2; exit 1; }

# One health probe, parsed by node so the assertions are over fields and not substrings.
health() { curl -s -m 3 "http://127.0.0.1:$PORT/health"; }
runs_for() {
  health | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      const h = JSON.parse(s);
      const rows = (h.runs || []).filter((r) => r.conversation === process.argv[1]);
      console.log(rows.map((r) => r.worker + ":" + r.class + ":" + r.pending).join(","));
    });' "$1"
}
distinct_workers_for() {
  health | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      const h = JSON.parse(s);
      const workers = new Set((h.runs || []).filter((r) => r.conversation === process.argv[1]).map((r) => r.worker));
      console.log(workers.size);
    });' "$1"
}
chat() {
  # chat <file> <thread> <marker> [extra header...]
  local file="$1" thread="$2" marker="$3"; shift 3
  local headers=(-H 'content-type: application/json' -H 'accept: text/event-stream')
  local extra
  for extra in "$@"; do headers+=(-H "$extra"); done
  curl -sN -m 60 -X POST "${headers[@]}" \
    -d "{\"text\":\"answer with the literal text $marker\",\"thread\":\"$thread\"}" \
    "http://127.0.0.1:$PORT/chat" > "$file" 2>&1
}

[ -x "$BIN" ] || fail "no binary at $BIN (build first: cargo build --release --manifest-path rust/Cargo.toml)"

node scripts/mock-provider-isolation.cjs "$MOCK_PORT" > "$WORK/mock.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 40); do curl -fsS -m 2 "http://127.0.0.1:$MOCK_PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS -m 2 "http://127.0.0.1:$MOCK_PORT/" >/dev/null 2>&1 || fail "the mock provider did not start"

# The lane bounds are deliberately tiny so saturation is reachable in seconds, and the session
# backlog is 4 (the default) so the bound is exercised with a handful of runs. Worker 0 is the
# interactive reserve, so background work uses workers 1..=max.
WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$MOCK_PORT" \
WASM_AGENT_LLM_API_KEY=test-only \
WASM_AGENT_WORKERS_MAX=3 \
WASM_AGENT_BACKGROUND_MAX=1 \
WASM_AGENT_BACKGROUND_BACKLOG=0 \
WASM_AGENT_SESSION_QUEUE_DEPTH=4 \
  "$BIN" --db "$WORK/iso.db" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$ROOT/ui" > "$WORK/serve.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)"
  [ "$code" = "200" ] && break
  sleep 0.25
done
[ "${code:-}" = "200" ] || { tail -20 "$WORK/serve.log" >&2; fail "the node did not come up"; }

# ---------------------------------------------------------------------------
# 1. Per-run stream isolation.
echo
echo "isolation: two overlapping runs must not share a stream"
chat "$WORK/alpha.sse" "iso-alpha" "RUN-MARKER-ALPHA" &
A=$!
chat "$WORK/bravo.sse" "iso-bravo" "RUN-MARKER-BRAVO" &
B=$!
# They must actually overlap: both admitted before either finishes.
for _ in $(seq 1 40); do
  overlap="$(runs_for iso-alpha),$(runs_for iso-bravo)"
  printf '%s' "$overlap" | grep -q 'iso-alpha' && printf '%s' "$overlap" | grep -q 'iso-bravo' && break
  sleep 0.1
done
wait "$A"; wait "$B"

[ "$(grep -c '"type":"done"' "$WORK/alpha.sse")" = "1" ] \
  || fail "alpha's stream had $(grep -c '"type":"done"' "$WORK/alpha.sse") done events, expected exactly 1 (a stolen stream is silent or doubled)"
[ "$(grep -c '"type":"done"' "$WORK/bravo.sse")" = "1" ] \
  || fail "bravo's stream had $(grep -c '"type":"done"' "$WORK/bravo.sse") done events, expected exactly 1"
grep -q 'RUN-MARKER-ALPHA' "$WORK/alpha.sse" || fail "alpha's stream did not carry its own answer"
grep -q 'RUN-MARKER-BRAVO' "$WORK/bravo.sse" || fail "bravo's stream did not carry its own answer"
grep -q 'RUN-MARKER-BRAVO' "$WORK/alpha.sse" && fail "alpha's stream carried bravo's answer: the runs shared a sink"
grep -q 'RUN-MARKER-ALPHA' "$WORK/bravo.sse" && fail "bravo's stream carried alpha's answer: the runs shared a sink"
echo "  ok: each run carried only its own events (alpha $(wc -c < "$WORK/alpha.sse" | tr -d ' ') bytes, bravo $(wc -c < "$WORK/bravo.sse" | tr -d ' ') bytes)"

# ---------------------------------------------------------------------------
# 2. Atomic ownership: back-to-back admissions for one conversation share an owner.
echo
echo "ordering: two runs admitted back to back for one conversation"
chat "$WORK/one.sse" "order-session" "RUN-MARKER-ONE" &
ONE=$!
for _ in $(seq 1 40); do
  runs_for order-session | grep -q '^[0-9]' && break
  sleep 0.1
done
chat "$WORK/two.sse" "order-session" "RUN-MARKER-TWO" &
TWO=$!
sleep 0.4
owners="$(runs_for order-session)"
case "$owners" in
  *,*) fail "order-session had more than one owner row: $owners" ;;
  "" ) fail "order-session was not admitted at all" ;;
esac
distinct="$(distinct_workers_for order-session)"
[ "$distinct" = "1" ] || fail "order-session was held by $distinct workers, expected exactly 1"
pending="$(printf '%s' "$owners" | cut -d: -f3)"
[ "${pending:-0}" -ge 2 ] || fail "the second run did not queue behind the owner (pending=$pending)"
echo "  ok: one owner holds the conversation with both runs pending ($owners)"
wait "$ONE"; wait "$TWO"

order="$(curl -s -m 3 "http://127.0.0.1:$PORT/session?id=order-session" | node -e '
  let s = "";
  process.stdin.on("data", (d) => s += d).on("end", () => {
    const p = JSON.parse(s);
    const rows = (p.messages || []).map((m) => {
      const body = String(m.content || "");
      const who = body.includes("RUN-MARKER-ONE") ? "ONE" : body.includes("RUN-MARKER-TWO") ? "TWO" : "";
      return who ? m.role + ":" + who : "";
    }).filter(Boolean);
    console.log(rows.join(","));
  });')"
case "$order" in
  *"user:ONE"*"assistant:ONE"*"user:TWO"*"assistant:TWO"*)
    echo "  ok: the conversation stayed ordered ($order)" ;;
  *) fail "same-conversation runs interleaved or reordered: $order" ;;
esac

# ---------------------------------------------------------------------------
# 3. Lanes: background capacity is bounded and cannot take the interactive reserve.
echo
echo "lanes: background capacity is bounded and cannot take the interactive reserve"
chat "$WORK/bg1.sse" "bg-one" "RUN-MARKER-BG1" "x-wa-run-class: background" &
BG1=$!
for _ in $(seq 1 40); do
  runs_for bg-one | grep -q '^[0-9]' && break
  sleep 0.1
done
case "$(runs_for bg-one)" in
  *":background:"*) echo "  ok: the marker put the run in the background lane" ;;
  *) fail "x-wa-run-class: background was not honoured: $(runs_for bg-one)" ;;
esac
code="$(curl -s -o "$WORK/bg2.json" -w '%{http_code}' -m 5 -X POST \
  -H 'content-type: application/json' -H 'accept: text/event-stream' -H 'x-wa-run-class: background' \
  -d '{"text":"answer with RUN-MARKER-BG2","thread":"bg-two"}' "http://127.0.0.1:$PORT/chat")"
body="$(cat "$WORK/bg2.json" 2>/dev/null)"
case "$code:$body" in
  503:*background_queue_full*) echo "  ok: a second background run is refused with a reason" ;;
  *) fail "expected 503 background_queue_full, got $code $body" ;;
esac
# The marker is one-way: `interactive` cannot promote a run into the reserve, but the default
# is already interactive, so the proof is that a *background* run stays background and an
# interactive run is still served while the background lane is full.
code="$(curl -s -o "$WORK/person.json" -w '%{http_code}' -m 60 -X POST \
  -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -d '{"text":"answer with RUN-MARKER-PERSON","thread":"person-thread"}' "http://127.0.0.1:$PORT/chat")"
[ "$code" = "200" ] || fail "an interactive run was refused while background capacity was full ($code)"
grep -q 'RUN-MARKER-PERSON' "$WORK/person.json" || fail "the interactive run did not get its answer"
echo "  ok: an interactive run was served while the background lane was full"
wait "$BG1"
grep -q '"type":"done"' "$WORK/bg1.sse" || fail "the admitted background run did not complete"
echo "  ok: the admitted background run completed"

# ---------------------------------------------------------------------------
# 4. Race: simultaneous same-conversation admissions stay on one owner and stay isolated.
echo
echo "race: simultaneous runs for one conversation"
RACE_PIDS=()
for n in 1 2 3 4; do
  chat "$WORK/race$n.sse" "race-session" "RUN-MARKER-RACE$n" &
  RACE_PIDS+=("$!")
done
sleep 0.8
distinct="$(distinct_workers_for race-session)"
[ "$distinct" = "1" ] || fail "race-session was held by $distinct workers, expected exactly 1"
echo "  ok: four simultaneous runs shared exactly one owner"
for pid in "${RACE_PIDS[@]}"; do wait "$pid"; done
for n in 1 2 3 4; do
  [ "$(grep -c '"type":"done"' "$WORK/race$n.sse")" = "1" ] \
    || fail "race run $n had $(grep -c '"type":"done"' "$WORK/race$n.sse") done events, expected 1"
  grep -q "RUN-MARKER-RACE$n" "$WORK/race$n.sse" || fail "race run $n did not carry its own answer"
  for m in 1 2 3 4; do
    [ "$n" = "$m" ] && continue
    grep -q "RUN-MARKER-RACE$m" "$WORK/race$n.sse" && fail "race run $n carried run $m's answer"
  done
done
echo "  ok: four simultaneous same-conversation runs stayed ordered and isolated"

# ---------------------------------------------------------------------------
# 5. The conversation backlog is bounded: past it, a run is refused rather than queued forever.
echo
echo "bound: a conversation's backlog is bounded"
BOUND_PIDS=()
for n in 1 2 3 4; do
  chat "$WORK/bound$n.sse" "bound-session" "RUN-MARKER-BOUND$n" &
  BOUND_PIDS+=("$!")
  sleep 0.1
done
# Wait for the backlog to reach the bound.
for _ in $(seq 1 40); do
  pending="$(runs_for bound-session | cut -d: -f3)"
  [ "${pending:-0}" -ge 4 ] && break
  sleep 0.1
done
code="$(curl -s -o "$WORK/bound5.json" -w '%{http_code}' -m 5 -X POST \
  -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -d '{"text":"answer with RUN-MARKER-BOUND5","thread":"bound-session"}' "http://127.0.0.1:$PORT/chat")"
body="$(cat "$WORK/bound5.json" 2>/dev/null)"
case "$code:$body" in
  503:*session_queue_full*) echo "  ok: a run past the conversation's backlog is refused, not queued" ;;
  *) fail "expected 503 session_queue_full, got $code $body (pending=$pending)" ;;
esac
for pid in "${BOUND_PIDS[@]}"; do wait "$pid"; done
for n in 1 2 3 4; do
  grep -q "RUN-MARKER-BOUND$n" "$WORK/bound$n.sse" || fail "bound run $n did not complete"
done
echo "  ok: the runs inside the bound all completed"

echo
echo "auth: the credential is not the conversation, and invalid credentials are refused"
# Mint a guest credential (local account switch; no password by design).
guest_token="$(curl -s -m 3 -X POST --data 'guest' "http://127.0.0.1:$PORT/login" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).session||"")}catch(e){console.log("")}})')"
[ -n "$guest_token" ] || fail "could not mint a guest credential"
# A run with a valid credential and a named thread is owned by the THREAD, not by the token.
curl -sN -m 40 -X POST -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -H "x-wa-session: $guest_token" \
  -d '{"text":"answer with RUN-MARKER-AUTHTHREAD","thread":"guest-thread"}' \
  "http://127.0.0.1:$PORT/chat" > "$WORK/auth.sse" 2>&1 &
AUTHRUN=$!
for _ in $(seq 1 40); do
  [ -n "$(runs_for guest-thread)" ] && break
  sleep 0.1
done
[ -n "$(runs_for guest-thread)" ] || fail "the credentialed run was not owned by its thread"
wait "$AUTHRUN"
grep -q 'RUN-MARKER-AUTHTHREAD' "$WORK/auth.sse" || fail "the credentialed run did not answer"
echo "  ok: a valid credential's run is keyed by its thread, not by the credential"
# A nonempty invalid credential is refused at the boundary, never served as the default user.
code="$(curl -s -o "$WORK/badtoken.json" -w '%{http_code}' -m 5 -X POST \
  -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -H 'x-wa-session: not-a-real-token' \
  -d '{"text":"answer with RUN-MARKER-NOPE","thread":"nope-thread"}' "http://127.0.0.1:$PORT/chat")"
body="$(cat "$WORK/badtoken.json" 2>/dev/null)"
case "$code:$body" in
  401:*invalid_session*) echo "  ok: an invalid credential is refused with 401, not served as master" ;;
  *) fail "expected 401 invalid_session, got $code $body" ;;
esac
# A guest must not address a thread that belongs to another user.
code="$(curl -s -o "$WORK/foreign.json" -w '%{http_code}' -m 5 -X POST \
  -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -H "x-wa-session: $guest_token" \
  -d '{"text":"answer with RUN-MARKER-FOREIGN","thread":"order-session"}' "http://127.0.0.1:$PORT/chat")"
body="$(cat "$WORK/foreign.json" 2>/dev/null)"
case "$code:$body" in
  403:*forbidden_thread*) echo "  ok: a guest cannot address another user's thread" ;;
  *) fail "expected 403 forbidden_thread, got $code $body" ;;
esac

echo
echo "run isolation ok"
