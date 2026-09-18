#!/usr/bin/env bash
# A real guest node on this machine, and the attacks it has to survive.
#
# One device can run more than one node, which is the only way to test this honestly: the
# interesting failures are *between* nodes, and a mock would have to reimplement the rendezvous
# before it could say anything about them. So this starts a genuine guest - its own home, its own
# database, its own ed25519 key, its own port - beside the master node already running, and then
# tries to make the guest do master work.
#
# What it must show:
#   1. a guest node is a guest: no worktree, guest capabilities, no local master work
#   2. the rendezvous is told it is a guest (a node that is a guest locally and a master remotely
#      is how a guest gets master tools from a peer)
#   3. a guest cannot command a master
#   4. a forged master call is refused - the key must be the one the rendezvous agrees with
#   5. a replayed call is refused even though its signature is genuine
#   6. a master's wish runs *as that master*: the ledger says the master, not the guest
#   7. an enrolled-master list, when set, is the authority instead of the rendezvous
#
# Usage:  WA_BIN=/path/to/wa bash scripts/test-guest-e2e.sh
# Needs a reachable rendezvous and a master node already running locally. Writes only into a
# temporary directory, and stops only the process it started.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  BIN="$(command -v wa || true)"
fi
if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then
  echo "guest e2e: no wa binary (set WA_BIN)" >&2
  exit 1
fi

RENDEZVOUS="${WASM_AGENT_RENDEZVOUS:-}"
if [ -z "$RENDEZVOUS" ]; then
  RENDEZVOUS="$(grep -i '^WASM_AGENT_RENDEZVOUS=' "$HOME/.wasm-agent/env" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
if [ -z "$RENDEZVOUS" ]; then
  echo "guest e2e: no rendezvous (set WASM_AGENT_RENDEZVOUS)" >&2
  exit 1
fi

MASTER_PORT="${MASTER_PORT:-8799}"
GUEST_PORT="${GUEST_PORT:-8803}"
GUEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wa-guest-XXXXXX")"
GUEST_DB="$GUEST_HOME/guest.db"
GUEST_KEY="$GUEST_HOME/node.key"
GUEST_PID=""

checks=0
failed=0
say() { printf '  %s\n' "$*"; }
ok() {
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then say "ok   $2"; else failed=$((failed + 1)); say "FAIL $2${3:+ - $3}"; fi
}

# Nothing is stopped by image name: another `wa` on this machine is somebody's session, and
# killing it for sharing a name is how that session dies. The guest is found by *its port*, which
# is the one thing in its command line that is unique to this run - the home directory is an
# environment variable, so it never appears there at all, which is how the first version of this
# silently failed to stop anything.
kill_guest() {
  local pids=""
  if command -v powershell.exe >/dev/null 2>&1; then
    pids="$(powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"name like 'wa%'\" | Where-Object { \$_.CommandLine -like '*--port $GUEST_PORT*' } | ForEach-Object { \$_.ProcessId }" 2>/dev/null | tr -d '\r')"
  elif command -v pgrep >/dev/null 2>&1; then
    pids="$(pgrep -f -- "--port $GUEST_PORT" 2>/dev/null || true)"
  fi
  [ -z "$pids" ] && pids="$GUEST_PID"
  for pid in $pids; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
}

cleanup() {
  kill_guest
  # A busy database means the process has not finished dying; wait rather than leave the run's
  # debris behind, but keep the directory when something failed, because the log is the only
  # evidence of why.
  for _ in $(seq 1 20); do
    rm -rf "$GUEST_HOME" 2>/dev/null && break
    sleep 0.5
  done
  if [ -d "$GUEST_HOME" ] && [ "$failed" -gt 0 ]; then
    say "kept $GUEST_HOME (the guest's log is $GUEST_HOME/serve.log)"
  fi
}
trap cleanup EXIT

# The guest uses this working tree's Lua, so a Lua edit is testable without rebuilding - but the
# Rust it runs is the real binary, because the announcement to the rendezvous and the verification
# of callers live there.
guest_env() {
  env WASM_AGENT_HOME="$GUEST_HOME" \
      WASM_AGENT_NODE_ROLE="${GUEST_ROLE:-guest}" \
      WASM_AGENT_NODE_KEY="$GUEST_KEY" \
      WASM_AGENT_RENDEZVOUS="$RENDEZVOUS" \
      WASM_AGENT_ENDPOINT="127.0.0.1:$GUEST_PORT" \
      WASM_AGENT_LUA_ROOT="$ROOT" \
      ${GUEST_TRUST:-X=unset} \
      "$@"
}

