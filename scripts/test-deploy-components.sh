#!/usr/bin/env bash
# Proof for scripts/lib/deploy-components.sh, with no network, no wasm toolchain and no node:
# the graph component itself is exercised by the gate's graph tests, and this covers the install
# path a deploy takes - the pin, the hash, the atomic swap and the rollback - because a deploy that
# installs the new core and not its `graph` component answers every graph call with
# `component_not_installed:graph` (docs/KERNEL.md, stream C).
#
#   bash scripts/test-deploy-components.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
. scripts/lib/deploy-components.sh

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "deploy components FAILED: $*" >&2; exit 1; }
expect_status() { # <want> <got> <what>
  [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"
  ok
}
contains() { # <text> <needle> <what>
  printf '%s' "$1" | grep -qF -- "$2" || fail "$3: '$2' not in: $1"
  ok
}

repo="$WORK/repo"
artifacts="$WORK/artifacts"
dest="$WORK/components"
mkdir -p "$repo" "$artifacts"
printf 'graph-wasm-v1' > "$artifacts/graph.wasm"
printf '{"name":"graph"}\n' > "$artifacts/graph.json"
pin="$(wa_component_sha256 "$artifacts/graph.wasm")"
bytes="$(wc -c < "$artifacts/graph.wasm" | tr -d '[:space:]')"
cat > "$repo/components.lock" <<LOCK
# name sha256 bytes
graph $pin $bytes
LOCK

# --- the pin is read, never guessed ---------------------------------------------------------------
expect_status 0 "$(wa_component_pin "$repo" graph >/dev/null; echo $?)" "a pinned component"
[ "$(wa_component_pin "$repo" graph)" = "$pin $bytes" ] || fail "pin did not parse as 'sha bytes'"
ok
expect_status 3 "$(wa_component_pin "$repo" other >/dev/null; echo $?)" "an unpinned component"
expect_status 2 "$(wa_component_pin "$WORK/nope" graph >/dev/null; echo $?)" "a missing lock file"
cp "$repo/components.lock" "$WORK/lock.bak"
printf '# a name with no hash is not a pin\ngraph\n' > "$repo/components.lock"
expect_status 3 "$(wa_component_pin "$repo" graph >/dev/null; echo $?)" "a blank pin is not a pin"
cp "$WORK/lock.bak" "$repo/components.lock"

# --- staging: the pinned bytes only --------------------------------------------------------------
stage="$WORK/stage"
WA_DEPLOY_COMPONENT_SOURCE="$artifacts" wa_component_stage "$repo" graph "$stage" || fail "staging the pinned artifact"
cmp -s "$stage/graph.wasm" "$artifacts/graph.wasm" || fail "staged bytes differ from the artifact"
[ "$(cat "$stage/graph.wasm.sha256")" = "$pin" ] || fail "staged pin differs"
[ -f "$stage/graph.json" ] || fail "staged manifest missing"
ok

bad="$WORK/bad-artifacts"; mkdir -p "$bad"
printf 'graph-wasm-v2' > "$bad/graph.wasm"; cp "$artifacts/graph.json" "$bad/graph.json"
out="$(WA_DEPLOY_COMPONENT_SOURCE="$bad" wa_component_stage "$repo" graph "$WORK/stage-bad" 2>&1)"
expect_status 5 "$?" "a component whose bytes are not the pinned ones"
contains "$out" "component_hash_mismatch: graph" "the mismatch names the component"
contains "$out" "$pin" "the mismatch names the pinned hash"

missing="$WORK/missing-artifacts"; mkdir -p "$missing"
out="$(WA_DEPLOY_COMPONENT_SOURCE="$missing" wa_component_stage "$repo" graph "$WORK/stage-missing" 2>&1)"
expect_status 3 "$?" "a component that is not there"
contains "$out" "component_missing:" "the missing component is named"

short="$WORK/short-artifacts"; mkdir -p "$short"
cp "$bad/graph.wasm" "$short/graph.wasm"; cp "$artifacts/graph.json" "$short/graph.json"
printf 'graph %s %s\n' "$(wa_component_sha256 "$short/graph.wasm")" 999999 > "$repo/components.lock"
out="$(WA_DEPLOY_COMPONENT_SOURCE="$short" wa_component_stage "$repo" graph "$WORK/stage-short" 2>&1)"
expect_status 6 "$?" "a component whose size is not the pinned one"
contains "$out" "component_size_mismatch: graph" "the size mismatch is named"
cp "$WORK/lock.bak" "$repo/components.lock"

# Even an explicit repin does not bless an artifact that is supposed to be the pinned one.
out="$(WA_DEPLOY_COMPONENT_REPIN=1 WA_DEPLOY_COMPONENT_SOURCE="$bad" wa_component_stage "$repo" graph "$WORK/stage-repin" 2>&1)"
expect_status 5 "$?" "an artifact that is not the pinned one, with a repin claimed"

out="$(WA_DEPLOY_COMPONENT_SOURCE="$artifacts" wa_component_stage "$WORK/nope-repo" graph "$WORK/stage-nopin" 2>&1)"
expect_status 2 "$?" "staging without a lock file"
contains "$out" "component_pin_missing:" "the missing pin is named"

# --- install and rollback ------------------------------------------------------------------------
mkdir -p "$dest"
printf 'previous-module' > "$dest/graph.wasm"
printf 'previous-pin\n' > "$dest/graph.wasm.sha256"
printf '{"name":"graph","old":true}\n' > "$dest/graph.json"
printf 'unrelated' > "$dest/mcp-whatsapp.wasm"   # another component must survive untouched
out="$(wa_component_install "$stage" "$dest" graph 2>&1)"
expect_status 0 "$?" "installing a staged component"
contains "$out" "component_installed: $dest/graph.wasm" "the install is reported"
[ "$(cat "$dest/graph.wasm")" = "graph-wasm-v1" ] || fail "installed module is not the staged one"
[ "$(cat "$dest/graph.wasm.sha256")" = "$pin" ] || fail "installed pin is not the staged one"
[ "$(cat "$dest/.prev/graph.wasm")" = "previous-module" ] || fail "previous module was not kept"
[ "$(cat "$dest/mcp-whatsapp.wasm")" = "unrelated" ] || fail "another component was touched"
ok
out="$(wa_component_restore "$dest" graph 2>&1)"
expect_status 0 "$?" "rolling back"
[ "$(cat "$dest/graph.wasm")" = "previous-module" ] || fail "rollback did not put the previous module back"
[ "$(cat "$dest/graph.wasm.sha256")" = "previous-pin" ] || fail "rollback did not put the previous pin back"
[ "$(cat "$dest/graph.json")" = '{"name":"graph","old":true}' ] || fail "rollback did not put the previous manifest back"
contains "$out" "component_restored: graph files=3" "the rollback reports three files"

# A node that never had the component: rollback removes the triple rather than leaving a half one.
fresh="$WORK/fresh-components"; mkdir -p "$fresh"
wa_component_install "$stage" "$fresh" graph >/dev/null || fail "installing into a node without the component"
[ -f "$fresh/graph.wasm" ] || fail "install into an empty directory did not land"
cp "$dest/.prev/graph.wasm" "$fresh/.prev/graph.wasm" 2>/dev/null
rm -rf "$fresh/.prev"
wa_component_restore "$fresh" graph >/dev/null || fail "restoring where there was no previous component"
[ ! -f "$fresh/graph.wasm" ] && [ ! -f "$fresh/graph.wasm.sha256" ] && [ ! -f "$fresh/graph.json" ] \
  || fail "rollback of a first install left files behind"
ok

# --- dry run: prove the plan without touching what is installed -----------------------------------
before="$(cat "$dest/graph.wasm")"
out="$(WA_DEPLOY_COMPONENTS_DRY_RUN=1 wa_component_install "$stage" "$dest" graph 2>&1)"
expect_status 0 "$?" "a dry-run install"
contains "$out" "component_would_install:" "the dry run says what it would install"
[ "$(cat "$dest/graph.wasm")" = "$before" ] || fail "the dry run changed the installed module"
ok

# --- the staged triple must be complete ----------------------------------------------------------
partial="$WORK/stage-partial"; mkdir -p "$partial"
cp "$stage/graph.wasm" "$partial/graph.wasm"
out="$(wa_component_install "$partial" "$dest" graph 2>&1)"
expect_status 3 "$?" "an install missing the manifest"
contains "$out" "component_missing:" "the incomplete stage is named"

echo "deploy components ok: $checks checks"
