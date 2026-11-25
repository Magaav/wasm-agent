#!/usr/bin/env bash
# A RELEASE NAMED FOR THIS COMMIT CARRYING THE COVER'S BYTES (25/11, Fable decision A).
#
# MEASURED: nextcloud (v0.1.1 release-install.sh) could install nothing of 6a70f1ba -
#   node_release_unavailable: no prebuilt ... at node-6a70f1ba2ba9
# - because the cut's --ensure found that a published release covers the same compiled inputs and published
# nothing for the commit being cut. This row holds the step that closes it (scripts/publish-named-release.sh,
# called by publish-node-binaries.sh --named-from-cover):
#
#   1. EQUAL DIGEST: a release named node-<this commit> is written, its binaries are BYTE-IDENTICAL to the
#      cover's, its manifest names this commit and the cover it came from, its SHA256SUMS is signed and the
#      signature verifies with the trusted key, and the node's own download path installs it;
#   2. DIFFERENT DIGEST: refused by name, nothing written;
#   3. NO COVER: refused by name.
#
# Everything is local: a stub channel (WA_NODE_BINARIES_URL) and a SCRATCH wa-vault (the real
# vault/wa_vault.py with its own key), so the signature is made by the publisher's own signer and no network,
# no gh, no credential and no operator key is touched. No node is started and nothing is installed into a
# real tree; the download path is the function release-install.sh calls.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip() { printf 'SKIP publish named release: %s\n' "$1"; exit 0; }
command -v python3 >/dev/null 2>&1 || skip 'python3 is needed to sign the fixture cover'
command -v curl >/dev/null 2>&1 || skip 'curl is needed by the scratch vault'
[ -f "$ROOT/vault/wa_vault.py" ] || skip 'vault/wa_vault.py is not in this tree, so nothing can be signed'
[ -f "$ROOT/scripts/publish-named-release.sh" ] || { echo 'publish named release: no scripts/publish-named-release.sh' >&2; exit 2; }

R="${WA_ROW_SCRATCH_ROOT:-}"
[ -n "$R" ] || R="$(mktemp -d "${TMPDIR:-/tmp}/wa-named-release-XXXXXX")" || exit 2
mkdir -p "$R/home" "$R/tmp" "$R/cover" "$R/out" "$R/bin" "$R/stub" || exit 2
export HOME="$R/home" WASM_AGENT_HOME="$R/home" TMPDIR="$R/tmp"
. "$ROOT/scripts/lib/test-release-vault.sh"
test_release_vault_start || skip 'the scratch vault did not start (python3/curl/vault missing)'
trap 'test_release_vault_stop 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$R"' EXIT
. "$ROOT/scripts/lib/node-binaries.sh"
. "$ROOT/scripts/lib/release-signing.sh"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SHORT="$(wa_node_short_sha "$COMMIT")"
TRIPLE="x86_64-unknown-linux-gnu"
COVER="6a70f1ba2ba9"
DIGEST="$(wa_compiled_inputs_digest "$ROOT" "$COMMIT")" || skip 'this commit cannot be digested'
REPO="fixture/fixture"
mkdir -p "$R/stub/node-$COVER" "$R/stub/node-$SHORT" || exit 2
export WA_NODE_BINARIES_URL="$R/stub" WA_RELEASE_KEYS="$TEST_RELEASE_VAULT_KEYS"

# The cover: the bytes a previous cut published, pinned by their own manifest, signed the product's way.
mk_cover() { # <compiled_inputs>
  local digest="$1" t="$TRIPLE"
  rm -rf "$R/cover"; mkdir -p "$R/cover"
  # The bytes are a real ELF header for the triple (magic + e_machine): the download path checks a binary's
  # shape before it installs it, so a text fixture would be refused by the product for the right reason.
  python3 - "$R/cover/wa-$t-$COVER" "$R/cover/wa-sentinel-$t-$COVER" <<'PY'
import sys
ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
head = ident + bytes([2, 0]) + bytes([0x3e, 0]) + bytes(64 - 20)
for path in sys.argv[1:]:
    open(path, 'wb').write(head + b'cover payload\n')
PY
  {
    printf 'source_commit=%s\n' 'a1857d15887cc8f7f3c07419f6af2639e852a8d5'
    printf 'compiled_inputs=%s\n' "$digest"
    printf 'built_utc=2026-11-24T10:00:00Z\n'
    printf 'build_seconds=120\n'
    printf '%s %s %s %s %s\n' "$t" "$(wa_node_sha256 "$R/cover/wa-$t-$COVER")" "$(wc -c < "$R/cover/wa-$t-$COVER" | tr -d '[:space:]')" "$(wa_node_sha256 "$R/cover/wa-sentinel-$t-$COVER")" "$(wc -c < "$R/cover/wa-sentinel-$t-$COVER" | tr -d '[:space:]')"
  } > "$R/cover/node-$COVER.manifest"
  test_release_sign_dir "$R/cover" || return 2
  rm -rf "$R/stub/node-$COVER"; cp -R "$R/cover" "$R/stub/node-$COVER"
}

