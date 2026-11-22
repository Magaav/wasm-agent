#!/usr/bin/env bash
# A held deploy is not a stuck one: the sentinel names who holds the node, and past its bound it proceeds over
# the sessions that have PAUSED - and over nothing else (22/11).
#
#   bash scripts/test-deploy-bound.sh
#
# Measured twice on this laptop (22/11, ~/.wasm-agent/sentinel/sentinel.log): the deploy for 8082b42e was held
# with `the node is busy: a run, a subagent or an operation is in flight` from 10:01:24Z to 10:31:48Z - thirty
# minutes - and `wa-sentinel status` named no session at all, so the operator had to park four sessions by hand.
# Nothing bounded the wait either.
#
# This script drives the REAL sentinel binary of this tree against a stub `/health` (loopback only):
#
#   1. `status` names each holder: which session, what it is doing, for how long, and whether it has paused for
#      the request it is holding up;
#   2. before the bound, a held deploy is held - the installer does not run;
#   3. past the bound, a holder that is still WORKING is reported by name and NOT passed over;
#   4. past the bound, when every holder has recorded a pause for this request, the install runs;
#   5. a holder that names no session (a subagent, a queued turn) is never passed over, and neither is a node that
#      reports itself busy and names nobody.
#
# Hermetic: its own WASM_AGENT_HOME under $TMPDIR, a stub /health on loopback, a fake installer that only writes
# its own log, no rendezvous, no relay, no provider, and it signals only PIDs it started.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-bound-XXXXXX")"
HOME_DIR="$WORK/home"
STUB_PID=""
cleanup() {
  local status=$?
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  [ "$status" != "0" ] && echo "  fixture kept at $WORK" >&2
  [ "$status" = "0" ] && rm -rf "$WORK"
  return "$status"
}
trap cleanup EXIT

fails=0
step() { printf '  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
ok()   { printf '    ok: %s\n' "$*"; }
want() { case "$1" in *"$2"*) ok "$3" ;; *) fail "$3: expected '$2' in: $1" ;; esac; }
unwant() { case "$1" in *"$2"*) fail "$3: unexpected '$2' in: $1" ;; *) ok "$3" ;; esac; }

# THE BINARY OF THIS TREE, never another commit's: a sentinel that predates the bound would pass every check
# below by never proceeding, and one from a newer tree would prove nothing about this diff (scripts/lib/fast-binary.sh
# makes the same point about `wa`).
SENTINEL="${WA_SENTINEL_BIN:-}"
if [ -z "$SENTINEL" ]; then
  for candidate in "${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa-sentinel" "$ROOT/rust/target/debug/wa-sentinel"; do
    [ -x "$candidate" ] && { SENTINEL="$candidate"; break; }
  done
fi
if [ -z "$SENTINEL" ]; then
  CARGO="$(command -v cargo || true)"
  [ -z "$CARGO" ] && [ -x "$HOME/.cargo/bin/cargo" ] && CARGO="$HOME/.cargo/bin/cargo"
  if [ -z "$CARGO" ]; then
    echo "deploy bound: SKIP (no wa-sentinel for this tree and no cargo to build one)" >&2
    exit 0
  fi
  step "building this tree's wa-sentinel ($CARGO)"
  if ! CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}" "$CARGO" build --offline \
       --manifest-path rust/wa-sentinel/Cargo.toml >"$WORK/build.log" 2>&1; then
    echo "deploy bound: SKIP (this tree's wa-sentinel did not build: tail of $WORK/build.log)" >&2
    tail -5 "$WORK/build.log" >&2
    exit 0
  fi
  SENTINEL="${CARGO_TARGET_DIR:-$ROOT/rust/target}/debug/wa-sentinel"
fi
[ -x "$SENTINEL" ] || { echo "deploy bound: SKIP (no executable sentinel at $SENTINEL)" >&2; exit 0; }
step "sentinel: $SENTINEL"

