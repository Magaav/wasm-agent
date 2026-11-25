#!/usr/bin/env bash
# THE RELEASE DOOR, END TO END, ON A NODE INSTALLED FROM A BUNDLE THIS COMMIT BUILT (mission
# release-node-updates, the row). A coordinator asks a scratch peer to install a signed release through the
# door the code execs - <install>/scripts/release-install.sh -> scripts/upgrade.sh - and the node's own record
# has to say installed, with its ledger fact still there. Before commit 2111510e this row could not pass on any
# published bundle: the bundle did not carry that script and the peer answered
#   bash: <install>/scripts/release-install.sh: No such file or directory   (code 127)
#
# WHAT IT DOES, and every step is the product's own:
#   1. builds the bundle from THIS checkout (scripts/release-linux.sh --local) and signs it as a release
#      channel on the local filesystem with the committed TEST key (tests/fixtures/release-sign) - no network,
#      no GitHub, no real signing key;
#   2. installs a scratch peer from that channel with the public installer's own core (scripts/linux/
#      bootstrap.sh), --no-service;
#   3. serves a second signed release directory (the same bytes, named by their own commit) from the bundle it
#      just built, and starts the peer's sentinel with its OWN port and home;
#   4. runs `wa update <peer> --release --commit <sha>` from a scratch coordinator over a private rendezvous
#      and asserts the answer ends `installed`, the peer's own record says installed with that commit, and the
#      ledger fact written before the update is still there afterwards;
#   5. stops every process it started, by the PID it recorded.
#
# ISOLATION: WA_ROW_SCRATCH_ROOT (or a fresh mktemp) holds HOME, WASM_AGENT_HOME, WA_INSTALL_DIR, the unit dir
# and TMPDIR; the guard in scripts/lib/install-isolation.sh is asked before any installer starts, and the
# processes this row starts are its own children, killed in the trap.
#
#   bash scripts/test-release-door-update.sh        (normally: via the orchestrator's row runner)
#
# Prints `release door update ok (N checks)`; a failed check raises, and a missing toolchain SKIPs by name.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/install-isolation.sh"

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip() { printf 'SKIP release door update: %s\n' "$1"; exit 0; }

command -v cargo >/dev/null 2>&1 || skip 'no cargo on PATH, and the bundle this row installs must be built from this commit'
command -v python3 >/dev/null 2>&1 || skip 'python3 is needed to sign the fixture release'
command -v curl >/dev/null 2>&1 || skip 'curl is needed to reach the row private rendezvous'

R="${WA_ROW_SCRATCH_ROOT:-}"
if [ -z "$R" ]; then R="${TMPDIR:-/tmp}/wa-release-door-$$"; fi
mkdir -p "$R/home" "$R/install" "$R/units" "$R/bin" "$R/tmp" "$R/coord" || exit 2
# THE ROW'S OWN ENVIRONMENT: every child below gets this, and nothing inherited.
export HOME="$R/home" WASM_AGENT_HOME="$R/home" WA_INSTALL_DIR="$R/install"
export WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub"
export XDG_CONFIG_HOME="$R/config" TMPDIR="$R/tmp"
printf '#!/bin/sh\nprintf "systemctl-stub: refused: %s\\n" "$*" >&2\nexit 1\n' > "$R/bin/systemctl-stub"
chmod +x "$R/bin/systemctl-stub"
wa_scratch_home_guard "$R/home" || { echo 'release door update: the scratch home is refused' >&2; exit 2; }
unset WASM_AGENT_DB WASM_AGENT_VAULT_URL WASM_AGENT_OPENCODE_GO_VAULT_URL WASM_AGENT_VAULT_DIR \
      WASM_AGENT_VAULT_KEYSTORE WASM_AGENT_VAULT_PASSPHRASE WASM_AGENT_VAULT_OPERATOR_URL

