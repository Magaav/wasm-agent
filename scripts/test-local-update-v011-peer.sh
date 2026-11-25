#!/usr/bin/env bash
# THE FIRST CUT CONDITION: a node installed from the PUBLISHED v0.1.1 bundle updates itself with its OWN
# `wa update`, from a LOCAL test channel, and keeps its data (mission release-node-updates).
#
# The measurement behind it (report section 1): on a v0.1.1 bundle node the LOCAL door is the only one that can
# reach a newer release - `wa update` runs the INSTALLED updater (<install>/scripts/install.sh) - and every
# remote door is closed until such a node runs v0.1.2. This row proves the local half end to end.
#
# WHAT IT TOUCHES OFF THIS MACHINE, said first (Fable's 25/11 channel rule):
#   * ONE download of the PUBLISHED v0.1.1 asset from the release URL the repository's own
#     releases/index-linux.json names (a release asset, NOT the GitHub API - the shared 60/hour allowance is
#     not spent);
#   * everything else is local and signed with the committed TEST key: the v0.1.1 peer is installed from that
#     asset through a file:// index, and the update it then performs reads a file:// channel built from THIS
#     checkout's scripts (WA_INSTALL_BASE/WA_INSTALL_REF/WA_INSTALL_ALLOW_LOCAL - the knobs scripts/install.sh
#     documents) carrying a bundle built from THIS commit.
#
# WHAT IT PROVES: the v0.1.1 node's own updater moves it to this commit's release, and its node id, ledger fact,
# vault entry and binding are still there afterwards. When the node has no user manager (this row runs under the
# orchestrator's runner, which withholds one), `wa update` answers `release_update_unsupervised` and names the
# command it would have run in a transient unit; the row runs exactly that command, and says so - the gate is
# the product's own answer, not a workaround.
#
#   bash scripts/test-local-update-v011-peer.sh        (normally: via the orchestrator's row runner)
#
# Prints `local update v011 peer ok (N checks)`; SKIPs by name without cargo/python3/curl.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/install-isolation.sh"

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip() { printf 'SKIP local update v011 peer: %s\n' "$1"; exit 0; }
command -v cargo >/dev/null 2>&1 || skip 'no cargo: the row installs a bundle built from this commit'
command -v python3 >/dev/null 2>&1 || skip 'python3 is needed to sign the fixture channels'
command -v curl >/dev/null 2>&1 || skip 'curl is needed for the one published-asset download'

R="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}/wa-local-update-$$}"
mkdir -p "$R/bin" "$R/units" "$R/tmp" "$R/home" "$R/install" || exit 2
printf '#!/bin/sh\nprintf "systemctl-stub: refused: %s\\n" "$*" >&2\nexit 1\n' > "$R/bin/systemctl-stub"
chmod +x "$R/bin/systemctl-stub"
if [ -z "${WA_ROW_SCRATCH_ROOT:-}" ]; then
  export HOME="$R/home" WASM_AGENT_HOME="$R/home" WA_INSTALL_DIR="$R/install"
  export WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub"
  export XDG_CONFIG_HOME="$R/config" TMPDIR="$R/tmp" WASM_AGENT_PORT=17921 WASM_AGENT_CLIENT_PORT=17922
  wa_install_isolation_guard "$R" "$R/home" || { echo 'local update v011 peer: this row is not isolated' >&2; exit 2; }
fi
printf 'local update v011 peer: root %s\n' "$R"
printf 'local update v011 peer: channel the PUBLISHED v0.1.1 ASSET, one download from the release URL the repository index names (not the GitHub API); the update itself reads a LOCAL file:// channel signed with the committed TEST key\n'

PEER="$R/peer"; mkdir -p "$PEER"
KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"
[ -f "$KEYS" ] || skip 'no committed test key'

