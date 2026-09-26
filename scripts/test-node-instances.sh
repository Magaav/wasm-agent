#!/usr/bin/env bash
# Two real nodes on one machine, isolated, and the failures isolation must survive.
#
# This is the hermetic counterpart to scripts/test-guest-e2e.sh: no model, no rendezvous, no
# network. It starts an operator master node and a guest node that belongs to another master,
# both from the built `wa`, each through the sentinel's named-instance lifecycle, and then checks
# the properties that make "co-located" safe, including the mutations a review found:
#
#   1. named setup: separate homes, keys, databases, ports and supervisor records
#   2. port collision rejected at add (including node-vs-client cross-role) and at start
#   3. home/install collisions and a nonempty foreign home are rejected
#   4. the guest cannot read the operator's sessions or memory
#   5. stop/restart of A cannot touch B, and the identities survive a restart
#   6. a wrong listener, a corrupt record, and a forged legacy pid/home are refused, not killed
#   7. legacy adoption works only with positive proof, and records the creation marker first
#   8. a protected environment share is refused; a guest cannot be turned into a master
#   9. a corrupt registry is an error and is never overwritten
#  10. remove --purge refuses a home the sentinel does not own
#
# Usage:  bash scripts/test-node-instances.sh
# Needs:  the built wa and wa-sentinel binaries. Build with CARGO_BUILD_JOBS=2.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa.exe}"
[ -x "$BIN" ] || BIN="$ROOT/rust/target/release/wa"
SENTINEL="${WA_SENTINEL:-$ROOT/rust/wa-sentinel/target/release/wa-sentinel.exe}"
[ -x "$SENTINEL" ] || SENTINEL="$ROOT/rust/wa-sentinel/target/release/wa-sentinel"
if [ ! -x "$BIN" ] || [ ! -x "$SENTINEL" ]; then
  echo "node instances: missing binaries; build first:" >&2
  echo "  CARGO_BUILD_JOBS=2 cargo build --release --offline --manifest-path rust/Cargo.toml" >&2
  echo "  CARGO_BUILD_JOBS=2 cargo build --release --offline --manifest-path rust/wa-sentinel/Cargo.toml" >&2
  exit 2
fi

BASE="$(mktemp -d "${TMPDIR:-/tmp}/wa-instances-XXXXXX")"
ARTIFACTS="${WA_INSTANCE_ARTIFACT_DIR:-${BASE}-failure-artifacts}"
ARTIFACT_DIR_CUSTOM=0
[ -z "${WA_INSTANCE_ARTIFACT_DIR:-}" ] || ARTIFACT_DIR_CUSTOM=1
BIN_NATIVE="$(cygpath -w "$BIN" 2>/dev/null || printf '%s' "$BIN")"
export WA_INSTANCE_BASE_HOME="$BASE"
export WA_INSTANCE_REGISTRY="$BASE/instances.json"
# A secret in the supervisor's environment must not reach the guest. It is deliberately only in the
# environment, never written to any file, so a leak could only come from inheritance.
export WA_TEST_SECRET_API_KEY="sk-operator-secret-do-not-leak"

VALID_MASTER="0123456789abcdef0123456789abcdef"

checks=0
failed=0
skipped=0
failed_names=()
skipped_names=()
say() { printf '  %s\n' "$*"; }
ok() {
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then say "ok   $2"; else failed=$((failed + 1)); failed_names+=("$2"); say "FAIL $2${3:+ - $3}"; fi
}
skip() {
  checks=$((checks + 1)); skipped=$((skipped + 1)); skipped_names+=("$2")
  say "skip $2${3:+ - $3}"
}

winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$1 "
  elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    netstat -ltn 2>/dev/null | grep -q ":$1 .*LISTEN"
  else
    netstat -ano -p TCP 2>/dev/null | grep -q ":$1 .*LISTENING"
  fi
}
pick_port_base() {
  local base=$((19000 + ($$ % 500) * 6))
  while :; do
    local free=1
    for p in $(seq "$base" $((base + 5))); do
      if port_in_use "$p"; then free=0; break; fi
    done
    [ "$free" = 1 ] && { echo "$base"; return; }
    base=$((base + 6))
  done
}
pid_of() { sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
node_id_of() {
  local port="$1" body="$BASE/sync-head-$1.json" code
  code="$(curl --silent --show-error --max-time 1 -o "$body" -w '%{http_code}' "http://127.0.0.1:$port/sync/head" 2>/dev/null)" || return 1
  [ "$code" = 200 ] || return 1
  node -e '
    try { const value=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const id=value && value.node_id; if (typeof id!=="string" || !id.trim()) process.exit(1);
      process.stdout.write(id);
    } catch (_) { process.exit(1); }' "$(winpath "$body")"
}
http_json_200() {
  local url="$1" output="$2" code
  code="$(curl --silent --show-error --max-time 5 -o "$output" -w '%{http_code}' "$url" 2>/dev/null)" || return 1
  [ "$code" = 200 ] || return 1
  node -e 'try { JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); } catch (_) { process.exit(1); }' "$(winpath "$output")"
}
wait_node_id() {
  local port="$1" i value=""
  for i in $(seq 1 12); do
    value="$(node_id_of "$port" 2>/dev/null || true)"
    [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    sleep 0.25
  done
  return 1
}
start_instance() {
  local name="$1" label="$2"
  "$SENTINEL" --instance "$name" instance start >"$BASE/$name-$label-start.stdout" 2>"$BASE/$name-$label-start.stderr"
}
probe_node_start() {
  local name="$1" port="$2" client="$3" role="$4" home="$BASE/.wasm-agent/instances/$1"
  local install="$home/install" ui="$home/install/ui"
  local output="$BASE/$name-node-probe"
  if [ -n "$(pid_on_port "$port")" ]; then
    printf 'probe skipped: port %s is still occupied\n' "$port" >"$output.stdout"
    return
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    printf 'probe unavailable: timeout command is missing\n' >"$output.stderr"
    return
  fi
  env -u WASM_AGENT_LUA_ROOT \
    WASM_AGENT_HOME="$(winpath "$home")" WASM_AGENT_PORT="$port" \
    WASM_AGENT_CLIENT_PORT="$client" WASM_AGENT_INSTANCE="$name" \
    WASM_AGENT_NODE_NAME="$name" WASM_AGENT_NODE_ROLE="$role" \
    WASM_AGENT_TRUSTED_MASTERS="$VALID_MASTER" \
    WA_INSTALL_DIR="$(winpath "$install")" WA_UI_DIR="$(winpath "$ui")" \
    timeout 6 "$BIN" serve --port "$port" --client-port "$client" --ui "$(winpath "$ui")" \
    >"$output.stdout" 2>"$output.stderr"
  printf '%s\n' "$?" >"$output.exit"
}
pid_on_port() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep ":$1 " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
  elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    netstat -ltnp 2>/dev/null | grep ":$1 .*LISTEN" | sed -n 's#.* \([0-9][0-9]*\)/.*#\1#p' | head -1
  else
    netstat -ano -p TCP 2>/dev/null | grep ":$1 .*LISTENING" | awk '{print $5}' | head -1
  fi
}
OP_RECORD="$BASE/.wasm-agent/instances/op/.wasm-agent/sentinel/node.json"
GUEST_RECORD="$BASE/.wasm-agent/instances/guest1/.wasm-agent/sentinel/node.json"
cleanup_failed=0
cleanup_nodes() {
  local name port
  for name in op guest1; do
    port="$OP_PORT"
    [ "$name" != guest1 ] || port="$GUEST_PORT"
    "$SENTINEL" instance stop "$name" >"$BASE/cleanup-$name.stdout" 2>"$BASE/cleanup-$name.stderr" || true
    if port_in_use "$port"; then
      cleanup_failed=1
      printf 'cleanup could not prove/stop test instance %s on port %s; no unrelated process was killed\n' "$name" "$port" >>"$BASE/cleanup-warning.log"
    fi
  done
}
stop_all() {
  local exit_status=$?
  cleanup_nodes
  # Keep all registry, home, lifecycle and captured command output if any assertion or setup step
  # failed. Cleanup still goes through the sentinel's pid/identity proof; never kill by image name.
  if [ "$failed" -gt 0 ] || [ "$exit_status" -ne 0 ]; then
    mkdir -p "$ARTIFACTS"
    cp -a "$BASE/." "$ARTIFACTS/" 2>/dev/null || true
    [ ! -f "$VERDICT" ] || cp "$VERDICT" "$ARTIFACTS/verdict.json" 2>/dev/null || true
    echo "node instances: failure artifacts retained at $ARTIFACTS" >&2
    rm -rf "$BASE" 2>/dev/null || true
  else
    rm -rf "$BASE" 2>/dev/null || true
    [ "$ARTIFACT_DIR_CUSTOM" -eq 1 ] || rm -rf "$ARTIFACTS" 2>/dev/null || true
  fi
}
trap stop_all EXIT
VERDICT="${WA_INSTANCE_VERDICT:-${TMPDIR:-/tmp}/wa-node-instances-verdict.json}"

P="$(pick_port_base)"
OP_PORT=$P; OP_CLIENT=$((P + 1)); GUEST_PORT=$((P + 2)); GUEST_CLIENT=$((P + 3)); FOREIGN_PORT=$((P + 4)); EXTRA_CLIENT=$((P + 5))
say "ports: op $OP_PORT/$OP_CLIENT  guest $GUEST_PORT/$GUEST_CLIENT  foreign $FOREIGN_PORT"

# 1. named setup ------------------------------------------------------------
say "setting up two named instances with separate homes, keys, databases and ports"
"$SENTINEL" instance add op --port "$OP_PORT" --client-port "$OP_CLIENT" --binary "$BIN_NATIVE" >"$BASE/add-op.stdout" 2>"$BASE/add-op.stderr"
OP_ADD_STATUS=$?
ok "$([ "$OP_ADD_STATUS" -eq 0 ] && echo 1 || echo 0)" "sentinel add succeeds for the operator (see add-op.* artifacts)"
ok "$([ -f "$BASE/.wasm-agent/instances/op/.wasm-agent/node.role" ] && echo 1 || echo 0)" \
  "the operator instance has its own home and role file"
"$SENTINEL" instance add guest1 --port "$GUEST_PORT" --client-port "$GUEST_CLIENT" --role guest \
  --master "$VALID_MASTER" --binary "$BIN_NATIVE" >"$BASE/add-guest.stdout" 2>"$BASE/add-guest.stderr"
GUEST_ADD_STATUS=$?
ok "$([ "$GUEST_ADD_STATUS" -eq 0 ] && echo 1 || echo 0)" "sentinel add succeeds for the guest (see add-guest.* artifacts)"
ok "$([ "$(cat "$BASE/.wasm-agent/instances/guest1/.wasm-agent/node.role" 2>/dev/null)" = "guest" ] && echo 1 || echo 0)" \
  "the guest instance records its role"
ok "$(grep -q "WASM_AGENT_TRUSTED_MASTERS=$VALID_MASTER" "$BASE/.wasm-agent/instances/guest1/.wasm-agent/env" && echo 1 || echo 0)" \
  "the guest is explicitly bound to a remote master node id"

# A guest without a master, or with a name instead of a node id, is refused.
if "$SENTINEL" instance add rogue --port $((P + 10)) --client-port $((P + 11)) --role guest --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a guest without a remote master is refused"
else
  ok 1 "a guest without a remote master is refused"
fi
if "$SENTINEL" instance add rogue --port $((P + 10)) --client-port $((P + 11)) --role guest --master friendly-name --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a master alias is not accepted as a node id"
else
  ok 1 "a master alias is not accepted as a node id"
fi

# 2. port and path collisions ----------------------------------------------
if "$SENTINEL" instance add collide --port "$OP_PORT" --client-port "$EXTRA_CLIENT" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a second instance cannot claim the operator's node port"
else
  ok 1 "a second instance cannot claim the operator's node port"
fi
# The cross-role case the first version missed: node port == the guest's *client* port.
if "$SENTINEL" instance add collide --port "$GUEST_CLIENT" --client-port "$EXTRA_CLIENT" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a node port cannot collide with another instance's client port"
else
  ok 1 "a node port cannot collide with another instance's client port"
fi
# A home inside another instance's home.
if "$SENTINEL" instance add collide --port $((P + 12)) --client-port $((P + 13)) \
  --home "$(winpath "$BASE/.wasm-agent/instances/op/nested")" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a home inside another instance's home is refused"
else
  ok 1 "a home inside another instance's home is refused"
fi
# The operator home itself.
if "$SENTINEL" instance add collide --port $((P + 12)) --client-port $((P + 13)) \
  --home "$(winpath "$BASE")" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a named home cannot be the operator home"
else
  ok 1 "a named home cannot be the operator home"
fi
# A nonempty directory the operator points at by hand.
mkdir -p "$BASE/foreign-home"
echo "do not lose me" > "$BASE/foreign-home/precious.txt"
if "$SENTINEL" instance add collide --port $((P + 12)) --client-port $((P + 13)) \
  --home "$(winpath "$BASE/foreign-home")" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a nonempty foreign home is never overwritten"
else
  ok 1 "a nonempty foreign home is never overwritten"
fi
ok "$([ -f "$BASE/foreign-home/precious.txt" ] && echo 1 || echo 0)" "the foreign home is left intact"

# 3. protected environment shares -------------------------------------------
if "$SENTINEL" instance add share-bad --port $((P + 12)) --client-port $((P + 13)) \
  --role guest --master "$VALID_MASTER" --share "WASM_AGENT_NODE_ROLE=master" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a share cannot set the node role"
else
  ok 1 "a share cannot set the node role"
fi
if "$SENTINEL" instance add share-bad --port $((P + 12)) --client-port $((P + 13)) \
  --role guest --master "$VALID_MASTER" --share "WASM_AGENT_HOME=$(winpath "$BASE")" --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "a share cannot set the node home"
else
  ok 1 "a share cannot set the node home"
fi
# A malicious registry entry (as if hand-edited) is refused on load, so start never spawns it.
ORIGINAL_REGISTRY="$(cat "$BASE/instances.json")"
node -e '
const fs = require("fs");
const path = process.argv[1];
const doc = JSON.parse(fs.readFileSync(path, "utf8"));
doc.instances["evil"] = { name: "evil", home: process.argv[2], install_dir: process.argv[3],
  node_port: Number(process.argv[4]), client_port: Number(process.argv[5]), role: "guest",
  master: "0123456789abcdef0123456789abcdef", shared_env: { WASM_AGENT_NODE_ROLE: "master" } };
fs.writeFileSync(path, JSON.stringify(doc));
' "$(winpath "$BASE/instances.json")" "$(winpath "$BASE/evil-home")" "$(winpath "$BASE/evil-home/install")" $((P + 12)) $((P + 13))
if "$SENTINEL" instance start evil >/dev/null 2>&1; then
  ok 0 "a protected share smuggled into the registry does not spawn a master guest"
else
  ok 1 "a protected share smuggled into the registry does not spawn a master guest"
fi
ok "$([ -z "$(pid_on_port $((P + 12)))" ] && echo 1 || echo 0)" "the malicious instance did not start"
printf '%s' "$ORIGINAL_REGISTRY" > "$BASE/instances.json"

# 4. start both -------------------------------------------------------------
say "starting the operator and the guest through the sentinel lifecycle"
start_instance op initial
OP_START_STATUS=$?
start_instance guest1 initial
GUEST_START_STATUS=$?
OP_ID="$(wait_node_id "$OP_PORT" 2>/dev/null || true)"
GUEST_ID="$(wait_node_id "$GUEST_PORT" 2>/dev/null || true)"
STARTUP_READY=0
[ "$OP_START_STATUS" -eq 0 ] && [ "$GUEST_START_STATUS" -eq 0 ] \
  && [ -n "$OP_ID" ] && [ -n "$GUEST_ID" ] && STARTUP_READY=1
ok "$([ "$OP_START_STATUS" -eq 0 ] && [ "$GUEST_START_STATUS" -eq 0 ] && echo 1 || echo 0)" \
  "both sentinel start commands succeed (see *-initial-start.* artifacts)"
ok "$([ -n "$OP_ID" ] && [ -n "$GUEST_ID" ] && echo 1 || echo 0)" \
  "both nodes return valid HTTP 200 JSON identities from /sync/head" "op ${OP_ID:-missing} guest ${GUEST_ID:-missing}"
if [ "$STARTUP_READY" -eq 1 ]; then
  ok "$([ "$OP_ID" != "$GUEST_ID" ] && echo 1 || echo 0)" "the two nodes have different identities"
else
  skip "a valid HTTP /sync/head response from both nodes and successful sentinel starts are required" \
    "the two nodes have different identities"
  [ "$OP_START_STATUS" -eq 0 ] && [ -n "$OP_ID" ] || probe_node_start op "$OP_PORT" "$OP_CLIENT" master
  [ "$GUEST_START_STATUS" -eq 0 ] && [ -n "$GUEST_ID" ] || probe_node_start guest1 "$GUEST_PORT" "$GUEST_CLIENT" guest
fi

OP_HOME="$BASE/.wasm-agent/instances/op"
GUEST_HOME="$BASE/.wasm-agent/instances/guest1"
OP_DB="$OP_HOME/.wasm-agent/memory.db"
GUEST_DB="$GUEST_HOME/.wasm-agent/memory.db"
OP_KEY="$OP_HOME/.wasm-agent/node.key"
GUEST_KEY="$GUEST_HOME/.wasm-agent/node.key"
OP_PID=""
GUEST_PID=""
if [ "$STARTUP_READY" -eq 1 ]; then
  ok "$([ -f "$OP_DB" ] && [ -f "$GUEST_DB" ] && [ "$OP_DB" != "$GUEST_DB" ] && echo 1 || echo 0)" \
    "each node has its own database file"
  ok "$([ -f "$OP_KEY" ] && [ -f "$GUEST_KEY" ] && ! cmp -s "$OP_KEY" "$GUEST_KEY" && echo 1 || echo 0)" \
    "each node has its own identity key"
  ok "$([ -f "$OP_RECORD" ] && [ -f "$GUEST_RECORD" ] && echo 1 || echo 0)" \
    "each instance has its own supervisor lifecycle record"
  OP_PID="$(pid_of "$OP_RECORD")"
  GUEST_PID="$(pid_of "$GUEST_RECORD")"
  ok "$([ -n "$OP_PID" ] && [ -n "$GUEST_PID" ] && [ "$OP_PID" != "$GUEST_PID" ] && echo 1 || echo 0)" \
    "the two nodes are different processes" "op pid ${OP_PID:-missing} guest pid ${GUEST_PID:-missing}"

  # 5. the guest cannot read the operator's sessions or memory -----------------
  say "checking the guest cannot see the operator's sessions or memory"
  PYTHON_CMD=()
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import sqlite3' >/dev/null 2>&1; then
      PYTHON_CMD=("$candidate")
      break
    fi
  done
  if [ "${#PYTHON_CMD[@]}" -eq 0 ] && command -v py >/dev/null 2>&1 \
      && py -3 -c 'import sqlite3' >/dev/null 2>&1; then
    PYTHON_CMD=(py -3)
  fi
  if [ "${#PYTHON_CMD[@]}" -eq 0 ]; then
    echo "node instances: Python with sqlite3 is required for the database isolation probe" >&2
    exit 2
  fi
  "${PYTHON_CMD[@]}" - "$(winpath "$OP_DB")" <<'PY'
import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, route_id TEXT NOT NULL DEFAULT '', objective TEXT NOT NULL DEFAULT '', parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL)")
columns = [row[1] for row in db.execute("PRAGMA table_info(sessions)")]
if "title" not in columns:
    db.execute("ALTER TABLE sessions ADD COLUMN title TEXT NOT NULL DEFAULT ''")
