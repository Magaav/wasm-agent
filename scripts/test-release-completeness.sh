#!/usr/bin/env bash
# Is a published commit INSTALLABLE BY DOWNLOAD? - the check that was missing after a publish (24/11).
#
# THE DEFECT (24/11). Publishing is per landing and covers the node binary only; a node also needs the
# components bundle named by the sha256 of its components.lock. A landing that moved the lock published a
# binary whose bundle was never made - components-df6f97708c72 answered HTTP 404 - and every node without a
# toolchain refused the update, with nothing in the publish path saying which asset was missing.
#
# WHAT RUNS HERE. The real scripts/lib/release-completeness.sh and scripts/check-release-complete.sh, against a
# LOCAL HTTP STAND-IN of the release channel (python3 -m http.server over a fixture tree, WA_RELEASE_DOWNLOAD_BASE
# pointed at it): no network, no gh, no node, nothing published. The rows:
#   * every asset 200 -> complete, exit 0;
#   * the components bundle gone (THE 24/11 SHAPE) -> exit 1 and the verdict "<sha12> is NOT installable by
#     download: components-<lock12>/<name>.wasm missing";
#   * one node asset missing (the signature) -> exit 1 naming it;
#   * the manifest missing -> exit 1 naming the manifest, not a short asset list;
#   * a channel that does not answer at all -> exit 2 unknown, and never "complete" (unknown is not yes);
#   * the tag asked for is the one THIS COMMIT's lock names, not the working tree's: the fixture moves the
#     lock after the commit, and the row proves the bundle named is the committed one.
#
# Scratch HOME/WASM_AGENT_HOME through scripts/lib/scratch-home.sh; the server is a child of this test and is
# stopped by its own PID (never by name).
#
#   bash scripts/test-release-completeness.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"

root="$(wa_scratch_root wa-release-completeness)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
REAL_HOME="${HOME:-}"
export HOME="$W/home"
mkdir -p "$HOME"
HOME="$REAL_HOME" wa_scratch_home_guard "$W/home" || exit 2
export WASM_AGENT_HOME="$HOME"

checks=0; failed=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
command -v python3 >/dev/null 2>&1 || { echo 'test-release-completeness: needs python3 for the local stand-in'; exit 2; }

# ---- a fixture commit whose lock and manifest we control -------------------------------------------
REPO="$W/repo"
mkdir -p "$REPO/scripts/lib"
git -c init.defaultBranch=main init -q "$REPO"
printf 'svc-a %064d 3\nsvc-b %064d 4\n' 1 2 > "$REPO/components.lock"
( cd "$REPO" && git add components.lock && git -c user.email=t@t -c user.name=t commit -qm lock )
COMMIT="$(git -C "$REPO" rev-parse HEAD)"
SHORT="${COMMIT:0:12}"
# The bundle tag the COMMITTED lock names.
LOCK_SHA="$(sha256sum < "$REPO/components.lock" | awk '{print $1}')"
LOCK_TAG="components-${LOCK_SHA:0:12}"
# ...and the working tree's lock, moved AFTER the commit: the check must not use it.
printf 'svc-a %064d 3\n' 9 > "$REPO/components.lock"
TREE_LOCK_SHA="$(sha256sum < "$REPO/components.lock" | awk '{print $1}')"
ok "$([ "$LOCK_TAG" != "components-${TREE_LOCK_SHA:0:12}" ] && echo 1)" "the fixture's committed lock and its working-tree lock name different bundles"

MANIFEST_DIR="$W/manifest"
mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST_DIR/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$COMMIT
built_utc=2026-11-24T00:00:00Z
x86_64-unknown-linux-gnu deadbeef 11 feedface 22
MANIFEST

# ---- the channel: a local directory tree served over HTTP ------------------------------------------
SRV="$W/srv"
DIST="$SRV/Magaav/wasm-agent/releases/download"
mkdir -p "$DIST/node-$SHORT" "$DIST/$LOCK_TAG"
for asset in "node-$SHORT.manifest" SHA256SUMS SHA256SUMS.sig wa-x86_64-unknown-linux-gnu-$SHORT wa-sentinel-x86_64-unknown-linux-gnu-$SHORT; do
  printf 'x' > "$DIST/node-$SHORT/$asset"
done
for name in svc-a svc-b; do
  printf 'x' > "$DIST/$LOCK_TAG/$name.wasm"
  printf 'x' > "$DIST/$LOCK_TAG/$name.json"
done
printf 'x' > "$DIST/$LOCK_TAG/components.lock"
# A tag of another lock, which is what a publish from the working tree would have produced: present, so a
# check reading the working tree would answer 200 and call the release complete.
mkdir -p "$DIST/components-${TREE_LOCK_SHA:0:12}"
for name in svc-a; do printf 'x' > "$DIST/components-${TREE_LOCK_SHA:0:12}/$name.wasm"; printf 'x' > "$DIST/components-${TREE_LOCK_SHA:0:12}/$name.json"; done
printf 'x' > "$DIST/components-${TREE_LOCK_SHA:0:12}/components.lock"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
[ -n "$PORT" ] || { echo 'test-release-completeness: no free port for the stand-in' >&2; exit 2; }
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" >"$W/server.log" 2>&1 &
SERVER_PID=$!
export WA_RELEASE_DOWNLOAD_BASE="http://127.0.0.1:$PORT"
export WA_RELEASE_API_BASE="http://127.0.0.1:$PORT/api"
for _ in $(seq 1 50); do
  curl -fsS -m 2 -o /dev/null "$WA_RELEASE_DOWNLOAD_BASE/Magaav/wasm-agent/releases/download/node-$SHORT/SHA256SUMS" 2>/dev/null && break
  sleep 0.1
