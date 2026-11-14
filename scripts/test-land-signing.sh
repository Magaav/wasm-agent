#!/usr/bin/env bash
# The signing half of `wa land`'s fastlane: a release's identity is produced ONCE per round, so the signature
# the signing host made is still true when the ship and publish steps re-run the publisher.
#
# WHY. Measured 13/11, by hand: the round built a release set, the vault host signed its `SHA256SUMS`, and the
# next step - shipping the set, which re-runs `scripts/publish-node-binaries.sh` - rewrote the manifest with a
# fresh `built_utc`. A new manifest is a new manifest sha256, a new manifest sha256 is a new `SHA256SUMS`, and a
# new `SHA256SUMS` is not the file that was signed: the operator had to freeze the build by hand and publish
# with `--from`. That is the failure this row proves gone, and it proves it the way the round does it:
#
#   build (--from a fixture set)  ->  sign  ->  re-run the publisher  ->  verify  ->  publish (a gh shim)
#
# What is REAL here: `scripts/publish-node-binaries.sh` and `scripts/publish-lua-tree.sh` themselves, the real
# signature library (`scripts/lib/release-signing.sh`) and its verifier, the real `sha256sum`, and real git.
# What is a FIXTURE: the payloads (two ELF headers, because a cross-build is not a test's business), `gh` (a
# shim that records its arguments - no test may publish), and the vault (a signature made offline with a fixed
# seed through `vault/wa_vault.py`, the same ed25519 code the vault runs; the vault's own admin path is proved
# by `scripts/test-release-signing.sh`).
#
#   bash scripts/test-land-signing.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "land signing FAILED: $*" >&2; exit 1; }
expect_status() { # <want> <got> <what>
  [ "$2" = "$1" ] || fail "$3: expected status $1, got $2"
  ok
}
contains() { # <text> <needle> <what>
  # Here-string, not a pipe: under `set -o pipefail` a `grep -q` that finds its match closes the pipe, the
  # writer dies of SIGPIPE (141) and a TRUE assertion reads as false. Measured on this suite's neighbour.
  grep -qF -- "$2" <<< "$1" || fail "$3: '$2' not in: $(printf '%s' "$1" | head -20)"
  ok
}
absent() { # <text> <needle> <what>
  grep -qF -- "$2" <<< "$1" && fail "$3: '$2' unexpectedly in: $(printf '%s' "$1" | head -20)"
  ok
}
sha() { sha256sum "$1" | awk '{print $1}'; }
bytes() { wc -c < "$1" | tr -d '[:space:]'; }
mkelf() { { printf '\177ELF\002\001\001'; printf '\000\000\000\000\000\000\000\000\000'; printf '\003\000'; printf "\x$2"; printf 'fixture%s' "${3:-}"; } > "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-land-signing: no python3, so the offline signer cannot run"; exit 0; }
[ -f "$ROOT/vault/wa_vault.py" ] || { echo "SKIP test-land-signing: vault/wa_vault.py is not in this tree, so no signature can be made"; exit 0; }

mkdir -p "$WORK/bin"
# `gh` is first on PATH and records every call: `release view` says the tag is absent, create/upload succeed.
cat > "$WORK/bin/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh-called"
case "\$1 \$2" in
  "release create"|"release upload") exit 0 ;;
  "release view") exit 1 ;;
esac
exit 1
SHIM
chmod +x "$WORK/bin/gh"
PATH="$WORK/bin:$PATH"; export PATH

# The offline signer: the vault's own ed25519 code, a fixed seed, and the signature file format
# `scripts/lib/release-signing.sh` verifies (`wa-release-signature v1`).
cat > "$WORK/bin/sign-fixture" <<'SIGNER'
#!/usr/bin/env python3
"""Sign a SHA256SUMS the way the vault's admin API does, offline, with a fixture seed. Not a real key."""
import hashlib, importlib.util, os, sys
root = os.environ["WA_FIXTURE_ROOT"]
spec = importlib.util.spec_from_file_location("wa_vault", os.path.join(root, "vault", "wa_vault.py"))
vault = importlib.util.module_from_spec(spec); spec.loader.exec_module(vault)
seed = hashlib.sha256(b"wasm-agent land-signing fixture seed").digest()
public = vault.ed25519_public(seed).hex()
key_id = "release-signing-" + hashlib.sha256(bytes.fromhex(public)).hexdigest()[:16]
if sys.argv[1] == "--keys":
    open(sys.argv[2], "w").write("wa-trusted-keys v1\nkey %s %s\n" % (key_id, public))
    print(key_id)
    raise SystemExit(0)
