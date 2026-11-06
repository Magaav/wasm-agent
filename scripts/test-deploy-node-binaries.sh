#!/usr/bin/env bash
# Proof for scripts/lib/node-binaries.sh - the deploy half of "a node installs a published binary"
# (docs/COMPONENTS.md "The node binary itself", job p3x). No network, no toolchain, no node: every
# candidate is a fixture directory, and the release stub is WA_NODE_BINARIES_URL pointing at it.
#
# What is checked, and why each case earns its line:
#   * the decision (dry run) says where the bytes WOULD come from without fetching anything;
#   * a matching release is verified, cached under the commit's short sha, and used again from that cache
#     with the release gone - the repeated deploy must not refetch;
#   * a mismatch (hash, size, ELF machine), another commit's manifest, an unpublished target and a
#     manifest that says codemode=empty are REFUSALS - the bytes that claim to be this commit's are not
#     this commit's - and each one leaves no cache entry behind;
#   * only "nothing is published" (rc 8) is a fallback, and the fallback is conditioned on the disk floor:
#     a node below it refuses by name instead of starting a build it cannot finish;
#   * WA_DEPLOY_BINARY_SOURCE (an operator's directory) is staged and says so.
#
#   bash scripts/test-deploy-node-binaries.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
. scripts/lib/node-binaries.sh

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "node binaries (deploy) FAILED: $*" >&2; exit 1; }
expect_status() { # <want> <got> <what>
  [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"
  ok
}
contains() { # <text> <needle> <what>
  printf '%s' "$1" | grep -qF -- "$2" || fail "$3: '$2' not in: $1"
  ok
}

COMMIT=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
SHORT="${COMMIT:0:12}"
X64=x86_64-unknown-linux-gnu
ARM=aarch64-unknown-linux-gnu

# A 21-byte "ELF for <machine>": the four magic bytes, e_type, and the machine byte at offset 18. That is
# what wa_node_binary_shape reads, and it is the whole of the machine check.
mkelf() { # FILE MACHINE_HEX
  { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture-binary'; } > "$1"
}

release="$WORK/release"
mkdir -p "$release"
mkelf "$release/wa-$X64-$SHORT" 3e
mkelf "$release/wa-sentinel-$X64-$SHORT" 3e
xsha="$(wa_node_sha256 "$release/wa-$X64-$SHORT")"; xbytes="$(wc -c < "$release/wa-$X64-$SHORT" | tr -d '[:space:]')"
ssha="$(wa_node_sha256 "$release/wa-sentinel-$X64-$SHORT")"; sbytes="$(wc -c < "$release/wa-sentinel-$X64-$SHORT" | tr -d '[:space:]')"
cat > "$release/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$COMMIT
source_tree=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=2026-11-06T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$X64 $xsha $xbytes $ssha $sbytes
MANIFEST

# --- the triple this machine reads -----------------------------------------------------------------
[ "$(wa_node_target_triple Linux aarch64)" = "$ARM" ] || fail "aarch64 Linux did not map to $ARM"
ok
[ "$(wa_node_target_triple Linux x86_64)" = "$X64" ] || fail "x86_64 Linux did not map to $X64"
ok
expect_status 1 "$(wa_node_target_triple MINGW64_NT x86_64 >/dev/null; echo $?)" "Windows has no published target (it builds)"
expect_status 1 "$(wa_node_target_triple Linux riscv64 >/dev/null; echo $?)" "an unpublished architecture"
[ "$(WA_NODE_TARGET=$ARM wa_node_target_triple MINGW64_NT x86_64)" = "$ARM" ] || fail "WA_NODE_TARGET did not override"
ok
expect_status 1 "$(WA_NODE_UNAME_S=MINGW64_NT WA_NODE_UNAME_M=x86_64 wa_node_target_triple >/dev/null; echo $?)" "a Windows host through the uname knobs"

# --- the tag is the commit, the pin is the row ------------------------------------------------------
[ "$(wa_node_release_tag "$COMMIT")" = "node-$SHORT" ] || fail "tag is not node-<sha12>"
ok
expect_status 2 "$(wa_node_release_tag 1111 >/dev/null; echo $?)" "a short sha is not a tag"
expect_status 2 "$(wa_node_release_tag zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz >/dev/null; echo $?)" "a non-hex id"
[ "$(wa_node_manifest_pin "$release/node-$SHORT.manifest" "$X64")" = "$xsha $xbytes $ssha $sbytes" ] \
  || fail "the manifest row did not parse as 'sha bytes sha bytes'"
ok
expect_status 3 "$(wa_node_manifest_pin "$release/node-$SHORT.manifest" "$ARM" >/dev/null; echo $?)" "a target with no row"
expect_status 2 "$(wa_node_manifest_pin "$WORK/none.manifest" "$X64" >/dev/null; echo $?)" "a missing manifest"
[ "$(wa_node_binary_shape "$release/wa-$X64-$SHORT")" = "elf:3e" ] || fail "an x86_64 ELF did not read as elf:3e"
ok

# --- the dry run: the decision before anything is fetched -------------------------------------------
plan="$(wa_node_binary_plan "$ROOT" "$COMMIT" "$X64" "$WORK/install")"
contains "$plan" "binary_source: release node-$SHORT" "the plan names the release tag"
case "$plan" in *"$WORK/install/node-binaries/$SHORT/$X64"*) ok ;; *) fail "the plan does not name the cache entry it would use: $plan" ;; esac

