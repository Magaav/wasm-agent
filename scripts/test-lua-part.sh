#!/usr/bin/env bash
# THE LUA CORE AS A PART (Fable 25/11): the lock line, the verifier, and the interface - refused BY NAME.
#
# What it pins, each a named failure:
#   R1  a good part verifies against the lock (size, then sha256) and unpacks with every file checked against the
#       tree's own manifest; a truncated file is lua_part_size_mismatch, a flipped byte is lua_part_digest_mismatch,
#       a good digest with a bad member is lua_part_file_mismatch, an unpinned part is lua_part_not_pinned;
#   R3  the interface is declared as data (the lock's interface= and the manifest's capabilities line) and a
#       mismatch is refused BY NAME with BOTH digests - a part built for another host, in either direction;
#   R4  a path that escapes the destination is refused (a tarball is untrusted input).
#
# It builds its own parts from a fixture tree under /tmp and touches nothing else: no install, no pointer, no
# network. Milliseconds, as the brief asks.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/lua-part.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-lua-part: $*" >&2; exit 1; }

BASE="${TMPDIR:-/tmp}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-luapart-XXXXXX")" || { echo "FAIL test-lua-part: no scratch" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

HOST_INT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_INT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

build_tree() { # <dir> <interface>
  local dir="$1" int="$2"
  mkdir -p "$dir/lua/core"
  printf -- '-- init for %s\nreturn {}\n' "$int" > "$dir/lua/core/init.lua"
  printf 'vendored\n' > "$dir/lua/core/vendor.lua"
  { printf 'capabilities %s\n' "$int"
    printf 'commit deadbeefcafe\n'
    printf '%s  lua/core/init.lua\n' "$(sha256sum < "$dir/lua/core/init.lua" | awk '{print $1}')"
    printf '%s  lua/core/vendor.lua\n' "$(sha256sum < "$dir/lua/core/vendor.lua" | awk '{print $1}')"
  } > "$dir/manifest.txt"
}

part_from() { # <tree dir> <out file>
  ( cd "$1" && tar czf "$2" manifest.txt lua )
}

lock_line() { # <lock> <part file> <interface>
  local lock="$1" part="$2" int="$3" sha bytes filler
  sha="$(sha256sum < "$part" | awk '{print $1}')"
  bytes="$(wc -c < "$part" | tr -d '[:space:]')"
  filler="$(printf 'f%.0s' $(seq 1 64))"
  { printf 'compat 1\n'
    printf '# a comment line, as components.lock has\n'
    printf 'lua-core %s %s interface=%s\n' "$sha" "$bytes" "$int"
    printf 'agent-core %s 392561\n' "$filler"
  } > "$lock"
}

T1="$W/tree1"; build_tree "$T1" "$HOST_INT"; P1="$W/lua-core-1.tar.gz"; part_from "$T1" "$P1"
LOCK="$W/components.lock"; lock_line "$LOCK" "$P1" "$HOST_INT"

# R1: the good part
wa_lua_part_verify_file "$P1" "$LOCK" || fail "R1: a good part must verify"
ok
[ "$(wa_lua_part_lock_value "$LOCK" lua-core sha256)" = "$(sha256sum < "$P1" | awk '{print $1}')" ] || fail "R1: the lock's sha256 is not the part's"
[ "$(wa_lua_part_lock_value "$LOCK" lua-core interface)" = "$HOST_INT" ] || fail "R1: the lock's interface is not the part's"
ok
dest="$W/dest1"; wa_lua_part_unpack "$P1" "$LOCK" "$dest" || fail "R1: unpacking a good part"
[ -f "$dest/lua/core/init.lua" ] || fail "R1: the unpacked tree is not where it belongs"
ok

# R1: a truncated file is refused by SIZE, before hashing
head -c 40 "$P1" > "$W/trunc.tar.gz"
wa_lua_part_verify_file "$W/trunc.tar.gz" "$LOCK" 2> "$W/e1" && fail "R1: a truncated part must be refused"
grep -q 'lua_part_size_mismatch' "$W/e1" || { sed -n 1,2p "$W/e1" >&2; fail "R1: the size refusal is not named"; }
ok

# R1: a flipped byte is refused by DIGEST
cp "$P1" "$W/flipped.tar.gz"; printf 'x' | dd of="$W/flipped.tar.gz" bs=1 seek=60 conv=notrunc 2>/dev/null
lock_line "$LOCK" "$W/flipped.tar.gz" "$HOST_INT"      # pin the good bytes, then hand over the flipped file
part_from "$T1" "$W/again.tar.gz"; lock_line "$LOCK" "$W/again.tar.gz" "$HOST_INT"
wa_lua_part_verify_file "$W/flipped.tar.gz" "$LOCK" 2> "$W/e2" && fail "R1: a flipped byte must be refused"
grep -q 'lua_part_digest_mismatch' "$W/e2" || { sed -n 1,2p "$W/e2" >&2; fail "R1: the digest refusal is not named"; }
ok

# R1: a good digest with a bad member is refused by the MANIFEST
T2="$W/tree2"; build_tree "$T2" "$HOST_INT"; printf 'tampered\n' > "$T2/lua/core/vendor.lua"
P2="$W/lua-core-2.tar.gz"; part_from "$T2" "$P2"; lock_line "$LOCK" "$P2" "$HOST_INT"
wa_lua_part_unpack "$P2" "$LOCK" "$W/dest2" 2> "$W/e3" && fail "R1: a member that is not its manifest's bytes must be refused"
grep -q 'lua_part_file_mismatch' "$W/e3" || { sed -n 1,3p "$W/e3" >&2; fail "R1: the member refusal is not named"; }
ok

# R1: unpinned
printf 'compat 1\n' > "$W/empty.lock"
wa_lua_part_verify_file "$P1" "$W/empty.lock" 2> "$W/e4" && fail "R1: an unpinned part must be refused"
grep -q 'lua_part_not_pinned' "$W/e4" || fail "R1: the unpinned refusal is not named"
ok

# R3: the interface, both directions, by name
lock_line "$LOCK" "$P1" "$HOST_INT"
wa_lua_part_interface "$W/dest1" "$HOST_INT" || fail "R3: a matching interface must pass"
ok
wa_lua_part_interface "$W/dest1" "$OTHER_INT" 2> "$W/e5" && fail "R3: a part built for another host must be refused"
grep -q "lua_part_interface_mismatch: part needs $HOST_INT, host offers $OTHER_INT" "$W/e5" || { sed -n 1,2p "$W/e5" >&2; fail "R3: the mismatch does not name BOTH digests"; }
ok

# R4: a path that escapes the destination
esc="$W/esc"; mkdir -p "$esc/lua/core"; printf 'x\n' > "$esc/lua/core/init.lua"
{ printf 'capabilities %s\n' "$HOST_INT"; printf 'commit x\n'; printf '%s  ../escape.lua\n' "$(printf 'a%.0s' $(seq 1 64))"; } > "$esc/manifest.txt"
( cd "$esc" && tar czf "$W/esc.tar.gz" manifest.txt lua )
lock_line "$LOCK" "$W/esc.tar.gz" "$HOST_INT"
wa_lua_part_unpack "$W/esc.tar.gz" "$LOCK" "$W/dest3" 2> "$W/e6" && fail "R4: a path escaping the destination must be refused"
grep -q 'lua_part_unsafe_path' "$W/e6" || { sed -n 1,3p "$W/e6" >&2; fail "R4: the unsafe-path refusal is not named"; }
ok

echo "lua part ok ($n checks)"