sums, out = sys.argv[1], sys.argv[2]
digest = hashlib.sha256(open(sums, "rb").read()).hexdigest()
sig = vault.ed25519_sign(seed, bytes.fromhex(digest)).hex()
open(out, "w").write("wa-release-signature v1\nkey %s\nalg ed25519\nsha256 %s\nsig %s\n" % (key_id, digest, sig))
print("signed %s (key %s)" % (out, key_id))
SIGNER
chmod +x "$WORK/bin/sign-fixture"
WA_FIXTURE_ROOT="$ROOT"; export WA_FIXTURE_ROOT

# ---- a fixture checkout -------------------------------------------------------------------------------
# The publisher, the record script and the two libraries are the REAL ones: what this row proves is their
# behaviour, and a fixture copy of a rule would prove the copy. The tree also carries the Lua files a record is
# about, because `scripts/lib/lua-tree.sh` names them.
fixture="$WORK/fixture"
mkdir -p "$fixture/scripts/lib" "$fixture/config" "$fixture/lua/core" "$fixture/lua/vendor"
cp "$ROOT/scripts/lib/node-binaries.sh" "$ROOT/scripts/lib/lua-tree.sh" "$ROOT/scripts/lib/release-signing.sh" \
   "$ROOT/scripts/lib/release_verify.py" "$ROOT/scripts/lib/build-requirements.sh" "$fixture/scripts/lib/"
cp "$ROOT/scripts/publish-node-binaries.sh" "$ROOT/scripts/publish-lua-tree.sh" "$fixture/scripts/"
cp "$ROOT/scripts/check-disk-floor.sh" "$fixture/scripts/"
printf 'return {}\n' > "$fixture/lua/core/init.lua"
printf 'return {}\n' > "$fixture/lua/core/agent.lua"
printf '{}\n' > "$fixture/lua/vendor/json.lua"
printf '# orchestrator\n' > "$fixture/AGENTS.orchestrator.md"
printf '# subagents\n' > "$fixture/AGENTS.subagents.md"
"$WORK/bin/sign-fixture" --keys "$fixture/config/release-keys.txt" > "$WORK/key-id"
( cd "$fixture" && git init -q -b main && git config core.autocrlf false && git config user.email t@t \
    && git config user.name t && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD ) \
  >/dev/null 2>&1 || fail "could not build the git fixture"
FIXTURE_SHA="$(git -C "$fixture" rev-parse HEAD)"
SHORT="${FIXTURE_SHA:0:12}"
TRIPLE=x86_64-unknown-linux-gnu
PUBLISH="$fixture/scripts/publish-node-binaries.sh"
RECORD="$fixture/scripts/publish-lua-tree.sh"

# ---- 1. a set built elsewhere, verified, and its sums produced once ------------------------------------
built="$WORK/built"
mkdir -p "$built"
mkelf "$built/wa-$TRIPLE-$SHORT" 3e
mkelf "$built/wa-sentinel-$TRIPLE-$SHORT" 3e
cat > "$built/node-$SHORT.manifest" <<MANIFEST
schema=wasm-agent-node-binaries/1
source_commit=$FIXTURE_SHA
source_tree=$(git -C "$fixture" rev-parse "$FIXTURE_SHA^{tree}")
compiled_inputs=$(. "$fixture/scripts/lib/node-binaries.sh"; wa_compiled_inputs_digest "$fixture" "$FIXTURE_SHA")
rustc_version=fixture
zig_version=fixture
glibc_floor=2.31
codemode=embedded
built_utc=2026-11-13T00:00:00Z
# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes
$TRIPLE $(sha "$built/wa-$TRIPLE-$SHORT") $(bytes "$built/wa-$TRIPLE-$SHORT") $(sha "$built/wa-sentinel-$TRIPLE-$SHORT") $(bytes "$built/wa-sentinel-$TRIPLE-$SHORT")
MANIFEST

out="$(WA_RELEASE_SIGN_DEFER=1 WA_PUBLISH_RUNNER=true bash "$PUBLISH" --repo "$fixture" --from "$built" --out "$WORK/release" --target "$TRIPLE" --local 2>&1)"
expect_status 0 "$?" "the artifacts step accepts a set built elsewhere"
contains "$out" "identity taken from" "the identity travels with the bytes"
contains "$out" "checksums $WORK/release/SHA256SUMS" "the sums are written once"
manifest_before="$(sha "$WORK/release/node-$SHORT.manifest")"
sums_before="$(sha "$WORK/release/SHA256SUMS")"

# ---- 2. sign it, and verify the signature the way a node would ---------------------------------------
"$WORK/bin/sign-fixture" "$WORK/release/SHA256SUMS" "$WORK/release/SHA256SUMS.sig" >/dev/null \
  || fail "the fixture signer could not sign the sums"
signed_sums="$(sha "$WORK/release/SHA256SUMS")"
verify_out="$( cd "$fixture" && . scripts/lib/release-signing.sh && wa_release_verify_sums "$WORK/release" 2>&1 )"
expect_status 0 "$?" "the signature over the sums verifies against this tree's trusted keys"
contains "$(cat "$WORK/release/SHA256SUMS.sig")" "key $(cat "$WORK/key-id")" "the signature names the trusted key"

