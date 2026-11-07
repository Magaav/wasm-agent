#!/usr/bin/env bash
# The mesh on a *running* node: keygen/sign/show, live enable and disable, and a call that flows.
#
#   bash scripts/test-mesh-live.sh [--offline]
#
# What it measures, in order, all with the real `wa` binary from this checkout:
#
#   1. **keygen + sign + show.** `wa fleet keygen` creates the fleet key (one explicit path, mode 0600
#      claimed only where the host has POSIX modes), refuses the node home and a git checkout;
#      `wa fleet sign` signs the canonical bytes and leaves the template alone; `wa fleet show`
#      verifies and prints the levels; a *tampered* roster is refused with exit 1 and
#      `roster_unverified:bad_signature`.
#   2. **live enable, three times, on one running `wa serve`.** The node starts with a `mesh` section
#      that is off and has no port: its mesh port is closed. The script then rewrites the node's own
#      `policy.json` the way `wa fleet push-roster` writes it (enabled, the roster, the port) and the
#      listener mounts **without a restart** — the process id never changes — answers `/mesh/health`,
#      and a mesh call from a second node's home is admitted by the roster
#      (`decision=allow transport=direct`) and answered by the target, signed.
#   3. **live disable.** The same file turns it off; the socket closes and the port can be bound by
#      something else. Three full cycles on the *same* port, so a leaked or stuck socket fails.
#
# What it deliberately does NOT do: touch `~/.wasm-agent`, the operator's node, ports 8799/8800/8890,
# the rendezvous or the relay. Every home is a fresh temp dir, `WASM_AGENT_HOME` is that dir,
# rendezvous and relay are empty, `WASM_AGENT_MANAGED=0`, the model URL is a stub that is never called,
# every port is picked fresh and is never 8799, and the one node this starts is killed by the pid it
# recorded. (AGENTS.md, the hard rule after the 07/11 incident.)
#
# The target is *not* a managed guest (the hard rule keeps this at `WASM_AGENT_MANAGED=0`), so the
# call's last hop — the node's own `/node/admitted` — still verifies the caller the way it always has
# and answers `unknown_caller` with no rendezvous there. That is docs/MESH.md §9's open item 2, and it
# is reported, not hidden: what this script proves is the mesh's own path (mount, roster, verdict,
# signed answer), and `scripts/test-mesh-attest.lua` proves the managed node's verb admission.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

target="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
exe=""; [ "${OS:-}" = "Windows_NT" ] && exe=".exe"
bin="${WA_BIN:-}"
if [ -z "$bin" ]; then
  for c in "$target/debug/wa$exe" "$target/release/wa$exe" "$ROOT/rust/target/debug/wa$exe" "$ROOT/rust/target/release/wa$exe"; do
    [ -f "$c" ] && { bin="$c"; break; }
  done
fi
if [ -z "$bin" ] || [ ! -f "$bin" ]; then
  echo "test-mesh-live: SKIPPED (needs a built wa: WA_BIN, or cargo build -p wa-host)"
  echo "  looked in $target/debug, $target/release, rust/target/debug, rust/target/release"
  exit 0
fi
echo "wa: $bin"