db.execute("INSERT OR REPLACE INTO sessions(id, started_at, title) VALUES(?,?,?)", ("op-secret-session", time.time(), "operator secret session"))
db.commit()
db.close()
PY
  MARKER="$("${PYTHON_CMD[@]}" - "$(winpath "$GUEST_DB")" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute("SELECT id FROM sessions WHERE id=?", ("op-secret-session",)).fetchone()
print("FOUND" if row else "ABSENT")
db.close()
PY
)"
  ok "$([ "$MARKER" = "ABSENT" ] && echo 1 || echo 0)" \
    "the operator's session is not in the guest's database" "$MARKER"
  if http_json_200 "http://127.0.0.1:$GUEST_PORT/sessions" "$BASE/guest-sessions.json" \
      && node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.exit(Array.isArray(d.sessions)&&!JSON.stringify(d).includes("op-secret-session")?0:1)' "$(winpath "$BASE/guest-sessions.json")"; then
    ok 1 "guest /sessions returns valid HTTP JSON without the operator session"
  else
    ok 0 "guest /sessions returns valid HTTP JSON without the operator session" "invalid HTTP response, JSON, or leaked session"
  fi
  if http_json_200 "http://127.0.0.1:$GUEST_PORT/session?id=op-secret-session" "$BASE/guest-session.json" \
      && node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.exit(["forbidden","unknown_session"].includes(d.error)&&!JSON.stringify(d).includes("op-secret-session")?0:1)' "$(winpath "$BASE/guest-session.json")"; then
    ok 1 "guest /session returns valid HTTP JSON denying the operator session"
  else
    ok 0 "guest /session returns valid HTTP JSON denying the operator session" "invalid HTTP response, JSON, or unexpected access"
  fi
