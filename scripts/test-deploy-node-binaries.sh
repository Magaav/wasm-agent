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
# The supervisor half (job sentfix, the first prebuilt deploy of 75ac2964 on openclaw, 06/11: the node
# installed and then `could not install wa-sentinel - it is still the old build`). A published release
# carries `wa-sentinel` too, and the step that installs it is READ OUT OF deploy.sh by its own markers and
# run against fixtures:
#   * the prebuilt supervisor is taken from the verified directory (not from the staging directory the same
#     deploy has already removed), installed, and its hash recorded - and the directory's manifest pin is
#     re-checked at that point, so a cached sentinel swapped under a cache hit is REFUSED by name;
#   * the build path is unchanged: no prebuilt source, and the tree's own artifact is installed;
#   * installed.txt for a prebuilt install records commit=<40 hex>, binary_source=, binary_release= and
#     binary_commit=, and refuses to write a record whose commit is not a full id.
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

# --- the supervisor inside a verified directory -----------------------------------------------------
# The deploy's sentinel step takes the supervisor from here (see the install-block cases below), so the two
# answers it needs are pinned directly: which file, and which sha256 the manifest pins for it. The third
# answer - "there is no manifest row" - must be distinguishable from a pin, because an operator's directory
# (WA_DEPLOY_BINARY_SOURCE) has no manifest and is installed on the node's own proof instead.
[ "$(wa_node_sentinel_file "$release" "$COMMIT" "$X64")" = "$release/wa-sentinel-$X64-$SHORT" ] \
  || fail "the release's sentinel file was not found under its published name"
ok
[ "$(wa_node_sentinel_pin "$release" "$COMMIT" "$X64")" = "$ssha" ] \
  || fail "the sentinel pin is not the manifest row's third field"
ok
expect_status 3 "$(wa_node_sentinel_pin "$release" "$COMMIT" "$ARM" >/dev/null 2>&1; echo $?)" "a target with no row pins no sentinel"
plain_sentinel="$WORK/plain-sentinel"; mkdir -p "$plain_sentinel"; mkelf "$plain_sentinel/wa-sentinel" 3e
[ "$(wa_node_sentinel_file "$plain_sentinel" "$COMMIT" "$X64")" = "$plain_sentinel/wa-sentinel" ] \
  || fail "a plain wa-sentinel (the WA_DEPLOY_BINARY_SOURCE shape) was not found"
ok
expect_status 3 "$(wa_node_sentinel_pin "$plain_sentinel" "$COMMIT" "$X64" >/dev/null 2>&1; echo $?)" "an unpinned directory is unpinned, not pinned"
no_sentinel="$WORK/no-sentinel"; mkdir -p "$no_sentinel"
expect_status 2 "$(wa_node_sentinel_file "$no_sentinel" "$COMMIT" "$X64" >/dev/null 2>&1; echo $?)" "a directory with no supervisor at all"
expect_status 2 "$(wa_node_sentinel_file "$no_sentinel" 1111 "$X64" >/dev/null 2>&1; echo $?)" "a commit id that is not 40-hex names no sentinel"

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
    echo 'echo "SENTINEL_SOURCE=${SENTINEL_SOURCE:-}"'
    echo 'echo "BINARY_DIR=${BINARY_DIR:-} BINARY_TRIPLE=${BINARY_TRIPLE:-}"'
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
contains "$out" "SENTINEL_SOURCE=$WORK/explicit/wa-sentinel" "the override's own wa-sentinel is the supervisor"
contains "$out" "carries no manifest row for $X64" "an operator directory is said to be unpinned, not read as a pass"

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

# --- the prebuilt supervisor: the step that failed on openclaw (06/11) -------------------------------
# The first prebuilt deploy of 75ac2964 installed the node and then refused -
# `could not install wa-sentinel - it is still the old build; the node and its supervisor would disagree` -
# because deploy.sh removes the staging directory (`node-binary.next`) once the proved node is its
# hash-named candidate, and the sentinel step was still reading `$BINARY_STAGE/wa-sentinel` out of it. So
# the sentinel step is read out of deploy.sh by its own markers and RUN: first with the prebuilt supervisor
# of a verified directory and the stage already removed (must install), then with the build path's own
# artifact (must install exactly that, unchanged), then with a stage-and-no-source (must refuse by name).
SENTINEL_BLOCK="$WORK/sentinel-install.sh"
DEPLOY="$ROOT/scripts/deploy.sh"
awk '/^# wa-deploy-sentinel-install: begin$/{on=1} on{print} on && /^# wa-deploy-sentinel-install: end$/{exit}' "$DEPLOY" > "$SENTINEL_BLOCK"
[ -s "$SENTINEL_BLOCK" ] || fail "could not read the sentinel install step out of deploy.sh (its markers are gone)"
grep -q 'SENTINEL_SOURCE' "$SENTINEL_BLOCK" || fail "the extracted sentinel step does not read SENTINEL_SOURCE"
ok

