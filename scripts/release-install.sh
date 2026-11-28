#!/usr/bin/env bash
# Install a published node release on THIS node, as a NEIGHBOUR of the running node (item 28).
#
# WHY THIS EXISTS. Two of the ring's nodes cannot build: nextcloud is aarch64 with no toolchain, and a
# node that was installed FROM a release has no tree to deploy. `mode=binary` covers the first (the
# published binary, installed by the node's own deploy.sh), but the second has no tree at all - so
# `prepare_tree` refuses it before anything is attempted (`no_runtime_tree`) and the only way to move it
# is a hand-run upgrade.sh on the machine. This is that procedure as one supported unit.
#
# IT DOES NOT REPLACE ITSELF: scripts/upgrade.sh is the one code path that proves a candidate `/health`,
# waits for the node to be idle, swaps, restarts and rolls back if the new one does not come up. It is
# started here as a CHILD of the caller (the node's own Sentinel), which is what makes it a neighbour
# process and not the running node rewriting its own image.
#
# Usage:
#   bash scripts/release-install.sh <40-hex commit> [--cover-commit <40-hex>] [--lua-inputs <sha256>]
#
# --cover-commit names the release whose bytes are ANOTHER commit's build (a cover: identical compiled inputs,
# different commit). A tree-less node runs the binary's EMBEDDED Lua, so a cover is only installable when that
# Lua is this commit's - and this node has no tree to compute that from, so the caller that HAS one passes the
# result: --lua-inputs is the wa_lua_tree_digest of the commit being installed, and scripts/upgrade.sh refuses
# the cover by name when the release's lua_inputs row disagrees with it, or when no digest was given at all.
#
# Exit codes: 0 installed and verified; 2 a named refusal (nothing staged); 3 installed but the
# verification after the swap disagreed (upgrade.sh's own rollback is what put the old bytes back).
set -uo pipefail

say() { printf '  %s\n' "$*"; }
fail() { printf 'release_install: %s\n' "$*" >&2; exit 2; }

COMMIT="${1:-}"
[ "$#" -gt 0 ] && shift
COVER_COMMIT=""
LUA_INPUTS="${WA_RELEASE_LUA_INPUTS:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cover-commit) [ "$#" -ge 2 ] || fail 'cover_commit_value_required'; COVER_COMMIT="$2"; shift 2 ;;
    --lua-inputs) [ "$#" -ge 2 ] || fail 'lua_inputs_value_required'; LUA_INPUTS="$2"; shift 2 ;;
    *) fail "unknown_option: $1" ;;
  esac
done
INSTALL="${WA_INSTALL_DIR:-${WA_RELEASE_INSTALL:-}}"
if [ -z "$INSTALL" ]; then
  if [ -f "${HOME:-}/.wasm-agent/install-dir.txt" ]; then
    INSTALL="$(tr -d '\r\n' < "${HOME:-}/.wasm-agent/install-dir.txt")"
  else
    INSTALL="${HOME:-}/.local/bin"
  fi
fi
[ -d "$INSTALL" ] || fail "install_dir_missing: $INSTALL does not exist; this installs over a running node, it does not create one"

# The libs beside the binary are what a release install has: the installer shipped the core's own
# requirement list, and deploy.sh ships this one beside them (it is what fetches and verifies a release).
LIB=""
for candidate in "$INSTALL/scripts/lib/node-binaries.sh" "${WA_RELEASE_LIB:-}"; do
  [ -n "$candidate" ] && [ -f "$candidate" ] && { LIB="$candidate"; break; }
done
[ -n "$LIB" ] || fail "node_binaries_lib_missing: no scripts/lib/node-binaries.sh under $INSTALL, so a published release cannot be fetched or verified (deploy this commit there once, or set WA_RELEASE_LIB)"
# shellcheck source=/dev/null
. "$LIB"

[ -n "$COMMIT" ] || fail "release_commit_required: name the 40-hex commit to install (this node has no tree to read one from)"
case "$COMMIT" in
  *[!0-9a-f]*|'') fail "release_commit_invalid: \"$COMMIT\" is not a hex commit id" ;;
