#!/usr/bin/env bash
# A PROBE FAN-OUT IS BOUNDED (item 0 of the node-ops round 3, after 19/11).
#
#   bash scripts/test-nodes-probe-bound.sh
#
# WHAT HAPPENED. 'wa nodes' probes one child per peer. Before c31f9ab6 a probe child probed AGAIN (M.probe
# -> M.find -> M.list with no exclusion), so every child started one child per peer: a fork TREE. On 19/11
# one command left 1,653 processes behind and the kernel killed wa-serve in this mission's own cgroup
# (constraint=CONSTRAINT_MEMCG, the killed process holding only 45 MB - a crowd, not a leak).
#
# WHY THIS ROW EXISTS AND scripts/test-nodes-probe-parallel.lua IS NOT ENOUGH. That row stubs the host and
# counts host.operation STARTS, so it proves the code does not ASK to fan out. It cannot see what the
# machine actually PAID: a child that fans out for real is a real process, and only a real one shows it.
#
# WHAT IS MEASURED, from the kernel rather than from the code's own story: the run happens inside a systemd
# user scope with memory accounting on, and the scope's own cgroup counters are read afterwards
# (pids.peak = the most processes alive at any moment, memory.peak = the most bytes charged to them). The
# roster comes from a stub rendezvous serving six peers that never answer.
#
# MEASURED ON THIS NODE (avell, 19/11), this tree against the parent commit in the same shape:
#   this tree:      1 process generation,   6 operations, pids.peak 20,  134 MB
#   c31f9ab6^:     22 process generations, 129 operations, pids.peak 77, 1297 MB
# The four bounds below sit between the two, so the row goes red when the recursion comes back; it is not a
# row that can only pass. WA_PROBE_BOUND_LUA_ROOT points the run at another lua/ tree, which is how the red
# half was reproduced (an ordinary run never sets it).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2

PEERS=6
MAX_GENERATIONS=1     # measured: 1 here, 22 before the fix
MAX_OPERATIONS=6      # measured: 6 here (one per peer), 129 before the fix
MAX_PIDS=40           # measured: 20 here, 77 before the fix
MAX_MEM_MB=512        # measured: 134 here, 1297 before the fix

skip() { echo "SKIP test-nodes-probe-bound: $*"; exit 0; }
refuse() { echo "REFUSED test-nodes-probe-bound: $*" >&2; exit 2; }
fail() { echo "FAIL test-nodes-probe-bound: $*" >&2; exit 1; }

# WHY A SKIP AND NOT A PASS: the bound is read from cgroup v2 counters, which exist on Linux with a systemd
# user manager and nowhere else (the fast path also runs on macOS and Windows). A machine that cannot
# measure says so by name; it never passes by staying silent.
command -v systemd-run >/dev/null 2>&1 || skip 'no systemd-run, so no cgroup to read pids.peak/memory.peak from'
command -v node >/dev/null 2>&1 || skip 'no node on PATH for the rendezvous stub'
command -v python3 >/dev/null 2>&1 || skip 'no python3 on PATH to read the operation records'
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$(command -v wa || true)"
[ -x "$BIN" ] || skip 'no wa binary to run the probe with'
LUA_ROOT="${WA_PROBE_BOUND_LUA_ROOT:-$ROOT}"

# The scratch root is deliberately NOT $TMPDIR: on this node TMPDIR points INSIDE the operator store
# (~/.wasm-agent/tmp), and a home under it is exactly what the guard below must refuse. /tmp is outside.
SCRATCH="${WA_TEST_ROOT:-$(mktemp -d /tmp/wa-probe-bound.XXXXXX)}"
mkdir -p "$SCRATCH/home/.wasm-agent" || refuse "cannot create a scratch home under $SCRATCH"
stub_pid=
cleanup() { [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$SCRATCH/home" || exit 2

# The stub rendezvous: GET /nodes answers six peers that will never answer a call. Every POST is HELD so a
# child has to wait - a probe that fans out needs time to do it, and an instant refusal would hide the tree
# behind a 503.
cat > "$SCRATCH/rendezvous.mjs" <<'JS'
import http from 'node:http'
const peers = ['a','b','c','d','e','f'].map(c => ({ node_id: c.repeat(16), name: c, public_key: 'aa' }))
const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url.split('?')[0] === '/nodes') {
    const body = JSON.stringify({ ok: true, nodes: peers })
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) })
    res.end(body)
    return
  }
  req.resume()
  setTimeout(() => { res.writeHead(503, { 'content-length': '0' }); res.end() }, 2000)
})
server.listen(0, '127.0.0.1', () => console.log(server.address().port))
JS
node "$SCRATCH/rendezvous.mjs" > "$SCRATCH/port" 2>"$SCRATCH/rendezvous.err" &
stub_pid=$!
for _ in $(seq 1 200); do [ -s "$SCRATCH/port" ] && break; sleep 0.05; done
port=$(head -1 "$SCRATCH/port" 2>/dev/null)
[ -n "$port" ] || refuse "the rendezvous stub printed no port: $(head -c 300 "$SCRATCH/rendezvous.err" 2>/dev/null)"
kill -0 "$stub_pid" 2>/dev/null || refuse 'the rendezvous stub is not running'