done

. "$ROOT/scripts/lib/release-completeness.sh"
run() { bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" --repo "$REPO" --manifest-dir "$MANIFEST_DIR" 2>&1; }

# ---- 1. every asset answers 200 -> complete ----------------------------------------------------------
out="$(run)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "a release whose every asset answers 200 is complete" "rc=$rc $(printf '%s' "$out" | tail -3)"
ok "$(printf '%s\n' "$out" | grep -q '^200 wa-x86_64-unknown-linux-gnu-' && echo 1)" "the node assets are listed with their status" "$(printf '%s' "$out" | head -3)"
ok "$(printf '%s\n' "$out" | grep -q "^200 svc-b.wasm .*/$LOCK_TAG/svc-b.wasm" && echo 1)" "and every pinned component of THIS COMMIT's lock" "$(printf '%s' "$out" | tail -4)"
ok "$(printf '%s\n' "$out" | grep -q "components-${TREE_LOCK_SHA:0:12}" && echo 0 || echo 1)" "the working tree's lock is never the one asked for (it is not in the URLs)"

# ---- 2. THE 24/11 SHAPE: the components bundle was never published -----------------------------------
rm -rf "$DIST/$LOCK_TAG"
out="$(run)"; rc=$?
ok "$([ "$rc" = 1 ] && echo 1)" "a commit whose components bundle is missing is NOT installable by download" "rc=$rc"
ok "$([ "$(printf '%s\n' "$out" | tail -1)" = "$SHORT is NOT installable by download: $LOCK_TAG/svc-a.wasm missing" ] && echo 1)" "and the sentence names the bundle and the asset" "$(printf '%s\n' "$out" | tail -1)"

# ---- 3. one node asset missing (the signature) -------------------------------------------------------
mkdir -p "$DIST/$LOCK_TAG"
for name in svc-a svc-b; do printf 'x' > "$DIST/$LOCK_TAG/$name.wasm"; printf 'x' > "$DIST/$LOCK_TAG/$name.json"; done
printf 'x' > "$DIST/$LOCK_TAG/components.lock"
rm -f "$DIST/node-$SHORT/SHA256SUMS.sig"
out="$(run)"; rc=$?
ok "$([ "$rc" = 1 ] && echo 1)" "a node release without its signature is not installable" "rc=$rc"
ok "$(printf '%s\n' "$out" | tail -1 | grep -q 'SHA256SUMS.sig missing' && echo 1)" "and the verdict names the signature" "$(printf '%s\n' "$out" | tail -1)"
printf 'x' > "$DIST/node-$SHORT/SHA256SUMS.sig"

# ---- 4. the manifest itself is missing: named, not a short asset list --------------------------------
rm -f "$MANIFEST_DIR/node-$SHORT.manifest"
rm -f "$DIST/node-$SHORT/node-$SHORT.manifest"
out="$(run)"; rc=$?
ok "$([ "$rc" = 1 ] && echo 1)" "a release with no manifest at all is not installable" "rc=$rc"
ok "$(printf '%s\n' "$out" | tail -1 | grep -q "node-$SHORT.manifest missing" && echo 1)" "and the verdict names the manifest" "$(printf '%s\n' "$out" | tail -1)"
cat > "$MANIFEST_DIR/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$COMMIT
built_utc=2026-11-24T00:00:00Z
x86_64-unknown-linux-gnu deadbeef 11 feedface 22
MANIFEST
printf 'x' > "$DIST/node-$SHORT/node-$SHORT.manifest"

# ---- 5. a channel that does not answer: unknown, never complete --------------------------------------
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
out="$(run)"; rc=$?
ok "$([ "$rc" = 2 ] && echo 1)" "a channel that does not answer is unknown, not complete" "rc=$rc"
ok "$(printf '%s\n' "$out" | grep -qi 'not the same as installable' && echo 1)" "and the verdict says so in words" "$(printf '%s\n' "$out" | tail -2)"

# ---- 6. --json carries the row releases.jsonl records ------------------------------------------------
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" >"$W/server2.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS -m 2 -o /dev/null "$WA_RELEASE_DOWNLOAD_BASE/Magaav/wasm-agent/releases/download/node-$SHORT/SHA256SUMS" 2>/dev/null && break
  sleep 0.1
done
rm -rf "$DIST/$LOCK_TAG"
line="$(bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" --repo "$REPO" --manifest-dir "$MANIFEST_DIR" --json 2>/dev/null)"; rc=$?
ok "$([ "$rc" = 1 ] && echo 1)" "--json exits with the verdict it prints" "rc=$rc line=$line"
ok "$(printf '%s' "$line" | grep -q '"installable":"no"' && echo 1)" "the json row says installable=no" "$line"
ok "$(printf '%s' "$line" | grep -q "\"missing\":\"$LOCK_TAG/svc-a.wasm\"" && echo 1)" "and names the missing asset" "$line"
ok "$(printf '%s' "$line" | grep -q "\"sha\":\"$COMMIT\"" && echo 1)" "keyed by the commit" "$line"

printf 'release completeness ok (%d checks, %d failed)\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
