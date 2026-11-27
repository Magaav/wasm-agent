#!/usr/bin/env bash
# A LUA PART IS ACCEPTED ONLY UNDER THE SAME TRUSTED-KEY CHECK AS A NODE BUILD (27/11, Fable).
#
# WHY. A lua part is the node's whole Lua tree: the lock line (sha256, bytes, interface) proves what the bytes ARE
# and never WHO produced them, so anyone who can write the lock can pin any tree. The node-build path already
# answers the real question - `wa release verify <SHA256SUMS> [SHA256SUMS.sig]` against this node's trusted keys
# (rust/wa-host/src/release.rs, verify_release_at) - and scripts/lib/lua-part.sh now calls THAT, so there is one
# verifier and one trust set.
#
# WHAT THIS ROW PINS, one case per refusal, each BY NAME:
#   R1  no SHA256SUMS.sig beside the part            -> lua_part_unsigned, and NOTHING is unpacked
#   R2  signed by a key this node does not carry     -> lua_part_signed_by_untrusted_key
#   R3  signed by the key it does trust              -> lua_part_signed_ok (the gate passes)
#   R4  the whole fill path, unsigned                -> refuses at the signature and leaves the tree untouched
#
# The signatures are the repository's TEST keys (tests/fixtures/release-sign), produced by the vault's own signer
# through scripts/lib/release-fixture-sign.py - the same keys and the same signer the release rows use, so a pass
# here says the publisher's signature is the one this verifier accepts.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD

n=0
ok()   { n=$((n+1)); }
fail() { echo "FAIL test-lua-part-signature: $*" >&2; exit 1; }

BIN="${WA_BIN:-$(command -v wa || true)}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "FAIL test-lua-part-signature: no wa binary (set WA_BIN)" >&2; exit 2; }

BASE="${TMPDIR:-/tmp}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-luapartsig-XXXXXX")" || { echo "FAIL: no scratch" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

HOST_INT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

. scripts/lib/lua-part.sh

build_tree() { # <dir>
  local dir="$1"
  mkdir -p "$dir/lua/core"
  printf -- '-- init\nreturn {}\n' > "$dir/lua/core/init.lua"
  { printf 'capabilities %s\n' "$HOST_INT"
    printf 'commit deadbeefcafe\n'
    printf '%s  lua/core/init.lua\n' "$(sha256sum < "$dir/lua/core/init.lua" | awk '{print $1}')"
  } > "$dir/manifest.txt"
}

# One release directory per case: the part file plus whatever signature that case carries.
make_case() { # <name> <sign args...>
  local name="$1"; shift
  local dir="$W/$name"
  mkdir -p "$dir"
  build_tree "$W/tree-$name"
  ( cd "$W/tree-$name" && tar czf "$dir/lua-core-part.tar.gz" manifest.txt lua ) || fail "could not build the part for $name"
  python3 scripts/lib/release-fixture-sign.py "$dir" "$@" >/dev/null 2>&1 || fail "could not sign the fixture for $name"
  printf '%s\n' "$dir/lua-core-part.tar.gz"
}

export WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"

# R1: no signature at all -------------------------------------------------------
PART="$(make_case unsigned --unsigned)"
[ -f "$W/unsigned/SHA256SUMS" ] || fail "the fixture wrote no SHA256SUMS"
[ -f "$W/unsigned/SHA256SUMS.sig" ] && fail "the --unsigned fixture wrote a signature"
out="$( WA_BIN="$BIN" ; wa_lua_part_verify_signed "$PART" "$BIN" 2>&1 )"; rc=$?
[ "$rc" = 12 ] || fail "R1: an unsigned part must be refused with 12, got $rc ($out)"
case "$out" in *lua_part_unsigned:*) ok ;; *) fail "R1: the refusal must be named lua_part_unsigned: $out" ;; esac

# R2: signed, by a key this node does not carry ---------------------------------
PART="$(make_case untrusted --key B)"
out="$( wa_lua_part_verify_signed "$PART" "$BIN" 2>&1 )"; rc=$?
[ "$rc" = 13 ] || fail "R2: a part signed by an untrusted key must be refused with 13, got $rc ($out)"
case "$out" in *lua_part_signed_by_untrusted_key:*) ok ;; *) fail "R2: the refusal must name the untrusted key: $out" ;; esac
case "$out" in *"signed by"*|*"does not trust"*) ok ;; *) fail "R2: and quote the VERIFIER's own sentence (signed by ...), not the terminal's: $out" ;; esac