# Hermetic environment, before anything starts: every WA_*/WASM_AGENT_*/provider variable inherited
# from this shell is dropped, so the node below cannot read the operator's database, keys or tokens.
for name in $(env | sed -n 's/^\(WASM_AGENT_[A-Za-z0-9_]*\|WA_[A-Za-z0-9_]*\|OPENAI_[A-Za-z0-9_]*\|ANTHROPIC_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$name"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-mesh-live-XXXXXX")" || exit 2
HOME_OP="$WORK/op"     # the operator's node home (makes the roster, calls the target)
HOME_TGT="$WORK/tgt"   # the target node home (the one that must enable the mesh while running)
SERVE_PID=""
cleanup() {
  # Only the pid this script recorded, and only that one.
  if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null
    wait "$SERVE_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
step() { printf '\n== %s\n' "$*"; }
good() { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; fails=$((fails + 1)); }

mkdir -p "$HOME_OP/.wasm-agent" "$HOME_TGT/.wasm-agent" "$WORK/fleet"
export NO_PROXY="127.0.0.1,localhost,::1"
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:1/v1" WASM_AGENT_LLM_API_KEY="fixture-only"

# A free loopback port, without assuming one tool: node and python both ask the kernel.
free_port() {
  if command -v node >/dev/null 2>&1; then
    node -e 'const n=require("net");const s=n.createServer();s.on("error",()=>process.stdout.write("0"));s.listen(0,"127.0.0.1",()=>{const p=s.address().port;s.close(()=>process.stdout.write(String(p)))})'
  elif command -v python >/dev/null 2>&1; then
    python -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
  else
    echo "0"
  fi
}
free_port_distinct() { # $1.. = ports already taken
  local p=0
  while [ "$p" = "0" ] || [ "$p" = "8799" ] || printf '%s\n' "$@" | grep -qx "$p"; do p=$(free_port); done
  printf '%s' "$p"
}
NPORT=$(free_port_distinct); CPORT=$(free_port_distinct "$NPORT"); MPORT=$(free_port_distinct "$NPORT" "$CPORT")
if [ "$NPORT" = "0" ] || [ "$MPORT" = "0" ]; then
  echo "test-mesh-live: SKIPPED (no free-port probe: node or python is needed)"
  exit 0
fi
echo "ports: serve $NPORT, client $CPORT, mesh $MPORT (never 8799)"

mesh_up()     { (exec 3<>"/dev/tcp/127.0.0.1/$MPORT") 2>/dev/null; }
http_get() { # host port path -> body
  exec 3<>"/dev/tcp/$1/$2" || return 1
  printf 'GET %s HTTP/1.1\r\nHost: %s:%s\r\nConnection: close\r\n\r\n' "$3" "$1" "$2" >&3
  cat <&3
  exec 3<&- 3>&-
}
wait_up() { # seconds
  local i=0
  while [ "$i" -lt "$(( $1 * 10 ))" ]; do
    mesh_up && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
wait_down() { # seconds
  local i=0
  while [ "$i" -lt "$(( $1 * 10 ))" ]; do
    mesh_up || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
json_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }

# ---- 1. the operator's tools: keygen, sign, show --------------------------------------------------
step "wa fleet keygen (one explicit path, refused inside the node home and a git checkout)"
KEYGEN="$(HOME_TMP="$HOME_OP" WASM_AGENT_HOME="$(native "$HOME_OP")" "$bin" fleet keygen --out "$WORK/fleet/ohana.key")"
if printf '%s' "$KEYGEN" | grep -q '"ok":true'; then good "fleet key created"; else bad "keygen refused: $KEYGEN"; fi
FLEET_PUB="$(printf '%s' "$KEYGEN" | json_field public_key)"
[ -n "$FLEET_PUB" ] && good "public key printed: ${FLEET_PUB:0:16}…" || bad "keygen printed no public key"
REFUSED="$(WASM_AGENT_HOME="$(native "$HOME_OP")" "$bin" fleet keygen --out "$HOME_OP/.wasm-agent/fleet.key")"
case "$REFUSED" in
  *key_path_in_node_home*) good "a path inside the node home is refused" ;;
  *) bad "keygen accepted a path inside the node home: $REFUSED" ;;
esac
REFUSED="$("$bin" fleet keygen --out "$ROOT/fleet.key")"
case "$REFUSED" in
  *key_path_in_git_checkout*) good "a path inside this checkout is refused" ;;
  *) bad "keygen accepted a path inside a git checkout: $REFUSED" ;;
esac

step "the roster: two nodes, then wa fleet sign + show"
OP_JSON="$(WASM_AGENT_HOME="$(native "$HOME_OP")" "$bin" node)"
TGT_JSON="$(WASM_AGENT_HOME="$(native "$HOME_TGT")" "$bin" node)"
OP_ID="$(printf '%s' "$OP_JSON" | json_field node_id)"; OP_PUB="$(printf '%s' "$OP_JSON" | json_field public_key)"
TGT_ID="$(printf '%s' "$TGT_JSON" | json_field node_id)"; TGT_PUB="$(printf '%s' "$TGT_JSON" | json_field public_key)"
cat > "$WORK/roster.json" <<JSON
{
  "version": 1,
  "fleet": "ohana",
  "issued_at": 0,
  "expires_at": 0,
  "nodes": [
    { "node_id": "$OP_ID", "public_key": "$OP_PUB", "name": "laptop", "level": 0, "addresses": [], "revoked_at": 0 },
    { "node_id": "$TGT_ID", "public_key": "$TGT_PUB", "name": "nextcloud", "level": 1,
      "addresses": ["127.0.0.1:$MPORT"], "revoked_at": 0 }
  ]
}
JSON
TEMPLATE_BEFORE="$(cat "$WORK/roster.json")"
SIGNED="$(WASM_AGENT_HOME="$(native "$HOME_OP")" "$bin" fleet sign "$WORK/roster.json" --key "$WORK/fleet/ohana.key" --expires-days 30)"
case "$SIGNED" in
  *'"ok":true'*) good "roster signed (2 nodes)" ;;
  *) bad "sign failed: $SIGNED" ;;