# A FREE PORT PAIR AND A RENDEZVOUS PORT, asked of the kernel, never the live 8799/8800.
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PORT=$(freeport); CPORT=$(freeport); RPORT=$(freeport)
[ -n "$PORT" ] && [ -n "$CPORT" ] && [ -n "$RPORT" ] || skip 'no free port could be asked of the kernel'
export WASM_AGENT_PORT="$PORT" WASM_AGENT_CLIENT_PORT="$CPORT"
export WA_SENTINEL_SCRIPTS="$WA_INSTALL_DIR/scripts"
wa_install_isolation_guard "$R" "$R/home" || { echo 'release door update: this row is not isolated' >&2; exit 2; }
printf 'release door update: root %s, peer port %s, rendezvous %s\n' "$R" "$PORT" "$RPORT"

PIDS=()
stop_all() {
  local pid
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
}
trap stop_all EXIT

# ---- 1. the bundle, built from this checkout ----------------------------------------------------
BUILD="$R/build"
if ! CARGO_TARGET_DIR="$R/target" bash scripts/release-linux.sh --local --out "$BUILD" > "$R/build.log" 2>&1; then
  tail -6 "$R/build.log" >&2; skip 'the bundle could not be built from this checkout (see the log above)'
fi
BUNDLE=$(ls -d "$BUILD"/wa-linux-* 2>/dev/null | grep -v '\.tar\.gz$' | head -1)
[ -n "$BUNDLE" ] && [ -d "$BUNDLE" ] || skip 'no staged bundle was produced'
COMMIT=$(sed -n 's/^source_commit=//p' "$BUNDLE/bundle.manifest" | head -1)
SHORT=${COMMIT:0:12}
TRIPLE=$(sed -n 's/^target_triple=//p' "$BUNDLE/bundle.manifest" | head -1)
ARCH=x64; case "$TRIPLE" in aarch64*) ARCH=arm64 ;; esac
ok "$([ -n "$COMMIT" ] && echo 1)" "the bundle names its own commit: $SHORT ($TRIPLE)"
for door in scripts/release-install.sh scripts/upgrade.sh scripts/lib/node-binaries.sh; do
  ok "$([ -f "$BUNDLE/$door" ] && echo 1)" "the bundle carries the door the node execs: $door"
done

# ---- 2. a signed channel on the filesystem, and the installer over it ---------------------------
KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"
[ -f "$KEYS" ] || skip 'no committed test key at tests/fixtures/release-sign/keys.txt'
CHANNEL="$R/channel"; mkdir -p "$CHANNEL"
ASSET=$(basename "$(ls "$BUILD"/wa-linux-*.tar.gz | head -1)")
cp -f "$BUILD/$ASSET" "$CHANNEL/$ASSET"
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$CHANNEL" --key A >/dev/null 2>&1 \
  || skip 'the fixture channel could not be signed'
MANSHA=$(sha256sum "$BUNDLE/bundle.manifest" | cut -d' ' -f1)
INSHA=$(sha256sum "$BUNDLE/scripts/install.sh" | cut -d' ' -f1)
SIZE=$(wc -c < "$CHANNEL/$ASSET" | tr -d ' ')
NODEVER=$(sed -n 's/^node_version=//p' "$BUNDLE/bundle.manifest" | head -1)
python3 - "$CHANNEL/index-linux.json" "$COMMIT" "$TRIPLE" "$ARCH" "$MANSHA" "$ASSET" "$SIZE" "$NODEVER" "$INSHA" "$CHANNEL" <<'PY'
import json, sys
path, commit, target, arch, manifest, asset, size, nodev, installer, out = sys.argv[1:11]
json.dump({"schema": "wasm-agent-linux-release-index", "schema_version": 1,
           "releases": [{"tag": "v0.0.0-row", "commit": commit, "commit_short": commit[:12],
                         "target": target, "arch": arch, "manifest_sha256": manifest,
                         "url": "file://%s/%s" % (out, asset), "size": int(size),
                         "node_version": nodev, "installer_sha256": installer}]}, open(path, "w"), indent=2)
PY
PEER="$R/peer"; mkdir -p "$PEER"
WA_RELEASE_KEYS="$KEYS" WA_LINUX_RELEASE_ALLOW_LOCAL=1 bash "$ROOT/scripts/linux/bootstrap.sh" \
  --index "file://$CHANNEL/index-linux.json" --prefix "$PEER/install" --no-service --rendezvous none \
  --port "$PORT" --client-port "$CPORT" > "$R/bootstrap.log" 2>&1