# --- the match: verified, cached, then served from the cache with the release gone -------------------
cache_root="$WORK/install/node-binaries"
out="$(WA_NODE_BINARIES_URL="$release" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$WORK/install" 2>&1)"
expect_status 0 "$?" "a matching release resolves"
contains "$out" "$cache_root/$SHORT/$X64" "the resolved directory is the cache entry"
[ -f "$cache_root/$SHORT/$X64/.complete" ] || fail "the cache entry has no .complete marker"
ok
[ -f "$cache_root/$SHORT/$X64/wa-$X64-$SHORT" ] || fail "the cached binary is not there"
ok
# Cache hit: the release directory is replaced with bytes that do NOT match, and the resolve still
# answers from the cache. If it refetched, it would refuse - which is the point.
mv "$release" "$WORK/release.moved"
mkdir -p "$release"; mkelf "$release/wa-$X64-$SHORT" 3e; printf 'tampered' >> "$release/wa-$X64-$SHORT"
out="$(WA_NODE_BINARIES_URL="$release" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$WORK/install" 2>&1)"
expect_status 0 "$?" "a cache hit does not refetch"
contains "$out" "$cache_root/$SHORT/$X64" "the cache hit is the cached directory"
rm -rf "$release"; mv "$WORK/release.moved" "$release"
plan="$(wa_node_binary_plan "$ROOT" "$COMMIT" "$X64" "$WORK/install")"
contains "$plan" "binary_source: cache" "the plan reads the cache once it is populated"

# --- refusals: the bytes that claim to be this commit's are not -------------------------------------
fresh() { rm -rf "$WORK/install-$1"; printf '%s\n' "$WORK/install-$1"; }
bad="$WORK/bad"; mkdir -p "$bad"
cp "$release/node-$SHORT.manifest" "$bad/"
cp "$release/wa-$X64-$SHORT" "$bad/"; cp "$release/wa-sentinel-$X64-$SHORT" "$bad/"
printf 'tampered' >> "$bad/wa-$X64-$SHORT"
i="$(fresh hash)"
out="$(WA_NODE_BINARIES_URL="$bad" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$i" 2>&1)"
expect_status 5 "$?" "a binary whose bytes are not the pinned ones"
contains "$out" "node_hash_mismatch: wa-$X64-$SHORT" "the hash refusal names the file"
[ ! -d "$i/node-binaries/$SHORT/$X64" ] || fail "a refused fetch left a cache entry behind"
ok

