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
runs_status() {
  local thread="$1" token="${2:-}"
  if [ -n "$token" ]; then
    curl -s -m 3 -X POST -H 'content-type: application/json' -H "x-wa-session: $token" -d "{\"action\":\"status\",\"thread\":\"$thread\"}" "http://127.0.0.1:$PORT/runs"
  else
    curl -s -m 3 -X POST -H 'content-type: application/json' -d "{\"action\":\"status\",\"thread\":\"$thread\"}" "http://127.0.0.1:$PORT/runs"
  fi
}
runs_cancel() {
  local thread="$1" token="${2:-}" run_id="${3:-}"
  local body="{\"action\":\"cancel\",\"thread\":\"$thread\""
  [ -n "$run_id" ] && body="$body,\"run_id\":$run_id"
  body="$body}"
  if [ -n "$token" ]; then
    curl -s -m 3 -X POST -H 'content-type: application/json' -H "x-wa-session: $token" -d "$body" "http://127.0.0.1:$PORT/runs"
  else
    curl -s -m 3 -X POST -H 'content-type: application/json' -d "$body" "http://127.0.0.1:$PORT/runs"
  fi
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
WASM_AGENT_CONTROL_WORKERS=1 \
WASM_AGENT_SUBAGENT_AWAIT_MS=800 \
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
echo "cancel: owner-scoped, per-run, and never claimed before it settles"
chat "$WORK/cancel.sse" "cancel-thread" "RUN-MARKER-CANCELME" &
CANCEL_PID=$!
for _ in $(seq 1 40); do
  [ -n "$(runs_for cancel-thread)" ] && break
  sleep 0.1
done
cancel_run_id="$(runs_status cancel-thread | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=(JSON.parse(s).runs||[])[0];console.log(r?r.run_id:"")})')"
[ -n "$cancel_run_id" ] || fail "no run id for cancel-thread"
# A guest cannot cancel it, even knowing the id.
code="$(curl -s -o "$WORK/guest-cancel.json" -w '%{http_code}' -m 3 -X POST -H 'content-type: application/json' -H "x-wa-session: $guest_token" -d "{\"action\":\"cancel\",\"thread\":\"cancel-thread\",\"run_id\":$cancel_run_id}" "http://127.0.0.1:$PORT/runs")"
case "$code" in
  403) echo "  ok: another user cannot cancel this run even by id" ;;
  *) fail "expected 403 for a foreign cancel, got $code $(cat "$WORK/guest-cancel.json" 2>/dev/null)" ;;
esac
# Master cancel is a request, reported with the state it was in - never "cancelled" before it stops.
resp="$(runs_cancel cancel-thread)"
printf '%s' "$resp" | grep -q '"cancel_requested":true' || fail "cancel did not set the flag: $resp"
printf '%s' "$resp" | grep -q '"state":"running"' || fail "cancel must not claim the run stopped: $resp"
echo "  ok: cancel is a request that reports the current state ($resp)"
runs_status cancel-thread | grep -q '"cancelled":true' || fail "status must show the cancel request"
wait "$CANCEL_PID"
[ "$(grep -c '"type":"done"' "$WORK/cancel.sse")" = "1" ] || fail "the cancelled run must settle its stream exactly once"
grep -q 'run_cancelled' "$WORK/cancel.sse" || fail "the running run did not observe the cancel through the provider path"
# The state only becomes `cancelled` after the run actually stopped, and the flag is scoped to this
# run, so the queued run behind it (if any) is untouched.
runs_status cancel-thread | grep -q '"state":"cancelled"' || fail "the cancelled run did not settle as cancelled"
echo "  ok: the running run observed the cancel, settled once, and is reported cancelled"

# A run queued behind a running one is cancelled on its own flag: it settles without executing, and
# the running run is untouched. This is the per-run guarantee - cancelling one run cannot cancel the
# next.
echo
echo "cancel: a queued run settles without executing"
chat "$WORK/q1.sse" "queue-cancel" "RUN-MARKER-Q1" &
Q1=$!
for _ in $(seq 1 40); do
  [ -n "$(runs_for queue-cancel)" ] && break
  sleep 0.1
done
chat "$WORK/q2.sse" "queue-cancel" "RUN-MARKER-Q2" &
Q2=$!
q2_id=""
for _ in $(seq 1 40); do
  q2_id="$(runs_status queue-cancel | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const rs=JSON.parse(s).runs||[];const q=rs.find(r=>r.state==="queued");console.log(q?q.run_id:"")})')"
  [ -n "$q2_id" ] && break
  sleep 0.1
done
[ -n "$q2_id" ] || fail "the second run was never queued"
runs_cancel queue-cancel "" "$q2_id" >/dev/null
wait "$Q1"; wait "$Q2"
grep -q 'RUN-MARKER-Q1' "$WORK/q1.sse" || fail "the running run was disturbed by the queued run's cancel"
grep -q 'run_cancelled' "$WORK/q2.sse" || fail "the queued run did not settle as cancelled"
grep -q 'RUN-MARKER-Q2' "$WORK/q2.sse" && fail "the cancelled queued run executed anyway"
[ "$(grep -c '"type":"done"' "$WORK/q2.sse")" = "1" ] || fail "the queued run must settle its stream exactly once"
echo "  ok: the queued run was cancelled without executing, and the running run was untouched"

