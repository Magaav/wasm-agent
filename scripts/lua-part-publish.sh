#!/usr/bin/env bash
# lua-part-publish: produce THE PART as a node would receive it - the tarball, its SHA256SUMS, and the signature
# over those sums - and print the lock line that pins it.
#
# WHY (lua-core-is-a-signed-part slice 2, the publish half, DARK): scripts/lua-part-build.sh makes the bytes and
# scripts/lib/lua-part.sh judges them, but nothing produced the SIBLING FILES a node actually fetches. A part with no
# SHA256SUMS and no .sig is `lua_part_unsigned` at install, so a publisher that forgets them ships something no node
# can install - the same shape of silence as a pin with no artifact behind it (q#119) and a row nobody runs.
#
#   lua-part-publish.sh --tree <lua-tree-or-checkout> --interface <digest> [--commit <sha>] [--out <dir>]
#
# It writes <out>/lua-core-<sha12>.tar.gz, <out>/SHA256SUMS, <out>/SHA256SUMS.sig and prints the lock line. It
# installs nothing, moves no pointer and reads no node state: the release script decides where the files go, and the
# switch (slice 2, after the read) is what consumes them.
#
# Signing is the repository's own fixture signer for now (scripts/lib/release-fixture-sign.py), because the vault key
# is not on a worker node; the release path swaps in the real signer without changing this contract - the file is
# judged by `wa release verify`, not by who wrote it.
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true

say() { printf 'lua-part-publish: %s\n' "$*"; }
die() { printf 'lua-part-publish: %s\n' "$*" >&2; exit 2; }

TREE="" INTERFACE="" COMMIT="" OUT="."
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="${2:-}"; shift 2 ;;
    --interface) INTERFACE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) die "lua_part_publish_usage: unknown argument $1" ;;
  esac
done
[ -n "$TREE" ] || die 'lua_part_tree_missing: --tree <dir>'
[ -n "$INTERFACE" ] || die 'lua_part_interface_unknown: --interface <the digest wa --interface prints>'
[ -d "$TREE" ] || die "lua_part_tree_missing: $TREE"

mkdir -p "$OUT" || die "lua_part_out_unwritable: $OUT"
# The build wants a tree that holds lua/ at its root; a checkout does not, so stage it the same way the pin row does.
stage="$OUT/.tree.$$"
rm -rf "$stage"; mkdir -p "$stage"
if [ -d "$TREE/lua" ]; then cp -a "$TREE/lua" "$stage/"; else die "lua_part_no_lua_core: $TREE has no lua/"; fi
[ -f "$TREE/manifest.txt" ] && cp -a "$TREE/manifest.txt" "$stage/"

line=$(bash scripts/lua-part-build.sh --tree "$stage" --commit "${COMMIT:-unknown}" --interface "$INTERFACE" --out "$OUT" 2>&1)
rc=$?
rm -rf "$stage"
[ $rc -eq 0 ] || { printf '%s\n' "$line" >&2; die 'lua_part_build_failed'; }
printf '%s\n' "$line" | tail -1

part=$(ls "$OUT"/lua-core-*.tar.gz 2>/dev/null | head -1)
[ -n "$part" ] || die 'lua_part_missing: the build wrote no part'

# SHA256SUMS names the FILE, as `wa release verify` expects (sha256, two spaces, the bare name).
( cd "$OUT" && sha256sum "$(basename "$part")" > SHA256SUMS ) || die 'lua_part_sums_unwritable'
say "sums $(cat "$OUT/SHA256SUMS")"

WA_RELEASE_KEYS="${WA_RELEASE_KEYS:-$PWD/tests/fixtures/release-sign/keys.txt}" \
  python3 scripts/lib/release-fixture-sign.py "$OUT" >/dev/null 2>&1 || die 'lua_part_sign_failed: no signer (set WA_RELEASE_KEYS to the vault keys file)'
[ -f "$OUT/SHA256SUMS.sig" ] || die 'lua_part_unsigned: the signer wrote no SHA256SUMS.sig'
say "signed $(basename "$part"): SHA256SUMS + SHA256SUMS.sig beside it"
