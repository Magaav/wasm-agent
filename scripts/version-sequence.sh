#!/usr/bin/env bash
# version-sequence: the five steps a version-folder install runs, in ONE place that a row can drive.
#
# WHY IT IS A SCRIPT AND NOT A BLOCK IN deploy.sh. Fable requires a node-shape row through steps 1-5 - including a
# FAILED restart and a FAILED sentinel move - BEFORE the switch is ever turned on, and a block buried in deploy.sh
# can only be exercised by running a whole deploy against a real node. The same sequence, named here, is driven by
# the row on a scratch node and called by deploy.sh when WA_VERSION_FOLDERS=1: one implementation, so what the row
# proves is what the deploy runs.
#
#   version-sequence.sh --install <dir> --candidate <new wa> --commit <sha> --root <deploy tree>
#                       --upgrade <path to upgrade.sh> [--lua-stage <dir>] [--share <dir>]
#                       [--reason R] [--force-reason R] [--via NAME] [--sentinel-fail-expected]
#
# STEPS (each fails by name; nothing is skipped):
#   1 convert     scripts/versions-adopt.sh converts an in-place node ONCE and verifies it, rolling itself back
#                 on failure - the sequence stops there with the in-place install untouched.
#   2 stage       upgrade.sh with WA_VERSION_STAGING writes the program, itself and the record into the staging
#                 tree (no swap, no restart); lua-core, scripts and ui are REQUIRED - a version sealed without
#                 them would be incomplete while looking complete.
#   3 seal+point  scripts/version-install.sh seals the tree and moves the pointer BEFORE any restart.
#   4 restart     upgrade.sh runs again through the pointer: the installed program is already the new bytes, so it
#                 takes its own already-the-installed-one branch and restarts and verifies. If THAT fails, current
#                 is moved back by one rename (no copy, no reinstall) and the sequence says so.
#   5 sentinel    scripts/lib/sentinel-move.sh moves the sentinel LAST; a failed start leaves the PREVIOUS version
#                 supervising through a drop-in (or names that nothing is supervising).
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true
. scripts/lib/versions.sh
. scripts/lib/sentinel-move.sh

say() { printf 'version-sequence: %s\n' "$*"; }
die() { printf 'version-sequence: %s\n' "$*" >&2; exit 2; }

INSTALL="" CANDIDATE="" COMMIT="" ROOT="" UPGRADE="" LUA_STAGE="" SHARE="" LUA_PART="" LUA_LOCK=""
REASON="version folders" FORCE_REASON="" VIA="version-sequence" SENTINEL_FAIL_EXPECTED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL="${2:-}"; shift 2 ;;
    --candidate) CANDIDATE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --upgrade) UPGRADE="${2:-}"; shift 2 ;;
    --lua-stage) LUA_STAGE="${2:-}"; shift 2 ;;
    --share) SHARE="${2:-}"; shift 2 ;;
    --lua-part) LUA_PART="${2:-}"; shift 2 ;;
    --lua-lock) LUA_LOCK="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --force-reason) FORCE_REASON="${2:-}"; shift 2 ;;
    --via) VIA="${2:-}"; shift 2 ;;
    --sentinel-fail-expected) SENTINEL_FAIL_EXPECTED=1; shift ;;
    *) die "version_sequence_usage: unknown argument $1" ;;
  esac
done
[ -n "$SHARE" ] || SHARE="$(wa_share_root)"
[ -n "$INSTALL" ] && [ -d "$INSTALL" ] || die "version_sequence_install_missing: ${INSTALL:-<none>}"
[ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ] || die "version_sequence_candidate_missing: ${CANDIDATE:-<none>}"
[ -n "$COMMIT" ] || die "version_sequence_commit_missing"
[ -n "$UPGRADE" ] && [ -f "$UPGRADE" ] || die "version_sequence_upgrade_missing: ${UPGRADE:-<none>}"
export WA_SHARE_ROOT="$SHARE"
ID="$(wa_version_id "$COMMIT")" || exit 2
PREV="$(wa_version_current 2>/dev/null || true)"

# 1. CONVERT (the conversion is its own step, and it verifies).
say "SEQSTEP 1 convert"
bash "$(dirname "$0")/versions-adopt.sh" --install "$INSTALL" --share "$SHARE" \
  || die "version_folders_adopt_failed: the conversion failed; the in-place install is untouched"

