#!/usr/bin/env bash
# Keep the newest N hand-kept copies of the installed binary (`wa.prev-*`, `wa.prev.*`, `wa.pre-<sha>`)
# and remove the older ones.
#
# WHY. Measured 21/11 on the laptop: ~/.local/bin held 22 such copies (50-76 MB each, 16-19/11), written by
# the hand install recipe of those days. Nothing in this tree writes or reads them any more: a rollback
# restores <install>/rollback/ (scripts/rollback-node.sh), and the upgrade's own backup is `wa.pre-upgrade`.
# So they are disk and nothing else - but they are an operator's files, so the DEFAULT IS A DRY RUN and a
# removal needs --apply.
#
# NEVER TOUCHED, whatever the flags: `wa` itself, `wa.pre-upgrade` (upgrade.sh restores from it),
# rollback/ and .prev/ (what rollback-node.sh restores), lua-core*, anything that is not a regular file,
# and any copy that IS the installed binary (same inode).
#
#   bash scripts/prune-kept-binaries.sh                     # dry run on ~/.local/bin, keep 3
#   bash scripts/prune-kept-binaries.sh --apply             # remove them
#   bash scripts/prune-kept-binaries.sh --install DIR --keep N [--apply]
#
# Exit codes: 0 done (or nothing to do); 2 usage.
set -uo pipefail
INSTALL="${WA_INSTALL_DIR:-$HOME/.local/bin}"
KEEP=3
APPLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) [ "$#" -ge 2 ] || { echo 'prune-kept-binaries: refused(install_value_required)' >&2; exit 2; }; INSTALL="$2"; shift 2 ;;
    --keep) [ "$#" -ge 2 ] || { echo 'prune-kept-binaries: refused(keep_value_required)' >&2; exit 2; }; KEEP="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    *) echo "prune-kept-binaries: refused(unknown_option): $1 (the options are --install DIR, --keep N, --apply, --dry-run)" >&2; exit 2 ;;
  esac
done
case "$KEEP" in ''|*[!0-9]*) echo "prune-kept-binaries: refused(keep_not_a_number): --keep $KEEP" >&2; exit 2 ;; esac
[ -d "$INSTALL" ] || { echo "prune-kept-binaries: refused(install_missing): $INSTALL is not a directory" >&2; exit 2; }

# Newest first, by modification time. The names are this script's own three globs and nothing else.
mapfile -t found < <(
  for file in "$INSTALL"/wa.prev-* "$INSTALL"/wa.prev.* "$INSTALL"/wa.pre-*; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [ "$(basename "$file")" = "wa.pre-upgrade" ] && continue
    [ -e "$INSTALL/wa" ] && [ "$file" -ef "$INSTALL/wa" ] && continue
    printf '%s\t%s\t%s\n' "$(stat -c %Y "$file")" "$(stat -c %s "$file")" "$file"
  done | sort -t "$(printf '\t')" -k1,1nr -k3,3r
)
kept=0; removed=0; bytes=0
for row in "${found[@]}"; do
  size="$(printf '%s' "$row" | cut -f2)"; file="$(printf '%s' "$row" | cut -f3-)"
  if [ "$kept" -lt "$KEEP" ]; then
    kept=$((kept + 1)); echo "prune-kept-binaries: keep   $file"
    continue
  fi
  if [ "$APPLY" = 1 ]; then
    rm -f -- "$file" || { echo "prune-kept-binaries: could not remove $file" >&2; continue; }
    echo "prune-kept-binaries: removed $file ($((size / 1048576)) MB)"
  else
    echo "prune-kept-binaries: would remove $file ($((size / 1048576)) MB)"
  fi
  removed=$((removed + 1)); bytes=$((bytes + size))
done
if [ "$APPLY" = 1 ]; then
  echo "prune-kept-binaries: kept $kept, removed $removed ($((bytes / 1048576)) MB) in $INSTALL"
else
  echo "prune-kept-binaries: dry run - kept $kept, would remove $removed ($((bytes / 1048576)) MB) in $INSTALL; nothing was changed (--apply removes them)"
fi
