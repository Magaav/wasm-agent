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
skip_row() { skipped=$((skipped + 1)); printf '  SKIP %s%s\n' "$1" "${2:+ - $2}"; }
skipped=0
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

# ---- 7. --components: the one question a check and a deploy owe first -------------------------------
# Missing bundle + no toolchain on PATH -> the sentence and exit 1; with a cargo/rustup on PATH -> exit 0,
# because a build can supply them (a different cost, and the row says which).
NO_TOOLCHAIN="$W/bin-notoolchain"
mkdir -p "$NO_TOOLCHAIN"
for t in bash sh git curl python3 sha256sum mkdir wc tr awk sed grep stat id uname dirname basename mktemp cp mv rm chmod cat date env; do
  p="$(command -v $t 2>/dev/null)" && ln -sf "$p" "$NO_TOOLCHAIN/$t" 2>/dev/null
done
out="$(PATH="$NO_TOOLCHAIN" bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" --repo "$REPO" --components 2>&1)"; rc=$?
ok "$([ "$rc" = 1 ] && echo 1)" "--components says rc 1 when the bundle is missing and this node cannot build it" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q "this commit needs $LOCK_TAG, which is not published; this node cannot build it" && echo 1)" "with the sentence a person needs" "$out"
WITH="$W/bin-withtoolchain"
mkdir -p "$WITH"
for t in "$NO_TOOLCHAIN"/*; do ln -sf "$t" "$WITH/$(basename "$t")" 2>/dev/null; done
printf '#!/bin/sh\nexit 0\n' > "$WITH/cargo"; chmod +x "$WITH/cargo"
printf '#!/bin/sh\nexit 0\n' > "$WITH/rustup"; chmod +x "$WITH/rustup"
out="$(PATH="$WITH" bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" --repo "$REPO" --components 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "and rc 0 when a build could supply them" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q 'buildable=yes' && echo 1)" "saying so in its fields" "$out"
mkdir -p "$DIST/$LOCK_TAG"
for name in svc-a svc-b; do printf 'x' > "$DIST/$LOCK_TAG/$name.wasm"; printf 'x' > "$DIST/$LOCK_TAG/$name.json"; done
printf 'x' > "$DIST/$LOCK_TAG/components.lock"
mkdir -p "$W/srv/api/repos/Magaav/wasm-agent/releases/tags"
touch "$W/srv/api/repos/Magaav/wasm-agent/releases/tags/$LOCK_TAG"
out="$(PATH="$NO_TOOLCHAIN" bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" --repo "$REPO" --components 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "and rc 0 with components=published when the bundle is there" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q 'components=published' && echo 1)" "naming the state in a field" "$out"

# ---- 8. a channel that accepts and then says nothing: UNKNOWN inside the stated bound, never a hang ------
# The --components question runs while a person waits for `wa update --check`, so it runs to a STATED bound
# (10 s: scripts/check-release-complete.sh --components, the same bound as the update refresh). A closed
# port refuses in milliseconds and would prove nothing about the bound, so the channel here ACCEPTS the
# connection and sends nothing (scripts/lib/http-stub.py: a file with a `.stall` sidecar of 0 bytes).
STUBROOT="$W/stub"; mkdir -p "$STUBROOT/repos/Magaav/wasm-agent/releases/tags"
STUBTAG="$STUBROOT/repos/Magaav/wasm-agent/releases/tags/$LOCK_TAG"
printf '{}' > "$STUBTAG"; printf '0' > "$STUBTAG.stall"
STUBPORTFILE="$W/stub.port"; rm -f "$STUBPORTFILE"
python3 "$ROOT/scripts/lib/http-stub.py" "$STUBROOT" "$STUBPORTFILE" >"$W/stub.log" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$STUBPORTFILE" ] && break; sleep 0.1; done
STUBPORT="$(cat "$STUBPORTFILE" 2>/dev/null)"
if [ -z "$STUBPORT" ]; then
  skip_row "the stated bound" "scripts/lib/http-stub.py did not come up"
else
  started=$(date +%s)
  out="$(WA_RELEASE_API_BASE="http://127.0.0.1:$STUBPORT" bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" --repo "$REPO" --components 2>&1)"; rc=$?
  elapsed=$(( $(date +%s) - started ))
  ok "$([ "$rc" = 2 ] && echo 1)" "a channel that accepts and answers nothing is unknown, not a wait" "rc=$rc ${elapsed}s $out"
  ok "$(printf '%s' "$out" | grep -q 'components=unknown' && echo 1)" "and the fields say components=unknown" "$out"
  ok "$([ "$elapsed" -ge 8 ] && echo 1)" "it waited for the stated bound rather than giving up early (elapsed ${elapsed}s, bound 10s)" "elapsed=${elapsed}s"
  ok "$([ "$elapsed" -le 20 ] && echo 1)" "and did NOT hang past it (elapsed ${elapsed}s, bound 10s + 5s guard)" "elapsed=${elapsed}s"
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""
fi

# ---- 9. THE BUNDLE CARRIES EVERY DOOR THE CODE EXECS FROM THE INSTALL (25/11, release-node-updates D2) --
# A peer installed from the published v0.1.1 bundle accepted `wa update <node> --release`, queued it, and then
# died with "bash: <install>/scripts/release-install.sh: No such file or directory" (code 127): the packer's
# member list was written by hand and the code had grown a door. The list is derived from the code now
# (scripts/lib/install-script-doors.mjs), and these rows hold it to that: the derivation must read the code
# (a fixture door appears and a tree-relative path does not), an unclassified door must be a red gate, and a
# STAGED bundle missing a door must be refused before it can be tarred or published.
DOORS="$ROOT/scripts/lib/install-script-doors.mjs"
if [ ! -f "$DOORS" ]; then
  ok 0 "the install-side door derivation exists (scripts/lib/install-script-doors.mjs)" "the file is missing: a bundle's member list would be hand-written again"
else
  list="$(node "$DOORS" --root "$ROOT" --list 2>&1)"; rc=$?
  ok "$([ "$rc" = 0 ] && echo 1)" "the door list is derived from this tree" "rc=$rc $(printf '%s' "$list" | tail -2)"
  for member in scripts/release-install.sh scripts/upgrade.sh scripts/rollback-node.sh scripts/wave-entry.mjs scripts/lib/node-binaries.sh scripts/lib/install-record.sh; do
    ok "$(printf '%s\n' "$list" | grep -qx "$member" && echo 1)" "$member is a derived bundle member" "$(printf '%s' "$list" | tr '\n' ' ')"
  done

  # A FIXTURE TREE, so "derived" is proven and not assumed: a door the code names appears, a path the code
  # names only against a TREE does not, and a door the code names that the tree lacks is refused by name.
  MINI="$W/doors-mini"; mkdir -p "$MINI/lua/core" "$MINI/rust/src" "$MINI/scripts/lib" "$MINI/scripts"
  printf 'local install = "/opt/wa"\nlocal door = install .. "/scripts/fixture-door.sh"\nlocal tree = "/some/tree"\nlocal other = tree .. "/scripts/not-a-door.sh"\n' > "$MINI/lua/core/fixture.lua"
  printf '#!/bin/sh\nexit 0\n' > "$MINI/scripts/fixture-door.sh"
  printf '#!/bin/sh\nexit 0\n' > "$MINI/scripts/not-a-door.sh"
  mini="$(node "$DOORS" --root "$MINI" --list 2>&1)"; rc=$?
  ok "$([ "$rc" = 0 ] && printf '%s\n' "$mini" | grep -qx 'scripts/fixture-door.sh' && echo 1)" \
    "a <install>/scripts path the code names IS derived (the list reads the code, it is not written down)" "rc=$rc $(printf '%s' "$mini" | tr '\n' ' ')"
  ok "$(printf '%s\n' "$mini" | grep -qx 'scripts/not-a-door.sh' && echo 0 || echo 1)" \
    "a TREE-relative scripts path is not a bundle member (that tree is not in a bundle)"
  printf 'local install = "/opt/wa"\nlocal ghost = install .. "/scripts/ghost-door.sh"\n' > "$MINI/lua/core/ghost.lua"
  ghost="$(node "$DOORS" --root "$MINI" --list 2>&1)"; rc=$?
  ok "$([ "$rc" = 1 ] && printf '%s' "$ghost" | grep -q 'door_absent_in_tree: scripts/ghost-door.sh' && echo 1)" \
    "a door the code execs that this tree does not have is refused by name" "rc=$rc $(printf '%s' "$ghost" | tail -1)"
  rm -f "$MINI/lua/core/ghost.lua"

  # THE ALLOW-LIST IS A REVIEWED EXEMPTION, NOT A SILENT ONE: no reason is refused, and so is a line that
  # exempts something no code needs any more.
  printf 'scripts/fixture-door.sh\n' > "$MINI/scripts/lib/install-script-doors.allow"
  bare="$(node "$DOORS" --root "$MINI" --list 2>&1)"; rc=$?
  ok "$([ "$rc" = 1 ] && printf '%s' "$bare" | grep -q 'exemption_without_reason' && echo 1)" \
    "an exemption with no reason is refused" "rc=$rc $(printf '%s' "$bare" | tail -1)"
  printf 'scripts/fixture-door.sh # a fixture: this door is answered by name instead\n' > "$MINI/scripts/lib/install-script-doors.allow"
  exempted="$(node "$DOORS" --root "$MINI" --list 2>&1)"; rc=$?
  ok "$([ "$rc" = 0 ] && ! printf '%s\n' "$exempted" | grep -qx 'scripts/fixture-door.sh' && echo 1)" \
    "an exempt door is not a required member (and the list still answers)" "rc=$rc $(printf '%s' "$exempted" | tr '\n' ' ')"
  printf 'scripts/no-code-uses-this.sh # stale\n' > "$MINI/scripts/lib/install-script-doors.allow"
  stale="$(node "$DOORS" --root "$MINI" --list 2>&1)"; rc=$?
  ok "$([ "$rc" = 1 ] && printf '%s' "$stale" | grep -q 'stale_exemption' && echo 1)" \
    "an exemption nothing in the code needs is refused (an allow-list that drifts is a block-list)" "rc=$rc $(printf '%s' "$stale" | tail -1)"
  rm -f "$MINI/scripts/lib/install-script-doors.allow"

  # A STAGED BUNDLE: complete -> ok; a door removed -> refused BY NAME; a door present but not a member -> refused.
  STAGE="$W/doors-stage"; mkdir -p "$STAGE"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    mkdir -p "$STAGE/$(dirname "$member")"
    cp "$ROOT/$member" "$STAGE/$member"
  done <<< "$list"
  sums() { ( cd "$STAGE" && find . -type f ! -name files.sha256 -printf '%P\n' | LC_ALL=C sort \
    | while IFS= read -r f; do sha256sum -- "$f"; done ) > "$STAGE/files.sha256"; }
  sums
  out="$(node "$DOORS" --root "$ROOT" --check "$STAGE" 2>&1)"; rc=$?
  ok "$([ "$rc" = 0 ] && echo 1)" "a bundle staged from the derived list is complete" "rc=$rc $out"
  mv "$STAGE/scripts/release-install.sh" "$W/release-install.sh.kept"
  out="$(node "$DOORS" --root "$ROOT" --check "$STAGE" 2>&1)"; rc=$?
  ok "$([ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'door_missing: scripts/release-install.sh' && echo 1)" \
    "the published v0.1.1 bundle's defect is a red gate: no scripts/release-install.sh, named with the code site" \
    "rc=$rc $(printf '%s' "$out" | head -1)"
  mv "$W/release-install.sh.kept" "$STAGE/scripts/release-install.sh"
  sed -i '\|scripts/release-install.sh$|d' "$STAGE/files.sha256"
  out="$(node "$DOORS" --root "$ROOT" --check "$STAGE" 2>&1)"; rc=$?
  ok "$([ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'present but not a bundle member' && echo 1)" \
    "a door that sits in the directory but is not a member (files.sha256 does not name it) is refused too" \
    "rc=$rc $(printf '%s' "$out" | head -1)"
  # ...and the cases where the question cannot be asked at all are UNKNOWN, never a pass.
  mkdir -p "$W/doors-nosums"; out="$(node "$DOORS" --root "$ROOT" --check "$W/doors-nosums" 2>&1)"; rc=$?
  ok "$([ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'bundle_has_no_member_list' && echo 1)" \
    "a directory with no files.sha256 is unknown, not complete" "rc=$rc $(printf '%s' "$out" | tail -1)"

  # THE PACKER USES IT: the list is derived before staging and the stage is checked before it is tarred.
  derive_line="$(grep -n 'install-script-doors.mjs" --root "$ROOT" --list' "$ROOT/scripts/release-linux.sh" | head -1 | cut -d: -f1)"
  check_line="$(grep -n 'install-script-doors.mjs" --root "$ROOT" --check "$stage"' "$ROOT/scripts/release-linux.sh" | head -1 | cut -d: -f1)"
  tar_line="$(grep -n 'tar -C "$out" -czf' "$ROOT/scripts/release-linux.sh" | head -1 | cut -d: -f1)"
  ok "$([ -n "$derive_line" ] && [ -n "$check_line" ] && [ -n "$tar_line" ] && [ "$derive_line" -lt "$check_line" ] && [ "$check_line" -lt "$tar_line" ] && echo 1)" \
    "scripts/release-linux.sh derives the doors, checks the staged bundle, and only then tars it" \
    "derive=${derive_line:-none} check=${check_line:-none} tar=${tar_line:-none}"
fi

printf 'release completeness ok (%d checks, %d failed)\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
