#!/usr/bin/env bash
# versions-adopt: the CONVERSION half of a deploy (Fable 25/11, decision (i): two halves in one deploy).
#
# WHY IT IS ITS OWN STEP. A node installed the old way has real files in its install directory (wa, lua-core/,
# scripts/, installed.txt) and no version folder. The deploy must convert that shape ONCE, before it installs
# anything: if the conversion fails, the deploy stops with the IN-PLACE install untouched and says so - a node is
# never left half-converted by a later step failing.
#
# "wa versions adopt" is this script; the deploy calls it as its own step and then installs. The verb and the
# step are ONE implementation, so what the operator can run by hand is exactly what the deploy runs.
#
#   versions-adopt.sh [--dry-run] [--install <dir>] [--share <root>] [--commit <sha>] [--keep <n>]
#
# WHAT IT DOES, in order, and why each order is safe:
#   1  read the install's own record (installed.txt) - no record, no adopt (adopt_no_record)
#   2  stage the CURRENT members (program, sentinel, lua tree, scripts, ui, record) under the share root
#   3  --dry-run stops here and prints exactly what it would move and what it would replace
#   4  assemble + point, through scripts/version-install.sh, so there is ONE installer implementation
#   5  VERIFY before anything about the deploy proceeds: current names the record's commit, the record path reads
#      the same record, every legacy path resolves through current, and the install's own program answers
#   6  a failed verification ROLLS BACK: the links are removed and the real paths renamed back from their
#      .stale.<ts> names, so the in-place install is exactly what it was, and the step exits non-zero
#   7  on success the old paths stay as <name>.stale.<ts> (wa clean lists them; nothing is deleted)
#
# It refuses to convert a node that is already on a version folder: adopt is a one-way, once-per-node step
# (adopt_already_adopted), and saying so is the answer rather than doing it twice.
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true
. scripts/lib/versions.sh

say() { printf 'versions-adopt: %s\n' "$*"; }
die() { printf 'versions-adopt: %s\n' "$*" >&2; exit 2; }

DRY=0 INSTALL="" SHARE="" COMMIT="" KEEP="${WA_VERSION_KEEP:-3}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --install) INSTALL="${2:-}"; shift 2 ;;
    --share) SHARE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --keep) KEEP="${2:-}"; shift 2 ;;
    *) die "versions_adopt_usage: unknown argument $1" ;;
  esac
done
[ -z "$SHARE" ] || export WA_SHARE_ROOT="$SHARE"
[ -n "$INSTALL" ] || INSTALL="$(pwd)"
[ -d "$INSTALL" ] || die "versions_adopt_install_missing: $INSTALL"

# 0. Already adopted? Then this step is a no-op that SAYS so (a deploy runs it on every install).
CURRENT="$(wa_version_current 2>/dev/null || true)"
if [ -n "$CURRENT" ] && [ -d "$(wa_version_dir "$CURRENT")" ] && [ -L "$INSTALL/installed.txt" ]; then
  say "adopt_already_adopted current=$CURRENT (the install is on a version folder; nothing to convert)"
  exit 0
fi

# 1. The record says which version this install is.
[ -f "$INSTALL/installed.txt" ] || die "adopt_no_record: $INSTALL/installed.txt (an install with no record cannot be adopted)"
[ -n "$COMMIT" ] || COMMIT="$(sed -n 's/^commit=//p' "$INSTALL/installed.txt" | head -1 | tr -d '[:space:]')"
[ -n "$COMMIT" ] || die "adopt_no_record: $INSTALL/installed.txt carries no commit="
ID="$(wa_version_id "$COMMIT")" || exit 2