short_size="$WORK/short"; mkdir -p "$short_size"
cp "$release/wa-$X64-$SHORT" "$short_size/"; cp "$release/wa-sentinel-$X64-$SHORT" "$short_size/"
sed "s/^$X64 $xsha $xbytes /$X64 $xsha 999999 /" "$release/node-$SHORT.manifest" > "$short_size/node-$SHORT.manifest"
i="$(fresh size)"
out="$(WA_NODE_BINARIES_URL="$short_size" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$i" 2>&1)"
expect_status 6 "$?" "a binary whose size is not the pinned one"
contains "$out" "node_size_mismatch:" "the size refusal is named"

foreign="$WORK/foreign"; mkdir -p "$foreign"
cp "$release/wa-$X64-$SHORT" "$foreign/"; cp "$release/wa-sentinel-$X64-$SHORT" "$foreign/"
sed "s/^source_commit=$COMMIT/source_commit=$OTHER/" "$release/node-$SHORT.manifest" > "$foreign/node-$SHORT.manifest"
i="$(fresh commit)"
out="$(WA_NODE_BINARIES_URL="$foreign" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$i" 2>&1)"
expect_status 2 "$?" "a manifest that names another commit"
contains "$out" "node_manifest_commit_mismatch:" "the commit refusal is named"

# A release that publishes this commit but not this target says so, and says it as "not published" (8:
# the deploy may build here) rather than as a refusal - the manifest is right, it just has no aarch64 row.
i="$(fresh unpublished)"
out="$(WA_NODE_BINARIES_URL="$release" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$ARM" "$i" 2>&1)"
expect_status 8 "$?" "a target the release does not publish"
contains "$out" "node_target_unpublished: $ARM" "the unpublished target is named"
contains "$out" "it publishes: $X64 " "the published targets are listed"

wrongmachine="$WORK/wrongmachine"; mkdir -p "$wrongmachine"
mkelf "$wrongmachine/wa-$ARM-$SHORT" 3e; cp "$release/wa-sentinel-$X64-$SHORT" "$wrongmachine/wa-sentinel-$ARM-$SHORT"
ash="$(wa_node_sha256 "$wrongmachine/wa-$ARM-$SHORT")"; abytes="$(wc -c < "$wrongmachine/wa-$ARM-$SHORT" | tr -d '[:space:]')"
as="$(wa_node_sha256 "$wrongmachine/wa-sentinel-$ARM-$SHORT")"; ab="$(wc -c < "$wrongmachine/wa-sentinel-$ARM-$SHORT" | tr -d '[:space:]')"
printf 'schema=wasm-agent-node-binaries/1\nsource_commit=%s\ncodemode=embedded\n%s %s %s %s %s\n' \
  "$COMMIT" "$ARM" "$ash" "$abytes" "$as" "$ab" > "$wrongmachine/node-$SHORT.manifest"
i="$(fresh machine)"
out="$(WA_NODE_BINARIES_URL="$wrongmachine" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$ARM" "$i" 2>&1)"
expect_status 5 "$?" "an x86_64 binary pinned under the aarch64 row"
contains "$out" "node_machine_mismatch:" "the machine refusal is named"

empty_cm="$WORK/emptyc"; mkdir -p "$empty_cm"
cp "$release/wa-$X64-$SHORT" "$release/wa-sentinel-$X64-$SHORT" "$empty_cm/"
sed 's/^codemode=embedded/codemode=empty/' "$release/node-$SHORT.manifest" > "$empty_cm/node-$SHORT.manifest"
i="$(fresh emptycodemode)"
out="$(WA_NODE_BINARIES_URL="$empty_cm" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$i" 2>&1)"
expect_status 2 "$?" "a binary built without the code-mode assets"
contains "$out" "node_codemode_empty:" "the empty code-mode refusal is named"
i="$(fresh emptycodemode-ok)"
out="$(WA_DEPLOY_ALLOW_EMPTY_CODEMODE=1 WA_NODE_BINARIES_URL="$empty_cm" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$i" 2>&1)"
expect_status 0 "$?" "the same release when the operator names the exemption"

