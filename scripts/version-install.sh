#!/usr/bin/env bash
# version-install: put a staged install into a version folder and make it current, in steps that each survive a cut.
#
# WHY. Slice (b) (Fable 24/11, docs/UPDATE-DESIGN.md section 2.0) replaces "overwrite ~/.local/bin in place"
# with "a complete, immutable version folder + one pointer". The deploy already stages the members it is about
# to install (program, sentinel, lua tree, scripts, ui, the record); this script is the ONE place that turns a
# staged tree into a version, and it is deliberately a sequence of numbered steps so a kill at any boundary
# leaves a node that starts, answers and can be installed again (requirement 5, row R3).
#
#   version-install.sh --staging <dir> --commit <sha> [--binary-commit <sha>] [--install <dir>]
#                      [--share <root>] [--keep 3]
#
# STEPS (each idempotent; a rerun after a cut continues instead of starting over):
#   1  arguments and id
#   2  the disk is asked BEFORE anything is written (version_no_room names free/need/margin)
#   3  the version folder already there and complete -> skip to 5 (a cut after the rename)
#   4  assemble versions/<id> from the staging tree: unchanged members are HARD LINKS to the previous
#      version, the rest copied, the tree sealed read-only, ONE rename into place
#   5  point current at it: ONE rename over the link
#   6  installed.txt becomes a LINK to current's own record (never a second file written at switch time)
#   7  the legacy paths (wa, wa-sentinel, lua-core, scripts, ui) become links THROUGH the pointer, with the
#      real path renamed aside first (the order that leaves a working node if the cut lands between them)
#   8  retention: N=3, never current, the one before it, a live process's version, or a pinned one
#   9  the summary line
#
# WA_VERSION_KILL_AFTER_STEP=<n> kills this process (SIGKILL, no cleanup) after step n finished: that is how
# the row drives a cut at every boundary instead of trusting a comment.
#
# Windows: not here (the in-place install stays there, requirement 9).
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true
. scripts/lib/versions.sh

say() { printf 'version-install: %s\n' "$*"; }
die() { printf 'version-install: %s\n' "$*" >&2; exit 2; }

STEP=0
step_done() {
  STEP=$1
  [ -z "${WA_VERSION_KILL_AFTER_STEP:-}" ] || [ "${WA_VERSION_KILL_AFTER_STEP}" != "$1" ] || {
    say "step $1 done; WA_VERSION_KILL_AFTER_STEP asked for a cut here"
    kill -9 $$
  }
}

STAGING="" COMMIT="" BINARY_COMMIT="" INSTALL="" SHARE="" KEEP="${WA_VERSION_KEEP:-3}"
while [ $# -gt 0 ]; do
  case "$1" in
    --staging) STAGING="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --binary-commit) BINARY_COMMIT="${2:-}"; shift 2 ;;
    --install) INSTALL="${2:-}"; shift 2 ;;
    --share) SHARE="${2:-}"; shift 2 ;;
    --keep) KEEP="${2:-}"; shift 2 ;;
    *) die "version_install_usage: unknown argument $1" ;;
  esac
done
[ -z "$SHARE" ] || export WA_SHARE_ROOT="$SHARE"

# 1. Arguments and id.
[ -n "$STAGING" ] || die "version_install_usage: --staging is required"
[ -d "$STAGING" ] || die "version_staging_missing: $STAGING"
ID="$(wa_version_id "$COMMIT")" || exit 2
[ -n "$INSTALL" ] || INSTALL="$(pwd)"
[ -d "$INSTALL" ] || die "version_install_dir_missing: $INSTALL"
step_done 1

# 2. The disk, before anything is written.
PREV="$(wa_version_current 2>/dev/null || true)"
PREV_DIR=""
[ -z "$PREV" ] || PREV_DIR="$(wa_version_dir "$PREV")"
NEED="$(wa_version_need_bytes "$STAGING" "$PREV_DIR")" || exit 2
wa_version_refuse_no_room "$NEED" || exit 3
step_done 2

# 3. Already assembled by an earlier run (a cut after step 4): keep it, it is immutable.
VERSION_DIR="$(wa_version_dir "$ID")"
if [ -f "$VERSION_DIR/version.txt" ]; then
  say "version $ID is already assembled; continuing from step 5"
  step_done 3
else
  step_done 3
  # 4. Assemble it.
  WA_VERSION_COMMIT="${COMMIT}" WA_VERSION_BINARY_COMMIT="${BINARY_COMMIT:-}" WA_VERSION_INSTALL_DIR="$INSTALL" \
    wa_version_assemble "$STAGING" "$ID" "$PREV_DIR" >/dev/null || die "version_assembled_failed: $ID"
  say "assembled $ID ($(wa_version_disk "$ID" | sed 's/^version_disk [^ ]* //'))"
fi
step_done 4

# 5. The pointer.
wa_version_point "$ID" >/dev/null || die "version_pointer_failed: $ID"
step_done 5

# 6. The record IS the pointer's own file.
if [ -f "$(wa_current_link)/installed.txt" ]; then
  wa_version_link_record "$INSTALL" >/dev/null || die "version_record_failed: $INSTALL/installed.txt"
else
  say "no installed.txt inside version $ID (a caller that did not stage a record); the pointer still names it"
fi
step_done 6

# 7. Today's paths through the pointer.
wa_version_link_legacy "$INSTALL" >/dev/null || die "version_legacy_failed: $INSTALL"
step_done 7

# 8. Retention, after the install that made this version current.
wa_version_prune "$KEEP" | sed 's/^/version-install: /'
step_done 8

# 9.
say "current -> $ID (step $STEP)"