else
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "each node has its own database file"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "each node has its own identity key"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "each instance has its own supervisor lifecycle record"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "the two nodes are different processes"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "the operator's session is not in the guest's database"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "guest /sessions valid response and isolation"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "guest /session valid denial response"
fi

# 6. guest environment ------------------------------------------------------
if grep -q 'WA_TEST_SECRET_API_KEY' "$GUEST_HOME/.wasm-agent/env" 2>/dev/null; then
  ok 0 "the guest home carries no operator secret"
else
  ok 1 "the guest home carries no operator secret"
fi
if [ "$STARTUP_READY" -eq 1 ] && [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -n "$GUEST_PID" ]; then
  if tr '\0' '\n' < "/proc/$GUEST_PID/environ" 2>/dev/null | grep -q 'WA_TEST_SECRET_API_KEY'; then
    ok 0 "the guest process did not inherit the operator's secret"
  else
    ok 1 "the guest process did not inherit the operator's secret"
  fi
elif [ "$STARTUP_READY" -eq 1 ]; then
  skip "the guest process environment is not readable on this platform" "the unit test proves the construction"
else
  skip "valid guest process identity/startup is required" "guest process environment secret isolation"
fi

# 7. a wrong listener is refused --------------------------------------------
say "checking a foreign listener on an instance port is refused"
"$SENTINEL" instance add foreign --port "$FOREIGN_PORT" --client-port "$EXTRA_CLIENT" --binary "$BIN_NATIVE" >/dev/null 2>&1
node -e 'require("net").createServer().listen(Number(process.argv[1]), "127.0.0.1")' "$FOREIGN_PORT" &
FOREIGN_JS=$!
sleep 2
FOREIGN_PID="$(pid_on_port "$FOREIGN_PORT")"
ok "$([ -n "$FOREIGN_PID" ] && echo 1 || echo 0)" "a foreign process is listening on the foreign port" "pid ${FOREIGN_PID:-none}"
if "$SENTINEL" --instance foreign instance stop >/dev/null 2>&1; then
  ok 0 "the sentinel refuses to stop a listener it did not start"