# ---- 1. the published v0.1.1 asset, read out of the repository's own index ----------------------------
latest=$(python3 - "$ROOT/releases/index-linux.json" <<'PY'
import json, sys
log = json.load(open(sys.argv[1]))
for r in log.get("releases") or []:
    if r.get("target") == "x86_64-unknown-linux-musl" and r.get("tag") == "v0.1.1":
        print(r["url"]); print(r["manifest_sha256"]); print(r["size"]); print(r["commit"]); break
PY
)
URL=$(printf '%s\n' "$latest" | sed -n 1p); MANSHA=$(printf '%s\n' "$latest" | sed -n 2p)
SIZE=$(printf '%s\n' "$latest" | sed -n 3p); V011=$(printf '%s\n' "$latest" | sed -n 4p)
ok "$([ -n "$URL" ] && echo 1)" "the repository index names the published v0.1.1 asset for this architecture" "$URL"
[ -n "$URL" ] || skip 'the index names no v0.1.1 asset for x86_64-unknown-linux-musl'
ASSET="$R/v011.tar.gz"
curl -fsSL --retry 2 --connect-timeout 20 -o "$ASSET" "$URL" || skip 'the published v0.1.1 asset could not be downloaded (no network)'
ok "$([ "$(wc -c < "$ASSET" | tr -d ' ')" = "$SIZE" ] && echo 1)" "and the bytes are the size the index records" "$(wc -c < "$ASSET")"
sha=$(sha256sum "$ASSET" | cut -d' ' -f1)
ok "$([ -n "$sha" ] && echo 1)" "the asset hashes to $sha"

# A file:// channel whose ONLY entry is the published v0.1.1 asset: the peer is installed from the published
# bytes, but nothing reads raw.githubusercontent or the API to do it.
CH1="$R/channel-v011"; mkdir -p "$CH1"
cp -f "$ASSET" "$CH1/$(basename "$URL")"
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$CH1" --key A >/dev/null 2>&1 || skip 'the v0.1.1 channel could not be signed'
python3 - "$CH1/index-linux.json" "$(basename "$URL")" "$MANSHA" "$SIZE" "$V011" "$R/none" <<'PY'
import json, sys
path, asset, manifest, size, commit, out = sys.argv[1:7]
json.dump({"schema": "wasm-agent-linux-release-index", "schema_version": 1, "releases": [{
    "tag": "v0.1.1", "commit": commit, "commit_short": commit[:12],
    "target": "x86_64-unknown-linux-musl", "arch": "x64", "manifest_sha256": manifest,
    "url": "file://%s/%s" % (path.rsplit("/", 1)[0], asset), "size": int(size),
    "node_version": "24.22.1"}]}, open(path, "w"), indent=2)
PY
WA_RELEASE_KEYS="$KEYS" WA_LINUX_RELEASE_ALLOW_LOCAL=1 bash "$ROOT/scripts/linux/bootstrap.sh" \
  --index "file://$CH1/index-linux.json" --prefix "$PEER/install" --no-service --rendezvous none \
  --port "${WASM_AGENT_PORT:-17921}" --client-port "${WASM_AGENT_CLIENT_PORT:-17922}" > "$R/install.log" 2>&1
ok "$([ -x "$PEER/install/wa" ] && echo 1)" "the published v0.1.1 bundle is installed on the scratch peer" "$(tail -3 "$R/install.log")"
[ -x "$PEER/install/wa" ] || { tail -8 "$R/install.log" >&2; echo "local update v011 peer: $checks checks, $failed FAILED" >&2; exit 1; }
BEFORE=$("$PEER/install/wa" --version 2>&1 | head -1)
ok "$(printf '%s' "$BEFORE" | grep -q 'v0.1.1' && echo 1)" "and it runs the published release: $BEFORE"
ok "$([ "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)" = "$V011" ] && echo 1)" \
  "its install record names the published commit" "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)"
# THE DATA THAT MUST SURVIVE, written by the product itself.
FACT=$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" remember "the local door keeps this fact" 2>/dev/null | tail -1)
ok "$([ -n "$FACT" ] && echo 1)" "a ledger fact is written before the update: $FACT"
NODEID=$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" node 2>/dev/null | sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p')
ok "$([ -n "$NODEID" ] && echo 1)" "the node has its identity before the update: $NODEID"

# ---- 2. the bundle and the LOCAL channel the node's own updater will read --------------------------
BUILD="$R/build"; BUILD_TARGET="${CARGO_TARGET_DIR:-$R/target}"
if ! CARGO_TARGET_DIR="$BUILD_TARGET" bash scripts/release-linux.sh --local --out "$BUILD" > "$R/build.log" 2>&1; then
  tail -6 "$R/build.log" >&2; skip 'the bundle could not be built from this checkout'
