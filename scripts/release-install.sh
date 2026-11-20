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
#   bash scripts/release-install.sh <40-hex commit>
#
# Exit codes: 0 installed and verified; 2 a named refusal (nothing staged); 3 installed but the
# verification after the swap disagreed (upgrade.sh's own rollback is what put the old bytes back).
set -uo pipefail

say() { printf '  %s\n' "$*"; }
fail() { printf 'release_install: %s\n' "$*" >&2; exit 2; }

COMMIT="${1:-}"
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

UPGRADE="$INSTALL/scripts/upgrade.sh"
[ -f "$UPGRADE" ] || fail "upgrade_script_missing: $UPGRADE is not installed, so nothing can stage or prove a new binary safely"

TRIPLE="$(wa_node_target_triple 2>/dev/null)" || fail "release_target_unknown: this host is not one of the published targets ($(uname -s 2>/dev/null)/$(uname -m 2>/dev/null))"
REPO="$(wa_node_release_repo "$INSTALL" 2>/dev/null)" || REPO=""
[ -n "$REPO" ] || fail "release_repo_unknown: no owner/repo for the node release (set WA_NODE_RELEASE_REPO)"
CACHE="$(wa_node_cache_root "$INSTALL")"
SHORT="${COMMIT:0:12}"

say "fetching node-$SHORT for $TRIPLE into $CACHE (manifest, signature and every pin verified)"
DIR="$(wa_node_binary_download "$REPO" "$COMMIT" "$TRIPLE" "$CACHE" 2>&1)" || {
  RC=$?
  fail "release_download_failed($RC): $DIR"
}
[ -d "$DIR" ] || fail "release_download_failed: wa_node_binary_download printed no directory"
CANDIDATE="$DIR/wa-$TRIPLE-$SHORT"
[ -f "$CANDIDATE" ] || fail "release_binary_missing: $CANDIDATE is not in the verified release directory"
[ -f "$DIR/SHA256SUMS" ] || fail "release_sums_missing: $DIR carries no SHA256SUMS, so upgrade.sh cannot verify the candidate"

say "upgrading: bash scripts/upgrade.sh $CANDIDATE --release $DIR"
if ! bash "$UPGRADE" "$CANDIDATE" --release "$DIR"; then
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
[ "$GOT" = "$COMMIT" ] || fail "installed_but_unproven: the installed build names commit=$GOT, this release is $COMMIT"
say "installed binary: --build-info commit=$GOT"
say "release install ok: $SHORT ($TRIPLE) on $INSTALL"
