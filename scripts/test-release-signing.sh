#!/usr/bin/env bash
# Signed releases, proved on every path that installs one - and on the one that publishes.
#
# WHAT THIS IS ABOUT. A node used to check a download against `SHA256SUMS` from the SAME release, so whoever
# could publish a release could swap the binary and the checksum together. Now the sums are signed by
# wa-vault's `release-signing` ed25519 key (which never leaves the vault) and verified against a public key
# the node already carries (`config/release-keys.txt`, embedded in the binary).
#
# What this suite proves, with no network and never the running vault:
#   1. the six cases that matter, on the committed fixtures: a good signature verifies; a flipped byte, an
#      unknown key and a missing signature are refused; a rotation announced by a trusted key is accepted;
#      a rotation signed by an unknown key is refused - and the refusal names the file;
#   2. the same six through the node's binary (`wa release verify`), when this run knows which binary it is
#      about (WA_RELEASE_BIN) - the two implementations answer identically;
#   2b. the same six through EACH of the three backends alone (binary, openssl, python3), the other two
#      faked absent - and the sentinel's own environment (a PATH with no python3 in it, the operator's
#      python3 only in ~/bin) verifying a good release and still refusing a flipped one;
#   3. signing against a SCRATCH vault: the vault signs the sums, the signature verifies, and with no token
#      or no key in the vault nothing is signed and no file is written (a release is not published);
#   4. the deploy's release path (scripts/lib/node-binaries.sh): a signed release is cached, an unsigned or
#      forged or untrusted one is refused BEFORE any payload is fetched, and nothing is left in the cache;
#   5. the binary-only updater's gate (scripts/upgrade.sh's `--release`): the candidate bytes must be the
#      ones the signed sums name, or the swap is refused;
#   6. the transport (scripts/publish-artifacts-branch.sh): a set without SHA256SUMS.sig is refused, and a
#      signed set ships both files - the sums AND the signature - in the commit and in PUBLISH.sh.
#
#   bash scripts/test-release-signing.sh        (exit 0 = everything above holds)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FIXTURES="$ROOT/tests/fixtures/release-sign"
checks=0
say() { printf 'release-signing: %s\n' "$*"; }
ok() { checks=$((checks + 1)); }
fail() { echo "FAILED: $*" >&2; exit 1; }
expect() { # <want-code> <got-code> <what> [output]
  [ "$2" = "$1" ] || fail "$3: expected exit $1, got $2${4:+: $4}"
  ok
}
contains() { printf '%s' "$1" | grep -qF -- "$2" || fail "$3: '$2' not in: $1"; ok; }
missing() { printf '%s' "$1" | grep -qf -- "$2" 2>/dev/null; }

for tool in python3 sha256sum git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP test-release-signing: $tool is not on this machine"; exit 0; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-release-sign.XXXXXX")" || { echo "SKIP test-release-signing: no scratch directory"; exit 0; }
VAULT_PID=""
cleanup() {
  [ -n "$VAULT_PID" ] && kill "$VAULT_PID" 2>/dev/null
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

. "$ROOT/scripts/lib/release-signing.sh"

# ---- 1. the six cases, on the committed fixtures -----------------------------------------------------
keys="$FIXTURES/keys.txt"
for pair in good:0 flipped:3 unknown:4 missing:2 rotation:0 rotation-unknown:5; do
  case="${pair%%:*}"; want="${pair##*:}"
  out="$(WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$FIXTURES/$case" "$keys" 2>&1)"; code=$?
  expect "$want" "$code" "fixture $case"
  if [ "$want" = 0 ]; then
    [ -z "$out" ] || fail "fixture $case verified but said '$out'"
  else
    printf '%s' "$out" | grep -qE 'release_(unsigned|signature_invalid)' \
      || fail "fixture $case was refused without naming why: $out"
    # The refusal names the FILE an operator has to look at, not just the rule.
    printf '%s' "$out" | grep -qE 'SHA256SUMS|TRUSTED-KEYS' \
      || fail "fixture $case: the refusal names no file: $out"
  fi
done
contains "$(WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$FIXTURES/unknown" "$keys" 2>&1)" \
  "release-signing-" "an untrusted key is refused by key id"
contains "$(WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$FIXTURES/rotation-unknown" "$keys" 2>&1)" \
  "rotation" "an unvouched rotation is refused as a rotation"