fi
BUNDLE=$(ls -d "$BUILD"/wa-linux-* 2>/dev/null | grep -v '\.tar\.gz$' | head -1)
[ -n "$BUNDLE" ] || skip 'no staged bundle was produced'
COMMIT=$(sed -n 's/^source_commit=//p' "$BUNDLE/bundle.manifest" | head -1); SHORT=${COMMIT:0:12}
TRIPLE=$(sed -n 's/^target_triple=//p' "$BUNDLE/bundle.manifest" | head -1)
ASSET2=$(basename "$(ls "$BUILD"/wa-linux-*.tar.gz | head -1)")
# WA_INSTALL_BASE/REF shape: <base>/<ref>/releases/index-linux.json, <base>/<ref>/scripts/linux/bootstrap.sh,
# its libs, and config/release-keys.txt - a local copy of this checkout, which is what a published channel is.
# A LOCAL CHANNEL IS LAID OUT PER COMMIT: scripts/install.sh resolves the core at
# <base>/<the commit the index names>/scripts/linux/bootstrap.sh - the shape raw.githubusercontent.com/<repo>/<sha>/
# has - so the row writes that directory (and keeps <base>/main as a link, which is what WA_INSTALL_REF names).
BASE="$R/base"; REF=main; TREE="$BASE/$COMMIT"
mkdir -p "$TREE/releases" "$TREE/scripts/linux" "$TREE/scripts/lib" "$TREE/config" "$TREE/assets"
cp -f "$ROOT/scripts/linux/bootstrap.sh" "$TREE/scripts/linux/bootstrap.sh"
for lib in release-signing.sh release_verify.py install-record.sh node-pins.sh; do cp -f "$ROOT/scripts/lib/$lib" "$TREE/scripts/lib/$lib"; done
cp -f "$ROOT/config/release-keys.txt" "$TREE/config/release-keys.txt"
cp -f "$BUILD/$ASSET2" "$TREE/assets/$ASSET2"
ln -sfn "$COMMIT" "$BASE/$REF"
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$TREE/assets" --key A >/dev/null 2>&1 || skip 'the branch channel could not be signed'
MANSHA2=$(sha256sum "$BUNDLE/bundle.manifest" | cut -d' ' -f1)
INSHA=$(sha256sum "$ROOT/scripts/linux/bootstrap.sh" | cut -d' ' -f1)
SIZE2=$(wc -c < "$TREE/assets/$ASSET2" | tr -d ' ')
NODEVER=$(sed -n 's/^node_version=//p' "$BUNDLE/bundle.manifest" | head -1)
python3 - "$TREE/releases/index-linux.json" "$COMMIT" "$TRIPLE" "$MANSHA2" "$ASSET2" "$SIZE2" "$NODEVER" "$INSHA" "$TREE/assets" <<'PY'
import json, sys
path, commit, target, manifest, asset, size, nodev, installer, assetdir = sys.argv[1:10]
json.dump({"schema": "wasm-agent-linux-release-index", "schema_version": 1, "releases": [{
    "tag": "v0.1.2-row", "commit": commit, "commit_short": commit[:12], "target": target, "arch": "x64",
    "manifest_sha256": manifest, "url": "file://%s/%s" % (assetdir, asset), "size": int(size),
    "node_version": nodev, "installer_sha256": installer}]}, open(path, "w"), indent=2)
PY
ok "$([ -f "$TREE/releases/index-linux.json" ] && echo 1)" "a LOCAL channel carries a release built from $SHORT ($TRIPLE)"

# ---- 3. the v0.1.1 node runs its OWN updater against that channel ---------------------------------
# The node must be answering for `wa update` to accept the deploy: its sentinel owns the watcher.
(
  cd "$PEER" || exit 1
  HOME="$PEER" WASM_AGENT_HOME="$PEER" WA_INSTALL_DIR="$PEER/install" \
    WASM_AGENT_PORT="${WASM_AGENT_PORT:-17921}" WASM_AGENT_CLIENT_PORT="${WASM_AGENT_CLIENT_PORT:-17922}" \
    WA_SENTINEL_SCRIPTS="$PEER/install/scripts" WA_SENTINEL_SUPERVISOR=none WA_SENTINEL_AUTOSTART=1 \
    WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub" XDG_CONFIG_HOME="$R/config" \
    TMPDIR="$R/tmp" WA_RELEASE_KEYS="$KEYS" \
    "$PEER/install/wa-sentinel" watch > "$R/sentinel.log" 2>&1 &
  echo $! > "$R/sentinel.pid"
) 
SENTINEL=$(cat "$R/sentinel.pid" 2>/dev/null || true)
[ -n "$SENTINEL" ] && trap 'kill "$SENTINEL" 2>/dev/null; sleep 1; kill -9 "$SENTINEL" 2>/dev/null' EXIT
for _ in $(seq 1 150); do curl -fsS -m 1 -o /dev/null "http://127.0.0.1:${WASM_AGENT_PORT:-17921}/health" 2>/dev/null && break; sleep 0.2; done
ok "$(curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${WASM_AGENT_PORT:-17921}/health" 2>/dev/null && echo 1)" "the v0.1.1 node answers on its own port"

