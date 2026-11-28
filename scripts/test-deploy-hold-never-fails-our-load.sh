#!/usr/bin/env bash
# AN INSTALL UNDER THE FACTORY'S NORMAL LOAD WAITS OR PROCEEDS; IT NEVER FAILS AT THE BOUND
# (deploy-hold-never-fails-our-load, Fable 23/11; this row is item 4 of that brief - the real shape, with N stated).
#
# MEASURED 23/11: two installs FAILED at the 180 s bound. One of them (edad0d39) held on a session the node had ITSELF
# paused for the deploy, whose only remaining activity was that session's child completion - a mutual wait. The other
# (7865a08e) failed because the node reported itself busy and named no holder at all.
#
# WHAT THIS ROW DOES, on a scratch home and a stub node, with no real node and no install:
#   * serves `/health` for a node that is busy with THREE sessions whose only queued work is a child completion each - the
#     measured shape;
#   * runs the real sentinel with `WA_DEPLOY_HOLD_BOUND=5` (a small bound, so the defect would fire in seconds);
#   * queues one request of its own and watches it for N = 25 s.
#
# THE ASSERTION IS THE DEFECT: past the bound the request must NOT be parked in `failed/`. Before this brief it was, with
# `bound_failed: true`; now the hold names each session and keeps waiting (or proceeds when the node goes quiet).
#
# Fences: HOME and WASM_AGENT_HOME are the scratch dir (the sentinel's state, the queue and the request all live THERE),
# the only port bound is the stub's, the provider and vault variables are cleared, and no deploy is ever started - the stub
# node never goes quiet, so the request cannot proceed to an install.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
SENTINEL="${WA_SENTINEL_BIN:-}"
[ -n "$SENTINEL" ] && [ -x "$SENTINEL" ] || {
  for candidate in "$HOME/.cargo/bin/wa-sentinel" "$HOME/.local/bin/wa-sentinel" "$(dirname "${WA_BIN:-/nonexistent}")/wa-sentinel"; do
    [ -x "$candidate" ] && { SENTINEL="$candidate"; break; }
  done
}
[ -n "$SENTINEL" ] || { echo "deploy-hold: SKIP (no wa-sentinel binary: set WA_SENTINEL_BIN)" >&2; exit 0; }
command -v node >/dev/null 2>&1 || { echo "deploy-hold: SKIP (node is not on PATH)" >&2; exit 0; }

S="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-hold.XXXXXX")"


cleanup() { [ "${KEEP:-0}" = 1 ] && { echo "deploy-hold: fixture kept at $S" >&2; return; }; kill "${STUB:-}" "${WATCH:-}" 2>/dev/null; wait "${STUB:-}" 2>/dev/null; chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT
PORT="$(( 20000 + ($$ % 20000) ))"
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

# ---- the stub node: busy, with three sessions whose only queued work is a child completion ---------------------------------
# ---- the managers are STUBS: nothing in this row may reach a real systemd (28/11) ----------------------------------
mkdir -p "$S/bin" "$S/manager-calls"
for tool in systemd-run systemctl; do
  cat > "$S/bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "$S/manager-calls/calls.txt"
exit 0
STUB
  chmod +x "$S/bin/$tool"
done
ok "systemd-run and systemctl are recording stubs on PATH (no real manager can be reached)"

cat > "$S/health.mjs" <<'NODE'
import http from 'node:http';
const port = Number(process.argv[2]);
const sessions = ['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333'];
const health = {
  ok: true,
  port,
  node_threads: sessions.map((session, index) => ({ session, label: 'POST /chat', busy_ms: 120000 + index })),
  queue: 0,
  queue_sessions: { wait_bound_ms: 600000, entries: sessions.map((session) => ({ session, kind: 'completion', waited_ms: 500, expired: false })) },
  subagents: { running: 0, queued: 0 },
  current: null,
  operation_overdue: false,
  run_journal_failed: false,
  worker: 'alive',
};
http.createServer((request, response) => {
  if (request.url.startsWith('/health')) { response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(health)); return; }
  response.writeHead(404).end('{}');
}).listen(port, '127.0.0.1');
NODE
node "$S/health.mjs" "$PORT" & STUB=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || { echo "deploy-hold: SKIP (the stub node did not answer)" >&2; exit 0; }
ok "a stub node answers /health with three sessions whose queued work is a child completion each"