else
  ok 1 "the sentinel refuses to stop a listener it did not start"
fi
# A stale record naming a different pid must be refused too.
mkdir -p "$BASE/.wasm-agent/instances/foreign/.wasm-agent/sentinel"
printf '{"schema":1,"pid":999999,"node_id":"deadbeef","home":"%s","binary":"%s","binary_sha256":"","started_at":0,"process_start":1}' \
  "$BASE/.wasm-agent/instances/foreign" "$BIN" > "$BASE/.wasm-agent/instances/foreign/.wasm-agent/sentinel/node.json"
if "$SENTINEL" --instance foreign instance stop >/dev/null 2>&1; then
  ok 0 "a stale lifecycle record is refused"
else
  ok 1 "a stale lifecycle record is refused"
fi
# A *corrupt* record must refuse rather than fall back to serve.pid.
printf '{ broken' > "$BASE/.wasm-agent/instances/foreign/.wasm-agent/sentinel/node.json"
if "$SENTINEL" --instance foreign instance stop >/dev/null 2>&1; then
  ok 0 "a corrupt lifecycle record is refused"
else
  ok 1 "a corrupt lifecycle record is refused"
fi
# Starting a node on an occupied port is refused before it is spawned.
if "$SENTINEL" --instance foreign instance start >/dev/null 2>&1; then
  ok 0 "a start on an occupied port is refused"