# ---- 2. the node's own binary, on the same six -------------------------------------------------------
if [ -n "${WA_RELEASE_BIN:-}" ] && [ -x "${WA_RELEASE_BIN}" ]; then
  for pair in good:0 flipped:3 unknown:4 missing:2 rotation:0 rotation-unknown:5; do
    case="${pair%%:*}"; want="${pair##*:}"
    out="$("$WA_RELEASE_BIN" release verify --sums "$FIXTURES/$case" --key "$keys" --quiet 2>&1)"; code=$?
    expect "$want" "$code" "the binary agrees on fixture $case" "$out"
  done
  ok
  say "the binary at $WA_RELEASE_BIN agrees with the shell verifier on all six cases"
else
  say "the binary check was not run (WA_RELEASE_BIN is not set); its rules are exercised by cargo test -p wa-host"
fi

# ---- 2b. each backend ALONE --------------------------------------------------------------------------
# The verifier answers from the installed binary, then OpenSSL, then python3. Each is proved on its own
# here, with the other two faked absent (`WA_RELEASE_VERIFY_SKIP`), on the same six cases: a fallback
# nobody ever runs is a fallback that does not work, and 13/11 is the day the only one that existed
# (python3) was not on the PATH the deploy ran with.
SIX="good:0 flipped:3 unknown:4 missing:2 rotation:0 rotation-unknown:5"
alone() { # <name of the backend that must answer> <the two to fake absent>
  local backend="$1" skip="$2" pair case want out code
  for pair in $SIX; do
    case="${pair%%:*}"; want="${pair##*:}"
    out="$(WA_RELEASE_ROOT="$ROOT" WA_RELEASE_VERIFY_SKIP="$skip" WA_RELEASE_BIN="${WA_RELEASE_BIN:-}" \
      wa_release_verify_sums "$FIXTURES/$case" "$keys" 2>&1)"; code=$?
    expect "$want" "$code" "$backend alone on fixture $case" "$out"
  done
  say "$backend alone answers all six cases exactly as the other backends do"
}

alone python3 "binary openssl"

openssl_why="$(WA_RELEASE_ROOT="$ROOT" wa_release_openssl_why)"
if [ -z "$openssl_why" ]; then
  alone openssl "binary python3"
else
  echo "SKIP test-release-signing: this machine's openssl cannot verify an ed25519 signature with pkeyutl -rawin ($openssl_why), so the openssl backend cannot be proved here"
fi

if [ -n "${WA_RELEASE_BIN:-}" ] && [ -x "${WA_RELEASE_BIN:-}" ]; then
  alone binary "openssl python3"
else
  say "the binary backend alone was not proved here (WA_RELEASE_BIN is not set); its rules are exercised by cargo test -p wa-host"
fi

# ---- 2c. the sentinel's PATH -------------------------------------------------------------------------
# Measured 13/11 on node `work`: `wa update` refused a GOOD signed release with
#   release_unverified: no python3 here to verify ...
# while /home/agent/bin/python3 existed - because the deploy the sentinel starts runs with a SERVICE's
# PATH, which has no ~/bin (rust/wa-sentinel/src/role.rs hands it the sentinel's own PATH, and
# rust/wa-operation/src/shell_env.rs never sources a login profile). This is that node, assembled here: a
# PATH with the tools and no python3 in it at all, and the operator's python3 only in ~/bin.
sentinel_path="$WORK/sentinel-path"; sentinel_home="$WORK/sentinel-home"
mkdir -p "$sentinel_path" "$sentinel_home/bin"
for tool in sha256sum awk sed grep sort tr dirname basename mktemp cat rm wc head cut sh; do
  one="$(command -v "$tool")" && ln -sf "$one" "$sentinel_path/$tool"
done
real_python="$(command -v python3)"
cat > "$sentinel_home/bin/python3" <<PY
#!/bin/sh
printf 'used-the-operators-python3\n' >> "$sentinel_home/marker"
exec "$real_python" "\$@"
PY
chmod +x "$sentinel_home/bin/python3"
BASH_BIN="$(command -v bash)"
sentinel() { # <fixture> [extra env assignment...] -> the verifier's output; sets code
  local fixture="$1"; shift
  local args=(env -i PATH="$sentinel_path" HOME="$sentinel_home" WA_RELEASE_ROOT="$ROOT" \
    WA_RELEASE_VERIFY_SKIP="binary openssl" "$@")
  out="$("${args[@]}" "$BASH_BIN" -c '. "$0"; wa_release_verify_sums "$1" "$2"' \
    "$ROOT/scripts/lib/release-signing.sh" "$FIXTURES/$fixture" "$keys" 2>&1)"; code=$?
}
sentinel good
expect 0 "$code" "a node whose PATH has no python3 at all verifies a good release" "$out"
[ -f "$sentinel_home/marker" ] \
  || fail "the verifier never looked in ~/bin: the sentinel's PATH case is exactly this and it must search ~/bin, /usr/bin, /usr/local/bin"