# ---- the sentinel, on its own home, with a five-second bound --------------------------------------------------------
mkdir -p "$S/home" "$S/missions"
env -u WA_VAULT -u WA_PROVIDER -u OPENAI_API_KEY \
  PATH="$S/bin:$PATH" HOME="$S/home" WASM_AGENT_HOME="$S/home" WASM_AGENT_MANAGED=0 WASM_AGENT_PORT="$PORT" \
  WA_DEPLOY_HOLD_BOUND=5 WA_SENTINEL_SUPERVISOR=test \
  "$SENTINEL" watch >"$S/sentinel.log" 2>&1 & WATCH=$!
sleep 2
kill -0 "$WATCH" 2>/dev/null || { echo "deploy-hold: SKIP (the sentinel did not start: $(tail -1 "$S/sentinel.log"))" >&2; exit 0; }
ok "the sentinel runs on a scratch home with WA_DEPLOY_HOLD_BOUND=5"

# ---- one request of our own, then watch it past the bound ---------------------------------------------------------
env PATH="$S/bin:$PATH" HOME="$S/home" WASM_AGENT_HOME="$S/home" WASM_AGENT_PORT="$PORT" "$SENTINEL" request deploy --reason 'deploy-hold row' >/dev/null 2>&1 || true
# THE NODE PAUSED these sessions for the coming deploy - the measured mutual wait. Without the pause record the same
# /health shape is just three sessions working, and failing the request would be correct; with it, their only activity is
# the queued child completion and the install cannot hurt them.
mkdir -p "$S/home/.wasm-agent/deploy-paused"
for session in 11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222 33333333-3333-3333-3333-333333333333; do
  # `since` must be at or after the moment the request was queued: `paused_since` ignores a record that predates it (that
  # is how a pause belonging to the PREVIOUS deploy is treated), and a record written in the same second as the request is
  # a coin flip. One second of slack, measured 28/11 when the same shape passed or failed on that coin.
  printf '{"session":"%s","since":%s,"reason":"deploy-hold row"}\n' "$session" "$(( $(date +%s) + 1 ))" > "$S/home/.wasm-agent/deploy-paused/$session.json"
done
ok "three sessions recorded a pause FOR THIS request (written after it was queued)"

WAITED=0
while [ "$WAITED" -lt 25 ]; do
  sleep 1; WAITED=$((WAITED+1))
  [ -n "$(ls "$S/home/.wasm-agent/sentinel/failed" 2>/dev/null)" ] && break
done
ok "the request was watched for ${WAITED}s, past the 5 s bound"



if [ -n "$(ls "$S/home/.wasm-agent/sentinel/failed" 2>/dev/null)" ]; then
  bad "the request FAILED at the bound: $(ls "$S/home/.wasm-agent/sentinel/failed" | tr '\n' ' ') - a busy node with named sessions must not fail it"
else
  ok "nothing was parked in failed/ past the bound"
fi

if grep -qE "held|holding|waiting" "$S/sentinel.log"; then
  ok "and the hold says it is waiting: $(grep -oE 'held[^"]*' "$S/sentinel.log" | head -1 | cut -c1-70)"
else
  bad "the sentinel never said it was holding (log: $(tail -2 "$S/sentinel.log" | tr '\n' ' ' | cut -c1-120))"
fi

kill "$WATCH" 2>/dev/null; wait "$WATCH" 2>/dev/null

# THE ARGV RULE (28/11): a non-root sentinel must never build a system-manager command, because on a desktop that is
# polkit - a password prompt per attempt - and a granted prompt runs the deploy AS ROOT.
if [ "$(id -u)" != 0 ] && [ -f "$S/manager-calls/calls.txt" ]; then
  if grep -E '^systemd-run ' "$S/manager-calls/calls.txt" | grep -vq -- '--user'; then
    bad "a systemd-run argv without --user was built by a non-root sentinel: $(grep -E '^systemd-run ' "$S/manager-calls/calls.txt" | grep -v -- '--user' | head -1)"
  else
    ok "every systemd-run argv carried --user (a non-root sentinel can never ask the system manager)"
  fi
else
  ok "no systemd-run argv reached a manager at all"
fi

if [ "$failed" -gt 0 ]; then echo "deploy-hold: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "deploy-hold ok ($checks checks)"