# The scratch home. Nothing here may be the operator's own store (scripts/lib/scratch-home.sh).
mkdir -p "$HOME_DIR/.wasm-agent" || { echo "deploy bound: SKIP (cannot create a scratch home)" >&2; exit 0; }
export WASM_AGENT_HOME="$HOME_DIR"
unset WASM_AGENT_RENDEZVOUS WASM_AGENT_RELAY WASM_AGENT_DB

# A port nothing else on this machine has: the stub asks the kernel for a free one and says which.
PORT_FILE="$WORK/port"
cat > "$WORK/health.mjs" <<'JS'
import { createServer } from 'node:http';
import { readFileSync, appendFileSync, writeFileSync } from 'node:fs';
const body = process.argv[2];
const count = process.argv[3];
writeFileSync(count, '');
const server = createServer((request, response) => {
  appendFileSync(count, request.url + '\n');
  response.writeHead(200, { 'content-type': 'application/json' });
  response.end(readFileSync(body, 'utf8'));
});
server.listen(0, '127.0.0.1', () => { writeFileSync(process.argv[4], String(server.address().port)); });
JS
HEALTH_BODY="$WORK/health.json"
HEALTH_COUNT="$WORK/health.count"
if command -v node >/dev/null 2>&1; then
  step "stub /health (node)"
  printf '%s' '{"ok":true,"current":null,"queue":0,"operation_overdue":false,"workers":[],"node_threads":[],"subagents":{"queued":0,"running":0,"active":0}}' > "$HEALTH_BODY"
  node "$WORK/health.mjs" "$HEALTH_BODY" "$HEALTH_COUNT" "$PORT_FILE" >"$WORK/health.log" 2>&1 &
  STUB_PID=$!
  for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
  if [ ! -s "$PORT_FILE" ]; then fail "the stub /health never named a port: $(cat "$WORK/health.log")"; exit 1; fi
  export WASM_AGENT_PORT="$(cat "$PORT_FILE")"
  ok "stub /health on 127.0.0.1:$WASM_AGENT_PORT"
else
  echo "deploy bound: SKIP (no node on this host: the stub /health is the node here)" >&2
  exit 0
fi

# The installer: it writes its own log, and nothing else. The sentinel spawns it only when it performs the
# request, so "did the installer run" is exactly "did the deploy proceed".
INSTALLER_LOG="$WORK/installer.log"
cat > "$WORK/installer.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "installed \$*" >> "$INSTALLER_LOG"
SH
chmod +x "$WORK/installer.sh"
export WA_SENTINEL_DEPLOY="$WORK/installer.sh"
export WA_SENTINEL_SCRIPTS="$WORK"
# This row runs inside somebody's session, and the sentinel refuses to start a deploy from a unit that cannot be
# shown to own it (role::placement) - correctly. No supervisor owns this scratch watcher, and its own answer is
# the one to give (`WA_SENTINEL_SUPERVISOR=none`, the message the refusal itself prints).
export WA_SENTINEL_SUPERVISOR=none

SENT_DIR="$HOME_DIR/.wasm-agent/sentinel"
BOX="$SENT_DIR/requests"
PAUSED="$HOME_DIR/.wasm-agent/deploy-paused"
SESSION="8082b42e-1111-2222-3333-444455556666"
SHA="8082b42e11112222333344445555666677778888"