run_sentinel_install() { # <install dir> [env...] -> the block's output; exit status is its own
  local install="$1"; shift
  {
    echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$install\""
    echo 'SENTINEL_NAME=wa-sentinel'
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    echo 'note() { echo "note: $*"; }'
    echo 'sentinel_restart() { return 0; }'
    cat "$SENTINEL_BLOCK"
    echo 'echo "SENTINEL_HASH=${SENTINEL_HASH:-} SWAP=${SENTINEL_SWAP_STARTED:-}"'
  } > "$WORK/run-sentinel.sh"
  ( env "$@" bash "$WORK/run-sentinel.sh" 2>&1 )
}

si_install="$WORK/si-prebuilt"; mkdir -p "$si_install"
printf '#!/bin/sh\necho "the supervisor that was installed before"\n' > "$si_install/wa-sentinel"
old_sentinel_hash="$(wa_node_sha256 "$si_install/wa-sentinel")"
out="$(run_branch "$WORK/br-sentinel" WA_NODE_BINARIES_URL="$head_release")"
expect_status 0 "$?" "the branch with a published release, for the supervisor step"
sentinel_src="$(printf '%s\n' "$out" | sed -n 's/^SENTINEL_SOURCE=//p' | tail -1)"
[ -n "$sentinel_src" ] || fail "the branch handed no supervisor source to the install step: $out"
ok
case "$sentinel_src" in
  "$WORK/br-sentinel/node-binaries/$HEAD_SHORT/$X64/wa-sentinel-$X64-$HEAD_SHORT") ok ;;
  *) fail "the prebuilt supervisor does not come from the verified cache entry: $sentinel_src" ;;
esac
contains "$out" "the prebuilt sentinel is the manifest's pinned bytes" "the branch says the supervisor is the pinned bytes"
# Exactly what deploy.sh does after the prove gate: the staged copy is not install state any more.
rm -rf "$WORK/br-sentinel/node-binary.next"
[ ! -e "$WORK/br-sentinel/node-binary.next/wa-sentinel" ] || fail "the stage the old step read from is still there"
ok
out="$(run_sentinel_install "$si_install" SENTINEL_SOURCE="$sentinel_src" NEW_SENTINEL="$WORK/br-sentinel/node-binary.next/wa-sentinel")"
expect_status 0 "$?" "the sentinel step with the staging directory removed"
contains "$out" "deploy: sentinel wa-sentinel updated" "the prebuilt supervisor replaces the installed one"
cmp -s "$sentinel_src" "$si_install/wa-sentinel" || fail "the installed supervisor is not the prebuilt one"
ok
contains "$out" "SENTINEL_HASH=$(wa_node_sha256 "$sentinel_src")" "the step records the hash of the supervisor it installed"
[ "$(wa_node_sha256 "$si_install/wa-sentinel")" != "$old_sentinel_hash" ] || fail "the supervisor was not replaced"
ok
# It has to be executable: the file now installed comes from the cache entry (a download), not from the
# staging copy that used to be chmod'ed. Only asserted where the filesystem HAS an exec bit - this checkout's
# /c mount reports every file executable, so a probe decides rather than the test's own assumption.
exec_probe="$WORK/exec-probe"; printf '#!/bin/sh\n' > "$exec_probe"; chmod 644 "$exec_probe" 2>/dev/null
if [ ! -x "$exec_probe" ]; then
  [ -x "$si_install/wa-sentinel" ] || fail "the installed prebuilt supervisor is not executable"
  ok
else
  echo "  (exec bit: this filesystem reports every file executable - the bit is not asserted here)"
fi