# --- nothing published is the one fallback, and the disk decides whether it is taken ------------------
nothing="$WORK/nothing"; mkdir -p "$nothing"
i="$(fresh missing)"
out="$(WA_NODE_BINARIES_URL="$nothing" wa_node_binary_source_resolve "$ROOT" "$COMMIT" "$X64" "$i" 2>&1)"
expect_status 8 "$?" "a release that is not there"
contains "$out" "node_release_unavailable:" "the missing release is named as unavailable"
[ ! -d "$i/node-binaries/$SHORT/$X64" ] || fail "an unavailable release left a cache entry behind"
ok
WA_NODE_DISK_FLOOR_BYTES=0 wa_node_disk_floor_ok "$ROOT" >/dev/null || fail "a zero floor did not pass (the machine should always be above it)"
ok
out="$(WA_NODE_DISK_FLOOR_BYTES=1099511627776 wa_node_disk_floor_ok "$ROOT" 2>&1)"
expect_status 1 "$?" "a floor no disk meets"
contains "$out" "the build refused to start" "the refusal carries the floor's own verdict and numbers"

# --- an operator's directory, and the staging the deploy does ----------------------------------------
explicit="$WORK/explicit"; mkdir -p "$explicit"
mkelf "$explicit/wa" 3e; mkelf "$explicit/wa-sentinel" 3e
i="$(fresh explicit)"
out="$(WA_DEPLOY_BINARY_SOURCE="$explicit" WA_NODE_TARGET="$X64" wa_node_binaries_prepare "$ROOT" "$COMMIT" "$WORK/stage-explicit" "$i" 2>&1)"
expect_status 0 "$?" "WA_DEPLOY_BINARY_SOURCE stages"
contains "$out" "binary_source: $X64 $explicit (WA_DEPLOY_BINARY_SOURCE)" "the override says it is the override"
[ -s "$WORK/stage-explicit/wa" ] && [ -s "$WORK/stage-explicit/wa-sentinel" ] || fail "the staged files are missing or empty"
ok
# The exec bit is not asserted on purpose: this checkout sits on a mount where `chmod` is a no-op, so a
# test that required it would pass on Linux and fail here for a reason that has nothing to do with the
# code (the deploy checks presence and then executes the binary in its prove gate).

i="$(fresh prepare)"
out="$(WA_NODE_TARGET="$X64" WA_NODE_BINARIES_URL="$release" wa_node_binaries_prepare "$ROOT" "$COMMIT" "$WORK/stage-published" "$i" 2>&1)"
expect_status 0 "$?" "a published release stages"
contains "$out" "binary_source: $X64 $i/node-binaries/$SHORT/$X64 (verified against node-$SHORT)" "the published source is named with its tag"
cmp -s "$WORK/stage-published/wa" "$release/wa-$X64-$SHORT" || fail "the staged binary is not the published one"
ok
[ -f "$WORK/stage-published/node-binaries.manifest" ] || fail "the staged manifest was not carried beside the binary"
ok

# A Windows-shaped host: no published target, so the deploy builds - rc 8, and the line says why.
i="$(fresh windows)"
out="$(WA_NODE_UNAME_S=MINGW64_NT WA_NODE_UNAME_M=x86_64 wa_node_binaries_prepare "$ROOT" "$COMMIT" "$WORK/stage-win" "$i" 2>&1)"
expect_status 8 "$?" "a host with no published target"
contains "$out" "binary_source: this tree" "the Windows path says it builds"

# --- the branch itself, executed ---------------------------------------------------------------------
# The lib and the wiring order are both checked above; what neither of them runs is the code deploy.sh
# adds - the case statement that turns a resolve into `NEW`, a build, or a refusal. So the branch is read
# out of deploy.sh by its own markers and run against the fixtures, with only `fail`/`note`/`wa_phase`
# stood in for. That is the same technique scripts/test-deploy-gate-policy.sh uses on the proof block,
# and it is why a change here cannot pass by never being executed.
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
HEAD_SHORT="${HEAD_SHA:0:12}"
BRANCH="$WORK/prebuilt-branch.sh"
awk '/^# wa-deploy-prebuilt-branch: begin$/{on=1} on{print} on && /^# wa-deploy-prebuilt-branch: end$/{exit}'   "$ROOT/scripts/deploy.sh" > "$BRANCH"
[ -s "$BRANCH" ] || fail "could not read the prebuilt branch out of deploy.sh (its markers are gone)"
grep -q 'wa_node_binaries_prepare' "$BRANCH" || fail "the extracted branch does not call the resolver"