# 2. STAGE.
say "SEQSTEP 2 stage"
[ -n "$SHARE" ] && [ -n "$ID" ] || die "version_folders_names: empty share root or version id"
STAGE="$SHARE/versions/.stage-$ID"
rm -rf "$STAGE"; mkdir -p "$STAGE" || die "version_folders_stage_unwritable: $STAGE"
WA_VERSION_STAGING="$STAGE" WA_UPGRADE_FORCE_REASON="$FORCE_REASON" \
  WA_INSTALL_DIR="$INSTALL" WA_UPGRADE_REASON="$REASON" WA_UPGRADE_VIA="$VIA" \
  bash "$UPGRADE" "$CANDIDATE" >> "$INSTALL/deploy-upgrade.log" 2>&1 \
  || die "version_folders_stage_failed: see $INSTALL/deploy-upgrade.log"
if [ -n "$LUA_PART" ]; then
  # THE LUA CORE ARRIVES AS A SIGNED PART (lua-core-is-a-signed-part): step 3 fills the member from it, checks the
  # interface against the staged program and verifies every file - so nothing is copied here and the member is
  # required all the same, by the part's own refusal if it is not good.
  [ -f "$LUA_PART" ] || die "version_folders_member_missing: lua-core part ($LUA_PART is not there)"
  [ -f "$LUA_LOCK" ] || die "version_folders_member_missing: lua-core lock (${LUA_LOCK:-<none>} is not there)"
  say "step 2 lua-core comes from the part $LUA_PART"
else
  [ -d "$LUA_STAGE" ] || die "version_folders_member_missing: lua-core (${LUA_STAGE:-<none>} is not there)"
  cp -a "$LUA_STAGE" "$STAGE/lua-core" || die "version_folders_member_failed: lua-core"
fi
[ -d "$ROOT/scripts" ] || die "version_folders_member_missing: scripts ($ROOT/scripts is not there)"
mkdir -p "$STAGE/scripts" && cp -a "$ROOT/scripts/." "$STAGE/scripts/" || die "version_folders_member_failed: scripts"
[ -d "$ROOT/ui" ] || die "version_folders_member_missing: ui ($ROOT/ui is not there)"
cp -a "$ROOT/ui" "$STAGE/ui" || die "version_folders_member_failed: ui"

# 3. SEAL AND POINT - before any restart.
say "SEQSTEP 3 seal and point"
if [ -n "$LUA_PART" ]; then
  bash "$(dirname "$0")/version-install.sh" --staging "$STAGE" --commit "$COMMIT" --install "$INSTALL" \
    --lua-part "$LUA_PART" --lua-lock "$LUA_LOCK" \
    || die "version_folders_seal_failed: the staged version could not be sealed or pointed at (lua part)"
else
bash "$(dirname "$0")/version-install.sh" --staging "$STAGE" --commit "$COMMIT" --install "$INSTALL" \
  || die "version_folders_seal_failed: the staged version could not be sealed or pointed at"
fi

# 4. RESTART through the pointer; a failed restart moves the pointer BACK by one rename.
say "SEQSTEP 4 restart through the pointer"
if ! WA_UPGRADE_FORCE_REASON="$FORCE_REASON" WA_INSTALL_DIR="$INSTALL" WA_UPGRADE_REASON="$REASON" \
     WA_UPGRADE_VIA="$VIA" bash "$UPGRADE" "$CANDIDATE" >> "$INSTALL/deploy-upgrade.log" 2>&1; then
  if [ -n "$PREV" ]; then
    if wa_version_point "$PREV" >/dev/null; then
      say "version_folders_restart_failed: current is back on $PREV (one rename, no reinstall); the new version $ID is sealed and kept"
    else
      say "version_folders_restart_failed_pointer: the restart failed AND the pointer could not be moved back to $PREV"
    fi
  else
    say "version_folders_restart_failed: no previous version to move back to (first install)"
  fi
  exit 3
fi

# 5. THE SENTINEL MOVES LAST.
say "SEQSTEP 5 sentinel move"
if [ -n "$PREV" ]; then
  WA_SENTINEL_NODE_HEALTHY=1 wa_sentinel_move "$INSTALL" "$SHARE/versions/$PREV" || {
    rc=$?
    if [ "$SENTINEL_FAIL_EXPECTED" = 1 ] && { [ "$rc" = 3 ] || [ "$rc" = 4 ]; }; then
      say "sentinel_move_failed_as_expected: rc=$rc (the previous version keeps supervising, or nothing is supervising and it is named)"
      exit 0
    fi
    say "version_folders_sentinel_failed: rc=$rc (the node is on $ID; see the sentinel line above)"
    exit 4
  }
fi
say "version_folders_ok: current -> $ID (previous ${PREV:-none})"
exit 0