busy_body() { # <health json with holders>
  printf '%s' "$1" > "$HEALTH_BODY"
}
# Two holders, the shape the node answers with when two worker turns are running: `node_threads` carries the
# session and how long it has been busy, `current` repeats the aggregate view.
BUSY='{"ok":true,"queue":0,"operation_overdue":false,"current":{"label":"POST /chat","ms":134000,"session":"8082b42e-1111-2222-3333-444455556666"},"node_threads":[{"id":0,"session":"8082b42e-1111-2222-3333-444455556666","label":"POST /chat","state":"busy","busy_ms":134000},{"id":2,"session":"deadbeef-1111-2222-3333-444455556666","label":"POST /chat","state":"busy","busy_ms":9000}],"workers":[{"id":0,"session":"8082b42e-1111-2222-3333-444455556666","label":"POST /chat","state":"busy","busy_ms":134000},{"id":2,"session":"deadbeef-1111-2222-3333-444455556666","label":"POST /chat","state":"busy","busy_ms":9000}],"subagents":{"queued":0,"running":0,"active":0}}'
SUBAGENT_BUSY='{"ok":true,"queue":0,"operation_overdue":false,"current":null,"node_threads":[],"workers":[],"subagents":{"queued":1,"running":2,"active":3}}'
# Busy, and with nothing that could be a session: an overdue operation is work the node reports without naming
# who is doing it, so there is nothing this request could point at and say "it paused".
NAMED_NOTHING='{"ok":true,"queue":0,"operation_overdue":true,"current":null,"node_threads":[],"workers":[],"subagents":{"queued":0,"running":0,"active":0}}'
IDLE='{"ok":true,"queue":0,"operation_overdue":false,"current":null,"node_threads":[],"workers":[],"subagents":{"queued":0,"running":0,"active":0}}'