mksha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
mkbytes() { wc -c < "$1" | tr -d '[:space:]'; }
head_release="$WORK/head-release"; mkdir -p "$head_release"
mkelf "$head_release/wa-$X64-$HEAD_SHORT" 3e
mkelf "$head_release/wa-sentinel-$X64-$HEAD_SHORT" 3e
cat > "$head_release/node-$HEAD_SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$HEAD_SHA
glibc_floor=2.31
codemode=embedded
$X64 $(mksha "$head_release/wa-$X64-$HEAD_SHORT") $(mkbytes "$head_release/wa-$X64-$HEAD_SHORT") $(mksha "$head_release/wa-sentinel-$X64-$HEAD_SHORT") $(mkbytes "$head_release/wa-sentinel-$X64-$HEAD_SHORT")
MANIFEST

run_branch() { # <install dir> [env...] -> the branch's output; exit status is its own
  local install="$1"; shift
  {
    echo 'set -uo pipefail'
    # Written into the harness, not sourced here: a `source` executed by this generator would land in the
    # test's own shell and the harness would then find no helper at all.
    echo ". \"$ROOT/scripts/lib/node-binaries.sh\""
    echo "ROOT=\"$ROOT\""
    echo "INSTALL_DIR=\"$install\""
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    echo 'note() { echo "note: $*"; }'
    echo 'wa_phase() { :; }'
    cat "$BRANCH"
    echo 'echo "PREBUILT=$PREBUILT_BINARIES NEW=${NEW:-} PROVENANCE=${BINARY_PROVENANCE:-} RELEASE=${BINARY_RELEASE:-}"'
  } > "$WORK/run-branch.sh"
  ( env WA_NODE_TARGET="$X64" "$@" bash "$WORK/run-branch.sh" 2>&1 )
}

bi="$WORK/branch-install"; mkdir -p "$bi"
out="$(run_branch "$bi" WA_NODE_BINARIES_URL="$head_release")"
expect_status 0 "$?" "the branch with a published release"
contains "$out" "binary_source: $X64 " "the branch prints the source line"
contains "$out" "PREBUILT=1" "the branch sets PREBUILT_BINARIES"
contains "$out" "PROVENANCE=prebuilt-release" "the branch records the release as the provenance"
contains "$out" "RELEASE=node-$HEAD_SHORT" "the branch records the release tag"

out="$(run_branch "$WORK/br-override" WA_DEPLOY_BINARY_SOURCE="$WORK/explicit")"
expect_status 0 "$?" "the branch with an operator directory"
contains "$out" "PROVENANCE=prebuilt-source" "the override is recorded as such"

tampered="$WORK/head-tampered"; cp -r "$head_release" "$tampered"; printf 'x' >> "$tampered/wa-$X64-$HEAD_SHORT"
out="$(run_branch "$WORK/br-tampered" WA_NODE_BINARIES_URL="$tampered")"
expect_status 3 "$?" "the branch with a tampered release"
contains "$out" "refused(prebuilt_binary_refused)" "the branch refuses by name"
contains "$out" "node_hash_mismatch:" "the refusal carries the lib's reason"

out="$(run_branch "$WORK/br-build" WA_NODE_BINARIES_URL="$nothing" WA_NODE_DISK_FLOOR_BYTES=0)"
expect_status 0 "$?" "the branch with nothing published and a disk that can build"
contains "$out" "building this tree (disk floor ok)" "the fallback says it is building"
contains "$out" "PREBUILT=0" "the fallback leaves PREBUILT_BINARIES alone"