contains "$(cat "$sentinel_home/marker")" "used-the-operators-python3" "the operator's ~/bin/python3 was the verifier"
# The same fallback refuses what must be refused - a fallback is not a way around the signature.
sentinel flipped
expect 3 "$code" "the ~/bin fallback still refuses a flipped signature" "$out"
sentinel unknown
expect 4 "$code" "the ~/bin fallback still refuses an untrusted key" "$out"
# Nothing to verify WITH: the refusal is a refusal, it names the release, and it says what was tried.
sentinel good WA_RELEASE_PYTHON_DIRS=/nonexistent
expect 7 "$code" "a node with no verifier at all installs nothing" "$out"
contains "$out" "release_unverified: no verifier on this node can check" "the no-backend refusal is named"
contains "$out" "tried: binary" "the no-backend refusal says what was tried"
contains "$out" "no python3 on PATH" "the no-backend refusal says why python3 could not answer"

# ---- 3. signing, against a scratch vault -------------------------------------------------------------
free_port() { python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}
vault_data="$WORK/vault-data"; mkdir -p "$vault_data"
ADMIN_PORT="$(free_port)"; PROXY_PORT="$(free_port)"
token="$(python3 -c 'print("t"*40)')"
( WA_VAULT_DATA="$vault_data" WA_VAULT_ADMIN_TOKEN="$token" WA_VAULT_ADMIN_PORT="$ADMIN_PORT" \
  WA_VAULT_PROXY_PORT="$PROXY_PORT" WA_VAULT_BIND=127.0.0.1 PYTHONDONTWRITEBYTECODE=1 \
  python3 "$ROOT/vault/wa_vault.py" > "$WORK/vault.log" 2>&1 ) &
VAULT_PID=$!
ready=0
for _ in $(seq 1 200); do
  if python3 - "$ADMIN_PORT" <<'PY' 2>/dev/null
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
    pass
PY
  then ready=1; break; fi
  sleep 0.05
done
[ "$ready" = 1 ] || fail "the scratch vault did not start: $(cat "$WORK/vault.log")"

signed_dir="$WORK/signed"; mkdir -p "$signed_dir"
printf 'wa payload\n' > "$signed_dir/wa-x86_64-unknown-linux-gnu-0123456789ab"
printf 'sentinel payload\n' > "$signed_dir/wa-sentinel-x86_64-unknown-linux-gnu-0123456789ab"
(cd "$signed_dir" && sha256sum wa-* > SHA256SUMS)

# No token: nothing is signed, and no signature file appears.
out="$(env -u WA_VAULT_ADMIN_TOKEN -u WA_VAULT_ADMIN_TOKEN_FILE WA_VAULT_ADMIN_URL="http://127.0.0.1:$ADMIN_PORT" \
  bash -c '. "$0"; wa_release_sign_sums "$1" "$2"' "$ROOT/scripts/lib/release-signing.sh" \
  "$signed_dir/SHA256SUMS" "$signed_dir/SHA256SUMS.sig" 2>&1 </dev/null)"; code=$?
expect 3 "$code" "signing without a token is refused"
contains "$out" "release_signing_unavailable" "the missing-token refusal is named"
[ ! -f "$signed_dir/SHA256SUMS.sig" ] || fail "a refused signing left a signature file behind"
ok

sign_with_vault() { # <sums> <sig> [token]
  WA_VAULT_ADMIN_URL="http://127.0.0.1:$ADMIN_PORT" WA_VAULT_ADMIN_TOKEN="${3:-$token}" \
    bash -c '. "$0"; wa_release_sign_sums "$1" "$2"' "$ROOT/scripts/lib/release-signing.sh" "$1" "$2" 2>&1
}

# A vault with no release-signing key refuses by name: there is nothing to sign with.
out="$(sign_with_vault "$signed_dir/SHA256SUMS" "$signed_dir/SHA256SUMS.sig")"; code=$?
expect 8 "$code" "a vault with no signing key refuses"
contains "$out" "release_signing_refused" "the no-key refusal is named"
[ ! -f "$signed_dir/SHA256SUMS.sig" ] || fail "an unsigned release left a signature file"
ok

