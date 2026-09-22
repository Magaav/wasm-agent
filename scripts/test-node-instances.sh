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
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano -p TCP 2>/dev/null | grep -q ":$1 .*LISTENING"
  else
    ss -ltn 2>/dev/null | grep -q ":$1 "
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
node_id_of() { curl -s -m 5 "http://127.0.0.1:$1/sync/head" 2>/dev/null | sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p'; }
pid_on_port() {
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano -p TCP 2>/dev/null | grep ":$1 .*LISTENING" | awk '{print $5}' | head -1
  else
    ss -ltnp 2>/dev/null | grep ":$1 " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
  fi
}
kill_port() {
  local pid
  pid="$(pid_on_port "$1")"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}

OP_RECORD="$BASE/.wasm-agent/instances/op/.wasm-agent/sentinel/node.json"
GUEST_RECORD="$BASE/.wasm-agent/instances/guest1/.wasm-agent/sentinel/node.json"
stop_all() {
  for name in op guest1; do
    "$SENTINEL" instance stop "$name" >/dev/null 2>&1 || true
  done
  # Anything the graceful stop could not prove is killed by port here, for cleanup only.
  kill_port "$OP_PORT" 2>/dev/null || true
  kill_port "$GUEST_PORT" 2>/dev/null || true
  sleep 1
  rm -rf "$BASE" 2>/dev/null || true
}
trap stop_all EXIT
VERDICT="${WA_INSTANCE_VERDICT:-${TMPDIR:-/tmp}/wa-node-instances-verdict.json}"

P="$(pick_port_base)"
OP_PORT=$P; OP_CLIENT=$((P + 1)); GUEST_PORT=$((P + 2)); GUEST_CLIENT=$((P + 3)); FOREIGN_PORT=$((P + 4)); EXTRA_CLIENT=$((P + 5))
say "ports: op $OP_PORT/$OP_CLIENT  guest $GUEST_PORT/$GUEST_CLIENT  foreign $FOREIGN_PORT"

# 1. named setup ------------------------------------------------------------
say "setting up two named instances with separate homes, keys, databases and ports"
"$SENTINEL" instance add op --port "$OP_PORT" --client-port "$OP_CLIENT" --binary "$BIN" >/dev/null 2>&1
ok "$([ -f "$BASE/.wasm-agent/instances/op/.wasm-agent/node.role" ] && echo 1 || echo 0)" \
  "the operator instance has its own home and role file"
"$SENTINEL" instance add guest1 --port "$GUEST_PORT" --client-port "$GUEST_CLIENT" --role guest \
  --master "$VALID_MASTER" --binary "$BIN" >/dev/null 2>&1
ok "$([ "$(cat "$BASE/.wasm-agent/instances/guest1/.wasm-agent/node.role" 2>/dev/null)" = "guest" ] && echo 1 || echo 0)" \
  "the guest instance records its role"
ok "$(grep -q "WASM_AGENT_TRUSTED_MASTERS=$VALID_MASTER" "$BASE/.wasm-agent/instances/guest1/.wasm-agent/env" && echo 1 || echo 0)" \
  "the guest is explicitly bound to a remote master node id"

# A guest without a master, or with a name instead of a node id, is refused.
if "$SENTINEL" instance add rogue --port $((P + 10)) --client-port $((P + 11)) --role guest --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a guest without a remote master is refused"
else
  ok 1 "a guest without a remote master is refused"
fi
if "$SENTINEL" instance add rogue --port $((P + 10)) --client-port $((P + 11)) --role guest --master friendly-name --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a master alias is not accepted as a node id"
else
  ok 1 "a master alias is not accepted as a node id"
fi

# 2. port and path collisions ----------------------------------------------
if "$SENTINEL" instance add collide --port "$OP_PORT" --client-port "$EXTRA_CLIENT" --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a second instance cannot claim the operator's node port"
else
  ok 1 "a second instance cannot claim the operator's node port"
fi
# The cross-role case the first version missed: node port == the guest's *client* port.
if "$SENTINEL" instance add collide --port "$GUEST_CLIENT" --client-port "$EXTRA_CLIENT" --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a node port cannot collide with another instance's client port"
else
  ok 1 "a node port cannot collide with another instance's client port"
fi
# A home inside another instance's home.
if "$SENTINEL" instance add collide --port $((P + 12)) --client-port $((P + 13)) \
  --home "$BASE/.wasm-agent/instances/op/nested" --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a home inside another instance's home is refused"
else
  ok 1 "a home inside another instance's home is refused"
fi
# The operator home itself.
if "$SENTINEL" instance add collide --port $((P + 12)) --client-port $((P + 13)) \
  --home "$BASE" --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a named home cannot be the operator home"
else
  ok 1 "a named home cannot be the operator home"
fi
# A nonempty directory the operator points at by hand.
mkdir -p "$BASE/foreign-home"
echo "do not lose me" > "$BASE/foreign-home/precious.txt"
if "$SENTINEL" instance add collide --port $((P + 12)) --client-port $((P + 13)) \
  --home "$BASE/foreign-home" --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a nonempty foreign home is never overwritten"
else
  ok 1 "a nonempty foreign home is never overwritten"
fi
ok "$([ -f "$BASE/foreign-home/precious.txt" ] && echo 1 || echo 0)" "the foreign home is left intact"

# 3. protected environment shares -------------------------------------------
if "$SENTINEL" instance add share-bad --port $((P + 12)) --client-port $((P + 13)) \
  --role guest --master "$VALID_MASTER" --share "WASM_AGENT_NODE_ROLE=master" --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "a share cannot set the node role"
else
  ok 1 "a share cannot set the node role"
fi
if "$SENTINEL" instance add share-bad --port $((P + 12)) --client-port $((P + 13)) \
  --role guest --master "$VALID_MASTER" --share "WASM_AGENT_HOME=$BASE" --binary "$BIN" >/dev/null 2>&1; then
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
"$SENTINEL" --instance op instance start >/dev/null 2>&1
"$SENTINEL" --instance guest1 instance start >/dev/null 2>&1
OP_ID="$(node_id_of "$OP_PORT")"
GUEST_ID="$(node_id_of "$GUEST_PORT")"
ok "$([ -n "$OP_ID" ] && [ -n "$GUEST_ID" ] && echo 1 || echo 0)" "both nodes answer /sync/head"
ok "$([ -n "$OP_ID" ] && [ "$OP_ID" != "$GUEST_ID" ] && echo 1 || echo 0)" \
  "the two nodes have different identities" "op $OP_ID guest $GUEST_ID"

OP_HOME="$BASE/.wasm-agent/instances/op"
GUEST_HOME="$BASE/.wasm-agent/instances/guest1"
OP_DB="$OP_HOME/.wasm-agent/memory.db"
GUEST_DB="$GUEST_HOME/.wasm-agent/memory.db"
OP_KEY="$OP_HOME/.wasm-agent/node.key"
GUEST_KEY="$GUEST_HOME/.wasm-agent/node.key"
ok "$([ -f "$OP_DB" ] && [ -f "$GUEST_DB" ] && [ "$OP_DB" != "$GUEST_DB" ] && echo 1 || echo 0)" \
  "each node has its own database file"
ok "$([ -f "$OP_KEY" ] && [ -f "$GUEST_KEY" ] && ! cmp -s "$OP_KEY" "$GUEST_KEY" && echo 1 || echo 0)" \
  "each node has its own identity key"

ok "$([ -f "$OP_RECORD" ] && [ -f "$GUEST_RECORD" ] && echo 1 || echo 0)" \
  "each instance has its own supervisor lifecycle record"
OP_PID="$(pid_of "$OP_RECORD")"
GUEST_PID="$(pid_of "$GUEST_RECORD")"
ok "$([ -n "$OP_PID" ] && [ -n "$GUEST_PID" ] && [ "$OP_PID" != "$GUEST_PID" ] && echo 1 || echo 0)" \
  "the two nodes are different processes" "op pid $OP_PID guest pid $GUEST_PID"

# 5. the guest cannot read the operator's sessions or memory -----------------
say "checking the guest cannot see the operator's sessions or memory"
node -e '
const {DatabaseSync} = require("node:sqlite");
const db = new DatabaseSync(process.argv[1]);
db.exec("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, route_id TEXT NOT NULL DEFAULT \x27\x27, objective TEXT NOT NULL DEFAULT \x27\x27, parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL)");
const cols = db.prepare("PRAGMA table_info(sessions)").all().map(c => c.name);
if (!cols.includes("title")) db.exec("ALTER TABLE sessions ADD COLUMN title TEXT NOT NULL DEFAULT \x27\x27");
db.prepare("INSERT OR REPLACE INTO sessions(id, started_at, title) VALUES(?,?,?)").run("op-secret-session", Date.now()/1000, "operator secret session");
db.close();
' "$(winpath "$OP_DB")"
MARKER="$(node -e '
const {DatabaseSync} = require("node:sqlite");
const db = new DatabaseSync(process.argv[1]);
const row = db.prepare("SELECT id FROM sessions WHERE id=?").get("op-secret-session");
console.log(row ? "FOUND" : "ABSENT");
db.close();
' "$(winpath "$GUEST_DB")")"
ok "$([ "$MARKER" = "ABSENT" ] && echo 1 || echo 0)" \
  "the operator's session is not in the guest's database" "$MARKER"
GUEST_SESSIONS="$(curl -s -m 5 "http://127.0.0.1:$GUEST_PORT/sessions" 2>/dev/null)"
ok "$(printf '%s' "$GUEST_SESSIONS" | grep -q 'op-secret-session' && echo 0 || echo 1)" \
  "the guest's session list does not expose the operator's session"
GUEST_SESSION="$(curl -s -m 5 "http://127.0.0.1:$GUEST_PORT/session?id=op-secret-session" 2>/dev/null)"
ok "$(printf '%s' "$GUEST_SESSION" | grep -q 'op-secret-session' && echo 0 || echo 1)" \
  "the guest cannot read the operator's session by id"

# 6. guest environment ------------------------------------------------------
if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -n "$GUEST_PID" ]; then
  if tr '\0' '\n' < "/proc/$GUEST_PID/environ" 2>/dev/null | grep -q 'WA_TEST_SECRET_API_KEY'; then
    ok 0 "the guest process did not inherit the operator's secret"
  else
    ok 1 "the guest process did not inherit the operator's secret"
  fi
