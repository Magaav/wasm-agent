#!/usr/bin/env bash
# The components question, asked BEFORE a deploy touches anything (24/11, work 20:56Z).
#
# THE DEFECT. `wa update` on work downloaded and verified node-9a0c589adfa0, then found no bundle for its
# lock (components-df6f97708c72: HTTP 404), spent two minutes fetching a toolchain for the fallback build,
# and died inside cargo: 117 s for an answer that was available in the first second. A core and its
# components are one install, so a deploy that cannot supply the components has nothing to do.
#
# WHAT RUNS HERE. The real wa_components_preflight (scripts/lib/deploy-components.sh):
#   * every pinned component already installed and matching -> 0, and NOBODY IS ASKED (a dead channel proves
#     it: the answer does not change);
#   * a cache entry for this lock with the right bytes -> the same;
#   * missing locally, bundle published -> 0 (the deploy fetches it);
#   * missing locally, bundle NOT published, no cargo/rustup on PATH -> 1 and the one sentence: "this commit
#     needs components-<x>, which is not published; this node cannot build it";
#   * the same with a cargo and a rustup on PATH -> 0 (a build can supply them: the answer is not the same
#     question as "is it published");
#   * a channel that does not answer -> 2 UNKNOWN, never 0 and never the missing sentence;
#   * WA_DEPLOY_COMPONENT_SOURCE set -> 0 without asking anybody;
#   * and the real scripts/deploy.sh says it in its FIRST lines: a tree whose lock names an unpublished bundle
#     refuses with refused(component_not_installable) and does not reach the binary decision or a build.
#     (If this test is itself running inside a node turn, the deploy's own turn guard refuses first and the
#     row says SKIP by name - that is the guard working, not this change.)
#
# The cargo/rustup on PATH in one row are two files that exist and are executable: the question asked there is
# "is a toolchain present", and the row says so - no build is run. No network beyond a local HTTP stand-in
# for the channel; scratch HOME through scripts/lib/scratch-home.sh.
#
#   bash scripts/test-components-preflight.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/deploy-components.sh"
. "$ROOT/scripts/lib/release-completeness.sh"

root="$(wa_scratch_root wa-components-preflight)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
SRV_PID=""
WT=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ -n "$WT" ] && git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  chmod -R u+w "$W" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
REAL_HOME="${HOME:-}"
export HOME="$W/home"
mkdir -p "$HOME"
HOME="$REAL_HOME" wa_scratch_home_guard "$W/home" || exit 2
export WASM_AGENT_HOME="$HOME"
unset WA_DEPLOY_COMPONENT_SOURCE WA_COMPONENTS_DIR WA_COMPONENTS_CACHE WA_COMPONENT_TOOLCHAIN

checks=0; failed=0; skipped=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip() { skipped=$((skipped + 1)); printf '  SKIP %s%s\n' "$1" "${2:+ - $2}"; }

# ---- a fixture lock, and the bytes that satisfy it -------------------------------------------------
REPO="$W/repo"
mkdir -p "$REPO/scripts/lib"
cp "$ROOT/scripts/publish-components.sh" "$REPO/scripts/publish-components.sh"
for lib in deploy-components.sh component-build-root.sh shared-commit.sh release-completeness.sh; do cp "$ROOT/scripts/lib/$lib" "$REPO/scripts/lib/$lib"; done
printf 'component-one\n' > "$W/one.wasm"
printf '{"name":"component-one"}\n' > "$W/one.json"
SHA="$(sha256sum < "$W/one.wasm" | awk '{print $1}')"
BYTES="$(wc -c < "$W/one.wasm" | tr -d '[:space:]')"
printf 'component-one %s %s\n' "$SHA" "$BYTES" > "$REPO/components.lock"
TAG="components-$(sha256sum < "$REPO/components.lock" | awk '{print $1}' | cut -c1-12)"
INSTALL="$W/install"
mkdir -p "$INSTALL"

# The channel stand-in: 200 when the tag's marker file exists, 404 when it does not.
SRV="$W/srv"
mkdir -p "$SRV/api/repos/Magaav/wasm-agent/releases/tags"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SRV" >"$W/srv.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/repos/Magaav/wasm-agent/releases/tags/nothing" 2>/dev/null && break
  sleep 0.1
done
export WA_RELEASE_API_BASE="http://127.0.0.1:$PORT/api"
export WA_COMPONENT_RELEASE_REPO="Magaav/wasm-agent"

# ---- 1. nothing local, channel says missing, no toolchain -> the sentence, rc 1 -----------------------
NO_TOOLCHAIN="$W/bin-notoolchain"
mkdir -p "$NO_TOOLCHAIN"
for t in bash sh git curl python3 sha256sum mkdir wc tr awk sed grep stat id uname dirname basename mktemp cp mv rm chmod cat date env; do
  p="$(command -v $t 2>/dev/null)" && ln -sf "$p" "$NO_TOOLCHAIN/$t" 2>/dev/null
done
out="$(PATH="$NO_TOOLCHAIN" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 1 ] && echo 1)" "nothing local, bundle unpublished, no toolchain: rc 1" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q "this commit needs $TAG, which is not published; this node cannot build it" && echo 1)" "the sentence a person needs, naming the bundle" "$out"
ok "$(printf '%s' "$out" | grep -q 'component-one' && echo 1)" "and which component is missing" "$out"

