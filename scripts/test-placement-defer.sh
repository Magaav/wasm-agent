#!/usr/bin/env bash
# A SESSION THAT IS BUSY MUST NOT HOLD ANOTHER SESSION'S WAKE (r7c, 24/11 - Fable's acceptance test, shape 1).
#
# The defect this row exists for, measured live: session A's resume was handed a node-thread, could not take the
# session's claim because an attended turn held it, and that lane never came back - three other sessions' wakes sat
# 1 761 s behind it while an idle lane existed. This starts a REAL scratch node, holds A's claim from another
# process the way an attended turn does, and asks the node to run both wakes: B must start within the bound, A must
# defer with its own line, and nothing may be waiting past the bound in /health.
#
# WHAT THIS ROW PROVES, AND WHAT IT DOES NOT (24/11). It proves shape 1 end to end through a real node: A's session
# is held (a real claim, taken the way an attended turn takes it), B's wake starts in seconds on the background lane,
# A's resume defers with its own line, and nothing waits past the bound in /health.
#
# It does NOT prove shape 2 (A's resume running a LONG turn on the only background lane). The node has no provider
# stub that can sleep inside a turn, so this row cannot make a lane busy for minutes; and on a node WITHOUT the
# borrow shape 1 still passes when the background lane is free, as it was measured to on 4c720beb - where this row
# fails only because the node's admission line (`[completion] admitted ... to node-thread N`) does not exist there.
# Shape 2 needs that stub first; until then the borrow is proven by its unit rule, not by a node.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "placement defer: no wa binary (set WA_BIN)" >&2; exit 1; }
BOUND="${PLACEMENT_BOUND_SECONDS:-30}"
S="$(mktemp -d /tmp/placement-XXXXXX)"
mkdir -p "$S/home/.wasm-agent"
export WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_HOME="$S/home" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_DB=
DB="$S/x.db" PORT=$(python3 -c 'import random;print(random.randint(20000,28000))') CPORT=$(python3 -c 'import random;print(random.randint(28001,32000))')
fail() {
  echo "FAIL: $*"
  python3 - "$DB" <<'EOF'
import sqlite3,sys
try:
    c=sqlite3.connect(sys.argv[1])
    for row in c.execute("SELECT session_id,status,attempts,last_error FROM self_wakes ORDER BY created_at"):
        print("  wake:", row)
    for row in c.execute("SELECT run_id,session_id,status,started_at,ended_at FROM runs ORDER BY started_at"):
        print("  run:", row)
except Exception as e:
    print("  db:", e)
EOF
  echo "  serve log:"; tail -14 "$S/serve.log" 2>/dev/null | sed 's/^/    /'
  kill "${NODE:-0}" "${HOLD:-0}" 2>/dev/null; rm -rf "$S"; exit 1
}
trap 'kill ${NODE:-0} ${HOLD:-0} 2>/dev/null; rm -rf "$S"' EXIT

WA_SCRIPT="$ROOT/scripts/lib/placement-fixture.lua" "$BIN" --db "$DB" > "$S/fixture.log" 2>&1 || fail "the fixture could not write the sessions and wakes"
grep -q "^ready$" "$S/fixture.log" || fail "the fixture did not finish: $(tail -3 "$S/fixture.log")"

"$BIN" serve --port "$PORT" --client-port "$CPORT" --db "$DB" > "$S/serve.log" 2>&1 &
NODE=$!
for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1 && break; sleep 0.25; done
curl -fsS "http://127.0.0.1:$PORT/health" > /dev/null 2>&1 || fail "the node did not answer /health on $PORT"

# A's attended turn: another process holds the session's run claim.
PLACEMENT_HOLD_MS=25000 WA_SCRIPT="$ROOT/scripts/lib/placement-hold.lua" "$BIN" --db "$DB" > "$S/hold.log" 2>&1 &
HOLD=$!
for _ in $(seq 1 40); do grep -q "^held=placement-a$" "$S/hold.log" 2>/dev/null && break; sleep 0.25; done
grep -q "^held=placement-a$" "$S/hold.log" || fail "the holder never took A's claim: $(tail -3 "$S/hold.log")"

# The node's own placement tick (every 2 s) must give B a place to run and defer A.
start=$(date +%s)
B_STARTED=""; A_DEFERRED=""
while [ $(( $(date +%s) - start )) -lt "$BOUND" ]; do
  # B STARTED is the node's own words: the dispatch line names B's wake and the queue's receipt, and the run is
  # admitted to a lane. Not "B's turn finished" - this scratch node has no provider, which would only prove that.
  grep -q "dispatched wake .* of session placement-b" "$S/serve.log" && B_STARTED=1
  python3 - "$DB" <<'EOF' | grep -q "a_error=session_busy" && A_DEFERRED=1
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
a=list(c.execute("SELECT last_error FROM self_wakes WHERE session_id='placement-a'"))
print("a_error=%s" % (a[0][0] if a else ""))
EOF
  [ -n "$B_STARTED" ] && [ -n "$A_DEFERRED" ] && break
  sleep 1
done
elapsed=$(( $(date +%s) - start ))
[ -n "$B_STARTED" ] || fail "B's wake did not start within ${BOUND}s while A's session was held"
[ -n "$A_DEFERRED" ] || fail "A's resume did not defer with session_busy within ${BOUND}s"
grep -q "deferred: another run holds the session claim" "$S/serve.log" || fail "A's deferral was not named in the node's log"
# The two ran on DIFFERENT lanes: B on a run lane, A's completion on a borrowed reserve lane.
grep -q "admitted run .* of session placement-b to node-thread 2" "$S/serve.log" || fail "B did not take the background lane"
grep -q "borrows reserve node-thread 0" "$S/serve.log" || fail "A did not borrow a reserve lane"

# /health must not report any completion waiting past the bound.
health=$(curl -fsS "http://127.0.0.1:$PORT/health")
echo "$health" | python3 -c '
import json,sys
d=json.load(sys.stdin)
q=d.get("queue_sessions") or {}
over=[e for e in (q.get("entries") or []) if e.get("over_bound")]
assert not over, "waiting past the bound: " + json.dumps(over)
print("queue_ok=1 count=%s" % q.get("count"))
' || fail "a completion is waiting past the bound in /health"

echo "placement defer ok (B started in ${elapsed}s, A deferred, no lane stalled)"