else
  ok 1 "a start on an occupied port is refused"
fi
kill "$FOREIGN_JS" 2>/dev/null || true

# 8. lifecycle record mutations against the running operator ---------------
say "mutating the operator's lifecycle record; the sentinel must refuse, not kill"
if [ "$STARTUP_READY" -eq 1 ]; then
cp "$OP_RECORD" "$BASE/op-record.bak"
printf '{ broken' > "$OP_RECORD"
if "$SENTINEL" --instance op instance stop >/dev/null 2>&1; then
  ok 0 "a corrupt operator record does not stop the node"
else
  ok 1 "a corrupt operator record does not stop the node"
fi
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator is still running after the corrupt record"
cp "$BASE/op-record.bak" "$OP_RECORD"

# A forged serve.pid (legacy path) must not be adopted.
OP_INSTALL="$OP_HOME/install"
cp "$OP_INSTALL/serve.pid" "$BASE/op-serve.pid.bak" 2>/dev/null || true
rm -f "$OP_RECORD"
printf '999999\n' > "$OP_INSTALL/serve.pid"
if "$SENTINEL" --instance op instance stop >/dev/null 2>&1; then
  ok 0 "a forged legacy serve.pid is refused"
else
  ok 1 "a forged legacy serve.pid is refused"
fi
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator is still running after the forged pid"

# A record naming a different home must be refused.
cp "$BASE/op-record.bak" "$OP_RECORD"
node -e '
const fs=require("fs"); const p=process.argv[1]; const d=JSON.parse(fs.readFileSync(p,"utf8"));
d.home=process.argv[2]; fs.writeFileSync(p, JSON.stringify(d));
' "$(winpath "$OP_RECORD")" "$(winpath "$BASE/other-home")"
if "$SENTINEL" --instance op instance stop >/dev/null 2>&1; then
  ok 0 "a record naming a different home is refused"
else
  ok 1 "a record naming a different home is refused"
fi
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator is still running after the wrong-home record"

# A record whose node_id is not the live identity must be refused.
cp "$BASE/op-record.bak" "$OP_RECORD"
node -e '
const fs=require("fs"); const p=process.argv[1]; const d=JSON.parse(fs.readFileSync(p,"utf8"));
d.node_id="00000000000000000000000000000000"; fs.writeFileSync(p, JSON.stringify(d));
' "$(winpath "$OP_RECORD")"
if "$SENTINEL" --instance op instance stop >/dev/null 2>&1; then
  ok 0 "a record with a forged node_id is refused"
else
  ok 1 "a record with a forged node_id is refused"
fi
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator is still running after the forged identity"

# A record whose process marker does not match (a reused pid) must be refused.
cp "$BASE/op-record.bak" "$OP_RECORD"
node -e '
const fs=require("fs"); const p=process.argv[1]; const d=JSON.parse(fs.readFileSync(p,"utf8"));
d.process_start=1; fs.writeFileSync(p, JSON.stringify(d));
' "$(winpath "$OP_RECORD")"
if "$SENTINEL" --instance op instance stop >/dev/null 2>&1; then
  ok 0 "a record with a stale process marker is refused"
else
  ok 1 "a record with a stale process marker is refused"
fi
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator is still running after the stale marker"
cp "$BASE/op-record.bak" "$OP_RECORD"