esac
[ -f "$WORK/roster.signed.json" ] && good "the signature landed in roster.signed.json" || bad "no signed roster was written"
[ "$(cat "$WORK/roster.json")" = "$TEMPLATE_BEFORE" ]   && good "the template is left exactly as it was" || bad "sign rewrote the template"
SHOWN="$(WASM_AGENT_HOME="$(native "$HOME_OP")" "$bin" fleet show "$WORK/roster.signed.json" --key "$FLEET_PUB")"
case "$SHOWN" in
  *'"verified":true'*) good "show verifies the signed roster" ;;
  *) bad "show did not verify: $SHOWN" ;;
esac
case "$SHOWN" in
  *'"name":"nextcloud","level":1'*|*'"level":1,"name":"nextcloud"'*) good "show prints the levels" ;;
  *) bad "show did not print the levels: $SHOWN" ;;
esac
# A tampered roster: one level changed after signing is a document nobody may accept.
sed 's/"level": 1/"level": 0/' "$WORK/roster.signed.json" > "$WORK/roster.tampered.json"
if grep -q '"level": 0' "$WORK/roster.tampered.json"; then
  TAMPERED="$(WASM_AGENT_HOME="$(native "$HOME_OP")" "$bin" fleet show "$WORK/roster.tampered.json" --key "$FLEET_PUB")"
  TAMPERED_STATUS=$?
  case "$TAMPERED" in
    *"roster_unverified:bad_signature"*) good "a tampered roster is refused: roster_unverified:bad_signature" ;;
    *) bad "a tampered roster was not refused: $TAMPERED" ;;
  esac
  [ "$TAMPERED_STATUS" != "0" ] && good "show exits non-zero for a roster that does not verify" || bad "show exited 0 for a tampered roster"
else
  bad "could not build the tampered fixture (the signed file has no \"level\": 1)"
fi

cp "$WORK/roster.signed.json" "$HOME_OP/.wasm-agent/mesh-roster.json"
cp "$WORK/roster.signed.json" "$HOME_TGT/.wasm-agent/mesh-roster.json"
write_policy() { # $1 = home, $2 = "on"/"off"
  local enabled=false
  [ "$2" = "on" ] && enabled=true
  cat > "$1/.wasm-agent/policy.json" <<JSON
{"version":1,"components":{},"mesh":{"version":1,"roster_key":"$FLEET_PUB","roster":"mesh-roster.json","enabled":$enabled,"port":$MPORT,"bind":"127.0.0.1"}}
JSON
}
# The target starts OFF — no `enabled`, no port — which is a node the mesh was never rolled out to.
cat > "$HOME_TGT/.wasm-agent/policy.json" <<JSON
{"version":1,"components":{},"mesh":{"version":1,"roster_key":"$FLEET_PUB","roster":"mesh-roster.json"}}
JSON
cat > "$HOME_OP/.wasm-agent/policy.json" <<JSON
{"version":1,"components":{},"mesh":{"version":1,"roster_key":"$FLEET_PUB","roster":"mesh-roster.json","enabled":true}}
JSON

# The caller half of the mesh: the same signed request `wa call` builds, handed to `host.mesh_call`
# by node id (a *name* would need the rendezvous, which this test deliberately does not run).
cat > "$WORK/call.lua" <<'LUA'
local json = dofile('lua/vendor/json.lua')
local nodes = dofile('lua/core/nodes.lua')
local identity = nodes.identity() or {}
local target = host.getenv('WA_MESH_TARGET')
local body = json.encode({ from_node_id = identity.node_id, to_node_id = target,
  request_id = host.uuid(), capability = 'status', args = {} })
