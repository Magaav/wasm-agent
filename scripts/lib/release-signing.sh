#!/usr/bin/env bash
# Signed releases: one vault signer, one verification, on every path that installs a release.
#
# WHY. Until this existed a node checked a download against `SHA256SUMS` from the SAME release, so whoever
# could publish a release could swap the binary and the checksum together and every check would pass. The
# release signing key lives in wa-vault (`release-signing`, ed25519): the vault signs the sums and never
# returns the key, and a node verifies the signature against a public key it already carries - the list
# embedded in the `wa` binary and the one in `config/release-keys.txt`.
#
# WHO CALLS THIS, and there is no fourth copy of the rule:
#   scripts/publish-node-binaries.sh   signs `SHA256SUMS` -> `SHA256SUMS.sig` (a release without it is not
#                                      published; `wa_release_sign_sums`)
#   scripts/lib/node-binaries.sh       verifies before any release asset enters the deploy's cache
#                                      (`wa_release_verify_release`, deploy.sh's release path)
#   scripts/linux/bootstrap.sh         verifies the bundle release before installing it
#   scripts/upgrade.sh                 verifies before the binary-only swap
#
# The verifier itself is `scripts/lib/release_verify.py` (pure standard library), because two of those
# callers run before a `wa` binary exists. The node's binary has the same rules in
# `rust/wa-host/src/release.rs`; both are judged by the same fixtures (`tests/fixtures/release-sign/`),
# which the vault's own signer produced, so the two sides are not allowed to agree only with each other.
#
# What is signed is the SHA-256 DIGEST of the file named on the `sha256` line (32 bytes), not its text.
#
#   SHA256SUMS.sig                    TRUSTED-KEYS (+ TRUSTED-KEYS.sig), only to announce a rotation
#   wa-release-signature v1           wa-trusted-keys v1
#   key <key id>                      key <key id> <public key hex>
#   alg ed25519                       ...
#   sha256 <hex of SHA256SUMS>
#   sig <hex, 64 bytes>
#
# Exit codes, the same everywhere so a caller can decide: 0 verified/signed; 2 no signature file (unsigned);
# 3 the signature is about other bytes; 4 the signing key is not trusted; 5 a rotation announcement is not
# signed by a currently trusted key; 6 a file is unreadable or malformed; 7 no python3 to verify with;
# 8 the vault is unreachable or refused (signing only).

# Where the vault's ADMIN listener is. The node's operator URL is the nonsecret half
# (`WASM_AGENT_VAULT_OPERATOR_URL`, docs/VAULT.md); WA_VAULT_ADMIN_URL overrides it for a coordinator.
wa_release_admin_url() {
  local url="${WA_VAULT_ADMIN_URL:-${WASM_AGENT_VAULT_OPERATOR_URL:-}}"
  if [ -z "$url" ]; then
    printf 'http://127.0.0.1:%s\n' "${WA_VAULT_ADMIN_PORT:-8801}"
  else
    printf '%s\n' "${url%/}"
  fi
}

# The token, from where the vault's operator tooling already reads it - never from an argument, so it
# cannot land in a process list or a shell history, and never printed: this function's output is captured
# by a caller into a variable that is not echoed (`wa_release_sign_sums`).
#   1. WA_VAULT_ADMIN_TOKEN        the variable the vault itself is configured with (docs/VAULT.md)
#   2. WA_VAULT_ADMIN_TOKEN_FILE   a 0600 file, for a publisher that keeps service secrets on disk
#   3. a TTY                        the operator tooling's own prompt (scripts/migrate-go-vault.py)
wa_release_admin_token() {
  if [ -n "${WA_VAULT_ADMIN_TOKEN:-}" ]; then
    printf '%s' "$WA_VAULT_ADMIN_TOKEN"
    return 0
  fi
  if [ -n "${WA_VAULT_ADMIN_TOKEN_FILE:-}" ] && [ -r "${WA_VAULT_ADMIN_TOKEN_FILE}" ]; then
    tr -d '\r\n' < "$WA_VAULT_ADMIN_TOKEN_FILE"
    return 0
  fi
  [ -t 0 ] || return 1
  local typed
  typed="$(stty -echo 2>/dev/null; printf 'Vault operator admin token (not stored): ' >&2; IFS= read -r typed; stty echo 2>/dev/null; printf '%s' "$typed")"
  [ -n "$typed" ] || return 1
  printf '%s' "$typed"
}

