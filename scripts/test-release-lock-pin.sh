#!/usr/bin/env bash
# The release lock's lua-core pin is the build of THIS tree, and a part that is not it is refused by name.
#
# WHY (lua-core-is-a-signed-part slice 1): the producer (scripts/lua-part-build.sh), the verifier and the
# signature row all existed on main while NOTHING WAS PINNED - the line shape lived only inside test fixtures.
# A pin nobody can reproduce is worse than no pin, so this row is the pin's own check, in the same discipline
# components.lock has: a fresh build of this tree must be the bytes the lock names, and one changed byte must be
# refused by name rather than accepted.
#
# WHAT IT PROVES, in order:
#   1. the pin line parses (part, sha256, bytes, interface=) and names lua-core;
#   2. a FRESH build of this tree has that sha256 and that size - the pin is reproducible;
#   3. the verifier accepts the built part against the pin (wa_lua_part_verify_file);
#   4. a part with ONE byte flipped is refused, and the refusal names the digest, not just "bad";
#   5. an interface that is not the pin's is refused by name (lua_part_interface_mismatch).
#
# Run: bash scripts/test-release-lock-pin.sh   (no node, no cargo; seconds)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
. scripts/lib/lua-part.sh

LOCK=$ROOT/release.lock
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lockpin-XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL test-release-lock-pin: %s\n' "$*" >&2; exit 1; }
checks=0

[ -f "$LOCK" ] || fail 'release_lock_missing'
pin_sha=$(wa_lua_part_lock_value "$LOCK" lua-core sha256) || fail 'pin_has_no_sha256'
pin_bytes=$(wa_lua_part_lock_value "$LOCK" lua-core bytes) || fail 'pin_has_no_bytes'
pin_iface=$(wa_lua_part_lock_value "$LOCK" lua-core interface) || fail 'pin_has_no_interface'
checks=$((checks+1)); echo "ok 1: lua-core pinned, ${pin_bytes} bytes, interface=${pin_iface:0:12}…"

# 2. THE PIN IS THIS TREE'S BUILD.
interface_arg=${WA_INTERFACE_OVERRIDE:-$pin_iface}
# THE PART IS THE LUA TREE, not the checkout: staging only `lua/` (and the manifest, when the tree carries one)
# keeps the pin reproducible. Built from the whole checkout, the part would contain release.lock and this very
# row, so committing the pin would change the bytes that pin names - the one-byte self-reference measured on the
# first run of this row (1746153 -> 1746154).
stage=$WORK/tree
mkdir -p "$stage"
cp -a "$ROOT/lua" "$stage/"
[ -f "$ROOT/manifest.txt" ] && cp -a "$ROOT/manifest.txt" "$stage/"
bash scripts/lua-part-build.sh --tree "$stage" --commit "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --interface "$interface_arg" --out "$WORK" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; fail 'build_failed'; }
part=$(ls "$WORK"/lua-core-*.tar.gz 2>/dev/null | head -1)
[ -n "$part" ] || fail 'no_part_written'
built_sha=$(sha256sum < "$part" | awk '{print $1}')
built_bytes=$(wc -c < "$part")
checks=$((checks+1))
if [ "$built_sha" = "$pin_sha" ] && [ "$built_bytes" = "$pin_bytes" ]; then
  echo "ok 2: a fresh build of this tree is the pinned bytes (${built_sha:0:12}…, $built_bytes)"
else
  fail "pin_is_not_this_tree: lock says ${pin_sha:0:12}…/$pin_bytes, this tree builds ${built_sha:0:12}…/$built_bytes - rebuild the part and commit the new line (see release.lock header)"
fi

# 3. THE VERIFIER ACCEPTS IT AGAINST THE PIN.
if out=$(wa_lua_part_verify_file "$part" "$LOCK" 2>&1); then
  checks=$((checks+1)); echo "ok 3: the verifier accepts the pinned part${out:+ ($out)}"
else
  fail "verifier_refused_the_pinned_part: $out"
fi

# 4. ONE CHANGED BYTE IS REFUSED, BY NAME.
tampered=$WORK/tampered.tar.gz
cp "$part" "$tampered"
printf '\x00' | dd of="$tampered" bs=1 seek=2048 conv=notrunc status=none 2>/dev/null || true
if out=$(wa_lua_part_verify_file "$tampered" "$LOCK" 2>&1); then
  fail 'a_tampered_part_was_accepted'
else
  checks=$((checks+1)); echo "ok 4: one changed byte refused by name ($(printf '%s' "$out" | head -1))"
fi

# 5. THE INTERFACE IS CHECKED BOTH WAYS, BY NAME.
# wa_lua_part_interface takes the UNPACKED tree and the host's digest: it reads `capabilities` from the part's own
# manifest.txt and refuses a part that needs something else (lua_part_interface_mismatch). Positional, not
# inferred - the host digest is passed in, never guessed from the tree being installed.
unpacked=$WORK/unpacked
mkdir -p "$unpacked"
if out=$(wa_lua_part_unpack "$part" "$LOCK" "$unpacked" 2>&1); then :; else fail "unpack_refused_the_pinned_part: $out"; fi
if out=$(wa_lua_part_interface "$unpacked" "$pin_iface" 2>&1); then
  checks=$((checks+1)); echo "ok 5: the part declares the interface the host offers"
else
  fail "interface_check_rejected_the_pinned_part: $out"
fi
if out=$(wa_lua_part_interface "$unpacked" 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' 2>&1); then
  fail 'a_foreign_interface_was_accepted'
else
  checks=$((checks+1)); echo "ok 6: a foreign interface refused by name ($(printf '%s' "$out" | head -1))"
fi

# 7. THE FETCH DECISION ANSWERS FOR THE DIGEST A NODE INSTALLED (slice 2, item 2). It compares like with like:
# the lock pins the digest of the part FILE, so what a node reports is the digest it installed, not a hash of the
# tree it unpacked (those are different numbers - measured: hashing an unpacked tree can never equal the part).
if out=$(wa_lua_part_fetch_decision "$LOCK" "$pin_sha" 2>&1); then
  [ -z "$out" ] || fail "a_node_holding_the_pinned_part_asked_to_download_again: $out"
  checks=$((checks+1)); echo "ok 7: a node holding the pinned part asks for no download"
else
  fail "fetch_decision_refused_the_pinned_digest: $out"
fi
out=$(wa_lua_part_fetch_decision "$LOCK" '1111111111111111111111111111111111111111111111111111111111111111' 2>&1) || fail "fetch_decision_failed: $out"
case "$out" in
  "lua-core $pin_sha $pin_bytes") checks=$((checks+1)); echo "ok 8: a node holding another part asks for exactly the pin" ;;
  *) fail "a_node_with_another_digest_asked_for: ${out:-nothing}" ;;
esac
out=$(wa_lua_part_fetch_decision "$LOCK" '' 2>&1) || fail "fetch_decision_failed_on_a_first_install: $out"
case "$out" in
  "lua-core $pin_sha $pin_bytes") checks=$((checks+1)); echo "ok 9: a first install (nothing held) asks for the pin" ;;
  *) fail "a_first_install_asked_for: ${out:-nothing}" ;;
esac
if out=$(wa_lua_part_fetch_decision "$LOCK" 'not-a-digest' 2>&1); then
  fail 'a_malformed_digest_was_accepted'
else
  case "$out" in
    *lua_part_digest_malformed*) checks=$((checks+1)); echo "ok 10: a malformed held digest is refused by name" ;;
    *) fail "a_malformed_digest_was_refused_without_a_name: $out" ;;
  esac
fi

printf 'release lock pin ok (%s checks)\n' "$checks"