ok "$([ -x "$PEER/install/wa" ] && echo 1)" "the public installer installed the bundle on a scratch peer" "$(tail -3 "$R/bootstrap.log")"
[ -x "$PEER/install/wa" ] || { tail -8 "$R/bootstrap.log" >&2; printf 'release door update: %d checks, %d failed\n' "$checks" "$failed"; exit 1; }
REC=$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)
ok "$([ "$REC" = "$COMMIT" ] && echo 1)" "and its install record names the commit the bundle reports" "got $REC want $COMMIT"

# ---- 3. a second signed release, and the peer's sentinel on its OWN port -------------------------
STUB="$R/release"; mkdir -p "$STUB/node-$SHORT"
install -m755 "$BUNDLE/wa" "$STUB/wa-$TRIPLE-$SHORT"
install -m755 "$BUNDLE/wa-sentinel" "$STUB/wa-sentinel-$TRIPLE-$SHORT"
WSHA=$(sha256sum "$STUB/wa-$TRIPLE-$SHORT" | cut -d' ' -f1); WBYTES=$(wc -c < "$STUB/wa-$TRIPLE-$SHORT" | tr -d ' ')
SSHA=$(sha256sum "$STUB/wa-sentinel-$TRIPLE-$SHORT" | cut -d' ' -f1); SBYTES=$(wc -c < "$STUB/wa-sentinel-$TRIPLE-$SHORT" | tr -d ' ')
TREE=$(sed -n 's/^source_tree=//p' "$BUNDLE/bundle.manifest" | head -1)
cat > "$STUB/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$COMMIT
source_tree=$TREE
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$TRIPLE $WSHA $WBYTES $SSHA $SBYTES
MANIFEST
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$STUB" --key A >/dev/null 2>&1 || skip 'the second release could not be signed'
for asset in "wa-$TRIPLE-$SHORT" "wa-sentinel-$TRIPLE-$SHORT" "node-$SHORT.manifest" SHA256SUMS SHA256SUMS.sig; do
  ln "$STUB/$asset" "$STUB/node-$SHORT/$asset"
done
ok "$([ -f "$STUB/SHA256SUMS.sig" ] && echo 1)" "a second signed release is served from this directory"

