#!/usr/bin/env bash
# lua-part-build: turn a Lua tree into THE PART, and print the lock line that pins it.
#
# WHY (Fable 25/11, lua-core-is-a-signed-part). Today the tree rides inside the host artifact, so a Lua-only landing
# costs a 55,570,056-byte download. The part is 1,654,295 bytes and the node fetches it only when its digest moves.
# This is the PRODUCER half: tar the tree with its manifest, name the file by its own digest, and print the line that
# goes into the lock - the same `name <sha256> <bytes>` shape components.lock already uses, plus interface=.
#
#   lua-part-build.sh --tree <dir> [--commit <sha>] [--interface <digest>] [--out <dir>]
#
# WHAT IT REFUSES, by name, rather than producing a part nobody can install:
#   lua_part_tree_missing        no such tree
#   lua_part_no_lua_core         the tree has no lua/core/init.lua (not a Lua tree)
#   lua_part_interface_unknown   no --interface and no `capabilities` line in an existing manifest
#
# The part it writes is EXACTLY what scripts/lib/lua-part.sh verifies: manifest.txt + the tree, tar.gz, and the lock
# line its own sha256/size. Producing and verifying are therefore the same contract, which is what
# scripts/test-lua-part.sh round-trips.
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true
. scripts/lib/lua-part.sh

say() { printf 'lua-part-build: %s\n' "$*"; }
die() { printf 'lua-part-build: %s\n' "$*" >&2; exit 2; }

TREE="" COMMIT="" INTERFACE="" OUT="."
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --interface) INTERFACE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) die "lua_part_build_usage: unknown argument $1" ;;
  esac
done
[ -d "$TREE" ] || die "lua_part_tree_missing: ${TREE:-<none>}"
[ -f "$TREE/lua/core/init.lua" ] || die "lua_part_no_lua_core: $TREE has no lua/core/init.lua"

# The interface the part will REQUIRE: the host that built it declares it, or the tree already carries one.
if [ -z "$INTERFACE" ] && [ -f "$TREE/manifest.txt" ]; then
  INTERFACE="$(sed -n 's/^capabilities //p' "$TREE/manifest.txt" | head -1 | tr -d '[:space:]')"
fi
[ -n "$INTERFACE" ] || die "lua_part_interface_unknown: pass --interface <host digest> (wa --interface) - a part that does not declare one cannot be checked"

# The tree manifest, written here so the part is self-describing: what it needs, which commit, and every file.
MANIFEST="$TREE/manifest.txt"
{
  printf 'capabilities %s\n' "$INTERFACE"
  printf 'commit %s\n' "${COMMIT:-unknown}"
  ( cd "$TREE" && find lua -type f | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s  %s\n' "$(sha256sum < "$path" | awk '{print $1}')" "$path"
    done )
} > "$MANIFEST" || die "lua_part_manifest_unwritable: $MANIFEST"

mkdir -p "$OUT" || die "lua_part_out_unwritable: $OUT"
RAW="$OUT/.lua-core-part.tar.gz"
# REPRODUCIBLE BYTES, and this line is why: a plain `tar czf` embeds every file's mtime and gzip embeds its own
# timestamp, so two builds of the SAME tree produced three different parts in a row (1746153, 1746155, 1746157
# bytes, three digests, measured 28/11 while pinning the part). A part whose bytes move cannot be pinned at all:
# the lock would name a file nobody can rebuild. So the archive is sorted, stamped at the epoch, owned by 0 and
# gzipped with -n (no name, no time).
( cd "$TREE" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu -cf - manifest.txt lua \
    | gzip -n -9 > "$RAW" ) || die "lua_part_tar_failed: $RAW"
SHA="$(sha256sum < "$RAW" | awk '{print $1}')"
BYTES="$(wc -c < "$RAW" | tr -d '[:space:]')"
FINAL="$OUT/lua-core-${SHA:0:12}.tar.gz"
mv -f "$RAW" "$FINAL" || die "lua_part_out_unwritable: $FINAL"

say "part $FINAL ($BYTES bytes, sha256 $SHA)"
# THE LOCK LINE, in components.lock's own shape. One line, printed so the caller appends it or diffs it.
printf 'lua-core %s %s interface=%s\n' "$SHA" "$BYTES" "$INTERFACE"