# R3: signed by the trusted key -------------------------------------------------
PART="$(make_case trusted --key A)"
out="$( wa_lua_part_verify_signed "$PART" "$BIN" 2>&1 )"; rc=$?
[ "$rc" = 0 ] || fail "R3: a part signed by a trusted key must pass, got $rc ($out)"
case "$out" in *lua_part_signed_ok*) ok ;; *) fail "R3: the pass must say so and name the key: $out" ;; esac
case "$out" in *key=*) ok ;; *) fail "R3: and name the key that vouched: $out" ;; esac

# R4: the fill path refuses BEFORE unpacking ------------------------------------
PART="$(make_case fill-unsigned --unsigned)"
LOCK="$W/fill.lock"
sha="$(sha256sum < "$PART" | awk '{print $1}')"
printf 'lua-core %s %s interface=%s\n' "$sha" "$(wc -c < "$PART" | tr -d '[:space:]')" "$HOST_INT" > "$LOCK"
DEST="$W/dest-tree"
if out="$( wa_lua_part_fill "$PART" "$LOCK" "$DEST" "$HOST_INT" "$BIN" 2>&1 )"; then
  fail "R4: fill accepted an unsigned part: $out"
else
  ok
fi
case "$out" in *lua_part_unsigned:*) ok ;; *) fail "R4: fill must refuse by name (lua_part_unsigned), got: $out" ;; esac
[ -e "$DEST" ] && fail "R4: the tree was touched although the part was unsigned"
ok

# R5: and the same fill, signed, gets past the gate ------------------------------
PART="$(make_case fill-signed --key A)"
sha="$(sha256sum < "$PART" | awk '{print $1}')"
printf 'lua-core %s %s interface=%s\n' "$sha" "$(wc -c < "$PART" | tr -d '[:space:]')" "$HOST_INT" > "$LOCK"
if out="$( wa_lua_part_fill "$PART" "$LOCK" "$DEST" "$HOST_INT" "$BIN" 2>&1 )"; then
  case "$out" in *lua_part_filled*) ok ;; *) fail "R5: fill should have filled the tree: $out" ;; esac
else
  case "$out" in
    *lua_part_signed*|*lua_part_signature*) fail "R5: a properly signed part was refused by the signature gate: $out" ;;
    *) ok ;;   # another gate (interface/manifest) is a different row's subject
  esac
fi

# R6: a genuine signature that does not cover THIS part ---------------------------
# The sums is signed by the trusted key, but it lists a different file: the signature proves the signer wrote the
# sums, never that the sums says anything about the part dropped beside it.
DIR="$W/notcovered"; mkdir -p "$DIR"
printf 'unrelated file
' > "$DIR/other.tar.gz"
python3 scripts/lib/release-fixture-sign.py "$DIR" --key A >/dev/null 2>&1 || fail "could not sign the not-covered fixture"
build_tree "$W/tree-notcovered"; ( cd "$W/tree-notcovered" && tar czf "$DIR/lua-core-part.tar.gz" manifest.txt lua )
out="$( wa_lua_part_verify_signed "$DIR/lua-core-part.tar.gz" "$BIN" 2>&1 )"; rc=$?
[ "$rc" = 16 ] || fail "R6: a signed sums that does not list the part must be refused with 16, got $rc ($out)"
case "$out" in *lua_part_not_covered:*) ok ;; *) fail "R6: the refusal must be named lua_part_not_covered: $out" ;; esac

# R7: the sums lists the part, at another digest --------------------------------
# The sums is signed over a part with digest D, then the part is REPLACED: the signature is genuine, the file it
# vouches for is not the file here. This is the tamper a lock alone cannot see, because the lock's digest is written
# by whoever wrote the lock.
DIR2="$W/mismatch"; mkdir -p "$DIR2"
build_tree "$W/tree-mm"; ( cd "$W/tree-mm" && tar czf "$DIR2/lua-core-part.tar.gz" manifest.txt lua )
python3 scripts/lib/release-fixture-sign.py "$DIR2" --key A >/dev/null 2>&1 || fail "could not sign the mismatch fixture"
printf 'tampered
' >> "$DIR2/lua-core-part.tar.gz"
out="$( wa_lua_part_verify_signed "$DIR2/lua-core-part.tar.gz" "$BIN" 2>&1 )"; rc=$?
[ "$rc" = 17 ] || fail "R7: a part that is not the one the sums pins must be refused with 17, got $rc: $out"
case "$out" in *lua_part_covered_digest_mismatch:*) ok ;; *) fail "R7: the refusal must name the digest mismatch: $out" ;; esac