esac
[ "${#COMMIT}" = 40 ] || fail "release_commit_invalid: \"$COMMIT\" is not a full 40-hex commit id"
if [ -n "$COVER_COMMIT" ]; then
  case "$COVER_COMMIT" in
    *[!0-9a-f]*) fail "cover_commit_invalid: \"$COVER_COMMIT\" is not a hex commit id" ;;
  esac
  [ "${#COVER_COMMIT}" = 40 ] || fail "cover_commit_invalid: \"$COVER_COMMIT\" is not a full 40-hex commit id"
  [ "$COVER_COMMIT" != "$COMMIT" ] || fail "cover_commit_pointless: --cover-commit names $COMMIT itself; ask for it as the release commit"
  # A COVER ON A TREE-LESS NODE IS DECIDED BY TWO DIGESTS, one of which this node cannot compute. Refusing here
  # rather than after the download says which fact is missing instead of leaving it to the installer one step
  # later (scripts/upgrade.sh owns the comparison itself - release_cover_lua_mismatch).
  case "$LUA_INPUTS" in
    '') fail "release_cover_lua_unknown: a cover runs its binary's embedded Lua, and this node has no tree to compute the Lua-tree digest of $COMMIT from - pass --lua-inputs <sha256> (wa_lua_tree_digest <tree> $COMMIT), or install a release named for $COMMIT itself" ;;
    *[!0-9a-f]*) fail "release_cover_lua_unknown: --lua-inputs \"$LUA_INPUTS\" is not a sha256 hex digest" ;;
  esac
  [ "${#LUA_INPUTS}" = 64 ] || fail "release_cover_lua_unknown: --lua-inputs must be 64 hex characters (a wa_lua_tree_digest), got ${#LUA_INPUTS}"
fi

UPGRADE="$INSTALL/scripts/upgrade.sh"
[ -f "$UPGRADE" ] || fail "upgrade_script_missing: $UPGRADE is not installed, so nothing can stage or prove a new binary safely"

TRIPLE="$(wa_node_target_triple 2>/dev/null)" || fail "release_target_unknown: this host is not one of the published targets ($(uname -s 2>/dev/null)/$(uname -m 2>/dev/null))"
REPO="$(wa_node_release_repo "$INSTALL" 2>/dev/null)" || REPO=""
[ -n "$REPO" ] || fail "release_repo_unknown: no owner/repo for the node release (set WA_NODE_RELEASE_REPO)"
CACHE="$(wa_node_cache_root "$INSTALL")"
SHORT="${COMMIT:0:12}"
# THE BYTES' OWN COMMIT: this one when a release names it, the cover's when one was named. Everything below
# reads the file the manifest pins for THAT commit, and the record is verified against it.
SOURCE_COMMIT="$COMMIT"

say "fetching node-$SHORT for $TRIPLE into $CACHE (manifest, signature and every pin verified)"
DIR=""
if ! DIR="$(wa_node_binary_download "$REPO" "$COMMIT" "$TRIPLE" "$CACHE" 2>&1)"; then
  RC=$?; EXACT_ERR="$DIR"; DIR=""
  # THE ANSWER A TREE-LESS NODE OWES when no release names the commit it was asked for: one line that says
  # what is missing, why another commit's build is not a substitute here, and what the caller can do. A node
  # with no tree runs the binary's EMBEDDED Lua (its install has no lua-core to stage), so a cover is only
  # installable when that Lua is this commit's - a fact only a machine with the tree can compute.
  [ -n "$COVER_COMMIT" ] || fail "release_cover_needed: no release names $SHORT and this node has no tree to build it from; a cover (another commit's build) is only installable when its embedded Lua tree is $COMMIT's, so pass --cover-commit <40-hex> --lua-inputs <sha256> (the coordinator's wa_node_release_digest_search plus wa_lua_tree_digest). The release channel said: $EXACT_ERR"
  say "node-$SHORT is not published: taking the cover node-${COVER_COMMIT:0:12} (a build of $COVER_COMMIT, whose Lua tree must be $COMMIT's)"
  DIR="$(wa_node_binary_download "$REPO" "$COVER_COMMIT" "$TRIPLE" "$CACHE" 2>&1)" || {
    RC=$?
    fail "release_download_failed($RC): $DIR (after node-$SHORT: $EXACT_ERR)"
  }
  SOURCE_COMMIT="$COVER_COMMIT"
fi
[ -d "$DIR" ] || fail "release_download_failed: wa_node_binary_download printed no directory"
SOURCE_SHORT="${SOURCE_COMMIT:0:12}"
CANDIDATE="$DIR/wa-$TRIPLE-$SOURCE_SHORT"
[ -f "$CANDIDATE" ] || fail "release_binary_missing: $CANDIDATE is not in the verified release directory"
[ -f "$DIR/SHA256SUMS" ] || fail "release_sums_missing: $DIR carries no SHA256SUMS, so upgrade.sh cannot verify the candidate"