# ---- 3. THE FIX: the ship step's re-run of the publisher must not invalidate it ------------------------
# `scripts/publish-artifacts-branch.sh` runs the publisher again over the same directory (that is how a set
# built on one host is shipped from another), so this is the exact step that broke on 13/11.
out="$(WA_RELEASE_SIGN_DEFER=1 WA_PUBLISH_RUNNER=true bash "$PUBLISH" --repo "$fixture" --from "$built" --out "$WORK/release" --target "$TRIPLE" --local 2>&1)"
expect_status 0 "$?" "the publisher re-runs over a signed set"
contains "$out" "manifest kept byte-for-byte" "the manifest is not rewritten when it already names this commit"
contains "$out" "checksums reused" "the sums are not rewritten either"
contains "$out" "signature verified" "and the signature that was made over them still verifies"
[ "$(sha "$WORK/release/node-$SHORT.manifest")" = "$manifest_before" ] || fail "the manifest changed bytes on a re-run"
[ "$(sha "$WORK/release/SHA256SUMS")" = "$sums_before" ] || fail "SHA256SUMS changed bytes on a re-run"
[ "$(sha "$WORK/release/SHA256SUMS")" = "$signed_sums" ] || fail "the sums are no longer the ones that were signed"
ok

# The identity, not only the sums: a second run must not invent a new `built_utc`.
grep -q "built_utc=2026-11-13T00:00:00Z" "$WORK/release/node-$SHORT.manifest" \
  || fail "the manifest's built_utc is not the frozen one"
ok
[ -f "$WORK/release/build-stamp.txt" ] || fail "no build stamp was written"
grep -q "source_commit=$FIXTURE_SHA" "$WORK/release/build-stamp.txt" || fail "the stamp does not name the commit"
ok

# ---- 4. publishing uses the signed bytes, without any hand-frozen build --------------------------------
out="$(WA_RELEASE_SIGN_DEFER=1 WA_PUBLISH_RUNNER=true bash "$PUBLISH" --repo "$fixture" --from "$built" --out "$WORK/release" --target "$TRIPLE" --publish 2>&1)"
[ "$?" = 0 ] || { printf '%s\n' "$out" | tail -5; fail "a signed set publishes without freezing anything by hand"; }
ok
called="$(cat "$WORK/gh-called" 2>/dev/null || true)"
contains "$called" "release create" "gh was asked to create the release"
contains "$called" "SHA256SUMS.sig" "the signature is uploaded with the payloads"
[ "$(sha "$WORK/release/SHA256SUMS")" = "$signed_sums" ] || fail "publishing changed the signed sums"
ok

# ---- 5. a stale signature is refused by name, never uploaded -------------------------------------------
# The set changes after it was signed - the case is a re-build of the same commit into the same directory, so
# the payload bytes and the manifest that pins them move together. The sums must then be written again, and a
# signature over the old ones is about other bytes: it must be refused HERE, by name, and never uploaded.
cp -f "$built/wa-$TRIPLE-$SHORT" "$WORK/wa-$TRIPLE-$SHORT.before"
printf 'rebuilt\n' >> "$built/wa-$TRIPLE-$SHORT"
sentinel_sha="$(sha "$built/wa-sentinel-$TRIPLE-$SHORT")"
sentinel_bytes="$(bytes "$built/wa-sentinel-$TRIPLE-$SHORT")"
sed -i "s|^$TRIPLE .*|$TRIPLE $(sha "$built/wa-$TRIPLE-$SHORT") $(bytes "$built/wa-$TRIPLE-$SHORT") $sentinel_sha $sentinel_bytes|" \
  "$built/node-$SHORT.manifest" || fail "could not rebuild the fixture manifest"
out="$(WA_RELEASE_SIGN_DEFER=1 WA_PUBLISH_RUNNER=true bash "$PUBLISH" --repo "$fixture" --from "$built" --out "$WORK/release" --target "$TRIPLE" --publish 2>&1)"
status=$?
[ "$status" = 6 ] || fail "a set whose sums no longer match its signature was not refused by name (status $status): $out"
ok
contains "$out" "signature_stale:" "the refusal is named signature_stale"
contains "$out" "sign the new" "and it says how to fix it"
absent "$(cat "$WORK/gh-called" 2>/dev/null || true)" "release upload" "nothing was uploaded after the refusal"
# Back to the set that was signed: the same re-run is green again (nothing was left in a broken state).
cp -f "$WORK/wa-$TRIPLE-$SHORT.before" "$built/wa-$TRIPLE-$SHORT"
sed -i "s|^$TRIPLE .*|$TRIPLE $(sha "$built/wa-$TRIPLE-$SHORT") $(bytes "$built/wa-$TRIPLE-$SHORT") $sentinel_sha $sentinel_bytes|" \
  "$built/node-$SHORT.manifest" || fail "could not restore the fixture manifest"