else
  if grep -q 'WA_TEST_SECRET_API_KEY' "$GUEST_HOME/.wasm-agent/env" 2>/dev/null; then
    ok 0 "the guest home carries no operator secret"
  else
    ok 1 "the guest home carries no operator secret"
  fi
  skip "the guest process did not inherit the operator's secret" "process environment is not readable on this platform; the unit test proves the construction"
fi

# 7. a wrong listener is refused --------------------------------------------
say "checking a foreign listener on an instance port is refused"
"$SENTINEL" instance add foreign --port "$FOREIGN_PORT" --client-port "$EXTRA_CLIENT" --binary "$BIN" >/dev/null 2>&1
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
"$SENTINEL" --instance op instance start >/dev/null 2>&1
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator restarts with the same identity after stale-record adoption"

# Positive legacy adoption: no record, the real serve.pid, and a live /sync/head.
rm -f "$OP_RECORD"
printf '%s\n' "$(pid_on_port "$OP_PORT")" > "$OP_INSTALL/serve.pid"
ok "$([ ! -f "$OP_RECORD" ] && echo 1 || echo 0)" "the record is gone before adoption"
"$SENTINEL" --instance op instance stop >/dev/null 2>&1
ok "$([ -z "$(node_id_of "$OP_PORT")" ] && echo 1 || echo 0)" "a proven legacy node is adopted and stopped"
"$SENTINEL" --instance op instance start >/dev/null 2>&1
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" "the operator restarts with the same identity"

