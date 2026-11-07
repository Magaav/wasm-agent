#!/usr/bin/env bash
# The real kernel, swapped under the real supervisor, with a client connected.
#
#   bash scripts/test-kernel-swap.sh
#
# Nothing here is a fake kernel except the *candidate* in step 6: `wa serve` from this checkout is started by
# `wa-watchdog run`, a client polls it, and the swap is asked for the way `scripts/upgrade.sh` asks for it
# (`wa-watchdog swap <binary> --sha256 <pin>`). What it measures, and why each number matters:
#
#   1. **a good swap** - the client's outage is measured in milliseconds, and after it the *same* session
#      reads back (its message is in `memory.db`, written before the swap and served after it): a swap
#      without the session would be a restart, not an update.
#   2. **a candidate that cannot start** - refused before anything is touched: exit 1, the kernel is the same
#      process, and the client sees no outage at all.
#   3. **a candidate that answers the proof port and fails the service port** (`selftest-kernel
#      --unhealthy-on-port`): the supervisor switches, the health gate fails, and it puts the previous
#      kernel back by itself. The client comes back, and `status.json` says `rolled_back: true` - the client
#      stayed on the old kernel, which is the promise.
#
# Hermetic by construction (AGENTS.md, the hard rule): every home is a fresh temp dir, `WASM_AGENT_HOME` is
# that dir, rendezvous and relay are empty, `WASM_AGENT_MANAGED=0`, the model URL is a stub that is never
# called, the port is chosen fresh and is never 8799, and every process this script starts is killed by the
# pid it recorded. No node of the operator is read, written, stopped or signalled.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
command -v node >/dev/null 2>&1 || { echo "test-kernel-swap: SKIPPED (node is not on PATH; the client is a node script)"; exit 0; }

fails=0
step() { printf '\n== %s\n' "$*"; }
bad() { echo "  FAIL: $*"; fails=$((fails + 1)); }
good() { echo "  ok: $*"; }

# ---- the two binaries -------------------------------------------------------------------------------
target="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
exe=""; [ "${OS:-}" = "Windows_NT" ] && exe=".exe"
find_bin() { # $1 = env override value, $2 = file name, rest = candidate dirs
  local override="$1" name="$2"; shift 2
  [ -n "$override" ] && [ -f "$override" ] && { printf '%s' "$override"; return; }
  local dir
  for dir in "$@"; do
    [ -f "$dir/$name" ] && { printf '%s' "$dir/$name"; return; }
  done
}
WA=$(find_bin "${WA_BIN:-}" "wa$exe" "$target/debug" "$target/release" "$ROOT/rust/target/debug" "$ROOT/rust/target/release")
WD=$(find_bin "${WA_WATCHDOG_BIN:-}" "wa-watchdog$exe" "$target/debug" "$target/release" "$ROOT/rust/target/debug" "$ROOT/rust/target/release")
if [ -z "$WA" ] || [ -z "$WD" ]; then
  echo "test-kernel-swap: SKIPPED (needs a built wa and wa-watchdog: WA_BIN/WA_WATCHDOG_BIN, or cargo build -p wa-host -p wa-watchdog)"
  echo "  looked in $target/debug, $target/release, rust/target/debug, rust/target/release"
  exit 0
fi
echo "kernel:   $WA"
echo "watchdog: $WD"