# The operator creates the key on the admin page; the vault signs; the answer is a signature and a key id.
created="$(curl -fsS -m 20 -X POST -H "X-Vault-Token: $token" -H 'Content-Type: application/json' \
  --data '{}' "http://127.0.0.1:$ADMIN_PORT/api/release-signing/key")" || fail "the scratch vault did not create a key"
key_id="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_id"])')"
public="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')"
printf 'wa-trusted-keys v1\nkey %s %s\n' "$key_id" "$public" > "$WORK/node-keys.txt"

out="$(sign_with_vault "$signed_dir/SHA256SUMS" "$signed_dir/SHA256SUMS.sig")"; code=$?
expect 0 "$code" "the vault signs the sums"
ok
[ -f "$signed_dir/SHA256SUMS.sig" ] || fail "the vault said it signed and wrote no file"
contains "$(cat "$signed_dir/SHA256SUMS.sig")" "key $key_id" "the signature file names the key id"
contains "$(cat "$signed_dir/SHA256SUMS.sig")" "sha256 $(wa_release_sha256 "$signed_dir/SHA256SUMS")" \
  "the signature file names the digest it is about"
WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$signed_dir" "$WORK/node-keys.txt" >/dev/null 2>&1 \
  || fail "a signature the vault just made did not verify against the key it published"
ok
printf '%s' "$out" | grep -q 'release signed' || fail "signing said nothing: $out"
ok
# The vault's own log says one line about this signature and never the seed or the signature itself.
grep -q "release-signing signature: key=$key_id sha256=$(wa_release_sha256 "$signed_dir/SHA256SUMS")" "$WORK/vault.log" \
  || fail "the vault did not log the signature with its key id and manifest digest"
ok
if grep -qF "$(sed -n 's/^sig //p' "$signed_dir/SHA256SUMS.sig")" "$WORK/vault.log"; then
  fail "the vault's log carries the signature"
fi
ok

# The same signature against the FEATURE fixtures' trust list is an unknown key, and the sums are refused.
out="$(WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$signed_dir" "$keys" 2>&1)"; code=$?
expect 4 "$code" "the scratch vault's key is unknown to another node's trust list"
contains "$out" "$key_id" "the refusal names the key that is not trusted"

# One byte of the sums changes after signing: refused, as "about other bytes".
cp -r "$signed_dir" "$WORK/tampered"
printf 'wa payload (changed)\n' > "$WORK/tampered/wa-x86_64-unknown-linux-gnu-0123456789ab"
(cd "$WORK/tampered" && sha256sum wa-* > SHA256SUMS)
out="$(WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$WORK/tampered" "$WORK/node-keys.txt" 2>&1)"; code=$?
expect 3 "$code" "a sums file changed after signing is refused"

# ---- 4. the deploy's release path ---------------------------------------------------------------------
# A release stub in the shape scripts/lib/node-binaries.sh reads, served from a file:// base.
# A REAL commit: scripts/publish-artifacts-branch.sh resolves the commit it ships (a tag names one), so a
# made-up sha is a refusal before the transport is even reached. The artifacts are fixtures; the identity
# they are shipped under is this checkout's.
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SHORT="${COMMIT:0:12}"
TRIPLE="x86_64-unknown-linux-gnu"
elf() { # <machine byte> <path> - the two header fields wa_node_binary_shape and the ELF check read
  # ELF magic, then the class/data/version bytes, then padding UP TO offset 18, then the machine byte:
  # `od -An -tx1 -j18 -N1` is what the deploy's own shape check reads (scripts/lib/node-binaries.sh).
  { printf '\177ELF'; printf '\002\001\001\000'; printf '\000\000\000\000\000\000\000\000\000\000'
    printf "\\$(printf '%03o' "$1")"; } > "$2"
  printf 'payload %s\n' "$2" >> "$2"
}
stub_release() { # <base> <sign: yes|no|flip|other-key>
  local base="$1" mode="$2" dir
  # Flat, because that is what `--from DIR` and the exact-commit fetch both read: one directory holding
  # this release's files (a per-tag subdirectory is the digest search's stub layout, not this one).
  dir="$base"; mkdir -p "$dir"
  elf 62 "$dir/wa-$TRIPLE-$SHORT"            # 0x3e = EM_X86_64
  elf 62 "$dir/wa-sentinel-$TRIPLE-$SHORT"
  {
    printf 'source_commit=%s\n' "$COMMIT"
    # The REAL digest of this commit's compiled inputs: publish-node-binaries.sh refuses a manifest whose
    # digest is not this tree's, which is the rule that lets a docs-only commit reuse older bytes.
    printf 'compiled_inputs=%s\n' "$COMPILED_INPUTS"
    printf 'codemode=embedded\n'
    # A '#'-prefixed header: every non-comment non-KEY=VALUE line is read as a target row, so a bare
    # header would be one more (unpinned) triple.
    printf '#target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes\n'
    printf '%s %s %s %s %s\n' "$TRIPLE" \
      "$(wa_release_sha256 "$dir/wa-$TRIPLE-$SHORT")" "$(wc -c < "$dir/wa-$TRIPLE-$SHORT" | tr -d '[:space:]')" \
      "$(wa_release_sha256 "$dir/wa-sentinel-$TRIPLE-$SHORT")" "$(wc -c < "$dir/wa-sentinel-$TRIPLE-$SHORT" | tr -d '[:space:]')"
  } > "$dir/node-$SHORT.manifest"
  case "$mode" in
    yes) python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$dir" --key A >/dev/null 2>&1 ;;
    other-key) python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$dir" --key B >/dev/null 2>&1 ;;
    no) python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$dir" --unsigned >/dev/null 2>&1 ;;
    flip) python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$dir" --key A >/dev/null 2>&1
          printf 'changed after signing\n' >> "$dir/SHA256SUMS" ;;
  esac
}