# ---- 2. the same with a toolchain present: a build can supply them, so rc 0 ---------------------------
WITH="$W/bin-withtoolchain"
mkdir -p "$WITH"
for t in "$NO_TOOLCHAIN"/*; do ln -sf "$t" "$WITH/$(basename "$t")" 2>/dev/null; done
printf '#!/bin/sh\nexit 0\n' > "$WITH/cargo"; chmod +x "$WITH/cargo"
printf '#!/bin/sh\nexit 0\n' > "$WITH/rustup"; chmod +x "$WITH/rustup"
out="$(PATH="$WITH" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 1)" "with cargo and rustup on PATH the answer is that a build can supply them (rc 0, nothing said)" "rc=$rc $out"

# ---- 3. the bundle is published: rc 0 (the deploy will fetch it) -------------------------------------
touch "$SRV/api/repos/Magaav/wasm-agent/releases/tags/$TAG"
out="$(PATH="$NO_TOOLCHAIN" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "a published bundle means the deploy can install this commit (rc 0)" "rc=$rc $out"
rm -f "$SRV/api/repos/Magaav/wasm-agent/releases/tags/$TAG"

# ---- 4. the components are already installed and match: rc 0 and NOBODY is asked ----------------------
COMP="$HOME/.wasm-agent/components"
mkdir -p "$COMP"
cp "$W/one.wasm" "$COMP/component-one.wasm"; cp "$W/one.json" "$COMP/component-one.json"
out="$(WA_RELEASE_API_BASE="http://127.0.0.1:1/api" PATH="$NO_TOOLCHAIN" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "an installed, matching component answers without asking anybody" "rc=$rc $out"
ok "$(! printf '%s' "$out" | grep -q 'could not be asked' && echo 1)" "and the dead channel is never consulted" "$out"
rm -f "$COMP/component-one.wasm" "$COMP/component-one.json"

# ---- 5. a cache entry for this lock: rc 0, no question either ----------------------------------------
LOCK_SHA="$(wa_component_lock_sha "$REPO")"
CACHE="$INSTALL/components-cache/$LOCK_SHA"
mkdir -p "$CACHE"
cp "$W/one.wasm" "$CACHE/component-one.wasm"; cp "$W/one.json" "$CACHE/component-one.json"; : > "$CACHE/.complete"
out="$(WA_RELEASE_API_BASE="http://127.0.0.1:1/api" PATH="$NO_TOOLCHAIN" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "a cached bundle for this lock answers without the channel" "rc=$rc $out"
rm -rf "$INSTALL/components-cache"

# ---- 6. the channel does not answer: UNKNOWN, never 0 and never the missing sentence ------------------
out="$(WA_RELEASE_API_BASE="http://127.0.0.1:1/api" PATH="$NO_TOOLCHAIN" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 2 ] && echo 1)" "an unanswerable channel is rc 2 (unknown), not a pass" "rc=$rc $out"
ok "$(printf '%s' "$out" | grep -q 'unknown is not published' && echo 1)" "and it says unknown is not published" "$out"

# ---- 7. WA_DEPLOY_COMPONENT_SOURCE: an operator's directory answers for it ----------------------------
WA_DEPLOY_COMPONENT_SOURCE="$W" out="$(WA_RELEASE_API_BASE="http://127.0.0.1:1/api" PATH="$NO_TOOLCHAIN" wa_components_preflight "$REPO" "$INSTALL" component-one 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "WA_DEPLOY_COMPONENT_SOURCE answers without the channel" "rc=$rc $out"

# ---- 8. the REAL deploy says it in its first lines ----------------------------------------------------
# A detached worktree of this commit whose lock names a bundle nobody published, a scratch install dir, a
# free port, a channel that cannot answer, and no toolchain: the deploy must refuse with the sentence above
# and never reach the binary decision or a build.
WT="$W/tree"
if git -C "$ROOT" worktree add -q --detach "$WT" HEAD 2>/dev/null; then
  sed -i 's/^\(codemode \)[0-9a-f]*/\1ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' "$WT/components.lock" 2>/dev/null
  mkdir -p "$W/live-install"
  out="$(cd "$WT" && env -u WASM_AGENT_IN_TURN WA_DEPLOY_ROOT="$WT" WA_INSTALL_DIR="$W/live-install" WA_PORT=18471 \
    WA_RELEASE_API_BASE="http://127.0.0.1:1/api" HOME="$HOME" PATH="$NO_TOOLCHAIN" \
    bash scripts/deploy.sh --reason components-preflight-test 2>&1)"; rc=$?
  if printf '%s' "$out" | grep -q 'cannot deploy from a turn running on the node'; then
    skip "the real deploy's first lines" "this test runs inside a node turn, so the deploy's turn guard refuses first"
  else
    ok "$([ "$rc" != 0 ] && echo 1)" "the deploy refuses a commit whose components cannot be supplied" "rc=$rc $(printf '%s' "$out" | tail -3)"
    ok "$(printf '%s' "$out" | grep -q 'refused(component_not_installable): this commit needs components-' && echo 1)" "with the sentence, in its first lines" "$(printf '%s' "$out" | head -6)"
    ok "$(! printf '%s' "$out" | grep -qE 'deploy: building|binary_source|deploy: compiled' && echo 1)" "and before the binary decision or a build" "$(printf '%s' "$out" | head -12)"
  fi
else
  skip "the real deploy's first lines" "this checkout cannot add a worktree at HEAD"
fi

printf 'components preflight ok (%d checks, %d failed, %d skipped)\n' "$checks" "$failed" "$skipped"
[ "$failed" = 0 ] || exit 1
exit 0
