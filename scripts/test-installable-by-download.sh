#!/usr/bin/env bash
# THE ROW THAT WAS MISSING: is a commit INSTALLABLE BY DOWNLOAD?
#
#   bash scripts/test-installable-by-download.sh [<40-hex commit>]
#
# WHY (24/11). "wa update is failing ... fix root cause" (Victor). Work's update failed three times in one
# day for three different causes; the third is this row, measured at 20:56Z. The node binary of
# node-9a0c589adfa0 downloaded and verified, and the components did not:
#
#   component_release_unreachable: .../releases/download/components-df6f97708c72/codemode.wasm
#   codemode is not cached and the components-df6f97708c72 bundle could not be fetched      (HTTP 404)
#
# The components bundle is keyed by the sha256 of components.lock (scripts/lib/deploy-components.sh,
# wa_component_release_tag) and the per-landing publish covers the node binary only, so every landing after
# a lock change is uninstallable by download on a node without a toolchain - and nothing said so before the
# fleet step paid for it. This file asks the node's own question, with the node's own assets.
#
# WHAT IT DOES, in the order a node does it, on a SCRATCH HOME with NO TOOLCHAIN ON PATH and EMPTY caches:
#   1. the node binary: release node-<sha12> for this host's triple, manifest + signature + every pin
#      (scripts/lib/node-binaries.sh, wa_node_binary_download) - the real release channel, read-only;
#   2. the components: release components-<sha12 of this commit's components.lock>, every name the lock
#      pins, verified against the lock and installed into the scratch component directory
#      (scripts/lib/deploy-components.sh, wa_components_prepare + wa_components_install_set - the deploy's
#      own step 3e);
#   3. the PAIR: the downloaded binary answers a call through the downloaded component
#      (scripts/check-component-proof.lua with WA_COMPONENTS_DIR=<what was installed>), which is the proof
#      scripts/deploy.sh runs on a candidate before it installs anything;
#   4. NOTHING WAS BUILT: cargo, rustup, rustc and zig are removed from PATH, RUSTUP_HOME and CARGO_HOME
#      point into the scratch root, and the run fails if a toolchain appeared there. A row that could build
#      would not be about the download.
#
# THE ANSWER, one line, which is the sentence the land report and releases.jsonl carry (item 2):
#   <sha12> is NOT installable by download: <asset> missing (<why>)                          (exit 1)
#   installable by download: <sha12> (node-<sha12>, components-<lock12>, <n> components)     (exit 0)
#
# IT IS THE CUT CONDITION BEFORE THE FLEET STEP, and it is RED until the assets it needs are published:
# today (24/11, origin/main 39e862d60bad) the components release is 404. Not a gate row for that reason -
# scripts/test.sh runs it only when WA_INSTALLABLE_BY_DOWNLOAD=1 asks for it, and says SKIP otherwise.
#
# It reads GitHub (HEAD/GET of release assets) and touches nothing else: no publish, no node, no fleet.
#
# Exit: 0 installable, installed and proven; 1 NOT installable by download (named); 2 the harness cannot ask
# (no scratch root, no curl/gh, a toolchain it cannot keep off PATH, a commit it cannot read) - an
# unanswerable question is a refusal, never a pass; 3 the release channel could not be reached (skip).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"

say()  { printf 'installable-by-download: %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
refuse() { printf 'installable-by-download: refused(%s): %s\n' "$1" "$2" >&2; exit 2; }

COMMIT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) refuse "unknown_option" "$1" ;;
    *) COMMIT="$1"; shift ;;
  esac
done