# A stale record for a node this install really started - exactly what a gate deploy leaves
# behind - is adopted when serve.pid names the live listener and the identity proves it.
# Otherwise the first deploy would kill `request restart` forever (measured live: record pid
# 2280 against a live 12236).
cp "$BASE/op-record.bak" "$OP_RECORD"
printf '%s\n' "$(pid_on_port "$OP_PORT")" > "$OP_INSTALL/serve.pid"
node -e '
const fs=require("fs"); const p=process.argv[1]; const d=JSON.parse(fs.readFileSync(p,"utf8"));
d.pid=999999; fs.writeFileSync(p, JSON.stringify(d));
' "$(winpath "$OP_RECORD")"
"$SENTINEL" --instance op instance stop >/dev/null 2>&1
ok "$([ -z "$(node_id_of "$OP_PORT")" ] && echo 1 || echo 0)" "a stale record with a matching serve.pid is adopted and stopped"
start_instance op after-stale-adoption
STALE_RESTART_STATUS=$?
STALE_RESTART_ID="$(wait_node_id "$OP_PORT" 2>/dev/null || true)"
ok "$([ "$STALE_RESTART_STATUS" -eq 0 ] && [ "$STALE_RESTART_ID" = "$OP_ID" ] && echo 1 || echo 0)" \
  "the operator restarts with the same identity after stale-record adoption"

# Positive legacy adoption: no record, the real serve.pid, and a live /sync/head.
rm -f "$OP_RECORD"
printf '%s\n' "$(pid_on_port "$OP_PORT")" > "$OP_INSTALL/serve.pid"
ok "$([ ! -f "$OP_RECORD" ] && echo 1 || echo 0)" "the record is gone before adoption"
"$SENTINEL" --instance op instance stop >/dev/null 2>&1
ok "$([ -z "$(node_id_of "$OP_PORT")" ] && echo 1 || echo 0)" "a proven legacy node is adopted and stopped"
start_instance op after-legacy-adoption
LEGACY_RESTART_STATUS=$?
LEGACY_RESTART_ID="$(wait_node_id "$OP_PORT" 2>/dev/null || true)"
ok "$([ "$LEGACY_RESTART_STATUS" -eq 0 ] && [ "$LEGACY_RESTART_ID" = "$OP_ID" ] && echo 1 || echo 0)" \
  "the operator restarts with the same identity"
else
  skip "operator startup and identity are required" "a corrupt operator record does not stop the node"
  skip "operator startup and identity are required" "operator remains live after corrupt record"
  skip "operator startup and identity are required" "a forged legacy serve.pid is refused"
  skip "operator startup and identity are required" "operator remains live after forged pid"
  skip "operator startup and identity are required" "a record naming a different home is refused"
  skip "operator startup and identity are required" "operator remains live after wrong-home record"
  skip "operator startup and identity are required" "a record with a forged node_id is refused"
  skip "operator startup and identity are required" "operator remains live after forged identity"
  skip "operator startup and identity are required" "a record with a stale process marker is refused"
  skip "operator startup and identity are required" "operator remains live after stale process marker"
  skip "operator startup and identity are required" "a stale record with matching serve.pid is adopted and stopped"
  skip "operator startup and identity are required" "operator restart keeps identity after stale-record adoption"
  skip "operator startup and identity are required" "the record is gone before legacy adoption"
  skip "operator startup and identity are required" "a proven legacy node is adopted and stopped"
  skip "operator startup and identity are required" "operator restart keeps identity after legacy adoption"
fi

# 9. stop/restart A cannot affect B -----------------------------------------
say "stopping and restarting the operator; the guest must not move"
if [ "$STARTUP_READY" -eq 1 ]; then
  GUEST_PID_AFTER="$(pid_of "$GUEST_RECORD")"
  "$SENTINEL" --instance op instance stop >"$BASE/op-isolation-stop.stdout" 2>"$BASE/op-isolation-stop.stderr"
  OP_STOP_STATUS=$?
  sleep 1
  ok "$([ "$OP_STOP_STATUS" -eq 0 ] && [ -z "$(node_id_of "$OP_PORT")" ] && echo 1 || echo 0)" "the operator is stopped"
  ok "$([ "$(node_id_of "$GUEST_PORT")" = "$GUEST_ID" ] && [ "$(pid_of "$GUEST_RECORD")" = "$GUEST_PID_AFTER" ] && echo 1 || echo 0)" \
    "the guest is untouched by the operator's stop"
  start_instance op isolation-restart
  ISOLATION_RESTART_STATUS=$?
  ISOLATION_RESTART_ID="$(wait_node_id "$OP_PORT" 2>/dev/null || true)"
  ok "$([ "$ISOLATION_RESTART_STATUS" -eq 0 ] && [ "$ISOLATION_RESTART_ID" = "$OP_ID" ] && echo 1 || echo 0)" \
    "the operator restarts with the same identity"
  ok "$([ "$(node_id_of "$GUEST_PORT")" = "$GUEST_ID" ] && [ "$(pid_of "$GUEST_RECORD")" = "$GUEST_PID_AFTER" ] && echo 1 || echo 0)" \
    "the guest is untouched by the operator's restart"