local headers, problem = nodes.signed_headers('call', body)
if not headers then print(json.encode({ error = problem or 'no_identity' })); os.exit(1) end
local pairs_list = {}
for name, value in pairs(headers) do pairs_list[#pairs_list + 1] = { name, tostring(value) } end
local raw = host.mesh_call(json.encode({ node = target, capability = 'status', args = {},
  inner_body = body, inner_headers = pairs_list }))
print(raw or '{"error":"mesh_unavailable"}')
LUA

# ---- 2/3. one running node, three enable/disable cycles -------------------------------------------
step "a running node, started with the mesh off"
env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY \
  WASM_AGENT_HOME="$(native "$HOME_TGT")" WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0 \
  WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:1/v1" WASM_AGENT_LLM_API_KEY="fixture-only" NO_PROXY="127.0.0.1,localhost,::1" \
  "$bin" --db "$(native "$HOME_TGT/.wasm-agent/memory.db")" serve --port "$NPORT" --client-port "$CPORT" --ui "$(native "$ROOT/ui")" \
  > "$WORK/target.log" 2>&1 &
SERVE_PID=$!
READY=0
for _ in $(seq 1 600); do
  if http_get 127.0.0.1 "$NPORT" /health 2>/dev/null | grep -q '"ok":true'; then READY=1; break; fi
  kill -0 "$SERVE_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$READY" = "1" ]; then good "wa serve is up on $NPORT (pid $SERVE_PID)"; else bad "wa serve did not come up (see $WORK/target.log)"; fi
if mesh_up; then bad "the mesh port $MPORT is open before the node was enabled"; else good "the mesh port is closed: the node is not in a fleet yet"; fi

for cycle in 1 2 3; do
  step "cycle $cycle: enable live, call, disable live (same port, same pid)"
  write_policy "$HOME_TGT" on
  if wait_up 20; then good "the listener mounted without a restart"; else bad "the listener did not mount within 20s"; fi
  kill -0 "$SERVE_PID" 2>/dev/null && good "the node is the same process (pid $SERVE_PID)" || bad "the serve process is gone"
  HEALTH="$(http_get 127.0.0.1 "$MPORT" /mesh/health)"
  case "$HEALTH" in
    *"$TGT_ID"*) good "/mesh/health names this node" ;;
    *) bad "/mesh/health did not answer for this node: $(printf '%s' "$HEALTH" | tail -1 | cut -c1-160)" ;;
  esac

  CALL="$(WASM_AGENT_HOME="$(native "$HOME_OP")" WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
    WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0 \
    WA_MESH_TARGET="$TGT_ID" WA_SCRIPT="$(native "$WORK/call.lua")" \
    "$bin" --db "$(native "$HOME_OP/.wasm-agent/memory.db")" 2>>"$WORK/caller.log" | tail -1)"
  case "$CALL" in
    *'"decision":"allow"'*) good "a mesh call was admitted by the roster: $(printf '%s' "$CALL" | cut -c1-120)…" ;;
    *) bad "the mesh call was not admitted: $CALL" ;;
  esac
  case "$CALL" in
    *'"transport":"direct"'*) good "it went over the direct path" ;;
    *) bad "the call did not use the direct path: $CALL" ;;
  esac
  case "$CALL" in
    *'"verified":true'*) good "the answer is signed by the target" ;;
    *) bad "the answer is not verified: $CALL" ;;
  esac
  # The documented last hop: the target is not a managed guest and there is no rendezvous here, so the
  # node's own `/node/admitted` refuses the caller it cannot verify. Reported, not hidden.
  case "$CALL" in
    *unknown_caller*) good "the last hop refused as documented (no rendezvous, target not managed): unknown_caller" ;;
    *'"body"'*) echo "  note: the capability answered: $(printf '%s' "$CALL" | cut -c1-160)" ;;
    *) bad "the call produced no understandable answer: $CALL" ;;
  esac
  grep -aq "mesh recv from=${OP_ID:0:8} to=${TGT_ID:0:8} levels=0->1 verb=read decision=allow" "$WORK/target.log" \
    && good "the target audited the admitted call" || bad "the target wrote no mesh recv audit line"

  write_policy "$HOME_TGT" off
  if wait_down 20; then good "disabling closed the listener"; else bad "the listener stayed up after disabling"; fi
  if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then good "the node kept running (no restart)"; else bad "the node died"; fi
  if command -v python >/dev/null 2>&1; then
    if python -c "import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $MPORT)); s.close()" 2>/dev/null; then
      good "the port is free again (nothing stuck)"
    else
      bad "the port is still bound after disabling"
    fi
  else
    echo "  skipped: the port-reuse check (needs python)"
  fi
done

# Nothing else may be left behind: one process, the one this script started.
if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
  kill "$SERVE_PID" 2>/dev/null
  wait "$SERVE_PID" 2>/dev/null
  good "the node this script started was stopped by its pid"
fi

echo
if [ "$fails" = "0" ]; then
  echo "test-mesh-live: PASS (keygen/sign/show round trip, tamper refused, 3 live enable/disable cycles with a call each)"
  exit 0
fi
echo "test-mesh-live: FAIL ($fails check(s) failed)"
exit 1