# ---- scratch, and never the operator's store ----------------------------------------------------
root="$(wa_scratch_root wa-installable-by-download)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
HOME_DIR="$W/home"
wa_scratch_home_guard "$HOME_DIR" || { rm -rf "$W"; exit 2; }
mkdir -p "$HOME_DIR" "$W/install"
TREE="$W/tree"
cleanup() {
  git -C "$ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT

for tool in git curl gh; do
  command -v "$tool" >/dev/null 2>&1 || refuse "tool_missing" "$tool is not on PATH; this row asks the real release channel"
done

# ---- the commit: this checkout's origin/main unless one is named ---------------------------------
git -C "$ROOT" fetch -q origin 2>/dev/null || true
if [ -z "$COMMIT" ]; then
  COMMIT="$(git -C "$ROOT" rev-parse origin/main 2>/dev/null)" || refuse "commit_unknown" "this checkout has no origin/main"
fi
case "$COMMIT" in
  *[!0-9a-f]*|'') refuse "commit_invalid" "'$COMMIT' is not a hex commit id" ;;
esac
[ "${#COMMIT}" = 40 ] || refuse "commit_invalid" "'$COMMIT' is not a full 40-hex commit id"
SHORT="${COMMIT:0:12}"
git -C "$ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null \
  || refuse "commit_absent" "$COMMIT is not in this checkout; fetch it first (the assets are published, the tree has to be readable)"
git -C "$ROOT" worktree add -q --detach "$TREE" "$COMMIT" 2>/dev/null \
  || refuse "tree_unavailable" "cannot check $SHORT out at $TREE"

# ---- NO TOOLCHAIN: this is the node the row is about --------------------------------------------
# Every PATH entry that carries cargo, rustup, rustc or zig is removed - measured on avell 24/11: a plain
# bash here has no cargo at all while ~/.cargo/bin holds cargo/rustc, so one node can look like both. After
# the filter the four must be unreachable, and a host where they are not is a refusal: a row that could
# build would prove nothing about the download.
TOOLCHAIN_DIRS=""
clean_path=""
IFS=':' read -r -a entries <<< "$PATH"
for entry in "${entries[@]}"; do
  [ -n "$entry" ] || continue
  skip=0
  for tool in cargo rustup rustc zig; do
    [ -x "$entry/$tool" ] && skip=1
  done
  if [ "$skip" = 1 ]; then TOOLCHAIN_DIRS="$TOOLCHAIN_DIRS $entry"; continue; fi
  clean_path="$clean_path:$entry"
done
export PATH="${clean_path#:}"
unset WASM_AGENT_HOME WASM_AGENT_RENDEZVOUS WASM_AGENT_RELAY WA_GRAPH_ROOT WA_GRAPH_DB
unset WA_COMPONENT_RELEASE_URL WA_COMPONENTS_DIR WA_COMPONENTS_CACHE WA_NODE_BINARIES_URL WA_NODE_BINARIES_CACHE
unset WA_COMPONENT_RELEASE_REPO WA_NODE_RELEASE_REPO WA_DEPLOY_COMPONENT_SOURCE
export HOME="$HOME_DIR"
export RUSTUP_HOME="$HOME_DIR/.rustup" CARGO_HOME="$HOME_DIR/.cargo"
for tool in cargo rustup rustc zig; do
  command -v "$tool" >/dev/null 2>&1 && refuse "toolchain_on_path" "$tool is still reachable ($(command -v "$tool")); this row is about a node that cannot build (removed:${TOOLCHAIN_DIRS:- nothing})"
done
note "PATH carries no cargo, rustup, rustc or zig (removed:${TOOLCHAIN_DIRS:- nothing}); HOME=$HOME_DIR"

# ---- the caches are empty, and say so ----------------------------------------------------------
COMPONENTS="$HOME_DIR/.wasm-agent/components"
INSTALL="$W/install"
BIN_CACHE="$INSTALL/node-binaries"
COMP_CACHE="$INSTALL/components-cache"
for dir in "$COMPONENTS" "$BIN_CACHE" "$COMP_CACHE"; do
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    refuse "cache_not_empty" "$dir is not empty; this row starts from nothing"
  fi
done
note "component, binary and bundle caches are empty ($INSTALL)"