# The build path is unchanged: no prebuilt source, and the step installs the tree's own artifact. That is
# the branch every Windows deploy and every WA_DEPLOY_BUILD_ONLY run still takes.
bs_install="$WORK/si-build"; mkdir -p "$bs_install"
printf '#!/bin/sh\necho "the supervisor that was installed before"\n' > "$bs_install/wa-sentinel"
mkdir -p "$WORK/built-sentinel"
printf '#!/bin/sh\necho "the supervisor this tree built"\n' > "$WORK/built-sentinel/wa-sentinel"
out="$(run_sentinel_install "$bs_install" NEW_SENTINEL="$WORK/built-sentinel/wa-sentinel")"
expect_status 0 "$?" "the sentinel step on the build path"
cmp -s "$WORK/built-sentinel/wa-sentinel" "$bs_install/wa-sentinel" || fail "the build path's own sentinel was not what got installed"
ok

# A step with neither a prebuilt source nor a tree artifact refuses BY NAME instead of reporting an install
# that put the old build in place. This is the shape the openclaw failure wore, said out loud.
out="$(run_sentinel_install "$bs_install" NEW_SENTINEL="$WORK/does-not-exist/wa-sentinel")"
expect_status 3 "$?" "the sentinel step with no supervisor to install"
contains "$out" "refused(sentinel_source_missing)" "the missing supervisor is refused by name"
contains "$out" "$WORK/does-not-exist/wa-sentinel" "the refusal names the path it looked at"

# --- the mismatch: a verified directory whose sentinel is not the pinned bytes -----------------------
# The check is not vacuous, and this is why it is re-read at install time rather than trusted from the
# fetch: the cache-hit path only re-checks the NODE's sha256 (`.complete`), so a cached sentinel can be
# swapped under a deploy that would otherwise install it. Same name, same size even - only the bytes differ.
# Same name, same size even - only the bytes differ (`fixture-binary` -> `fixture-BINARY`), so the size
# check cannot be what refuses it.
mismatch="$WORK/br-sentinel-mismatch"; mkdir -p "$mismatch"
WA_NODE_BINARIES_URL="$head_release" wa_node_binary_source_resolve "$ROOT" "$HEAD_SHA" "$X64" "$mismatch" >/dev/null 2>&1 \
  || fail "could not populate the cache entry the mismatch case needs"
mismatch_entry="$mismatch/node-binaries/$HEAD_SHORT/$X64"
[ -f "$mismatch_entry/.complete" ] || fail "the mismatch case has no cache entry"
ok
cp -f "$mismatch_entry/wa-sentinel-$X64-$HEAD_SHORT" "$WORK/pinned-sentinel"
sed 's/fixture-binary/fixture-BINARY/' "$WORK/pinned-sentinel" > "$mismatch_entry/wa-sentinel-$X64-$HEAD_SHORT"
cmp -s "$WORK/pinned-sentinel" "$mismatch_entry/wa-sentinel-$X64-$HEAD_SHORT" && fail "the mismatch fixture did not change the bytes"
ok
[ "$(wc -c < "$mismatch_entry/wa-sentinel-$X64-$HEAD_SHORT" | tr -d '[:space:]')" = "$(wc -c < "$WORK/pinned-sentinel" | tr -d '[:space:]')" ] \
  || fail "the mismatch fixture changed the size as well as the bytes"
ok
out="$(run_branch "$mismatch" WA_NODE_BINARIES_URL="$head_release")"
expect_status 3 "$?" "the branch with a cached sentinel that is not the pinned bytes"
contains "$out" "refused(prebuilt_sentinel_mismatch)" "the swapped supervisor is refused by name"
contains "$out" "wa-sentinel-$X64-$HEAD_SHORT" "the refusal names the file"
contains "$out" "nothing installed" "the refusal says nothing was installed"
# ...and the node's own binary in that entry is still accepted, so the refusal above is about the sentinel
# and not about the fixture being broken.
[ "$(wa_node_sha256 "$mismatch_entry/wa-$X64-$HEAD_SHORT")" = "$(wa_node_sha256 "$head_release/wa-$X64-$HEAD_SHORT")" ] \
  || fail "the mismatch fixture also replaced the node binary"
ok