# ---- 1. the equal digest: a release named for THIS commit, byte-identical to the cover ------------------
mk_cover "$DIGEST" || { echo 'publish named release: the cover fixture could not be built' >&2; exit 2; }
out="$(bash "$ROOT/scripts/publish-named-release.sh" --commit "$COMMIT" --cover-tag "node-$COVER" --out "$R/out" --repo "$REPO" 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && echo 1 || echo 0)" "an equal digest publishes a release named for this commit (rc $rc)" "$out"
case "$out" in *"named release ok: node-$SHORT from node-$COVER"*) ok 1 "and its words name both the tag and the cover it carries" ;; *) ok 0 "and its words name both the tag and the cover it carries" "$out" ;; esac
named_manifest="$R/out/node-$SHORT.manifest"
ok "$([ "$(wa_node_manifest_value "$named_manifest" source_commit)" = "$COMMIT" ] && echo 1 || echo 0)" "the named manifest names THIS commit"
ok "$([ "$(wa_node_manifest_value "$named_manifest" compiled_inputs)" = "$DIGEST" ] && echo 1 || echo 0)" "and keeps the cover's compiled inputs"
ok "$([ "$(wa_node_manifest_value "$named_manifest" named_from)" = "node-$COVER" ] && echo 1 || echo 0)" "and records the cover it came from"
ok "$([ "$(wa_node_manifest_value "$named_manifest" built_utc)" = '2026-11-24T10:00:00Z' ] && echo 1 || echo 0)" "and the cover's build identity, because the bytes were built then"
for kind in wa wa-sentinel; do
  from="$R/cover/$kind-$TRIPLE-$COVER"; to="$R/out/$kind-$TRIPLE-$SHORT"
  ok "$([ -f "$to" ] && [ "$(wa_node_sha256 "$from")" = "$(wa_node_sha256 "$to")" ] && echo 1 || echo 0)" "$kind is BYTE-IDENTICAL to the cover's ($kind-$TRIPLE-$SHORT)"
done
pin="$(wa_node_manifest_pin "$named_manifest" "$TRIPLE")" || pin=""
set -- $pin
ok "$([ -n "${1:-}" ] && [ -f "$R/out/wa-$TRIPLE-$SHORT" ] && [ "${1:-}" = "$(wa_node_sha256 "$R/out/wa-$TRIPLE-$SHORT")" ] && echo 1 || echo 0)" "the named manifest's pin is the named binary's own sha256"
ok "$([ "$(wc -c < "$R/out/wa-$TRIPLE-$SHORT" | tr -d '[:space:]')" = "${2:-}" ] && echo 1 || echo 0)" "and its size"
ok "$([ -s "$R/out/SHA256SUMS" ] && [ -s "$R/out/SHA256SUMS.sig" ] && echo 1 || echo 0)" "SHA256SUMS is written and signed"
rm -rf "$R/stub/node-$SHORT"; cp -R "$R/out" "$R/stub/node-$SHORT"
# The download and the verifier read WA_NODE_BINARIES_URL as ONE release directory (flat), while the
# cover fetch resolves a per-tag subdirectory: the same bytes, addressed the way each reader asks.
export WA_NODE_BINARIES_URL="$R/stub/node-$SHORT"
vd="$R/verify"; mkdir -p "$vd"
vout="$(wa_node_verify_signature "$REPO" "node-$SHORT" "$vd" 2>&1)"; vrc=$?
ok "$([ "$vrc" = 0 ] && echo 1 || echo 0)" "the signature verifies with the trusted key (verifier rc $vrc)" "$vout"
dl="$R/dl"; mkdir -p "$dl"
dout="$(wa_node_binary_download "$REPO" "$COMMIT" "$TRIPLE" "$dl" 2>&1)"; drc=$?
ok "$([ "$drc" = 0 ] && echo 1 || echo 0)" "the node's own download path installs it (rc $drc)" "$(printf '%s' "$dout" | tail -2)"
candidate="$(find "$dl" -name "wa-$TRIPLE-$SHORT" -type f 2>/dev/null | head -1)"  # the cache entry is the downloader's own layout
ok "$([ -x "$candidate" ] && [ "$(wa_node_sha256 "$candidate")" = "$(wa_node_sha256 "$R/out/wa-$TRIPLE-$SHORT")" ] && echo 1 || echo 0)" "and the candidate it leaves is the named binary, executable, byte for byte"

export WA_NODE_BINARIES_URL="$R/stub"