# Hermetic environment, before anything is started (the same rule as the gate's own checks): every
# `WASM_AGENT_*`/`WA_*`/provider variable this shell inherited is dropped, so a kernel started here cannot
# read the operator's database, provider keys or WhatsApp tokens. The ones set below are the only ones.
for name in $(env | sed -n 's/^\(WASM_AGENT_[A-Za-z0-9_]*\|WA_[A-Za-z0-9_]*\|OPENAI_[A-Za-z0-9_]*\|OPENCODE_[A-Za-z0-9_]*\|ANTHROPIC_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$name"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-kernel-swap-XXXXXX")" || exit 2
KS_HOME="$WORK/home"        # the kernel's home: memory.db lives here, so a session survives a swap
WD_HOME="$WORK/watchdog"    # the supervisor's state directory
SUP_PID=""
CLIENT_PID=""
cleanup() {
  # Only pids this script recorded, and the supervisor first so it does not restart what we stop.
  if [ -n "$CLIENT_PID" ] && kill -0 "$CLIENT_PID" 2>/dev/null; then kill "$CLIENT_PID" 2>/dev/null; fi
  if [ -n "$SUP_PID" ] && kill -0 "$SUP_PID" 2>/dev/null; then kill "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; fi
  local sp; sp=$(cat "$WD_HOME/supervisor.pid" 2>/dev/null)
  [ -n "$sp" ] && kill "$sp" 2>/dev/null
  local kp; kp=$(sed -n 's/.*"kernel_pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$WD_HOME/status.json" 2>/dev/null | head -1)
  [ -n "$kp" ] && [ "$kp" != "0" ] && kill "$kp" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

free_port() {
  node -e 'const net=require("net");const s=net.createServer();s.on("error",()=>{process.stdout.write("0")});s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>process.stdout.write(String(p)))})'
}
# How long the supervisor gives a swapped-in kernel to answer /health. Measured: this node answers in
# ~1.4s, so 10s is a wide margin and the rollback case still finishes in seconds.
SWAP_WINDOW=10000
PORT=$(free_port); CPORT=$(free_port)
while [ "$PORT" = "0" ] || [ "$PORT" = "8799" ] || [ "$PORT" = "$CPORT" ]; do PORT=$(free_port); done
echo "port:     $PORT (never 8799), client bridge $CPORT"
mkdir -p "$KS_HOME/.wasm-agent" "$WD_HOME" "$WORK/bad"
# One database, named explicitly, so the seed and the kernel cannot disagree about which file holds the
# session (a served node's default is `<home>/.wasm-agent/memory.db`; it is not given `--db`).
KS_DB="$(native "$KS_HOME/.wasm-agent/memory.db")"

export WASM_AGENT_HOME="$KS_HOME"
export WASM_AGENT_DB="$KS_DB"
export WASM_AGENT_RENDEZVOUS=""
export WASM_AGENT_RELAY=""
export WASM_AGENT_MANAGED=0
export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:1/v1"
export WASM_AGENT_LLM_API_KEY="fixture-only"
export WASM_AGENT_PROVENANCE=""
export NO_PROXY="127.0.0.1,localhost,::1"

# ---- 1. a session in memory.db, before any kernel exists --------------------------------------------
step "a session for this node (written into its own memory.db, no model call)"
SESSION_ID="swap$(date +%s)"
cat > "$WORK/seed.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local users = dofile("lua/core/users.lua")
-- A node's schema is created by setup(); a bare memory.db has no `sessions` table yet. The session is
-- created for the *node's own* user (`users.current(nil)`, which is what a served node resolves without a
-- window header) and with a known id, so the same row is readable through the node before and after.
memory.setup()
local user = users.current(nil)
local id = memory.start_session("swap-node", "seamless swap",
  { id = host.getenv("WA_SEED_SESSION"), user_id = user.id, node_id = "swap-node", title = "seamless swap" })
memory.append_turn(id, { role = "user", content = "seamless-swap-fixture", author = user.id })
print("seeded " .. id .. " for " .. tostring(user.id))
LUA
WA_SEED_SESSION="$SESSION_ID" WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT="$(native "$WORK/seed.lua")" \
  "$WA" --db "$KS_DB" >"$WORK/seed.log" 2>&1
if grep -q "seeded $SESSION_ID" "$WORK/seed.log"; then good "seeded session $SESSION_ID"; else bad "could not seed a session (see $WORK/seed.log)"; fi

# ---- 2. the supervisor config, and the supervisor ----------------------------------------------------
step "wa-watchdog init + run (the kernel is the supervisor's child)"
cat > "$WD_HOME/watchdog.conf" <<CONF
# A scratch supervisor: nothing here names the operator's home, port or binary.
kernel = $(native "$WA")
kernel_args = serve --port {port} --client-port {client_port}
port = $PORT
client_port = $CPORT
runtime_home = $(native "$KS_HOME")
work_dir = $(native "$ROOT")
start_timeout_ms = 30000
tick_ms = 100
backoff_base_ms = 200
backoff_factor = 2
backoff_max_ms = 2000
swap_health_window_ms = $SWAP_WINDOW
swap_wait_ms = 60000
stability_ms = 0
rollback_on_early_crash = false
health_miss_limit = 0
spare_port = 0
env = WASM_AGENT_HOME=$(native "$KS_HOME")
env = WASM_AGENT_RENDEZVOUS=
env = WASM_AGENT_RELAY=
env = WASM_AGENT_MANAGED=0
env = WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1/v1
env = WASM_AGENT_LLM_API_KEY=fixture-only
CONF
"$WD" run --home "$(native "$WD_HOME")" >"$WORK/supervisor.log" 2>&1 &
SUP_PID=$!
echo "  supervisor pid $SUP_PID"
wait_up() { # $1 = seconds to wait
  local deadline=$(( SECONDS + $1 ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS -m 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok":true'; then return 0; fi
    sleep 0.2
  done
  return 1
}
if wait_up 60; then good "the kernel answers /health on :$PORT"; else bad "the kernel never answered /health (see $WORK/supervisor.log)"; fi
FPID=$(sed -n 's/.*"kernel_pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$WD_HOME/status.json" 2>/dev/null | head -1)
[ -n "$FPID" ] && good "supervisor records kernel pid $FPID" || bad "no kernel_pid in status.json"

# ---- 3. the client ----------------------------------------------------------------------------------
step "a client that polls the node and reads the session through it"
cat > "$WORK/client.mjs" <<'JS'
// Polls /health and, before and after the window, reads the session back through the node's own HTTP API.
// A sample is "up" only on `ok:true`: the rollback candidate answers `ok:false`, which is exactly the state
// a client must treat as down. Only up->down transitions are outages, so a node that was still booting when
// the window opened does not count as one.
import { writeFileSync, existsSync } from "node:fs";
const [port, sessionId, outPath, stopPath, maxText] = process.argv.slice(2);
const maxMs = Number(maxText || 180000);
const base = `http://127.0.0.1:${port}`;
const started = Date.now();
async function get(path, ms = 1500) {
  const control = new AbortController();
  const timer = setTimeout(() => control.abort(), ms);
  try {
    const response = await fetch(base + path, { signal: control.signal });
    if (!response.ok) return null;
    return await response.json();
  } catch { return null; } finally { clearTimeout(timer); }
}
// The node admits reads through a bounded lane that is busy while it boots (`read_capacity_busy`, 503), so a
// single miss is not "the session is gone": ask for a few seconds before believing it.
async function sessionSeen(seconds = 15) {
  const deadline = Date.now() + seconds * 1000;
  for (;;) {
    const body = await get(`/session?id=${encodeURIComponent(sessionId)}`);
    if (body && JSON.stringify(body).includes("seamless-swap-fixture")) return true;
    if (Date.now() >= deadline) return body ? false : null;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}
const summary = { samples: 0, first_up_ms: null, last_up_ms: null, max_outage_ms: 0, outages: [], session_before: null, session_after: null };
summary.session_before = await sessionSeen();
let up = false, downAt = 0;
// The shell owns the window: the client polls until the stop file appears, so a slow proof or a rollback can
// never outlive the measurement (that is exactly how the first version of this test measured nothing).
while (Date.now() - started < maxMs && !existsSync(stopPath)) {
  const health = await get("/health");
  const ok = !!(health && health.ok === true);
  const at = Date.now() - started;
  summary.samples += 1;
  if (ok) {
    summary.last_up_ms = at;
    if (summary.first_up_ms === null) summary.first_up_ms = at;
    if (!up && downAt) {
      summary.outages.push({ down_ms: at - downAt, recovered: true });
      summary.max_outage_ms = Math.max(summary.max_outage_ms, at - downAt);
      downAt = 0;
    }
    up = true;
  } else if (up) {
    up = false;
    downAt = at;
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
}
if (downAt) {
  const stuck = Date.now() - started - downAt;
  summary.outages.push({ down_ms: stuck, recovered: false });
  summary.max_outage_ms = Math.max(summary.max_outage_ms, stuck);
}
summary.session_after = await sessionSeen();
writeFileSync(outPath, JSON.stringify(summary));
JS
node "$WORK/client.mjs" "$PORT" "$SESSION_ID" "$WORK/client.json" "$WORK/client.stop" 180000 &
CLIENT_PID=$!
sleep 4
if [ -s "$WORK/client.json" ]; then bad "the client finished too early"; fi
good "client pid $CLIENT_PID is polling :$PORT every 100ms until told to stop"

# ---- 4. a good swap of the same bytes ---------------------------------------------------------------
step "swap: the installed bytes, staged and proved, then handed over (the good case)"
cp "$WA" "$WORK/candidate-good$exe"
PIN=$(sha256sum "$WORK/candidate-good$exe" | cut -d' ' -f1)
SWAP_OUT="$WORK/swap-good.log"
"$WD" swap "$(native "$WORK/candidate-good$exe")" --sha256 "$PIN" --home "$(native "$WD_HOME")" --wait-ms 45000 >"$SWAP_OUT" 2>&1
SWAP_CODE=$?
if [ "$SWAP_CODE" = "0" ]; then good "the supervisor switched to the staged bytes (exit 0)"; else bad "the good swap failed with exit $SWAP_CODE (see $SWAP_OUT)"; fi
grep -E "proved on|is serving" "$SWAP_OUT" | sed 's/^/    /'
sleep 6

# ---- 5. a candidate that cannot start --------------------------------------------------------------
step "swap: bytes that cannot start are refused before anything is touched"
printf 'this is not an executable\n' > "$WORK/bad/wa$exe"
BADPIN=$(sha256sum "$WORK/bad/wa$exe" | cut -d' ' -f1)
before=$(sed -n 's/.*"kernel_pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$WD_HOME/status.json" | head -1)
BAD_OUT="$WORK/swap-bad.log"
"$WD" swap "$(native "$WORK/bad/wa$exe")" --sha256 "$BADPIN" --home "$(native "$WD_HOME")" --wait-ms 20000 >"$BAD_OUT" 2>&1
BAD_CODE=$?
after=$(sed -n 's/.*"kernel_pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$WD_HOME/status.json" | head -1)
[ "$BAD_CODE" = "1" ] && good "refused with exit 1 (the watchdog's own contract for a refused swap)" || bad "expected exit 1, got $BAD_CODE (see $BAD_OUT)"
[ "$before" = "$after" ] && good "the kernel is still pid $after: nothing was stopped for a candidate that cannot start" || bad "the kernel pid moved ($before -> $after)"
sleep 4

# ---- 6. a candidate that proves on the spare port and fails the service port ------------------------
step "swap: a candidate that fails the health gate on the service port is rolled back"
cp "$WD" "$WORK/candidate-unwell$exe"
UNWELL_PIN=$(sha256sum "$WORK/candidate-unwell$exe" | cut -d' ' -f1)
UNWELL_OUT="$WORK/swap-unwell.log"
"$WD" swap "$(native "$WORK/candidate-unwell$exe")" --sha256 "$UNWELL_PIN" --home "$(native "$WD_HOME")" \
  --arg selftest-kernel --arg --port --arg '{port}' --arg --unhealthy-on-port --arg "$PORT" \
  --wait-ms 30000 >>"$UNWELL_OUT" 2>&1
UNWELL_CODE=$?
[ "$UNWELL_CODE" = "1" ] && good "reported as a failure (exit 1), not as a successful swap" || bad "expected exit 1, got $UNWELL_CODE (see $UNWELL_OUT)"
sleep 3
rollback=$(grep -o '"rolled_back":[a-z]*' "$WD_HOME/status.json" | head -1)
[ "$rollback" = '"rolled_back":true' ] && good "the supervisor's record says rolled_back:true" || bad "status.json does not say rolled_back:true ($rollback)"
current=$(grep -o '"binary":"[^"]*"' "$WD_HOME/current.json" 2>/dev/null | head -1)
case "$current" in *candidate-unwell*) bad "current.json still names the candidate: $current" ;; *) good "current.json names the previous kernel again ($current)" ;; esac
if wait_up 30; then good "the node answers /health again on :$PORT"; else bad "the node did not come back after the rollback"; fi

# ---- 7. the client's own numbers --------------------------------------------------------------------
step "what the client saw"
touch "$WORK/client.stop"
wait "$CLIENT_PID" 2>/dev/null
CLIENT_PID=""
if [ -s "$WORK/client.json" ]; then
  node -e '
    const summary = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    console.log("    samples " + summary.samples + ", came up at " + summary.first_up_ms + "ms, last up at " + summary.last_up_ms + "ms");
    console.log("    outages " + JSON.stringify(summary.outages) + ", longest " + summary.max_outage_ms + "ms");
    console.log("    session before " + summary.session_before + ", after " + summary.session_after);
  ' "$WORK/client.json"
  swapped=$(node -e 'const o=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).outages;process.stdout.write(String(o[0]?o[0].down_ms:-1))' "$WORK/client.json")
  rolled=$(node -e 'const o=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).outages;process.stdout.write(String(o[1]?o[1].down_ms:-1))' "$WORK/client.json")
  every=$(node -e 'const o=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).outages;process.stdout.write(String(o.length>0&&o.every((x)=>x.recovered)))' "$WORK/client.json")
  count=$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).outages.length))' "$WORK/client.json")
  back=$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).session_after))' "$WORK/client.json")
  [ "$count" -ge 2 ] && good "the client saw both interruptions ($count outages)" || bad "expected two interruptions, the client saw $count"
  # The number the claim is about: a successful swap, measured from outside. The rollback's outage is the
  # health window by design (the supervisor must wait before it decides the candidate is unwell), so it is
  # bounded by that window plus the previous kernel's start - not by the same number.
  [ "$swapped" -ge 0 ] && [ "$swapped" -lt 10000 ] && good "the successful swap cost the client ${swapped}ms (bound 10000)" || bad "the successful swap cost the client ${swapped}ms, over the 10s bound"
  [ "$rolled" -ge 0 ] && [ "$rolled" -lt 40000 ] && good "the rolled-back swap cost ${rolled}ms (health window ${SWAP_WINDOW}ms plus the rollback's start; bound 40000)" || bad "the rolled-back swap cost ${rolled}ms, over the 40s bound"
  [ "$every" = "true" ] && good "every outage ended with the node answering again" || bad "an outage never recovered"
  [ "$back" = "true" ] && good "the session reads back through the post-swap node: the session view continues" || bad "the session did not read back after the swap ($back)"
else
  bad "the client wrote no summary (see $WORK/client.json)"
fi

# ---- 8. the supervisor's own account ---------------------------------------------------------------
step "the supervisor wrote down what happened"
"$WD" status --json --home "$(native "$WD_HOME")" | sed 's/^/    /' | head -5
echo
echo "state $(sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$WD_HOME/status.json") / restarts $(sed -n 's/.*"restarts":\([0-9]*\).*/\1/p' "$WD_HOME/status.json") (a swap is not a crash: a restart here would mean the supervisor saw its kernel die outside a swap)"
restarts=$(sed -n 's/.*"restarts":\([0-9]*\).*/\1/p' "$WD_HOME/status.json")
[ "$restarts" = "0" ] && good "restarts stayed 0: every kernel change went through the swap handoff" || bad "restarts is $restarts: the supervisor restarted a kernel outside a swap"

echo
if [ "$fails" = "0" ]; then echo "kernel swap: ALL PASS"; else echo "kernel swap: $fails FAILED"; fi
exit $([ "$fails" = "0" ] && echo 0 || echo 1)