# --- installed.txt for a prebuilt install: commit=<40 hex>, binary_source=, binary_release=, binary_commit=
# The record step is read out of deploy.sh and run, the way scripts/test-deploy-record.sh runs it. What this
# adds is the prebuilt half: the commit it names is the manifest's 40-hex identity (not the short id a build
# records), and the three binary lines say where the bytes came from. openclaw's record ended at
# `commit=unknown` because the deploy died before this step - so the step is also proved to refuse a commit
# it cannot state as a full id rather than write a record no check can use.
RECORD_BLOCK="$WORK/record.sh"
awk '/^record_installed\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$DEPLOY" > "$RECORD_BLOCK"
[ -s "$RECORD_BLOCK" ] || fail "could not read the install record step out of deploy.sh"
grep -q 'record_role=final' "$RECORD_BLOCK" || fail "the extracted record step is not the deploy's"
ok
rec_install="$WORK/rec-install"; mkdir -p "$rec_install/scripts"
printf '#!/bin/sh\necho node\n' > "$rec_install/wa"
printf '#!/bin/sh\necho sentinel\n' > "$rec_install/wa-sentinel"
printf '#!/bin/sh\n' > "$rec_install/scripts/upgrade.sh"
run_record() { # [commit the record should name] -> the record step's output, run against $rec_install
  local bcommit="${1:-$HEAD_SHA}"
  {
    echo 'set -uo pipefail'
    echo "INSTALL_DIR=\"$rec_install\""
    echo 'COMMIT=deadbee'                 # deliberately short: a prebuilt record must NOT name this
    echo 'BRANCH=main'
    echo 'DIRTY=0'
    echo 'HASH=nodehash'
    echo 'SENTINEL_HASH=sentinelhash'
    echo 'UPGRADE_HASH=upgradehash'
    echo 'REASON="prebuilt install"'
    echo 'RELEASE=""'
    echo 'WA_SERVICE_DIR=""'
    echo 'LUA_FAST=0'
    echo 'COMPONENT_DIR=/nonexistent'
    echo 'COMPONENT_SHA=deadbeef'
    echo 'BINARY_PROVENANCE=prebuilt-release'
    echo "BINARY_RELEASE=node-$HEAD_SHORT"
    echo "BINARY_COMMIT=$bcommit"
    echo 'fail() { echo "REFUSED: $*" >&2; exit 3; }'
    cat "$RECORD_BLOCK"
    echo 'record_installed'
  } > "$WORK/run-record.sh"
  ( bash "$WORK/run-record.sh" 2>&1 )
}
out="$(run_record)"
expect_status 0 "$?" "the record step for a prebuilt install"
record="$(cat "$rec_install/installed.txt")"
contains "$record" "commit=$HEAD_SHA" "the record names the 40-hex commit"
contains "$record" "binary_source=prebuilt-release" "the record says the binary came from a release"
contains "$record" "binary_release=node-$HEAD_SHORT" "the record names the release"
contains "$record" "binary_commit=$HEAD_SHA" "the record names the commit the bytes were verified against"
contains "$record" "sentinel_sha256=sentinelhash" "the record still names the installed supervisor's hash"
if printf '%s' "$record" | grep -q '^commit=deadbee$'; then fail "the record named the short id instead of the 40-hex commit"; fi
ok
# A prebuilt record whose commit is not a 40-hex id is refused, and the record that was already there stands.
out="$(run_record abc1234)"
expect_status 3 "$?" "the record step for a prebuilt install with a short commit"
contains "$out" "not a 40-hex commit id" "the refusal says what a prebuilt record must name"
contains "$(cat "$rec_install/installed.txt")" "commit=$HEAD_SHA" "the refused write did not replace the good record"


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
# ...and the resolver beside the INSTALLED copy of this script: `request deploy` runs that copy, so a deploy
# whose lib was never shipped notes "no node-binaries helper" and builds - which is exactly the node that
# cannot build (openclaw).
grep -q 'ship_file "$ROOT/scripts/lib/node-binaries.sh"' "$DEPLOY"   || fail "deploy.sh does not ship scripts/lib/node-binaries.sh beside the installed deploy"
ok
# The prebuilt branch must hand the sentinel step the verified directory's own supervisor: the staging copy
# it used to read is gone by then (see the install-block cases above).
grep -q 'wa_node_sentinel_file' "$BRANCH" || fail "the prebuilt branch does not take the supervisor from the verified directory"
ok
grep -q 'wa_node_sentinel_pin' "$BRANCH" || fail "the prebuilt branch does not check the supervisor against the manifest's pin"
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