out="$(WA_RELEASE_SIGN_DEFER=1 WA_PUBLISH_RUNNER=true bash "$PUBLISH" --repo "$fixture" --from "$built" --out "$WORK/release" --target "$TRIPLE" --local 2>&1)"
expect_status 0 "$?" "the untouched set is accepted again"
# The bytes, not the wording: the restored set is exactly the signed one, so the sums come out identical and
# the signature over them is true again. (A rewrite that produces the same bytes is harmless; what must never
# happen is different bytes with the old signature beside them, which case 5 refused by name.)
[ "$(sha "$WORK/release/SHA256SUMS")" = "$signed_sums" ] || fail "the restored set did not produce the signed sums"
ok
contains "$out" "signature verified" "and the signature over them verifies again"

# ---- 6. the Lua tree's record: one write per round, verified against a checkout ------------------------
record="$WORK/lua-record"
out="$(bash "$RECORD" --repo "$fixture" --commit "$FIXTURE_SHA" --out "$record" 2>&1)"
expect_status 0 "$?" "the Lua tree record is written"
contains "$out" "no cross-build, no node release" "and it says what it is not"
lua_before="$(sha "$record/node-lua-tree.manifest")"
lua_sums_before="$(sha "$record/SHA256SUMS")"
contains "$(cat "$record/node-lua-tree.manifest")" "schema=wasm-agent-lua-tree/1" "the record names its own schema"
contains "$(cat "$record/node-lua-tree.manifest")" "lua_inputs=" "and the digest that names the exact set"
contains "$(cat "$record/node-lua-tree.manifest")" "  lua/core/agent.lua" "every shipped file is pinned"
absent "$(cat "$record/node-lua-tree.manifest")" "  README.md" "and nothing outside the shipped set is"
contains "$out" "unsigned so far" "an unsigned record says so, never that it is signed"
verify_out="$(bash "$RECORD" --repo "$fixture" --verify "$fixture" --out "$record" 2>&1)"
expect_status 0 "$?" "a checkout of the commit verifies against the record"
contains "$verify_out" "record ok:" "and the answer names the file count"

# Signed, then re-run: the record and its sums must not move (the same rule as the node release).
"$WORK/bin/sign-fixture" "$record/SHA256SUMS" "$record/SHA256SUMS.sig" >/dev/null || fail "could not sign the record"
out="$(bash "$RECORD" --repo "$fixture" --commit "$FIXTURE_SHA" --out "$record" 2>&1)"
expect_status 0 "$?" "the record script re-runs over a signed record"
contains "$out" "identity frozen" "the identity is the frozen one"
contains "$out" "manifest reused" "the manifest is not rewritten"
contains "$out" "checksums reused" "the sums are not rewritten"
[ "$(sha "$record/node-lua-tree.manifest")" = "$lua_before" ] || fail "the record changed bytes on a re-run"
[ "$(sha "$record/SHA256SUMS")" = "$lua_sums_before" ] || fail "the record's sums changed bytes on a re-run"
verify_out="$(bash "$RECORD" --repo "$fixture" --verify "$fixture" --out "$record" 2>&1)"
expect_status 0 "$?" "and the signature over them still verifies"
contains "$verify_out" "signature ok" "the record's own verification reads the signature"

# A file that is not the record's bytes is refused by name.
cp -R "$fixture" "$WORK/tampered"
printf '\n-- tampered\n' >> "$WORK/tampered/lua/core/agent.lua"
verify_out="$(bash "$RECORD" --repo "$fixture" --verify "$WORK/tampered" --out "$record" 2>&1)"
expect_status 5 "$?" "a tampered tree is refused"
contains "$verify_out" "record_mismatch:" "the refusal is named"
contains "$verify_out" "lua/core/agent.lua" "and it names the file"

# ---- 7. the drift guard: deploy.sh stages the Lua tree through the one definition ----------------------
# A record over a slightly different file set would certify a tree no node installs, so the list lives once.
grep -q 'wa_lua_tree_files' "$ROOT/scripts/deploy.sh" || fail "scripts/deploy.sh no longer uses scripts/lib/lua-tree.sh's file list"
ok
grep -q 'scripts/lib/lua-tree.sh' "$ROOT/scripts/deploy.sh" || fail "scripts/deploy.sh does not source scripts/lib/lua-tree.sh"
ok
never="$(grep -c "find lua/core lua/vendor" "$ROOT/scripts/deploy.sh" || true)"
[ "${never:-0}" = 0 ] || fail "scripts/deploy.sh still spells the shipped Lua file list inline ($never place(s))"
ok

echo "land signing ok ($checks checks)"