out="$(run_branch "$WORK/br-nodisk" WA_NODE_BINARIES_URL="$nothing" WA_NODE_DISK_FLOOR_BYTES=1099511627776)"
expect_status 3 "$?" "the branch with nothing published and no disk"
contains "$out" "refused(no_prebuilt_binary_and_disk_floor)" "the neither-path refusal is named"
contains "$out" "publish-node-binaries.sh" "the refusal says how to publish"

out="$(run_branch "$WORK/br-buildonly" WA_DEPLOY_BUILD_ONLY=1 WA_NODE_BINARIES_URL="$head_release")"
expect_status 0 "$?" "WA_DEPLOY_BUILD_ONLY=1"
contains "$out" "WA_DEPLOY_BUILD_ONLY=1" "the knob is said out loud"
contains "$out" "PREBUILT=0" "the knob builds instead of installing"

# A host with no published target must reach the build without asking the disk floor, even when the floor
# says no: there is no channel for it to have fallen back from (scripts/test-deploy-preconditions.sh pins
# the consequence - a Windows tree without cargo is refused as cargo_unavailable, not as this).
out="$(run_branch "$WORK/br-windows" WA_NODE_TARGET= WA_NODE_UNAME_S=MINGW64_NT WA_NODE_UNAME_M=x86_64   WA_NODE_DISK_FLOOR_BYTES=1099511627776)"
expect_status 0 "$?" "the branch on a host with no published target"
contains "$out" "has no published node-binary target" "the host is told why it builds"
contains "$out" "PREBUILT=0" "it builds, with no disk question"


# --- the wiring in scripts/deploy.sh ------------------------------------------------------------------
# The lib is useless unless the deploy calls it BEFORE it asks for cargo: the whole point is that a node
# without a toolchain installs a published binary, so the order of these lines is the requirement, and a
# line that only exists in the lib would pass every check above while changing nothing on a node.
DEPLOY="$ROOT/scripts/deploy.sh"
[ -f "$DEPLOY" ] || fail "no scripts/deploy.sh"
grep -q 'for wa_lib_part in build-status build-requirements deploy-components node-binaries' "$DEPLOY"   || fail "deploy.sh does not source scripts/lib/node-binaries.sh"
ok
grep -q 'wa_node_binaries_prepare "$ROOT"' "$DEPLOY" || fail "deploy.sh never calls wa_node_binaries_prepare"
ok
grep -q 'no_prebuilt_binary_and_disk_floor' "$DEPLOY" || fail "deploy.sh has no refusal for 'no prebuilt and no disk'"
ok
grep -q 'binary_source=%s' "$DEPLOY" || fail "deploy.sh does not record where the binary came from in installed.txt"
ok
prepare_line="$(grep -n 'wa_node_binaries_prepare "$ROOT"' "$DEPLOY" | head -1 | cut -d: -f1)"
requirements_line="$(grep -n '^deploy_requirements$' "$DEPLOY" | head -1 | cut -d: -f1)"
build_line="$(grep -n 'WA_BUILD_CARGO_LOG=' "$DEPLOY" | head -1 | cut -d: -f1)"
[ -n "$prepare_line" ] && [ -n "$requirements_line" ] && [ -n "$build_line" ] || fail "could not locate the prebuilt/build lines in deploy.sh"
[ "$prepare_line" -lt "$requirements_line" ] || fail "the prebuilt step (line $prepare_line) runs after the toolchain check (line $requirements_line)"
ok
[ "$requirements_line" -lt "$build_line" ] || fail "the toolchain check runs after the build"
ok
# The prove gate must stay outside the prebuilt/build branch: a published binary is proved on the node too.
prove_line="$(grep -n '^# 5. Prove it answers' "$DEPLOY" | head -1 | cut -d: -f1)"
prebuilt_close="$(awk -v start="$prepare_line" 'NR > start && /^fi$/ {print NR; exit}' "$DEPLOY")"
[ -n "$prove_line" ] && [ -n "$prebuilt_close" ] && [ "$prebuilt_close" -lt "$prove_line" ]   || fail "the prebuilt branch (closed at ${prebuilt_close:-nowhere}) does not close before the prove gate (line $prove_line)"
ok

echo "node binaries (deploy) ok ($checks checks)"