start_guest() {
  ( cd "$ROOT" && guest_env "$BIN" serve --port "$GUEST_PORT" --db "$GUEST_DB" \
      > "$GUEST_HOME/serve.log" 2>&1 & echo $! > "$GUEST_HOME/serve.pid" )
  GUEST_PID="$(cat "$GUEST_HOME/serve.pid")"
  for _ in $(seq 1 60); do
    curl -s -m 2 "http://127.0.0.1:$GUEST_PORT/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  say "the guest did not come up; its log:"
  tail -20 "$GUEST_HOME/serve.log" | sed 's/^/    /'
  return 1
}

stop_guest() {
  kill_guest
  sleep 1
  GUEST_PID=""
}

# Lua in a throwaway process sharing the guest's identity (same home = same key), so a signature
# it produces really is the guest's.
guest_lua() { ( cd "$ROOT" && guest_env WA_SCRIPT="$1" "$BIN" --db "$GUEST_DB" 2>&1 ); }
# ... and the same on the master's side, which uses the machine's own home and key.
master_lua() { ( cd "$ROOT" && env WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT="$1" "$BIN" --db "$GUEST_HOME/master.db" 2>&1 ); }

guest_json() { curl -s -m 5 "http://127.0.0.1:$GUEST_PORT$1"; }
master_json() { curl -s -m 8 "http://127.0.0.1:$MASTER_PORT$1"; }

say "guest: $GUEST_HOME, port $GUEST_PORT, rendezvous $RENDEZVOUS"
start_guest || exit 1
sleep 2