# THE RUNTIME NAMES, BESIDE THE BINARY BEFORE upgrade.sh SEES IT (decision 27/11). upgrade.sh resolves its
# siblings by the name `wa` uses at runtime: dirname of the binary it is handed, then a plain wa-term /
# wa-operations-supervisor (scripts/upgrade.sh:168-185). A release directory holds the SUFFIXED asset names,
# so without this a cover install refuses term_program_missing for a set it has just verified and signature-
# checked - measured: every cover install ended in release_install: upgrade_refused. The names are copies of
# the bytes already verified in $DIR; upgrade.sh keeps ONE naming rule and nothing here renames an asset.
# THE MEMBERS COME FROM THE ONE LIST (law 17), never from a pair spelled here: wa_node_bundle_members answers what
# this release pins (wa, wa-sentinel, wa-term, and the supervisor when the manifest carries its columns), so a
# sibling added to WA_BUNDLE_MEMBERS is staged here without this block being edited again.
for _asset in $(wa_node_bundle_members "$DIR" "$TRIPLE" "$SOURCE_SHORT"); do
  _runtime="${_asset%-$TRIPLE-$SOURCE_SHORT}"
  [ -f "$DIR/$_asset" ] || continue
  cp -f "$DIR/$_asset" "$DIR/$_runtime" || fail "release_stage_failed: $DIR/$_runtime could not be staged beside $CANDIDATE"
  chmod +x "$DIR/$_runtime" 2>/dev/null || true
done
unset _asset _runtime

say "upgrading: bash scripts/upgrade.sh $CANDIDATE --release $DIR"
# THE TWO FACTS THE INSTALLER CANNOT COMPUTE ON A TREE-LESS NODE, handed to the one place that judges a cover
# (scripts/upgrade.sh: release_cover_lua_unknown / _unrecorded / _mismatch). WA_UPGRADE_REQUESTED_COMMIT is the
# commit this node is being moved TO; WA_RELEASE_LUA_INPUTS is that commit's Lua-tree digest, from the caller
# that has the tree.
if ! WA_UPGRADE_REQUESTED_COMMIT="$COMMIT" WA_RELEASE_LUA_INPUTS="$LUA_INPUTS" \
     bash "$UPGRADE" "$CANDIDATE" --release "$DIR"; then
  fail "upgrade_refused: scripts/upgrade.sh did not install $SHORT; it puts the previous bytes back itself, so this node is where it was. Its own words are above."
fi

# ---- the two checks that make "installed" a fact and not the installer's word --------------------
# 1. THE RUNNING PROCESS IS THOSE BYTES. /proc/<pid>/exe is the kernel's answer, not the script's: a
#    swap that left the old process running - the exact shape that leaves a node serving an old build
#    while installed.txt claims the new one - fails here.
PID_FILE="$INSTALL/serve.pid"
PID="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null || true)"
[ -n "$PID" ] || fail "installed_but_unproven: $PID_FILE names no process, so the running binary could not be read back"
EXE="$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)"
[ -n "$EXE" ] || fail "installed_but_unproven: /proc/$PID/exe could not be read (pid $PID from $PID_FILE)"
EXPECTED="$(readlink -f "$INSTALL/wa" 2>/dev/null || printf '%s' "$INSTALL/wa")"
[ "$EXE" = "$EXPECTED" ] || fail "installed_but_unproven: pid $PID runs $EXE, and this install is $EXPECTED; the node is serving bytes this install does not hold"
say "running binary: pid $PID is $EXE"

# 2. THOSE BYTES NAME THIS COMMIT. A build that cannot answer --build-info is refused rather than
#    trusted: the install would otherwise record a commit nothing verified.
INFO="$("$INSTALL/wa" --build-info 2>/dev/null || true)"
[ -n "$INFO" ] || fail "installed_but_unproven: $INSTALL/wa --build-info answered nothing, so the installed build cannot name its own commit"
GOT="$(printf '%s\n' "$INFO" | sed -n 's/^commit=//p' | head -1)"
[ -n "$GOT" ] || fail "installed_but_unproven: --build-info carries no commit= line, so what was installed cannot be compared with $COMMIT"
# The bytes are SOURCE_COMMIT's: this commit's own release, or a cover whose embedded Lua the installer proved
# to be $COMMIT's (scripts/upgrade.sh, before it staged anything). Anything else is not what was asked for.
[ "$GOT" = "$SOURCE_COMMIT" ] || fail "installed_but_unproven: the installed build names commit=$GOT, this release is $SOURCE_COMMIT"
say "installed binary: --build-info commit=$GOT"
if [ "$SOURCE_COMMIT" != "$COMMIT" ]; then
  say "covered: $SHORT installed the bytes of $SOURCE_SHORT, whose embedded Lua tree is $COMMIT's (lua_inputs $LUA_INPUTS)"
fi
say "release install ok: $SHORT ($TRIPLE) on $INSTALL"