# ---- 2. a different digest: refused by name, nothing written -------------------------------------------
rm -rf "$R/out2"; mkdir -p "$R/out2"
mk_cover '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff' || exit 2
export WA_NODE_BINARIES_URL="$R/cover"
out2="$(bash "$ROOT/scripts/publish-named-release.sh" --commit "$COMMIT" --cover-tag "node-$COVER" --out "$R/out2" --repo "$REPO" 2>&1)"; rc2=$?
ok "$([ "$rc2" != 0 ] && echo 1 || echo 0)" "a different digest is refused (rc $rc2)"
case "$out2" in *named_release_refused:*) ok 1 "and the refusal names itself" ;; *) ok 0 "and the refusal names itself" "$out2" ;; esac
case "$out2" in *"$DIGEST"*) ok 1 "and names this commit's digest" ;; *) ok 0 "and names this commit's digest" "$out2" ;; esac
ok "$([ ! -e "$R/out2/node-$SHORT.manifest" ] && [ ! -e "$R/out2/SHA256SUMS" ] && echo 1 || echo 0)" "and nothing was written"

# ---- 3. no cover at all ----------------------------------------------------------------------------------
out3="$(bash "$ROOT/scripts/publish-named-release.sh" --commit "$COMMIT" --cover-tag 'node-000000000000' --out "$R/out3" --repo "$REPO" 2>&1)"; rc3=$?
ok "$([ "$rc3" != 0 ] && echo 1 || echo 0)" "a cover that does not exist is refused (rc $rc3)"
case "$out3" in *cover_manifest_missing:*) ok 1 "and the refusal names what is missing" ;; *) ok 0 "and the refusal names what is missing" "$out3" ;; esac
ok "$([ ! -e "$R/out3/node-$SHORT.manifest" ] && echo 1 || echo 0)" "and nothing was written"

# ---- 4. a cover whose signature does not verify: refused by name, nothing written ------------------------
mk_cover "$DIGEST" || exit 2
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$R/stub/node-$COVER" --key B >/dev/null 2>&1 || skip 'the fixture signer could not sign with the rotation key'
export WA_NODE_BINARIES_URL="$R/stub"
rm -rf "$R/out4"; mkdir -p "$R/out4"
out4="$(bash "$ROOT/scripts/publish-named-release.sh" --commit "$COMMIT" --cover-tag "node-$COVER" --out "$R/out4" --repo "$REPO" 2>&1)"; rc4=$?
ok "$([ "$rc4" != 0 ] && echo 1 || echo 0)" "a cover signed by a key this node does not trust is refused (rc $rc4)"
case "$out4" in *cover_signature_invalid:*) ok 1 "and the refusal names the signature" ;; *) ok 0 "and the refusal names the signature" "$out4" ;; esac
ok "$([ ! -e "$R/out4/node-$SHORT.manifest" ] && [ ! -e "$R/out4/SHA256SUMS" ] && echo 1 || echo 0)" "and nothing was written, so nothing was re-signed"

# ---- 5. a cover with no signature at all ----------------------------------------------------------------
mk_cover "$DIGEST" || exit 2
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$R/stub/node-$COVER" --unsigned >/dev/null 2>&1 || skip 'the fixture signer could not write an unsigned release'
rm -f "$R/stub/node-$COVER/SHA256SUMS.sig"   # --unsigned leaves the sums, never a signature
export WA_NODE_BINARIES_URL="$R/stub"
rm -rf "$R/out5"; mkdir -p "$R/out5"
out5="$(bash "$ROOT/scripts/publish-named-release.sh" --commit "$COMMIT" --cover-tag "node-$COVER" --out "$R/out5" --repo "$REPO" 2>&1)"; rc5=$?
ok "$([ "$rc5" != 0 ] && echo 1 || echo 0)" "an unsigned cover is refused (rc $rc5)"
case "$out5" in *cover_unsigned:*) ok 1 "and the refusal says it is unsigned" ;; *) ok 0 "and the refusal says it is unsigned" "$out5" ;; esac
ok "$([ ! -e "$R/out5/node-$SHORT.manifest" ] && echo 1 || echo 0)" "and nothing was written"

# ---- 6. a LANDING does not do this: no flag, no named release -------------------------------------------
ok "$([ "$(grep -c -- '--named-from-cover' "$ROOT/scripts/landing-queue.mjs")" = 0 ] && echo 1 || echo 0)" "the landing path passes no --named-from-cover"
mk_cover "$DIGEST" || exit 2
printf 'node-%s\\n' "$COVER" > "$R/stub/releases.txt"
export WA_NODE_BINARIES_URL="$R/stub"
landing="$(bash "$ROOT/scripts/publish-node-binaries.sh" --ensure --commit "$COMMIT" --target "$TRIPLE" 2>&1)"; lrc=$?
case "$landing" in *"named release:"*) ok 0 "and a landing publish (--ensure, no flag) creates no named release" "$landing" ;; *) ok 1 "and a landing publish (--ensure, no flag) creates no named release" ;; esac
case "$landing" in *source_dirty*) ok 1 "(it refuses a dirty tree before anything else, so the publish path is not reached)" ;; *) ok 1 "and it reached the publisher's own gates" ;; esac

if [ "$failed" -gt 0 ]; then printf 'publish named release FAILED (%d checks, %d failed)\n' "$checks" "$failed"; exit 1; fi
printf 'publish named release ok (%d checks)\n' "$checks"
