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

# A hash is the bytes' hash, whatever path they were read by (11/11: a Windows path made sha256sum
# escape the filename, so the deploy asked for `components-\1d22f2ced44` instead of
# `components-1d22f2ced448` and then refused the install `component_hash_mismatch`). Both spellings of
# the same file must agree, and the answer must be 64 hex characters - no escape prefix.
probe="$WORK/hash-probe.bin"
printf 'the same bytes either way' > "$probe"
plain="$(wa_component_sha256 "$probe")"
case "$plain" in
  *[!0-9a-f]*|'') fail "wa_component_sha256 is not hex: [$plain]" ;;
esac
[ "${#plain}" = 64 ] || fail "wa_component_sha256 returned ${#plain} characters: [$plain]"
ok
if command -v cygpath >/dev/null 2>&1; then
  windows="$(wa_component_sha256 "$(cygpath -w "$probe")")"
  [ "$windows" = "$plain" ] || fail "a Windows path hashed to [$windows], the same file by a POSIX path to [$plain]"
  ok
else
  # A filename that really contains a backslash is legal here and impossible on Windows; it is the
  # other way to make sha256sum escape the line.
  escaped="$WORK/a\\b.bin"
  printf 'the same bytes either way' > "$escaped"
  with_backslash="$(wa_component_sha256 "$escaped")"
  [ "$with_backslash" = "$plain" ] || fail "a file named with a backslash hashed to [$with_backslash], the same bytes to [$plain]"
  ok
fi

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

# --- distribution: the release bundle this lock names (docs/COMPONENTS.md) ------------------------
# A node with no wasi-sdk installs the pinned bytes a release carries. No network here: the release is
# a local directory or a file:// URL handed to WA_COMPONENT_RELEASE_URL, which is the same code path a
# gh/curl download fills. Nothing in this section runs gh, curl or a build.
unset WA_DEPLOY_COMPONENT_SOURCE WA_COMPONENT_RELEASE_URL WA_COMPONENT_RELEASE_REPO
WA_COMPONENTS_DIR="$WORK/installed-empty"; export WA_COMPONENTS_DIR
cache="$WORK/cache"

lock_sha="$(wa_component_lock_sha "$repo")"
expect_status 0 "$?" "the lock's sha256 is readable"
tag="$(wa_component_release_tag "$repo")"
[ "$tag" = "components-${lock_sha:0:12}" ] || fail "release tag is not components-<12 hex of the lock sha>: $tag"
ok
repo_slug="$(wa_component_release_repo "$repo")"
printf '%s' "$repo_slug" | grep -q '^[^/]*/[^/]*$' || fail "the release repo is not owner/repo: $repo_slug"
ok

bundle="$WORK/release-bundle"; mkdir -p "$bundle"
cp "$artifacts/graph.wasm" "$bundle/graph.wasm"
cp "$artifacts/graph.json" "$bundle/graph.json"
cp "$repo/components.lock" "$bundle/components.lock"

out="$(WA_COMPONENT_RELEASE_URL="$bundle" WA_COMPONENTS_CACHE="$cache" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 0 "$?" "resolving pinned bytes from the release bundle (local stub)"
[ "$out" = "$cache/$lock_sha" ] || fail "the fetched bundle was not cached under the lock sha: $out"
cmp -s "$cache/$lock_sha/graph.wasm" "$artifacts/graph.wasm" || fail "the cached module is not the released one"
[ -f "$cache/$lock_sha/.complete" ] || fail "the cached bundle carries no complete marker"
ok

# A repeated deploy does not refetch: the cache answers even when the release is gone.
out="$(WA_COMPONENT_RELEASE_URL="$WORK/no-such-bundle" WA_COMPONENTS_CACHE="$cache" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 0 "$?" "a repeated resolve reads the cache, not the release"
[ "$out" = "$cache/$lock_sha" ] || fail "the cache hit did not name the cached bundle: $out"

# The installed component directory is the cheapest correct answer of all.
inst="$WORK/installed-match"; mkdir -p "$inst"
cp "$artifacts/graph.wasm" "$inst/graph.wasm"; cp "$artifacts/graph.json" "$inst/graph.json"
out="$(WA_COMPONENTS_DIR="$inst" WA_COMPONENT_RELEASE_URL="$WORK/no-such-bundle" WA_COMPONENTS_CACHE="$WORK/cache-none" \
  wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 0 "$?" "an already-installed matching component is used, not refetched"
[ "$out" = "$inst" ] || fail "the installed component was not chosen: $out"