. "$ROOT/scripts/lib/node-binaries.sh"
COMPILED_INPUTS="$(wa_compiled_inputs_digest "$ROOT" "$COMMIT")"
export WA_NODE_BINARIES_URL=""
for mode in yes no flip other-key; do
  base="$WORK/release-$mode"
  stub_release "$base" "$mode"
done
download() { # <base> <cache> -> code, output on stdout
  WA_RELEASE_KEYS="$keys" WA_NODE_BINARIES_URL="file://$1" \
    bash -c '. "$0"; . "$1"; wa_node_target_triple() { printf "%s\n" "$2"; }; wa_node_binary_download "Magaav/wasm-agent" "$3" "$2" "$4"' \
    "$ROOT/scripts/lib/node-binaries.sh" "$ROOT/scripts/lib/node-binaries.sh" "$TRIPLE" "$COMMIT" "$2" 2>&1
}
cache="$WORK/cache"
out="$(download "$WORK/release-yes" "$cache")"; code=$?
expect 0 "$code" "a signed release is fetched and verified" "$out"
[ -f "$cache/$SHORT/$TRIPLE/.complete" ] || fail "the verified release was not cached"
ok
for pair in no:2 flip:3 other-key:4; do
  mode="${pair%%:*}"; want="${pair##*:}"
  rm -rf "$cache"
  out="$(download "$WORK/release-$mode" "$cache")"; code=$?
  expect "$want" "$code" "a release that is $mode is refused by the deploy's release path" "$out"
  printf '%s' "$out" | grep -qE 'release_(unsigned|signature_invalid)' \
    || fail "the $mode refusal is not named: $out"
  ok
  [ ! -d "$cache/$SHORT/$TRIPLE" ] || [ ! -f "$cache/$SHORT/$TRIPLE/.complete" ] \
    || fail "a refused ($mode) release was cached anyway"
  ok
done

# ---- 5. the binary-only updater's gate ----------------------------------------------------------------
candidate="$WORK/release-yes/wa-$TRIPLE-$SHORT"
WA_RELEASE_KEYS="$keys" wa_release_verify_candidate "$candidate" "$WORK/release-yes" >/dev/null 2>&1 \
  || fail "the gate refused the very bytes the signed sums name"
ok
printf 'not the shipped bytes\n' >> "$WORK/other-binary"
out="$(WA_RELEASE_KEYS="$keys" wa_release_verify_candidate "$WORK/other-binary" "$WORK/release-yes" 2>&1)"; code=$?
expect 3 "$code" "a candidate the signed sums do not name is refused"
contains "$out" "release_candidate_not_listed" "the unlisted candidate refusal is named"
out="$(WA_RELEASE_KEYS="$keys" wa_release_verify_candidate "$candidate" "$WORK/release-no" 2>&1)"; code=$?
expect 2 "$code" "a candidate from an unsigned release is refused"
contains "$out" "release_unsigned" "the unsigned candidate refusal is named"