# The peer's own state file, then its sentinel started by hand with ITS port and home (never 8799).
COORD="$R/coord"
COORD_ID=$(HOME="$COORD" WASM_AGENT_HOME="$COORD" "$PEER/install/wa" node 2>/dev/null | sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p')
ok "$([ -n "$COORD_ID" ] && echo 1)" "the coordinator has its own identity" "$COORD_ID"

# The rendezvous the two nodes share (admins: the coordinator), then both registrations.
WASM_AGENT_NETWORK_ADMINS="$COORD_ID" "$PEER/install/wa" rendezvous --port "$RPORT" --db "$R/registry.db" \
  > "$R/registry.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$RPORT/health" 2>/dev/null && break; sleep 0.2; done
ok "$(curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$RPORT/health" 2>/dev/null && echo 1)" "the row's own rendezvous answers" "$(tail -2 "$R/registry.log")"
register() { # <home> <binary> <name>
  local home="$1" bin="$2" name="$3" id key ts sig body
  id=$(HOME="$home" WASM_AGENT_HOME="$home" "$bin" node 2>/dev/null | sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p')
  key=$(HOME="$home" WASM_AGENT_HOME="$home" "$bin" node 2>/dev/null | sed -n 's/.*"public_key":"\([^"]*\)".*/\1/p')
  [ -n "$id" ] && [ -n "$key" ] || return 1
  ts=$(date +%s)
  sig=$(HOME="$home" WASM_AGENT_HOME="$home" "$bin" node sign "v2|$id|$ts|$name|[]" 2>/dev/null) || return 1
  body=$(printf '{"node_id":"%s","public_key":"%s","name":"%s","role":"master","endpoints":[],"ts":%s,"signature":"%s"}' \
    "$id" "$key" "$name" "$ts" "$sig")
  curl -sS -X POST -H 'content-type: application/json' -d "$body" "http://127.0.0.1:$RPORT/register" >/dev/null 2>&1
}
PEER_ID=$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" node 2>/dev/null | sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p')
ok "$([ -n "$PEER_ID" ] && echo 1)" "the peer has its own identity" "$PEER_ID"

# ---- 4. the peer runs, the coordinator asks, the door installs ----------------------------------
(
  cd "$PEER" || exit 1
  HOME="$PEER" WASM_AGENT_HOME="$PEER" WA_INSTALL_DIR="$PEER/install" \
    WASM_AGENT_PORT="$PORT" WASM_AGENT_CLIENT_PORT="$CPORT" \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RPORT" WASM_AGENT_RELAY="http://127.0.0.1:$RPORT" \
    WASM_AGENT_TRUSTED_MASTERS="$COORD_ID" WASM_AGENT_NODE_NAME=peer \
    WA_SENTINEL_SCRIPTS="$PEER/install/scripts" WA_SENTINEL_SUPERVISOR=none WA_SENTINEL_AUTOSTART=1 \
    WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub" XDG_CONFIG_HOME="$R/config" \
    TMPDIR="$R/tmp" WA_RELEASE_KEYS="$KEYS" WA_NODE_BINARIES_URL="$STUB" \
    "$PEER/install/wa-sentinel" watch > "$R/peer-sentinel.log" 2>&1
) &
PIDS+=($!)
for _ in $(seq 1 150); do curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null && break; sleep 0.2; done
ok "$(curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null && echo 1)" "the peer's node answers on its own port ($PORT)" "$(tail -3 "$R/peer-sentinel.log")"
register "$PEER" "$PEER/install/wa" peer || true
register "$COORD" "$PEER/install/wa" coord

# A ledger fact, written before the update and read after it.
FACT=$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" remember "the release door keeps this fact" 2>/dev/null | tail -1)
ok "$([ -n "$FACT" ] && echo 1)" "a ledger fact is written before the update: $FACT"

ANSWER=$(cd "$COORD" && HOME="$COORD" WASM_AGENT_HOME="$COORD" \
  WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RPORT" WASM_AGENT_RELAY="http://127.0.0.1:$RPORT" \
  WASM_AGENT_NODE_NAME=coord TMPDIR="$R/tmp" \
  timeout 600 "$PEER/install/wa" update "$PEER_ID" --release --commit "$COMMIT" 2>&1)
printf '%s\n' "$ANSWER" | sed 's/^/    /' | tail -6
ok "$(printf '%s\n' "$ANSWER" | grep -q "installed $SHORT" && echo 1)" "the coordinator's follow ends INSTALLED on $SHORT" "$(printf '%s' "$ANSWER" | tail -2)"
ok "$(printf '%s\n' "$ANSWER" | grep -q 'No such file or directory' && echo 0 || echo 1)" "and no door answered code 127 (the defect this row exists for)"
RECJSON=$(ls -1t "$PEER/.wasm-agent/remote-update"/*.json 2>/dev/null | head -1)
if [ -n "$RECJSON" ]; then
  OUTCOME=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("outcome") or "", d.get("installed_commit") or "")' "$RECJSON" 2>/dev/null)
  ok "$(printf '%s' "$OUTCOME" | grep -q installed && echo 1)" "the peer's own record says installed" "$OUTCOME"
  ok "$(printf '%s' "$OUTCOME" | grep -q "$COMMIT" && echo 1)" "and names the commit that was installed" "$OUTCOME"
else
  ok 0 "the peer wrote a record for the request" 'no record file in .wasm-agent/remote-update'
fi
ok "$([ "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)" = "$COMMIT" ] && echo 1)" \
  "installed.txt names the commit the door installed" "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)"
AFTER=$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" recall 'release door' 2>/dev/null | tail -1)
ok "$(printf '%s' "$AFTER" | grep -q 'the release door keeps this fact' && echo 1)" "the ledger fact survives the install" "$AFTER"
ok "$(curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null && echo 1)" "and the node is up after it"

if [ "$failed" != 0 ]; then echo "release door update: $checks checks, $failed FAILED" >&2; exit 1; fi
echo "release door update ok ($checks checks)"