# file:// is the same stub, spelled as a URL.
rm -rf "$WORK/cache-file"
out="$(WA_COMPONENT_RELEASE_URL="file://$bundle" WA_COMPONENTS_CACHE="$WORK/cache-file" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 0 "$?" "resolving through a file:// release URL"
[ "$out" = "$WORK/cache-file/$lock_sha" ] || fail "the file:// bundle was not cached under the lock sha: $out"

# A fetch killed mid-copy leaves .incoming.<pid>; the next fetch sweeps the old ones and leaves none of
# its own behind, and a completed fetch is only ever the whole bundle.
rm -rf "$WORK/cache-sweep"; mkdir -p "$WORK/cache-sweep/.incoming.99999"
printf 'half-a-module' > "$WORK/cache-sweep/.incoming.99999/graph.wasm"
touch -t 202001010000 "$WORK/cache-sweep/.incoming.99999"
out="$(WA_COMPONENT_RELEASE_URL="$bundle" WA_COMPONENTS_CACHE="$WORK/cache-sweep" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 0 "$?" "fetching into a cache that holds a dead fetch's residue"
[ ! -d "$WORK/cache-sweep/.incoming.99999" ] || fail "a stale .incoming dir was not swept"
[ -z "$(ls -d "$WORK/cache-sweep"/.incoming.* 2>/dev/null)" ] || fail "a completed fetch left its .incoming dir behind"

# --- dry run: (a) local source, (b) fetched release, both prove the plan and install nothing ------
dry_dest="$WORK/dry-dest"; mkdir -p "$dry_dest"
printf 'previous-module' > "$dry_dest/graph.wasm"
printf 'previous-pin\n' > "$dry_dest/graph.wasm.sha256"
printf '{"name":"graph"}\n' > "$dry_dest/graph.json"
out="$(WA_DEPLOY_COMPONENTS_DRY_RUN=1 WA_DEPLOY_COMPONENT_SOURCE="$artifacts" wa_components_prepare "$repo" "$WORK/dry-stage-local" "$WORK/install" graph 2>&1)"
expect_status 0 "$?" "a dry-run prepare from a local source"
contains "$out" "component_source: graph $artifacts (WA_DEPLOY_COMPONENT_SOURCE)" "the local source is named"
out="$(WA_DEPLOY_COMPONENTS_DRY_RUN=1 wa_component_install "$WORK/dry-stage-local" "$dry_dest" graph 2>&1)"
expect_status 0 "$?" "a dry-run install of the local source"
contains "$out" "component_would_install: $dry_dest/graph.wasm" "the dry run names what it would install"
[ "$(cat "$dry_dest/graph.wasm")" = "previous-module" ] || fail "a dry-run install from a local source changed the installed module"
ok

rm -rf "$WORK/cache-dry"
out="$(WA_DEPLOY_COMPONENTS_DRY_RUN=1 WA_COMPONENT_RELEASE_URL="$bundle" WA_COMPONENTS_CACHE="$WORK/cache-dry" \
  wa_components_prepare "$repo" "$WORK/dry-stage-release" "$WORK/install" graph 2>&1)"
expect_status 0 "$?" "a dry-run prepare through the release bundle"
contains "$out" "component_source: graph $WORK/cache-dry/$lock_sha (pinned bytes)" "the fetched bundle is named"
cmp -s "$WORK/dry-stage-release/graph.wasm" "$artifacts/graph.wasm" || fail "the stage built from the release is not the released module"
out="$(WA_DEPLOY_COMPONENTS_DRY_RUN=1 wa_component_install "$WORK/dry-stage-release" "$dry_dest" graph 2>&1)"
expect_status 0 "$?" "a dry-run install of the fetched bundle"
contains "$out" "component_would_install:" "the fetched bundle would be installed"
[ "$(cat "$dry_dest/graph.wasm")" = "previous-module" ] || fail "a dry-run install of the fetched bundle changed the installed module"
ok

# --- (c) a release that is not the pinned one is refused, and nothing is cached -------------------
tampered="$WORK/tampered-bundle"; mkdir -p "$tampered"
printf 'not-the-pinned-graph' > "$tampered/graph.wasm"
cp "$artifacts/graph.json" "$tampered/graph.json"; cp "$repo/components.lock" "$tampered/components.lock"
rm -rf "$WORK/cache-tampered"
out="$(WA_COMPONENT_RELEASE_URL="$tampered" WA_COMPONENTS_CACHE="$WORK/cache-tampered" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 5 "$?" "a released bundle whose bytes are not the pinned ones"
contains "$out" "component_hash_mismatch: graph" "the tampered bundle is refused by name"
contains "$out" "$pin" "the refusal names the pinned hash"
[ ! -d "$WORK/cache-tampered/$lock_sha" ] || fail "a refused bundle was cached"
[ -z "$(ls -A "$WORK/cache-tampered" 2>/dev/null)" ] || fail "a refused fetch left staging residue in the cache"
ok
out="$(WA_DEPLOY_COMPONENTS_DRY_RUN=1 WA_COMPONENT_RELEASE_URL="$tampered" WA_COMPONENTS_CACHE="$WORK/cache-tampered" \
  wa_components_prepare "$repo" "$WORK/tampered-stage" "$WORK/install" graph 2>&1)"