else
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "the operator is stopped"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "the guest is untouched by the operator's stop"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "the operator restarts with the same identity"
  skip "both nodes must pass sentinel startup and valid HTTP /sync/head checks" "the guest is untouched by the operator's restart"
fi

# 10. corrupt registry is an error and is not overwritten --------------------
say "corrupting the registry; load must fail and the file must not change"
cp "$BASE/instances.json" "$BASE/registry.bak"
printf '{ not json' > "$BASE/instances.json"
BEFORE="$(cat "$BASE/instances.json")"
if "$SENTINEL" instance list >/dev/null 2>&1; then
  ok 0 "a corrupt registry is an error, not an empty registry"
else
  ok 1 "a corrupt registry is an error, not an empty registry"
fi
if "$SENTINEL" instance add after-corrupt --port $((P + 12)) --client-port $((P + 13)) --binary "$BIN_NATIVE" >/dev/null 2>&1; then
  ok 0 "add refuses to overwrite a corrupt registry"
else
  ok 1 "add refuses to overwrite a corrupt registry"
fi
AFTER="$(cat "$BASE/instances.json")"
ok "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)" "the corrupt registry is byte-for-byte unchanged"
cp "$BASE/registry.bak" "$BASE/instances.json"

# 11. purge refuses a home the sentinel does not own -------------------------
say "checking remove --purge safety"
if [ "$STARTUP_READY" -eq 1 ]; then
  if "$SENTINEL" instance remove op --purge >"$BASE/purge-running.stdout" 2>"$BASE/purge-running.stderr"; then
    ok 0 "purge refuses a running instance"
  else
    ok 1 "purge refuses a running instance"
  fi
  "$SENTINEL" --instance op instance stop >"$BASE/purge-op-stop.stdout" 2>"$BASE/purge-op-stop.stderr" || true
else
  skip "successful operator startup and valid identity are required" "purge refuses a running instance"
fi
# A home whose owned marker was removed must not be purged.
"$SENTINEL" instance add markerless --port $((P + 14)) --client-port $((P + 15)) --binary "$BIN_NATIVE" >/dev/null 2>&1
MARKERLESS_HOME="$BASE/.wasm-agent/instances/markerless"
rm -f "$MARKERLESS_HOME/.wasm-agent/instance.json"
if "$SENTINEL" instance remove markerless --purge >/dev/null 2>&1; then
  ok 0 "purge refuses a home without an owned marker"
else
  ok 1 "purge refuses a home without an owned marker"
fi
ok "$([ -d "$MARKERLESS_HOME" ] && echo 1 || echo 0)" "the markerless home is left in place"
"$SENTINEL" --instance guest1 instance stop >/dev/null 2>&1
if "$SENTINEL" instance remove guest1 --purge >/dev/null 2>&1; then
  ok 1 "purge removes an owned home"
else
  ok 0 "purge removes an owned home"
fi
ok "$([ ! -d "$GUEST_HOME" ] && echo 1 || echo 0)" "the owned guest home is gone"

# Cleanup is part of the fixture contract: use sentinel pid/identity checks, then verify our ports
# are free. If that proof fails, report failure and retain the evidence instead of killing by name.
cleanup_nodes
if [ "$cleanup_failed" -eq 1 ]; then
  ok 0 "test-owned operator and guest processes are stopped safely"
else
  ok 1 "test-owned operator and guest processes are stopped safely"
fi

# verdict -------------------------------------------------------------------
{
  printf '{"suite":"test-node-instances","checks":%d,"failed":%d,"skipped":%d,"ok":%s,"failed_names":[' \
    "$checks" "$failed" "$skipped" "$([ "$failed" -eq 0 ] && echo true || echo false)"
  first=1
  for n in "${failed_names[@]:-}"; do
    [ -z "$n" ] && continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '"%s"' "$(printf '%s' "$n" | sed 's/"/\\"/g')"
  done
  printf '],"skipped_names":['
  first=1
  for n in "${skipped_names[@]:-}"; do
    [ -z "$n" ] && continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '"%s"' "$(printf '%s' "$n" | sed 's/"/\\"/g')"
  done
  printf '],"at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$VERDICT"

if [ "$failed" -eq 0 ]; then
  echo "node instances ok ($checks checks, $skipped skipped)"
else
  echo "node instances FAILED ($failed of $checks, $skipped skipped) - see $VERDICT"
  exit 1
fi