# ---- the release channel answers at all --------------------------------------------------------
# A 404 for one asset is the answer this row exists for; a channel nobody can reach is a skip, and the two
# are never the same sentence.
# WHO ANSWERS: a node fetches a release asset with gh when it has one and with the public URL otherwise, so
# this asks the same two. The PUBLIC API is rate limited per address - measured here 24/11 21:44Z: HTTP 403
# with 0 of 60 left while the authenticated gh had 4,868 - and a rate-limited probe is not "the channel is
# down". Both failing is the only skip.
reach=""
if command -v gh >/dev/null 2>&1 && gh api "repos/Magaav/wasm-agent" --jq .full_name >/dev/null 2>&1; then
  reach="gh (authenticated)"
elif curl -fsS -m 20 -o /dev/null "https://api.github.com/repos/Magaav/wasm-agent" 2>/dev/null; then
  reach="the public release API"
fi
if [ -z "$reach" ]; then
  say "SKIP: neither gh nor the public release API could answer from here (the public API is rate limited per address); nothing was installed and nothing is claimed"
  exit 3
fi
note "the release channel answered through $reach"

. "$ROOT/scripts/lib/node-binaries.sh"
. "$ROOT/scripts/lib/deploy-components.sh"

SLUG="$(wa_node_release_repo "$ROOT")" || refuse "release_repo_unknown" "no owner/repo for the node release"
TRIPLE="$(wa_node_target_triple 2>/dev/null)" || refuse "target_unknown" "this host ($(uname -s)/$(uname -m)) has no published target"

# ---- 1. the node binary, resolved the way a deploy resolves it ------------------------------------
# NOT the exact tag alone: a deploy asks whether the NEWEST published release covers this commit's
# compiled inputs before it builds anything (wa_node_binaries_prepare -> wa_node_release_digest_search),
# which is how a docs-only or Lua-only landing installs without a binary of its own. Asking for the exact
# tag would report "missing" about a commit a node installs perfectly well - measured here 24/11:
# origin/main 39e862d60bad has no release of its own and resolves to node-9a0c589adfa0.
STAGE_BIN="$W/binary.stage"
mkdir -p "$STAGE_BIN"
BIN_OUT="$(wa_node_binaries_prepare "$ROOT" "$COMMIT" "$STAGE_BIN" "$INSTALL" 2>&1)"; rc=$?
printf '%s\n' "$BIN_OUT" | sed 's/^/  /'
if [ "$rc" -ne 0 ]; then
  case "$rc" in
    8) say "$SHORT is NOT installable by download: node-$SHORT ($TRIPLE) missing ($(printf '%s\n' "$BIN_OUT" | head -2 | tr '\n' ' ' | sed 's/ $//'))"
       exit 1 ;;
    *) refuse "node_binary_refused" "rc=$rc: the release for $SHORT is published but not installable - the refusal above is the reason" ;;
  esac
fi
BIN_DIR="$(printf '%s\n' "$BIN_OUT" | sed -n 's/^binary_verified: [^ ]* //p' | sed 's/ .*//' | head -1)"
BIN_TAG="$(printf '%s\n' "$BIN_OUT" | sed -n 's/^binary_release: //p' | awk '{print $1}' | head -1)"
[ -n "$BIN_TAG" ] || BIN_TAG="node-$SHORT"
CANDIDATE="$STAGE_BIN/wa"
[ -x "$CANDIDATE" ] || refuse "node_binary_not_executable" "$CANDIDATE is not an executable file"
note "node binary: staged from $BIN_TAG ($(wa_node_sha256 "$CANDIDATE"), manifest and signature verified)"
BUILD_INFO="$("$CANDIDATE" --build-info 2>/dev/null | sed -n 's/^commit=//p' | head -1)"
[ "$BUILD_INFO" = "$COMMIT" ] \
  || refuse "binary_commit_mismatch" "the published binary names commit='$BUILD_INFO', this row asked for $COMMIT"
note "the published binary runs and names commit=$BUILD_INFO"