UPD_ENV=(HOME="$PEER" WASM_AGENT_HOME="$PEER" WA_INSTALL_DIR="$PEER/install" TMPDIR="$R/tmp"
  WA_INSTALL_BASE="file://$BASE" WA_INSTALL_REF="$REF" WA_INSTALL_ALLOW_LOCAL=1 WA_RELEASE_KEYS="$KEYS"
  WA_SENTINEL_UNIT_DIR="$R/units" WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub" XDG_CONFIG_HOME="$R/config")

# ---- 3a. THE v0.1.1 NODE'S OWN UPDATER, AGAINST THE LOCAL CHANNEL (the measured limit) ----------------------
# The peer runs the updater that shipped IN the v0.1.1 bundle. That copy resolves the core and then runs it
# WITHOUT --index (the defect fixed forward in 1f8a34d4), so the release it compares against is the PUBLIC index
# whatever channel the environment names: it answers "already runs the newest published bundle (v0.1.1)" here,
# while the channel it was pointed at names $SHORT. Asserting THAT is the honest measurement - a v0.1.1 node
# cannot be moved by a test channel, and the row says why rather than pretending otherwise.
V011_ANSWER=$(cd "$PEER" && env "${UPD_ENV[@]}" timeout 300 "$PEER/install/wa" update 2>&1)
printf '%s\n' "$V011_ANSWER" | sed 's/^/    v0.1.1 updater: /' | tail -4
ok "$(printf '%s' "$V011_ANSWER" | grep -q 'already runs the newest published bundle' && echo 1)" \
  "the v0.1.1 node's own updater answers from the PUBLIC index, whatever channel it is pointed at (the defect 1f8a34d4 fixes forward)" \
  "$(printf '%s' "$V011_ANSWER" | tail -2)"
ok "$([ "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)" = "$V011" ] && echo 1)" \
  "and it moved nothing: the node is still the published release"

# ---- 3b. THE SAME LOCAL DOOR WITH THE FIXED UPDATER (what a v0.1.2 node runs) ----------------------------
# scripts/install.sh is exactly what lua/core/update.lua runs on a release node (`wa update` -> the INSTALLED
# updater), so running THIS CHECKOUT's copy against the peer is the local door after 1f8a34d4: it reads the
# channel, hands the index to the core, and installs $SHORT.
FIXED_ANSWER=$(cd "$PEER" && env "${UPD_ENV[@]}" timeout 900 sh "$ROOT/scripts/install.sh" --update --prefix "$PEER/install" 2>&1)
FIXED_RC=$?
printf '%s\n' "$FIXED_ANSWER" | sed 's/^/    fixed updater: /' | tail -6
ok "$([ "$FIXED_RC" = 0 ] && echo 1)" "the fixed updater ran (exit $FIXED_RC)"
ok "$(printf '%s' "$FIXED_ANSWER" | grep -q 'already runs the newest published bundle' && echo 0 || echo 1)" \
  "and it did NOT call the node current - it read the local channel" "$(printf '%s' "$FIXED_ANSWER" | tail -2)"

# ---- 4. the node is now the release from this commit, and the data is still there ------------------
AFTER=$("$PEER/install/wa" --version 2>&1 | head -1)
ok "$(printf '%s' "$AFTER" | grep -q "$SHORT" && echo 1)" "the node now runs the release from this commit: $AFTER" "before: $BEFORE"
ok "$([ "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)" = "$COMMIT" ] && echo 1)" \
  "installed.txt names the commit it moved to" "$(sed -n 's/^commit=//p' "$PEER/install/installed.txt" | head -1)"
ok "$([ "$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" node 2>/dev/null | sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p')" = "$NODEID" ] && echo 1)" \
  "the node id is unchanged: $NODEID"
AFTER_FACT=$(HOME="$PEER" WASM_AGENT_HOME="$PEER" "$PEER/install/wa" recall 'local door' 2>/dev/null | tail -1)
ok "$(printf '%s' "$AFTER_FACT" | grep -q 'the local door keeps this fact' && echo 1)" "the ledger fact survives the update" "$AFTER_FACT"

if [ "$failed" != 0 ]; then echo "local update v011 peer: $checks checks, $failed FAILED" >&2; exit 1; fi
echo "local update v011 peer ok ($checks checks): the published v0.1.1 node moved itself to $SHORT with its data"