# 9. stop/restart A cannot affect B -----------------------------------------
say "stopping and restarting the operator; the guest must not move"
GUEST_PID_AFTER="$(pid_of "$GUEST_RECORD")"
"$SENTINEL" --instance op instance stop >/dev/null 2>&1
sleep 1
ok "$([ -z "$(node_id_of "$OP_PORT")" ] && echo 1 || echo 0)" "the operator is stopped"
ok "$([ "$(node_id_of "$GUEST_PORT")" = "$GUEST_ID" ] && [ "$(pid_of "$GUEST_RECORD")" = "$GUEST_PID_AFTER" ] && echo 1 || echo 0)" \
  "the guest is untouched by the operator's stop"
"$SENTINEL" --instance op instance start >/dev/null 2>&1
ok "$([ "$(node_id_of "$OP_PORT")" = "$OP_ID" ] && echo 1 || echo 0)" \
  "the operator restarts with the same identity"
ok "$([ "$(node_id_of "$GUEST_PORT")" = "$GUEST_ID" ] && [ "$(pid_of "$GUEST_RECORD")" = "$GUEST_PID_AFTER" ] && echo 1 || echo 0)" \
  "the guest is untouched by the operator's restart"

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
if "$SENTINEL" instance add after-corrupt --port $((P + 12)) --client-port $((P + 13)) --binary "$BIN" >/dev/null 2>&1; then
  ok 0 "add refuses to overwrite a corrupt registry"
else
  ok 1 "add refuses to overwrite a corrupt registry"
fi
AFTER="$(cat "$BASE/instances.json")"
ok "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)" "the corrupt registry is byte-for-byte unchanged"
cp "$BASE/registry.bak" "$BASE/instances.json"

# 11. purge refuses a home the sentinel does not own -------------------------
say "checking remove --purge safety"
if "$SENTINEL" instance remove op --purge >/dev/null 2>&1; then
  ok 0 "purge refuses a running instance"
else
  ok 1 "purge refuses a running instance"
fi
"$SENTINEL" --instance op instance stop >/dev/null 2>&1
# A home whose owned marker was removed must not be purged.
"$SENTINEL" instance add markerless --port $((P + 14)) --client-port $((P + 15)) --binary "$BIN" >/dev/null 2>&1
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