# ---- 2. the components, from the release this commit's lock names --------------------------------
NAMES="$(wa_components_shipped "$TREE")" || refuse "components_lock_unreadable" "$TREE/components.lock"
[ -n "$NAMES" ] || refuse "components_lock_empty" "$TREE/components.lock pins no component"
COMP_TAG="$(wa_component_release_tag "$TREE")" || refuse "components_lock_unreadable" "$TREE/components.lock"
COUNT="$(printf '%s\n' $NAMES | grep -c .)"
STAGE="$INSTALL/components.next"
mkdir -p "$STAGE"
if ! out="$(wa_components_prepare "$TREE" "$STAGE" "$INSTALL" $NAMES 2>&1)"; then
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  # What the fallback build said, when it got that far: with no pinned bytes the deploy's own fallback is
  # the next thing a node tries, and its last lines are the reason the node cannot rescue itself (a
  # toolchain missing, or - measured on work 24/11 - wa-remap-rustc refusing to execute).
  for log in "$STAGE"/.build-*.log; do
    [ -f "$log" ] || continue
    printf '  %s (fallback build):\n' "$(basename "$log")" >&2
    tail -3 "$log" 2>/dev/null | sed 's/^/    /' >&2
  done
  # The asset the release cannot answer for, named as the node names it, and then the one-line verdict the
  # land report carries (item 2). The URL is what the fetch tried; the asset is its last path element.
  url="$(printf '%s\n' "$out" | sed -n 's/^component_release_unreachable: //p' | head -1)"
  asset=""
  [ -n "$url" ] && asset="${url##*/}"
  [ -n "$asset" ] || asset="$(printf '%s\n' "$out" | sed -n 's/^component_missing: //p' | head -1)"
  [ -n "$asset" ] || asset="(unnamed: the reason line above is the whole answer)"
  say "$SHORT is NOT installable by download: $COMP_TAG/$asset missing"
  exit 1
fi
note "components staged from $COMP_TAG: $COUNT name(s) verified against the lock at $SHORT"

# ---- 3. installed, and the pair proves itself ---------------------------------------------------
if ! out="$(wa_components_install_set "$STAGE" "$COMPONENTS" $NAMES 2>&1)"; then
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  refuse "component_install_failed" "the staged bytes could not be installed into $COMPONENTS"
fi
for name in $NAMES; do
  pin="$(wa_component_pin "$TREE" "$name")" || refuse "component_pin_missing" "$name is not pinned in components.lock"
  want="${pin%% *}"
  got="$(wa_component_sha256 "$COMPONENTS/$name.wasm" 2>/dev/null)"
  [ "$got" = "$want" ] || refuse "component_not_installed" "$COMPONENTS/$name.wasm is '$got', components.lock pins $want"
done
note "installed $COUNT component(s) into $COMPONENTS, every byte the pinned one"

PROOF_HOME="$W/proof"
mkdir -p "$PROOF_HOME"
if ! WA_COMPONENTS_DIR="$COMPONENTS" WASM_AGENT_HOME="$PROOF_HOME" WASM_AGENT_MANAGED=0 \
  WA_SCRIPT="$TREE/scripts/check-component-proof.lua" \
  env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY -u WA_GRAPH_ROOT -u WA_GRAPH_DB \
  "$CANDIDATE" --db "$PROOF_HOME/proof.db" >"$PROOF_HOME/proof.log" 2>&1; then
  tail -5 "$PROOF_HOME/proof.log" 2>/dev/null | sed 's/^/  /' >&2
  refuse "component_proof_failed" "the published binary did not answer a call through the components the download installed; the bytes are not this commit's pair"
fi
grep -q 'component proof ok' "$PROOF_HOME/proof.log" \
  || refuse "component_proof_silent" "the pair ran but printed no verdict; nothing is claimed"
note "the published binary answers through the installed memory component (check-component-proof.lua)"

# ---- 4. nothing was built, and no toolchain arrived ----------------------------------------------
for dir in "$RUSTUP_HOME" "$CARGO_HOME"; do
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    refuse "toolchain_fetched" "$dir is no longer empty - something fetched a toolchain for a row that must not build"
  fi
done
note "no toolchain was fetched (RUSTUP_HOME and CARGO_HOME under $HOME_DIR stayed absent)"

say "installable by download: $SHORT (node-$SHORT, $COMP_TAG, $COUNT components) on $TRIPLE"
exit 0