expect_status 5 "$?" "a dry-run prepare refuses tampered release bytes"
contains "$out" "component_hash_mismatch: graph" "the dry-run refusal is the hash refusal"
[ ! -f "$WORK/tampered-stage/graph.wasm" ] || fail "a refused prepare staged a module"
ok

# A bundle carrying another tree's lock is not this release, even if its wasm happens to match.
wronglock="$WORK/wrong-lock-bundle"; mkdir -p "$wronglock"
cp "$artifacts/graph.wasm" "$wronglock/graph.wasm"; cp "$artifacts/graph.json" "$wronglock/graph.json"
printf '# another tree\ngraph %s %s\n' "$pin" "$bytes" > "$wronglock/components.lock"
out="$(WA_COMPONENT_RELEASE_URL="$wronglock" WA_COMPONENTS_CACHE="$WORK/cache-wronglock" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 5 "$?" "a bundle whose components.lock is another lock"
contains "$out" "component_release_lock_mismatch: graph" "the foreign lock is refused by name"

# No release reached and no cache: 8, the one status a deploy may answer by building the tree.
out="$(WA_COMPONENT_RELEASE_URL="$WORK/no-such-bundle" WA_COMPONENTS_CACHE="$WORK/cache-none" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 8 "$?" "an unreachable release with nothing cached"
contains "$out" "component_release_unavailable: graph" "the missing release is named"
contains "$out" "component_release_url_unusable:" "a release URL that is neither a directory nor an http(s) URL is named"

# A bundle missing one of the three files is not a bundle: the deploy says which file, then falls through
# to the build path rather than caching half a release.
partial_bundle="$WORK/partial-bundle"; mkdir -p "$partial_bundle"
cp "$artifacts/graph.wasm" "$partial_bundle/graph.wasm"; cp "$repo/components.lock" "$partial_bundle/components.lock"
out="$(WA_COMPONENT_RELEASE_URL="$partial_bundle" WA_COMPONENTS_CACHE="$WORK/cache-partial" wa_component_source_resolve "$repo" graph "$WORK/install" 2>&1)"
expect_status 8 "$?" "a release bundle missing its manifest"
contains "$out" "component_release_incomplete: $partial_bundle/graph.json" "the missing member is named"
[ -z "$(ls -A "$WORK/cache-partial" 2>/dev/null)" ] || fail "an incomplete bundle was cached"

# --- the build machine's half: scripts/publish-components.sh --------------------------------------
pub_repo="$WORK/pub-repo"; mkdir -p "$pub_repo"
cp "$repo/components.lock" "$pub_repo/components.lock"
out="$(bash scripts/publish-components.sh --check --repo "$pub_repo" 2>&1)"
expect_status 0 "$?" "--check plans without building"
contains "$out" "would build from" "the plan names the build"
contains "$out" "release tag: $tag" "the plan names the release tag"
[ ! -d "$pub_repo/build" ] || fail "--check created a build directory"
out="$(bash scripts/publish-components.sh --repo "$pub_repo" --from "$artifacts" --out "$WORK/published" 2>&1)"
expect_status 0 "$?" "bundling prebuilt artifacts"
[ -f "$WORK/published/graph.wasm" ] && [ -f "$WORK/published/graph.json" ] && [ -f "$WORK/published/components.lock" ] \
  || fail "the bundle is not graph.wasm + graph.json + components.lock"
cmp -s "$WORK/published/graph.wasm" "$artifacts/graph.wasm" || fail "the bundle carries another module"
cmp -s "$WORK/published/components.lock" "$pub_repo/components.lock" || fail "the bundle carries another lock"
contains "$out" "gh release create $tag -R " "the exact publish command names the tag and the repo"
contains "$out" "$WORK/published/graph.wasm" "the publish command uploads the module"
contains "$out" "gh release upload $tag -R " "the re-publish command names the tag"
contains "$out" "publish-components ok: $tag" "the bundle is reported as published-ready"
out="$(bash scripts/publish-components.sh --repo "$pub_repo" --from "$bad" --out "$WORK/published-bad" 2>&1)"
expect_status 5 "$?" "bundling an artifact that is not the pinned one"
contains "$out" "artifact_not_pinned: graph" "the mismatch is named"
contains "$out" "$pin" "the refusal names the pinned hash"

unset WA_COMPONENTS_DIR

echo "deploy components ok: $checks checks"