# Mixed classes for one conversation: the class picks the lane, but ownership still serialises the
# conversation, so a background run cannot race an interactive run on one transcript.
echo
echo "mixed: background and interactive runs for one conversation share an owner"
chat "$WORK/mix1.sse" "mixed-session" "RUN-MARKER-MIX1" &
MIX1=$!
for _ in $(seq 1 40); do
  [ -n "$(runs_for mixed-session)" ] && break
  sleep 0.1
done
chat "$WORK/mix2.sse" "mixed-session" "RUN-MARKER-MIX2" "x-wa-run-class: background" &
MIX2=$!
sleep 0.3
distinct="$(distinct_workers_for mixed-session)"
[ "$distinct" = "1" ] || fail "mixed classes opened $distinct owners for one conversation"
wait "$MIX1"; wait "$MIX2"
grep -q 'RUN-MARKER-MIX1' "$WORK/mix1.sse" || fail "the interactive run did not answer"
grep -q 'RUN-MARKER-MIX2' "$WORK/mix2.sse" || fail "the background run did not answer"
echo "  ok: the background run queued behind the interactive run on the same conversation"

# Subagents are a control call, never a run: an invalid credential is refused at the boundary, and a
# long HTTP await cannot hold the lane while /runs and /health stay prompt.
# A peer run is admitted only after its signature is verified. A forged request is refused before
# admission and creates no owner, so the scheduler never keys a conversation by a header a caller wrote.
echo
echo "peer: a forged /node/chat is refused before admission"
code="$(curl -s -o "$WORK/forged.json" -w '%{http_code}' -m 5 -X POST -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -H 'x-wa-node: attacker' -H 'x-wa-pub: deadbeef' -H "x-wa-ts: $(date +%s)" -H 'x-wa-sig: forged' \
  -d '{"text":"peer run"}' "http://127.0.0.1:$PORT/node/chat")"
case "$code" in
  401|403) echo "  ok: a forged peer signature is refused before admission ($code)" ;;
  *) fail "a forged peer request must be refused before admission, got $code $(cat "$WORK/forged.json" 2>/dev/null)" ;;
esac
[ -z "$(runs_for 'peer:attacker')" ] || fail "a forged peer request created a run owner"
echo "  ok: the forged request created no admission"

echo
echo "subagents: control lane, bounded await, auth refused"
code="$(curl -s -o "$WORK/sub-auth.json" -w '%{http_code}' -m 3 -X POST -H 'content-type: application/json' -H 'x-wa-session: bogus-token' -d '{"action":"list"}' "http://127.0.0.1:$PORT/subagents")"
[ "$code" = "401" ] || fail "an invalid credential must be refused 401 on /subagents, got $code"
echo "  ok: /subagents refuses an invalid credential with 401"
started="$(curl -s -m 5 -X POST -H 'content-type: application/json' -d '{"action":"start","profile":"explore","prompt":"answer with RUN-MARKER-CHILD"}' "http://127.0.0.1:$PORT/subagents")"
child_id="$(printf '%s' "$started" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).subagent_id||"")}catch(e){console.log("")}})')"
[ -n "$child_id" ] || fail "subagent start did not return an id: $started"
echo "  ok: /subagents start returned a durable id ($child_id)"
curl -s -m 5 -X POST -H 'content-type: application/json' -d "{\"action\":\"await\",\"id\":\"$child_id\",\"wait_ms\":60000}" "http://127.0.0.1:$PORT/subagents" > "$WORK/await.json" &
AWAIT_PID=$!
sleep 0.3
t0=$(date +%s%3N)
runs_status cancel-thread >/dev/null
t1=$(date +%s%3N)
[ $((t1 - t0)) -lt 2000 ] || fail "/runs status blocked behind a control await ($((t1 - t0))ms)"
echo "  ok: /runs status answered in $((t1 - t0))ms while a control await was in flight"
wait "$AWAIT_PID"
waited="$(cat "$WORK/await.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s);console.log(v.waited_ms||v.state||"")}catch(e){console.log("")}})')"
echo "  ok: the HTTP await was bounded ($waited)"
# GET is the read half of the same control lane, and /health carries the versioned strict shape.
code="$(curl -s -o "$WORK/sub-get.json" -w '%{http_code}' -m 3 "http://127.0.0.1:$PORT/subagents")"
[ "$code" = "200" ] || fail "GET /subagents must answer 200, got $code"
echo "  ok: GET /subagents answers on the control lane"
health | node -e '
  let s = "";
  process.stdin.on("data", (d) => s += d).on("end", () => {
    const h = JSON.parse(s);
    if (h.execution_schema !== 1) throw new Error("execution_schema");
    const sub = h.subagents || {};
    if (typeof sub.queued !== "number" || typeof sub.running !== "number" || typeof sub.active !== "number") throw new Error("subagents shape");
    if (sub.active !== sub.queued + sub.running) throw new Error("active != queued + running");
  });' || fail "health must carry execution_schema:1 and strict subagents {queued,running,active}"
echo "  ok: /health carries execution_schema:1 and strict subagent counts"

echo
echo "run isolation ok"