# <file> -> its sha256 on stdout; 7 when no sha tool exists.
wa_release_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | awk '{print $1}'
  else return 7; fi
}

# <sums-file> <sig-file> -> 0 when the vault signed this exact file. Never prints the token, never echoes
# the key. The signature is written by THIS process, so a release can never be assembled from a file the
# signer did not produce.
wa_release_sign_sums() {
  local sums="$1" out="$2" url token sha status dirs body config answer
  [ -f "$sums" ] || { printf 'release_signing_missing: %s\n' "$sums" >&2; return 2; }
  command -v curl >/dev/null 2>&1 || { printf 'release_signing_unavailable: no curl on this host\n' >&2; return 3; }
  command -v python3 >/dev/null 2>&1 || { printf 'release_signing_unavailable: no python3 to read the vault answer\n' >&2; return 3; }
  url="$(wa_release_admin_url)"
  case "$url" in
    https://*|http://127.0.0.1:*|http://localhost:*) ;;
    *) printf 'release_signing_refused: the admin origin must be https (or loopback), not %s\n' "$url" >&2; return 3 ;;
  esac
  token="$(wa_release_admin_token)" || {
    printf 'release_signing_unavailable: no vault admin token (set WA_VAULT_ADMIN_TOKEN or WA_VAULT_ADMIN_TOKEN_FILE where the vault already reads it)\n' >&2
    return 3
  }
  [ -n "$token" ] || { printf 'release_signing_unavailable: the vault admin token is empty\n' >&2; return 3; }
  sha="$(wa_release_sha256 "$sums")" || { printf 'release_signing_unavailable: no sha256 tool\n' >&2; return 7; }
  dirs="$(mktemp -d "${TMPDIR:-/tmp}/wa-release-sign.XXXXXX")" || { printf 'release_signing_unavailable: no scratch directory\n' >&2; return 3; }
  # The token goes in a 0600 curl config, never on curl's command line: a process list is readable by the
  # same user, and the token is the one thing here that must not be.
  config="$dirs/curl.conf"
  ( umask 077; printf 'header = "X-Vault-Token: %s"\nheader = "Content-Type: application/json"\n' "$token" > "$config" ) \
    || { rm -rf "$dirs"; return 3; }
  body="$dirs/body.json"
  printf '{"sha256":"%s"}' "$sha" > "$body"
  unset token
  answer="$(curl -fsS -m 60 -K "$config" -X POST --data-binary "@$body" "$url/api/release-signing/sign" 2>/dev/null)"; status=$?
  if [ "$status" != 0 ] || [ -z "$answer" ]; then
    rm -rf "$dirs"
    printf 'release_signing_refused: the vault at %s did not sign %s (create the release-signing key on its admin page; no release is published unsigned)\n' \
      "$url" "$sums" >&2
    return 8
  fi
  # The answer goes to a file, not through this python's stdin: the script itself comes from the heredoc
  # on stdin, and a reader that consumed it would find nothing to parse (measured while writing this).
  printf '%s' "$answer" > "$dirs/answer.json"
  if ! python3 - "$sha" "$out" "$dirs/answer.json" <<'PY'
import json, sys
sha, out, source = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    value = json.load(open(source, encoding="utf-8"))
except ValueError:
    print("release_signing_refused: the vault's answer is not JSON", file=sys.stderr); sys.exit(8)
if value.get("alg") != "ed25519" or not value.get("key_id") or not value.get("signature"):
    print("release_signing_refused: the vault's answer carries no ed25519 signature", file=sys.stderr); sys.exit(8)
if value.get("sha256") != sha:
    print("release_signing_refused: the vault signed %s, this file is %s" % (value.get("sha256"), sha), file=sys.stderr); sys.exit(3)
signature = value["signature"]
if len(signature) != 128 or any(c not in "0123456789abcdef" for c in signature.lower()):
    print("release_signing_refused: the vault's signature is not 64 bytes of hex", file=sys.stderr); sys.exit(8)
with open(out, "w", encoding="utf-8") as handle:
    handle.write("wa-release-signature v1\nkey %s\nalg ed25519\nsha256 %s\nsig %s\n"
                 % (value["key_id"], sha, signature.lower()))