# The measured run, inside its own scope.
cat > "$SCRATCH/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -uo pipefail
SCRATCH="$1"; port="$2"; LUA_ROOT="$3"; BIN="$4"
cg=$(cut -d: -f3 /proc/self/cgroup)
[ -n "$cg" ] || { echo 'probe_bound_no_cgroup'; exit 3; }
WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$LUA_ROOT" WASM_AGENT_MANAGED=0 \
  WASM_AGENT_DB="$SCRATCH/home/t.db" WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$port" \
  timeout 120 "$BIN" --db "$SCRATCH/home/t.db" nodes > "$SCRATCH/nodes.json" 2> "$SCRATCH/nodes.err"
echo "run_exit=$?"
sleep 1
pids=$(cat "/sys/fs/cgroup$cg/pids.peak" 2>/dev/null) || pids=
mem=$(cat "/sys/fs/cgroup$cg/memory.peak" 2>/dev/null) || mem=
[ -n "$pids" ] || { echo 'probe_bound_no_pids_peak'; exit 3; }
[ -n "$mem" ] || { echo 'probe_bound_no_memory_peak'; exit 3; }
echo "pids_peak=$pids"
echo "mem_peak_mb=$(( mem / 1048576 ))"
INNER
chmod +x "$SCRATCH/inner.sh"
measured=$(systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 -p MemoryAccounting=yes \
  /bin/bash "$SCRATCH/inner.sh" "$SCRATCH" "$port" "$LUA_ROOT" "$BIN" 2>&1)
scope_code=$?
case "$measured" in
  *probe_bound_no_cgroup*|*probe_bound_no_pids_peak*|*probe_bound_no_memory_peak*)
    skip "this kernel does not expose pids.peak/memory.peak inside a user scope, so no bound can be read" ;;
esac
[ "$scope_code" = 0 ] || fail "the measured scope exited $scope_code: $(printf '%s' "$measured" | tail -2 | tr '\n' ' ')"
run_exit=$(printf '%s\n' "$measured" | sed -n 's/^run_exit=//p' | tail -1)
pids_peak=$(printf '%s\n' "$measured" | sed -n 's/^pids_peak=//p' | tail -1)
mem_peak_mb=$(printf '%s\n' "$measured" | sed -n 's/^mem_peak_mb=//p' | tail -1)
[ -n "$pids_peak" ] && [ -n "$mem_peak_mb" ] || refuse "the measured scope printed no counters: $(printf '%s' "$measured" | tr '\n' ' ')"
[ "${run_exit:-0}" = 0 ] || fail "\`wa nodes\` exited $run_exit against six unreachable peers: $(tail -3 "$SCRATCH/nodes.err" 2>/dev/null | tr '\n' ' ')"

# THE RUN MUST HAVE PROBED SOMETHING, or a green bound would only mean the stub was never reached - unknown
# is not yes. The roster line is read from the node's own answer.
answered=$(python3 - "$SCRATCH/nodes.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print('unreadable')
    raise SystemExit
nodes = data.get('nodes') or []
peers = [n for n in nodes if not n.get('local_node')]
print('%d %d' % (len(nodes), len(peers)))
PY
)
case "$answered" in
  unreadable) fail "the node printed no readable roster, so nothing was probed ($SCRATCH/nodes.json)" ;;
esac
total_nodes="${answered%% *}"
peer_nodes="${answered##* }"
expected=$(( PEERS + 1 ))
[ "$total_nodes" = "$expected" ] || fail "the roster named $total_nodes nodes, expected $expected (this node plus $PEERS peers): a run that never saw the peers cannot bound their probing"
[ "$peer_nodes" = "$PEERS" ] || fail "the roster named $peer_nodes peers, expected $PEERS: the stub was not read as the roster"

# ONE GENERATION: every operation record carries the process that started it. A child that fans out shows
# up as records from MORE than one process; the probe child itself is not supposed to start any.
generations=$(python3 - "$SCRATCH/home/.wasm-agent/operations" <<'PY'
import glob, json, os, sys
owners = set()
for path in glob.glob(os.path.join(sys.argv[1], 'op-*', 'state.json')):
    try:
        owners.add(json.load(open(path)).get('owner_process_id'))
    except Exception:
        continue
print(len(owners))
PY
)
operations=$(find "$SCRATCH/home/.wasm-agent/operations" -maxdepth 1 -name 'op-*' -type d 2>/dev/null | wc -l)

problems=()
[ "$generations" -le "$MAX_GENERATIONS" ] || problems+=("$generations process generations started probe children (bound $MAX_GENERATIONS)")
[ "$operations" -le "$MAX_OPERATIONS" ] || problems+=("$operations supervised operations for $PEERS peers (bound $MAX_OPERATIONS)")
[ "$pids_peak" -le "$MAX_PIDS" ] || problems+=("pids.peak $pids_peak (bound $MAX_PIDS)")
[ "$mem_peak_mb" -le "$MAX_MEM_MB" ] || problems+=("memory.peak ${mem_peak_mb} MB (bound $MAX_MEM_MB MB)")
if [ "${#problems[@]}" -gt 0 ]; then
  fail "$(printf '%s; ' "${problems[@]}")- the probe fan-out is growing again (19/11: 1,653 processes and 23 GB)"
fi

echo "nodes probe bound ok: $PEERS unreachable peers probed in $operations operation(s) from $generations process generation(s), pids.peak $pids_peak (bound $MAX_PIDS), memory.peak ${mem_peak_mb} MB (bound $MAX_MEM_MB MB)"
