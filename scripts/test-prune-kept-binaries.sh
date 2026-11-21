#!/usr/bin/env bash
# scripts/prune-kept-binaries.sh on a SCRATCH install directory (never ~/.local/bin): the dry run changes
# nothing, --apply keeps the newest 3 by mtime, and the live rollback copies are never candidates.
set -uo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-prune-kept-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
checks=0
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
check() { local name="$1"; shift; "$@" || fail "$name"; checks=$((checks + 1)); }
case "$WORK" in "$HOME/.local/bin"*) fail "the scratch directory is the real install" ;; esac
I="$WORK/bin"; mkdir -p "$I/rollback" "$I/lua-core.prev"
printf 'live\n' > "$I/wa"; printf 'backup\n' > "$I/wa.pre-upgrade"; printf 'pair\n' > "$I/rollback/wa"
age=100
for name in wa.prev-20261116T155246Z wa.prev-20261116T190640Z wa.prev.20261117T101818Z wa.prev.20261118T003151Z wa.pre-442291404f43 wa.pre-ac7717e0f7b2; do
  printf '%s\n' "$name" > "$I/$name"; touch -d "@$((1790000000 + age))" "$I/$name"; age=$((age + 100))
done
ln -s "$I/wa" "$I/wa.prev-link"
before="$(ls -1 "$I" | sort)"
out="$(bash "$HERE/scripts/prune-kept-binaries.sh" --install "$I")" || fail "the dry run exits 0"
check "the dry run changes nothing" [ "$(ls -1 "$I" | sort)" = "$before" ]
check "the dry run names what it would remove" grep -q "would remove $I/wa.prev-20261116T155246Z" <<<"$out"
check "the dry run says nothing was changed" grep -q "dry run - kept 3, would remove 3" <<<"$out"
out="$(bash "$HERE/scripts/prune-kept-binaries.sh" --install "$I" --apply)" || fail "--apply exits 0"
check "the three newest are kept" [ -f "$I/wa.pre-ac7717e0f7b2" -a -f "$I/wa.pre-442291404f43" -a -f "$I/wa.prev.20261118T003151Z" ]
check "the three oldest are gone" [ ! -e "$I/wa.prev-20261116T155246Z" -a ! -e "$I/wa.prev-20261116T190640Z" -a ! -e "$I/wa.prev.20261117T101818Z" ]
check "the installed binary is untouched" [ "$(cat "$I/wa")" = live ]
check "the upgrade's backup is never a candidate" [ "$(cat "$I/wa.pre-upgrade")" = backup ]
check "the rollback pair is untouched" [ "$(cat "$I/rollback/wa")" = pair ]
check "a symlink is never removed" [ -L "$I/wa.prev-link" ]
check "the summary counts" grep -q "kept 3, removed 3" <<<"$out"
out="$(bash "$HERE/scripts/prune-kept-binaries.sh" --install "$I" --apply)"
check "a second run removes nothing" grep -q "kept 3, removed 0" <<<"$out"
bash "$HERE/scripts/prune-kept-binaries.sh" --install "$I" --keep x >/dev/null 2>&1; check "a keep that is not a number is refused" [ "$?" = 2 ]
bash "$HERE/scripts/prune-kept-binaries.sh" --bogus >/dev/null 2>&1; check "an unknown option is refused" [ "$?" = 2 ]
echo "prune-kept-binaries ok ($checks checks)"
