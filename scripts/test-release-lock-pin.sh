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

# 11-13. THE PIN AND THE SIGNATURE ARE ONE GATE (slice 2, dark). The pin says WHICH bytes; the signature says WHO.
# A lock that names an artifact nobody signed is a lock a node would install blind, so the pinned part is signed
# here with the repository's own test signer (scripts/lib/release-fixture-sign.py, the same signer and the same keys
# scripts/test-lua-part-signature.sh uses) and the gate is judged in both directions. Skipped BY NAME when there is
# no host binary to verify with - a skip is not a pass, and the row says so.
if [ -n "${WA_BIN:-}" ] && [ -x "${WA_BIN}" ]; then
  export WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"
  sig_dir=$WORK/signed
  mkdir -p "$sig_dir"
  cp "$part" "$sig_dir/lua-core-part.tar.gz"
  sign_out=$(python3 scripts/lib/release-fixture-sign.py "$sig_dir" 2>&1) || fail "could not sign the pinned part: $sign_out"
  if out=$(wa_lua_part_verify_signed "$sig_dir/lua-core-part.tar.gz" "$WA_BIN" 2>&1); then
    checks=$((checks+1)); echo "ok 11: the pinned part, signed by a trusted key, passes the signature gate"
  else
    fail "the_signed_pinned_part_was_refused: $out"
  fi
  plain=$WORK/plain
  mkdir -p "$plain" && cp "$part" "$plain/lua-core-part.tar.gz"
  if out=$(wa_lua_part_verify_signed "$plain/lua-core-part.tar.gz" "$WA_BIN" 2>&1); then
    fail 'an_unsigned_pinned_part_was_accepted'
  else
    case "$out" in
      *lua_part_unsigned*) checks=$((checks+1)); echo "ok 12: an unsigned part beside the pin is refused by name" ;;
      *) fail "an_unsigned_part_was_refused_without_a_name: $out" ;;
    esac
  fi
  untrusted=$WORK/untrusted
  mkdir -p "$untrusted" && cp "$part" "$untrusted/lua-core-part.tar.gz"
  python3 scripts/lib/release-fixture-sign.py "$untrusted" --key B >/dev/null 2>&1 || fail 'could not sign with the untrusted key'
  if out=$(wa_lua_part_verify_signed "$untrusted/lua-core-part.tar.gz" "$WA_BIN" 2>&1); then
    fail 'a_part_signed_by_an_untrusted_key_was_accepted'
  else
    case "$out" in
      *lua_part_signed_by_untrusted_key*) checks=$((checks+1)); echo "ok 13: a part signed by a key this node does not carry is refused by name" ;;
      *) fail "an_untrusted_part_was_refused_without_a_name: $out" ;;
    esac
  fi
else
  printf 'skipped 11-13: no WA_BIN (a host binary) - the signature gate is judged by scripts/test-lua-part-signature.sh in the gate\n'
fi

# 14. THE WHOLE PATH A NODE TAKES, end to end and dark: nothing held -> the decision asks for the pin -> the part
# that arrived is verified against the lock -> fill puts it in a directory -> the tree is THERE and its interface is
# the host's. This is the sequence a real fetch would drive (items 2 and 3), judged in one place so the pieces cannot
# agree with each other only apart.
fresh=$WORK/node
mkdir -p "$fresh"
decision=$(wa_lua_part_fetch_decision "$LOCK" '') || fail 'the decision refused a first install'
[ "$decision" = "lua-core $pin_sha $pin_bytes" ] || fail "a first install asked for the wrong part: $decision"
out=$(wa_lua_part_verify_file "$part" "$LOCK" 2>&1) || fail "the fetched part did not verify: $out"
# The fill path takes FOUR positional values: part, lock, destination, host interface. The project record before me
# left one out and the function answered with the empty fifth slot instead of a sentence - so the call is written out
# here rather than abbreviated.
# FIVE values, not four: part, lock, destination, host interface, and THE VERIFIER PROGRAM (the host that will run
# the part - passed in, never looked up on PATH). The signature is checked first inside the fill, which is why this
# row signup above is not decoration.
signed_part="$sig_dir/lua-core-part.tar.gz"
[ -f "$signed_part" ] || fail 'no signed part to fill with (run with WA_BIN to sign it)'
out=$(wa_lua_part_fill "$signed_part" "$LOCK" "$fresh/lua-core" "$pin_iface" "$WA_BIN" 2>&1) || fail "fill refused the pinned part: $out"
[ -f "$fresh/lua-core/lua/core/init.lua" ] || fail 'the filled tree has no lua/core/init.lua'
checks=$((checks+1)); echo "ok 14: a first install goes decision -> verify -> fill and lands the pinned tree"

# 15. THE PUBLISHER PRODUCES WHAT THE PIN NAMES, and signs it (slice 2, the publish half, dark).
# scripts/lua-part-publish.sh is the producer a release would call: it stages the tree, builds the part, writes
# SHA256SUMS, signs it and prints the lock line. This check is the CONTRACT between publishing and the lock - the line
# the publisher prints must be the line the lock carries, or an operator would have to retype a digest (which is how a
# pin comes to disagree with the bytes beside it).
pub=$WORK/published
mkdir -p "$pub"
# The ROW supplies the key explicitly - the publisher has no default (a publisher that picks up a test key from the
# tree signs a release with something that means nothing). The fixture keys are RIGHT HERE, in a row, and nowhere
# else: release.sh passes the vault keys.
WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt" \
  pub_out=$(WA_RELEASE_KEYS="$ROOT/tests/fixtures/release-sign/keys.txt" bash scripts/lua-part-publish.sh --tree "$ROOT" --interface "$pin_iface" --commit "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" --out "$pub" 2>&1) || fail "the publisher failed: $pub_out"
pub_line=$(printf '%s\n' "$pub_out" | grep -m1 '^lua-core ')
[ "$pub_line" = "lua-core $pin_sha $pin_bytes interface=$pin_iface" ] || fail "the publisher printed a different line than the lock carries: got '$pub_line', lock has 'lua-core $pin_sha $pin_bytes interface=$pin_iface'"
[ -f "$pub/SHA256SUMS" ] && [ -f "$pub/SHA256SUMS.sig" ] || fail 'the publisher wrote no SHA256SUMS/.sig beside the part'
if [ -n "${WA_BIN:-}" ] && [ -x "${WA_BIN:-}" ]; then
  pub_part=$(ls "$pub"/lua-core-*.tar.gz | head -1)
  out=$(wa_lua_part_verify_signed "$pub_part" "$WA_BIN" 2>&1) || fail "what the publisher produced is not signed by a trusted key: $out"
  checks=$((checks+1)); echo "ok 15: the publisher prints the pinned line and signs what it produced"
else
  checks=$((checks+1)); echo "ok 15: the publisher prints the pinned line (signature not judged: no WA_BIN)"
fi

# 16. NO KEY, NO PART. The publisher must refuse rather than fall back to a key that happens to be in the tree:
# a release signed by a worker's test key is a release whose signature means nothing, and every check downstream
# would still pass. unset the variable in a subshell and ask it to publish.
if out=$(env -u WA_RELEASE_KEYS bash scripts/lua-part-publish.sh --tree "$ROOT" --interface "$pin_iface" --out "$WORK/nokey" 2>&1); then
  fail 'the publisher produced a part with no signing key'
else
  case "$out" in
    *lua_part_no_signing_key*) checks=$((checks+1)); echo "ok 16: no signing key is refused by name" ;;
    *) fail "no key was refused without a name: $out" ;;
  esac
fi

printf 'release lock pin ok (%s checks)\n' "$checks"