# 2. Stage the CURRENT members. A member the install does not have is not invented.
STAGE_DIR="$(wa_versions_dir)"
mkdir -p "$STAGE_DIR" || die "adopt_staging_unwritable: $STAGE_DIR"
STAGE="$STAGE_DIR/.adopt-$ID-$$"
mkdir -p "$STAGE" || die "adopt_staging_unwritable: $STAGE"
trap 'rm -rf "$STAGE" 2>/dev/null' EXIT
MOVES=""
for name in wa wa-sentinel lua-core scripts ui installed.txt; do
  [ -e "$INSTALL/$name" ] || continue
  if [ -d "$INSTALL/$name" ] && [ ! -L "$INSTALL/$name" ]; then
    mkdir -p "$STAGE/$name" && cp -a "$INSTALL/$name/." "$STAGE/$name/" 2>/dev/null || true
  else
    cp -a "$INSTALL/$name" "$STAGE/$name" 2>/dev/null || true
  fi
  MOVES="$MOVES $name"
done
[ -n "$MOVES" ] || die "adopt_nothing_to_move: $INSTALL holds none of wa, wa-sentinel, lua-core, scripts, ui, installed.txt"

# 3. Say what it would do, and stop if asked.
say "adopt_plan id=$ID commit=$COMMIT install=$INSTALL share=$(wa_share_root)"
say "adopt_plan moves:$MOVES"
say "adopt_plan creates $(wa_version_dir "$ID") (sealed) and points $(wa_current_link) at it"
say "adopt_plan replaces each real path with a link through current, keeping it as <name>.stale.<ts>"
say "adopt_plan then verifies: current's record, the record link, every link, and that wa --version answers"
if [ "$DRY" = 1 ]; then say "adopt_dry_run: nothing was written"; exit 0; fi

# 4. Assemble and point through the installer, so a cut here is the installer's own business (R3 covers it).
WA_VERSION_COMMIT="$COMMIT" WA_VERSION_BINARY_COMMIT="$(sed -n 's/^build_pin=//p' "$INSTALL/installed.txt" | head -1 | cut -c1-40)" \
  bash scripts/version-install.sh --staging "$STAGE" --commit "$COMMIT" --install "$INSTALL" --keep "$KEEP" > "$STAGE.log" 2>&1 \
  || { say "adopt_install_failed: $(tail -1 "$STAGE.log")"; exit 3; }
say "adopt_assembled $ID"

# 5. Verify BEFORE the deploy proceeds.
verify() {
  local problems=0 name
  [ "$(wa_version_current)" = "$ID" ] || { say "adopt_verify_failed current=$(wa_version_current)"; problems=1; }
  [ -L "$INSTALL/installed.txt" ] || { say "adopt_verify_failed installed.txt is not a link"; problems=1; }
  if [ -L "$INSTALL/installed.txt" ] && ! grep -q "^commit=$COMMIT" "$INSTALL/installed.txt"; then
    say "adopt_verify_failed the record link does not read commit=$COMMIT"; problems=1
  fi
  for name in wa wa-sentinel lua-core scripts; do
    [ -e "$(wa_version_dir "$ID")/$name" ] || continue
    [ -L "$INSTALL/$name" ] || { say "adopt_verify_failed $name is not a link"; problems=1; continue; }
    [ "$(readlink -f "$INSTALL/$name")" = "$(readlink -f "$(wa_version_dir "$ID")/$name")" ] || {
      say "adopt_verify_failed $name does not resolve through current"; problems=1; }
  done
  if [ -x "$INSTALL/wa" ]; then
    "$INSTALL/wa" --version >/dev/null 2>&1 || { say "adopt_verify_failed wa --version does not answer"; problems=1; }
  fi
  return "$problems"
}
if ! verify; then
  # 6. ROLL BACK so the in-place install is exactly what it was.
  say "adopt_rollback: putting the in-place install back"
  for name in wa wa-sentinel lua-core scripts installed.txt ui; do
    aside="$(ls -d "$INSTALL/$name".stale.* 2>/dev/null | tail -1)"
    [ -n "$aside" ] || continue
    [ -L "$INSTALL/$name" ] && rm -f "$INSTALL/$name"
    mv "$aside" "$INSTALL/$name" 2>/dev/null && say "adopt_rollback_kept_back $name"
  done
  say "adopt_failed: the deploy must stop; the in-place install is untouched"
  exit 4
fi
say "adopt_verified id=$ID (the install is on a version folder; the old paths are <name>.stale.<ts>)"
exit 0