# ---------------------------------------------------------------- 1. it is a guest
MODELS="$(guest_json /models)"
ok "$(grep -q '"node_role":"guest"' <<<"$MODELS" && echo 1 || echo 0)" "the node reports itself as a guest"
ok "$(grep -q '"node_worktree":""' <<<"$MODELS" && echo 1 || echo 0)" "a guest reports no worktree" "$(grep -o '"node_worktree":"[^"]*"' <<<"$MODELS")"
NAME="$(grep -o '"node_name":"[^"]*"' <<<"$MODELS" | cut -d'"' -f4)"
ok "$([ "$NAME" != "foundation" ] && echo 1 || echo 0)" "a guest is not named after the directory it runs in" "$NAME"

ME="$(guest_json /me)"
ok "$(grep -q '"role":"guest"' <<<"$ME" && echo 1 || echo 0)" "a local session on a guest node is a guest"
# The guest tier is memory on demand plus spells (DESIGN.md 8). `read` is *not* in it: a guest
# node reads files when a master asks it to, which is a different thing from being allowed to
# read on its own initiative - and that difference is the point of the check.
ok "$(grep -q '"remember"' <<<"$ME" && echo 1 || echo 0)" "the guest is offered memory"
ok "$(grep -q '"write"' <<<"$ME" && echo 0 || echo 1)" "the guest is not offered write"
ok "$(grep -q '"bash"' <<<"$ME" && echo 0 || echo 1)" "the guest is not offered a shell"
ok "$(grep -q '"edit"' <<<"$ME" && echo 0 || echo 1)" "the guest is not offered edit"

SHELL_REPLY="$(curl -s -m 5 -X POST "http://127.0.0.1:$GUEST_PORT/shell" -d 'echo pwned')"
ok "$(grep -q 'forbidden' <<<"$SHELL_REPLY" && echo 1 || echo 0)" "a guest cannot run a shell locally" "$SHELL_REPLY"

BRANCH_BEFORE="$(cd "$ROOT" && git branch --show-current)"
curl -s -m 5 -X POST "http://127.0.0.1:$GUEST_PORT/node/name" -d 'guest-e2e-node' >/dev/null
BRANCH_AFTER="$(cd "$ROOT" && git branch --show-current)"
ok "$([ "$BRANCH_BEFORE" = "$BRANCH_AFTER" ] && echo 1 || echo 0)" "naming a guest does not move a branch" "$BRANCH_BEFORE -> $BRANCH_AFTER"

# ------------------------------------------------- 2. the rendezvous is told the truth
# The master asks the rendezvous what it knows. A guest that announced itself as a master would
# appear here as one, and every other node would believe it.
sleep 3
PEERS="$(master_json /nodes)"
ok "$([ -n "$PEERS" ] && echo 1 || echo 0)" "the master can see the rendezvous's list"
ok "$(grep -q '"role":"guest"' <<<"$PEERS" && echo 1 || echo 0)" \
  "the rendezvous learned it is a guest" "$(grep -c '"role":"guest"' <<<"$PEERS") guest row(s)"

# ------------------------------------------------- 3. a guest cannot command a master
# The call goes to the master's own advertised endpoint rather than through the relay, so what is
# being tested is the role check and not the transport: a relay timeout would otherwise look like
# a refusal, and "it failed" is not the same answer as "it was refused".
cat > "$GUEST_HOME/call-master.lua" <<'LUA'
local nodes = dofile("lua/core/nodes.lua")
local json = dofile("lua/vendor/json.lua")
local identity = nodes.identity()
local master = nil
for _, node in ipairs(nodes.peers({ fresh = true })) do
  if node.node_id ~= identity.node_id and node.role == "master" and nodes.endpoint(node) then
    master = node break
  end
end
if not master then print("RESULT:no-master-with-endpoint") return end
local body = json.encode({ from_node_id = identity.node_id, capability = "status", args = {} })
local headers = nodes.signed_headers("call", body)
local response = json.decode(host.http("POST", nodes.endpoint(master) .. "/node/call",
  json.encode(headers), body))
print("RESULT:" .. tostring(response and response.body or "no-response"):sub(1, 80))
LUA
CMD_OUT="$(guest_lua "$GUEST_HOME/call-master.lua" | grep -o 'RESULT:.*' | head -1)"
ok "$(grep -q 'forbidden_role' <<<"$CMD_OUT" && echo 1 || echo 0)" "a guest cannot command a master" "$CMD_OUT"

# ------------------------------------------------- 4. a forged master call is refused
# The guest tries to be the master: it claims the master's node id while signing with its own key.
# The signature is genuine; the *claim* is what the rendezvous contradicts.
cat > "$GUEST_HOME/forge.lua" <<LUA
local nodes = dofile("lua/core/nodes.lua")
local json = dofile("lua/vendor/json.lua")
local identity = nodes.identity()
local master = nil
for _, node in ipairs(nodes.peers({ fresh = true })) do
  if node.node_id ~= identity.node_id and node.role == "master" then master = node break end
end
if not master then print("FORGE:no-master-visible") return end
-- A real signature by the guest's own key, sent as if it belonged to the master's node id. The
-- cryptography does its job: what fails is the *claim*, because the rendezvous will not confirm
-- that this key speaks for that node.
local body = json.encode({ from_node_id = identity.node_id, capability = "read", args = { path = "README.md" } })
local ts = math.floor(host.now())
local signed = json.decode(host.sign(table.concat({ "call", master.node_id, tostring(ts), host.sha256(body) }, "|")))
local headers = {
  ["Content-Type"] = "application/json",
  ["X-WA-Node"] = master.node_id,
  ["X-WA-Pub"] = identity.public_key,
  ["X-WA-Ts"] = tostring(ts),
  ["X-WA-Sig"] = signed.signature,
}
local response = json.decode(host.http("POST", "http://127.0.0.1:$GUEST_PORT/node/call",
  json.encode(headers), body))
print("FORGE:" .. tostring(response and response.body or "no-response"):sub(1, 80))
LUA
FORGE_OUT="$(guest_lua "$GUEST_HOME/forge.lua" | grep -o 'FORGE:.*' | head -1)"
ok "$(grep -qE 'unknown_caller|bad_signature|forbidden_role' <<<"$FORGE_OUT" && echo 1 || echo 0)" \
  "a call claiming a master's id with a guest's key is refused" "$FORGE_OUT"

# ------------------------------------------------- 5. a genuine call, replayed
# One body, sent twice - exactly what someone who captured a request would do. The signature is
# real, the timestamp is still fresh, and the second one must not run.
cat > "$GUEST_HOME/replay.lua" <<'LUA'
local nodes = dofile("lua/core/nodes.lua")
local json = dofile("lua/vendor/json.lua")
local identity = nodes.identity()
local guest = nil
for _, node in ipairs(nodes.peers({ fresh = true })) do
  if node.node_id ~= identity.node_id and node.role == "guest" and nodes.endpoint(node) then
    guest = node break
  end
end
if not guest then print("REPLAY:no-guest-with-endpoint") return end
local endpoint = nodes.endpoint(guest)
-- One body and one set of headers, sent twice: exactly what someone who captured a request would
-- do. The signature is genuine, the timestamp is still fresh, and the second one must not run.
local body = json.encode({ from_node_id = identity.node_id, capability = "read", args = { path = "README.md" } })
local headers = json.encode(nodes.signed_headers("call", body))
local first = json.decode(host.http("POST", endpoint .. "/node/call", headers, body))
local second = json.decode(host.http("POST", endpoint .. "/node/call", headers, body))
print("REPLAY:first=" .. tostring(first and first.body or "?"):sub(1, 30))
print("REPLAY:second=" .. tostring(second and second.body or "?"):sub(1, 60))
LUA
REPLAY_OUT="$(master_lua "$GUEST_HOME/replay.lua" | grep 'REPLAY:' | tr '\n' ' ')"
ok "$(grep -q 'replayed_request' <<<"$REPLAY_OUT" && echo 1 || echo 0)" "a replayed call is refused" "$REPLAY_OUT"

# ------------------------------------------------- 6. the master's wish is the master's work
cat > "$GUEST_HOME/wish.lua" <<'LUA'
local nodes = dofile("lua/core/nodes.lua")
local json = dofile("lua/vendor/json.lua")
local identity = nodes.identity()
local guest = nil
for _, node in ipairs(nodes.peers({ fresh = true })) do
  if node.node_id ~= identity.node_id and node.role == "guest" and nodes.endpoint(node) then
    guest = node break
  end
end
if not guest then print("WISH:no-guest-with-endpoint") return end
local body = json.encode({ from_node_id = identity.node_id, capability = "read", args = { path = "README.md" } })
local headers = nodes.signed_headers("call", body)
local response = json.decode(host.http("POST", nodes.endpoint(guest) .. "/node/call",
  json.encode(headers), body))
print("WISH:" .. tostring(response and response.body or "no-response"):sub(1, 70))
LUA
WISH_OUT="$(master_lua "$GUEST_HOME/wish.lua" | grep -o 'WISH:.*' | head -1)"
ok "$(grep -qi 'wasm-agent' <<<"$WISH_OUT" && echo 1 || echo 0)" "a master's wish runs on the guest" "$WISH_OUT"

cat > "$GUEST_HOME/author.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
memory.setup()
for _, session in ipairs(memory.list_sessions(nil, 8)) do
  print("AUTHOR:" .. tostring(session.user_id) .. " on " .. tostring(session.node_id))
end
LUA
AUTHOR_OUT="$(guest_lua "$GUEST_HOME/author.lua" | grep 'AUTHOR:' | tr '\n' ' ')"
ok "$(grep -q 'AUTHOR:foundation' <<<"$AUTHOR_OUT" && echo 1 || echo 0)" \
  "the work is filed under the master, not the guest" "$AUTHOR_OUT"
ok "$(grep -q 'AUTHOR:node on' <<<"$AUTHOR_OUT" && echo 0 || echo 1)" \
  "nothing is filed under the old anonymous 'node' user"

# ------------------------------------------------- 7. an enrolled list is the authority
# The rendezvous records what a node says about itself. With WASM_AGENT_TRUSTED_MASTERS set, an
# enrolled list decides instead - so a master the list does not name is refused even though the
# rendezvous would vouch for its key.
stop_guest
GUEST_TRUST="WASM_AGENT_TRUSTED_MASTERS=nobody-at-all" start_guest || exit 1
sleep 3
ANCHOR_OUT="$(master_lua "$GUEST_HOME/wish.lua" | grep -o 'WISH:.*' | head -1)"
ok "$(grep -qE 'forbidden_role|unknown_caller|no-guest-with-endpoint' <<<"$ANCHOR_OUT" && echo 1 || echo 0)" \
  "an enrolled-master list refuses a master it does not name" "$ANCHOR_OUT"
stop_guest

if [ "$failed" -eq 0 ]; then
  echo "guest e2e ok ($checks checks)"
else
  echo "guest e2e FAILED ($failed of $checks)"
  exit 1
fi