# A deploy request in the box, as the agent's request writer leaves it: verb, target, when it was asked for.
write_request() { # <id> <queued-at>
  mkdir -p "$BOX"
  # No `expected_sha`: a legacy request, which is what this row needs - a protocol request is first held by the
  # deploy protocol's own readiness (deploy_protocol::ready), and that hold is a different subject. The commit it
  # would install is recorded the way the older writer recorded it.
  printf '{"verb":"deploy","target_commit":"%s","queued_at":%s,"reason":"land the fix Victor is waiting for"}\n' \
    "$SHA" "$2" > "$BOX/$1.json"
}
clear_request() { rm -f "$BOX"/*.json; }
pause_record() { # <session> <since> [file-name]
  mkdir -p "$PAUSED"
  printf '{"session":"%s","since":%s,"to":"%s","source":"request"}\n' "$1" "$2" "$SHA" \
    > "$PAUSED/${3:-$1}.json"
}
status_out() { "$SENTINEL" status 2>&1; }
once_out()  { "$SENTINEL" once 2>&1; }
ran()       { [ -s "$INSTALLER_LOG" ]; }
installs()  { [ -s "$INSTALLER_LOG" ] && wc -l < "$INSTALLER_LOG" | tr -d ' ' || echo 0; }

NOW="$(date +%s)"
# The request was asked for a while ago: a bound is measured from the queue time, and a request written with
# "now" would never be past it (the sentinel's own bound is seconds, not milliseconds).
ASKED="$((NOW - 30))"
# The sentinel's own records: a request the operator asked for, and a node that is busy with two sessions.
clear_request
rm -rf "$PAUSED"
busy_body "$BUSY"
write_request "1700000000000000000-4242-00000000000000000000" "$ASKED"

step "status names each holder, and says none of them has paused yet"
out="$(status_out)"
want "$out" "requests:  1 waiting" "the request is named as waiting"
want "$out" "held: node busy" "and why it has not run"
want "$out" "busy:      2 holder(s) of the node" "the holders are counted"
want "$out" "session 8082b42e  POST /chat 2m  working" "the first holder is named, with its label and how long"
want "$out" "session deadbeef  POST /chat 9s  working" "the second too"
want "$out" "past 180s the sentinel proceeds if every holder has paused" "and the bound is printed"
want "$out" "the request has waited" "with how long it has waited"
# The holder that keeps the node busy is the session the request is waiting for, not the one that merely
# happens to be second in the snapshot: the two lines are different on purpose.

step "a holder that recorded a pause for THIS request is named as paused"
pause_record "$SESSION" "$NOW"
out="$(status_out)"
want "$out" "session 8082b42e  POST /chat 2m  paused for the deploy" "the paused holder says so"
want "$out" "session deadbeef  POST /chat 9s  working" "and the other is still working"

step "before the bound: held, and the installer does not run"
rm -f "$INSTALLER_LOG"
out="$(WA_DEPLOY_HOLD_BOUND=600 once_out)"
want "$out" "request(s) handled" "the tick answered"
unwant "$(installs)" "1" "nothing was installed"
[ -f "$BOX/1700000000000000000-4242-00000000000000000000.json" ] \
  && ok "the request is still in the box" || fail "the request left the box before its bound"
grep -q 'maintenance-deferred' "$SENT_DIR/sentinel.log" \
  && ok "the hold is written down" || fail "the hold left no line in the log"

step "past the bound with a WORKING holder: still held, and the reason names the session"
rm -f "$INSTALLER_LOG" "$PAUSED"/*.json
out="$(WA_DEPLOY_HOLD_BOUND=1 once_out)"
unwant "$(installs)" "1" "a working holder is not passed over"
grep -q 'still working' "$SENT_DIR/sentinel.log" \
  && ok "the log names the session that blocks it" || fail "the hold did not say which session is still working"

step "past the bound with every holder paused: the install runs"
pause_record "$SESSION" "$((NOW + 1))"
pause_record "deadbeef-1111-2222-3333-444455556666" "$((NOW + 1))"
rm -f "$INSTALLER_LOG"
out="$(WA_DEPLOY_HOLD_BOUND=1 once_out)"
if [ "$(installs)" = "1" ]; then ok "the installer ran once"; else fail "expected one install, saw $(installs): $out"; fi
grep -q 'hold-bound-passed' "$SENT_DIR/sentinel.log" \
  && ok "and the decision is written down" || fail "the bound being passed left no line in the log"

step "a pause recorded BEFORE the request was queued does not count"
clear_request; rm -f "$INSTALLER_LOG"
busy_body "$BUSY"
write_request "1700000000000000001-4242-00000000000000000000" "$ASKED"
pause_record "$SESSION" "$((NOW - 500))"
pause_record "deadbeef-1111-2222-3333-444455556666" "$((NOW - 500))"
out="$(WA_DEPLOY_HOLD_BOUND=1 once_out)"
unwant "$(installs)" "1" "a pause from an earlier deploy says nothing about this one"

step "a holder that names no session is never passed over"
clear_request; rm -f "$INSTALLER_LOG"
rm -rf "$PAUSED"
busy_body "$SUBAGENT_BUSY"
write_request "1700000000000000002-4242-00000000000000000000" "$ASKED"
out="$(WA_DEPLOY_HOLD_BOUND=1 once_out)"
unwant "$(installs)" "1" "a subagent holder blocks the bound"
grep -q 'names no session' "$SENT_DIR/sentinel.log" \
  && ok "the log says why it could not pass" || fail "the log did not name the reason"

step "a node that reports itself busy and names nobody is not passed over"
clear_request; rm -f "$INSTALLER_LOG"
busy_body "$NAMED_NOTHING"
write_request "1700000000000000003-4242-00000000000000000000" "$ASKED"
out="$(WA_DEPLOY_HOLD_BOUND=1 once_out)"
unwant "$(installs)" "1" "nothing proves a pause, so nothing is passed over"
grep -q 'names no holder' "$SENT_DIR/sentinel.log" \
  && ok "the log says the node named no holder" || fail "the log did not say it"

step "an idle node needs no bound at all: the request runs at once"
clear_request; rm -f "$INSTALLER_LOG"
busy_body "$IDLE"
write_request "1700000000000000004-4242-00000000000000000000" "$ASKED"
out="$(WA_DEPLOY_HOLD_BOUND=600 once_out)"
if [ "$(installs)" = "1" ]; then ok "an idle node runs the deploy without waiting for any bound"; else fail "an idle node did not run the deploy: $out"; fi

if [ "$fails" -ne 0 ]; then
  echo "deploy bound: $fails failure(s)" >&2
  exit 1
fi
echo "deploy bound ok"