# ---- 6. the transport ships the signature, or nothing -------------------------------------------------
# The real publisher builds SHA256SUMS from the bytes it ships and SIGNS it through the vault, so this half
# is end to end: no vault -> no release; a vault -> an orphan commit carrying the sums, the signature and
# the PUBLISH.sh that uploads both.
dropbox="$WORK/dropbox.git"; git init -q --bare "$dropbox"
ship() { # <artifact dir> <remote> <token: with|without> -> code, output
  if [ "$3" = with ]; then
    # WA_RELEASE_KEYS: the transport VERIFIES the signature before it commits it (change/waland's half of the
    # rule - presence alone would ship a signature nobody can check), and in this suite the trust anchor is the
    # scratch vault's key. In production the anchor is the key in `config/release-keys.txt` or in the node's own
    # `<home>/.wasm-agent/release-keys.txt`.
    WA_RELEASE_KEYS="$WORK/node-keys.txt" WA_VAULT_ADMIN_URL="http://127.0.0.1:$ADMIN_PORT" WA_VAULT_ADMIN_TOKEN="$token" \
      WA_PUBLISH_RUNNER=true bash "$ROOT/scripts/publish-artifacts-branch.sh" --from "$1" --commit "$COMMIT" \
      --targets "$TRIPLE" --out "$1" --remote "$2" 2>&1
  else
    env -u WA_VAULT_ADMIN_TOKEN -u WA_VAULT_ADMIN_TOKEN_FILE WA_VAULT_ADMIN_URL="http://127.0.0.1:$ADMIN_PORT" \
      WA_PUBLISH_RUNNER=true bash "$ROOT/scripts/publish-artifacts-branch.sh" --from "$1" --commit "$COMMIT" \
      --targets "$TRIPLE" --out "$1" --remote "$2" 2>&1
  fi
}
unsigned_dir="$WORK/ship-unsigned"; mkdir -p "$unsigned_dir"
cp "$WORK/release-yes"/* "$unsigned_dir/"
rm -f "$unsigned_dir/SHA256SUMS.sig"
out="$(ship "$unsigned_dir" "$dropbox" without)"; code=$?
[ "$code" != 0 ] || fail "publishing a set with no signer succeeded"
ok
contains "$out" "release_not_signed" "the refusal names the missing signature"
printf '%s\n' "$out" | grep -qF 'release_unsigned' && fail "the refusal did not come from the publisher's signing step"
ok
[ -z "$(git ls-remote "$dropbox" 'refs/heads/artifacts/*')" ] || fail "an unsigned set reached the drop box"
ok
out="$(ship "$WORK/release-yes" "$dropbox" with)"; code=$?
expect 0 "$code" "a signed set ships" "$out"
refs="$(git ls-remote "$dropbox" 'refs/heads/artifacts/*' | awk '{print $2}')"
ref="$(printf '%s\n' "$refs" | head -1)"
[ -n "$ref" ] || fail "the signed set pushed no artifacts ref"
listed="$(git --git-dir="$dropbox" ls-tree -r --name-only "${ref#refs/heads/}")"
for asset in SHA256SUMS SHA256SUMS.sig; do
  # The failure message carries the ref and what the commit DOES hold: a bare "does not carry" costs a
  # second run to diagnose (measured once, under load, and it did not reproduce).
  printf '%s\n' "$listed" | grep -qx "$asset" \
    || fail "the shipped ref $ref (refs: $(printf '%s' "$refs" | tr '\n' ' ')) does not carry $asset (holds: $(printf '%s' "$listed" | tr '\n' ' '))"
  ok
done
publish_sh="$(git --git-dir="$dropbox" show "${ref#refs/heads/}:PUBLISH.sh")"
printf '%s' "$publish_sh" | grep -q 'SHA256SUMS.sig' || fail "PUBLISH.sh does not publish SHA256SUMS.sig"
ok
printf '%s' "$publish_sh" | grep -qE 'SHA256SUMS( |$)' || fail "PUBLISH.sh does not publish SHA256SUMS"
ok
# The shipped signature is the vault's, over the sums the ref carries: the release is verifiable from the
# commit alone, which is the whole point of shipping it.
mkdir -p "$WORK/shipped"
for asset in SHA256SUMS SHA256SUMS.sig; do
  git --git-dir="$dropbox" show "${ref#refs/heads/}:$asset" > "$WORK/shipped/$asset"
done
WA_RELEASE_ROOT="$ROOT" wa_release_verify_sums "$WORK/shipped" "$WORK/node-keys.txt" >/dev/null 2>&1 \
  || fail "the shipped release does not verify against the key that signed it"
ok

say "ok ($checks checks)"