PY
  then
    rm -f "$out"
    rm -rf "$dirs"
    return 8
  fi
  rm -rf "$dirs"
  [ -s "$out" ] || { printf 'release_signing_refused: %s was not written\n' "$out" >&2; return 8; }
  chmod 644 "$out" 2>/dev/null || true
  printf 'release signed: %s (key %s)\n' "$out" "$(sed -n 's/^key //p' "$out")" >&2
  return 0
}

# <repo-root> -> the trusted-keys files that exist, one per line, embedded list first.
wa_release_key_files() {
  local root="$1" home="${2:-}"
  [ -f "$root/config/release-keys.txt" ] && printf '%s\n' "$root/config/release-keys.txt"
  [ -n "$home" ] && [ -f "$home/release-keys.txt" ] && printf '%s\n' "$home/release-keys.txt"
  if [ -n "${WA_RELEASE_KEYS:-}" ]; then
    local one
    for one in $WA_RELEASE_KEYS; do [ -f "$one" ] && printf '%s\n' "$one"; done
  fi
  return 0
}

# <candidate-file> <release-dir> -> 0 when the release is signed by a trusted key AND its signed sums name
# exactly these bytes. This is the binary-only updater's gate (`scripts/upgrade.sh`): the file that is
# about to replace the running node must be the file the signature is about, not merely one of a set it
# came with.
wa_release_verify_candidate() {
  local candidate="$1" dir="$2" name sha want
  [ -f "$candidate" ] || { printf 'release_candidate_missing: %s\n' "$candidate" >&2; return 2; }
  [ -d "$dir" ] || { printf 'release_unsigned: no release directory to verify %s against (%s)\n' "$candidate" "$dir" >&2; return 2; }
  wa_release_verify_sums "$dir" || return $?
  name="$(basename -- "$candidate")"
  sha="$(wa_release_sha256 "$candidate")" || { printf 'release_unverified: no sha256 tool\n' >&2; return 7; }
  # Matched by the name the release itself uses: the installer renames on the way in, so a candidate whose
  # basename the sums do not name is refused, never guessed at.
  want="$(awk -v n="$name" '$2 == n {print $1; exit}' "$dir/SHA256SUMS")"
  if [ -z "$want" ]; then
    printf 'release_candidate_not_listed: the signed SHA256SUMS does not name %s, so the release does not vouch for these bytes\n' "$name" >&2
    return 3
  fi
  [ "$sha" = "$want" ] || {
    printf 'release_candidate_mismatch: %s is %s, the signed SHA256SUMS names %s\n' "$name" "$sha" "$want" >&2
    return 3
  }
  return 0
}
# otherwise. The sentence names the FILE, because "an unsigned release" without a name is a puzzle.
wa_release_verify_sums() {
  local sums="$1"; shift
  local root="${WA_RELEASE_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local file keys=() answer code home="${WASM_AGENT_HOME:-${HOME:-}/.wasm-agent}"
  [ -d "$sums" ] && sums="$sums/SHA256SUMS"
  command -v python3 >/dev/null 2>&1 || { printf 'release_unverified: no python3 here to verify %s\n' "$sums" >&2; return 7; }
  [ -f "$root/scripts/lib/release_verify.py" ] || { printf 'release_unverified: %s/scripts/lib/release_verify.py is missing\n' "$root" >&2; return 7; }
  while IFS= read -r file; do [ -n "$file" ] && keys+=(--keys "$file"); done < <(wa_release_key_files "$root" "$home")
  for file in "$@"; do [ -n "$file" ] && keys+=(--keys "$file"); done
  answer="$(python3 "$root/scripts/lib/release_verify.py" --sums "$sums" --quiet "${keys[@]}" 2>&1)"; code=$?
  case "$code" in
    0) return 0 ;;
    2) printf 'release_unsigned: %s has no SHA256SUMS.sig - refusing to install from a release that is not signed\n' "$(dirname -- "$sums")" >&2 ;;
    3|4|5) printf 'release_signature_invalid: %s\n' "${answer#release_unsigned_or_forged: }" >&2 ;;
    *) printf 'release_unverified: %s\n' "${answer:-the verifier could not run}" >&2 ;;
  esac
  return "$code"
}