# R8: the whole fill path, with a signature that does not cover the part --------
LOCK2="$W/fill2.lock"
sha="$(sha256sum < "$DIR/lua-core-part.tar.gz" | awk '{print $1}')"
printf 'lua-core %s %s interface=%s
' "$sha" "$(wc -c < "$DIR/lua-core-part.tar.gz" | tr -d '[:space:]')" "$HOST_INT" > "$LOCK2"
DEST2="$W/dest-tree2"
if out="$( wa_lua_part_fill "$DIR/lua-core-part.tar.gz" "$LOCK2" "$DEST2" "$HOST_INT" "$BIN" 2>&1 )"; then
  fail "R8: fill accepted a part the signed sums does not cover: $out"
else
  case "$out" in *lua_part_not_covered:*) ok ;; *) fail "R8: fill must refuse by name, got: $out" ;; esac
fi
[ -e "$DEST2" ] && fail "R8: the tree was touched although the part was not covered"
ok

# R9: WA_BIN IS NOT A WAY IN ---------------------------------------------------
# Security read (Fable, 27/11): the verifier must be the program that will RUN the part, passed as an argument. If
# the library took ${WA_BIN:-wa} instead, whoever controls the environment or PATH would choose the program that
# says "signed ok". This case points WA_BIN at a fake that prints a success line and pins that it does NOT pass.
FAKE="$W/fake-bin"; mkdir -p "$FAKE"
cat > "$FAKE/wa" <<'FAKEWA'
#!/usr/bin/env bash
# a fake verifier: answers "ok" for anything, which is exactly what a hijacked lookup would give an attacker
if [ "${1:-}" = release ] && [ "${2:-}" = verify ]; then echo "release signature verified: attacker-key"; exit 0; fi
exit 0
FAKEWA
chmod +x "$FAKE/wa"
DIR3="$W/unsigned2"; mkdir -p "$DIR3"
build_tree "$W/tree-u2"; ( cd "$W/tree-u2" && tar czf "$DIR3/lua-core-part.tar.gz" manifest.txt lua )
python3 scripts/lib/release-fixture-sign.py "$DIR3" --unsigned >/dev/null 2>&1 || fail "could not build the unsigned fixture"
# 9a: an unsigned part, with WA_BIN pointing at the fake, must still be refused
out="$( WA_BIN="$FAKE/wa" ; wa_lua_part_verify_signed "$DIR3/lua-core-part.tar.gz" "$BIN" 2>&1 )"; rc=$?
[ "$rc" = 12 ] || fail "R9a: WA_BIN must not stand in for the verifier argument, got $rc: $out"
case "$out" in *lua_part_unsigned:*) ok ;; *) fail "R9a: expected lua_part_unsigned: $out" ;; esac
# a properly signed part, for the cases below that are about the PROGRAM and not the signature
DIR4="$W/covered-by-real"; mkdir -p "$DIR4"
build_tree "$W/tree-c"; ( cd "$W/tree-c" && tar czf "$DIR4/lua-core-part.tar.gz" manifest.txt lua )
python3 scripts/lib/release-fixture-sign.py "$DIR4" --key A >/dev/null 2>&1 || fail "could not sign the covered fixture"

# 9b: the library refuses to run WITHOUT a verifier ---------------------------------
# No argument is not "use PATH": the library fails closed, so a caller that forgot to name the program cannot get a
# part installed by accident. (Whichever program IS passed is trusted to be the real one - that is the caller's rule,
# and 9d pins it at the caller.)
out="$( wa_lua_part_verify_signed "$DIR4/lua-core-part.tar.gz" 2>&1 )" && fail "R9b: no verifier argument must fail, not pass"
case "$out" in *"verifier program"*) ok ;; *) fail "R9b: the refusal must name the missing verifier argument: $out" ;; esac
# 9d: the one caller passes the STAGED HOST, not a name from the environment
if grep -q 'wa_lua_part_fill "$LUA_PART" "$LUA_LOCK" "$STAGING/lua-core" "$HOST_INTERFACE" "$STAGING/wa"' "$ROOT/scripts/version-install.sh"; then ok; else fail "R9d: version-install must pass the staged host as the verifier (no WA_BIN, no PATH)"; fi

# 9c: a missing path is refused by name, never replaced by something on PATH
out="$( wa_lua_part_verify_signed "$DIR4/lua-core-part.tar.gz" "$W/no-such-program" 2>&1 )"; rc=$?
[ "$rc" = 15 ] || fail "R9c: a missing verifier must be refused with 15, got $rc: $out"
case "$out" in *lua_part_verifier_missing:*) ok ;; *) fail "R9c: expected lua_part_verifier_missing: $out" ;; esac

echo "lua part signature ok ($n checks)"

