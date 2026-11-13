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
# The verifier is one of three, in this order, because a node must be able to check a release with what
# its OS already has (`wa_release_verify_sums` below says why at length): the installed `wa` binary's own
# verifier (`rust/wa-host/src/release.rs`), OpenSSL >= 3, and `scripts/lib/release_verify.py` (pure
# standard library) for the two callers that run before a `wa` binary exists. All three are judged by the
# same fixtures (`tests/fixtures/release-sign/`), which the vault's own signer produced, so they are not
# allowed to agree only with each other.
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
# =====================================================================================================
# THE VERIFIER, and the three ways a node can be one.
#
# WHY THREE. A release is installed by a deploy the *sentinel* starts, and the sentinel is a service. On a
# systemd node the deploy is a transient unit whose environment carries the sentinel's OWN PATH
# (rust/wa-sentinel/src/role.rs, `deploy_environment`), and that PATH is the service manager's default -
# never a login profile's (rust/wa-operation/src/shell_env.rs: "never source user/login profiles"). So a
# python3 the operator installed in `~/bin` is invisible to the deploy that needs it: measured 13/11 on
# node `work`, where a GOOD signed release was refused with `release_unverified: no python3 here to
# verify ...` while /home/agent/bin/python3 sat there, executable. A node must be able to verify a release
# with what its OS already has, so these are tried in this order:
#
#   wa_release_verify_binary   the INSTALLED `wa` binary's own verifier (`wa release verify`, ring)
#   wa_release_verify_openssl  OpenSSL >= 3, `pkeyutl -verify -rawin` over the ed25519 SPKI
#   wa_release_verify_python   scripts/lib/release_verify.py (the pure-stdlib reference)
#
# Each answers release_verify.py's own codes - 0 verified, 2 unsigned, 3 about other bytes, 4 untrusted
# key, 5 unvouched rotation, 6 unreadable or malformed - and leaves the sentence that explains a refusal in
# WA_RELEASE_ANSWER. 7 is the ONLY answer that lets the next backend be tried: a backend that ran and
# refused is a verdict, and it is final. So nothing here is weaker than before - a missing signature, a
# flipped byte, a key this node does not trust and a rotation nobody vouched for are refused whichever
# backend answered, with the same exit code and the same sentence the callers already decide on
# (`wa_release_report` below).
#
# WA_RELEASE_VERIFY_SKIP="binary openssl python3" pretends a backend is absent, so each one can be proved
# alone on a machine that has all three (`scripts/test-release-signing.sh`). It can only remove a way to
# verify, never add one, which is why it is safe to leave in a shipped script.
WA_RELEASE_ANSWER=""
WA_RELEASE_KEYS_INDEX=""
WA_RELEASE_SIG_KEY=""
WA_RELEASE_SIG_ALG=""
WA_RELEASE_SIG_SHA256=""
WA_RELEASE_SIG_HEX=""
wa_release_openssl_state=""

# <backend> -> 0 when WA_RELEASE_VERIFY_SKIP names it and it must be pretended absent.
wa_release_skipped() {
  local list=" ${WA_RELEASE_VERIFY_SKIP:-} "
  list="${list//,/ }"
  case "$list" in *" $1 "*) return 0 ;; esac
  return 1
}

# <value> <characters> -> 0 when it is exactly that many hex characters.
wa_release_hex_ok() {
  [ "${#1}" = "$2" ] || return 1
  case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
  return 0
}

wa_release_lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

# The tree the embedded key list and the reference verifier are read from.
wa_release_root() {
  printf '%s\n' "${WA_RELEASE_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
}

# (a) the installed binaries this node might have: the install the deploy is about, the two layouts the
# installer writes, `wa` on PATH - and never the release being installed, because a candidate that
# verified itself would prove nothing.
wa_release_binary_candidates() {
  local home="${HOME:-}" one
  for one in "${WA_RELEASE_BIN:-}" \
             "${WA_INSTALL_DIR:+$WA_INSTALL_DIR/wa}" \
             "${home:+$home/.local/share/wasm-agent/wa}" \
             "${home:+$home/AppData/Local/wasm-agent/wa}" \
             "${home:+$home/.local/bin/wa}"; do
    [ -n "$one" ] && printf '%s\n' "$one"
  done
  one="$(command -v wa 2>/dev/null)" || one=""
  [ -n "$one" ] && printf '%s\n' "$one"
  return 0
}

# (a) The node's own verifier. `wa release verify` is dispatched before the interpreter on purpose
# (rust/wa-host/src/main.rs), so this answers on a node whose tree is broken - which is the node an
# upgrade is usually about.
wa_release_verify_binary() {
  local sums="$1"; shift
  local candidate binary="" answer code key
  WA_RELEASE_ANSWER=""
  if wa_release_skipped binary; then WA_RELEASE_ANSWER="skipped (WA_RELEASE_VERIFY_SKIP)"; return 7; fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # "Has one" is answered by the binary itself: a build that predates the verb says so in its own words,
    # and an unknown command is not a verifier.
    if "$candidate" release verify --help 2>/dev/null | grep -q 'wa release verify'; then
      binary="$candidate"
      break
    fi
  done < <(wa_release_binary_candidates)
  if [ -z "$binary" ]; then
    WA_RELEASE_ANSWER="no installed wa binary here answers 'wa release verify'"
    return 7
  fi
  local args=(--sums "$sums")
  for key in "$@"; do [ -n "$key" ] && args+=(--key "$key"); done
  answer="$("$binary" release verify "${args[@]}" --quiet 2>&1)"; code=$?
  WA_RELEASE_ANSWER="$answer"
  case "$code" in
    0|2|3|4|5|6) return "$code" ;;
    *) WA_RELEASE_ANSWER="$binary could not run its own verifier (exit $code): ${answer:-no output}"; return 7 ;;
  esac
}

# ---- (b) OpenSSL -------------------------------------------------------------------------------------
# The SPKI of a raw ed25519 public key is a fixed 12-byte prefix and the 32 key bytes after it
# (RFC 8410 §4: id-Ed25519 1.3.101.112, no parameters), so a host that already ships OpenSSL 3 needs no
# key file, no python and no extra package to verify a release: Debian 12, Ubuntu 22.04+ and current RHEL
# all qualify, and a binary-only node is exactly where that matters.
WA_RELEASE_SPKI_ED25519="302a300506032b6570032100"

# One real signature this script carries, so "can OpenSSL be asked" is answered by OpenSSL and not by a
# version string: LibreSSL also prints 3.x and has no `pkeyutl -rawin`. A backend that cannot be asked
# must be skipped - never allowed to answer "this signature is invalid".
WA_RELEASE_SELFTEST_PUBLIC="513b970ffdd6498d7dfadde28b853b884b30d8bd9798490c5aea1dfad2fd5f0c"
WA_RELEASE_SELFTEST_MESSAGE="77612d72656c656173652d7369676e61747572652d73656c6674657374"
WA_RELEASE_SELFTEST_SIGNATURE="922d402b5c5d55c1468ffc09cb96f99845d55057c51a68a27215810c2eab5db6807780515f92a9bf9cc62a5500cd39a745b228611347163a049e12975dd7eb05"

# <hex> <file> -> the bytes on disk; 1 when the text is not hex. sed and this shell's own printf, so a
# host with coreutils and nothing else can verify (`xxd` lives in vim-common and is absent from a Debian
# container).
wa_release_hex_to_file() {
  local hex="$1" out="$2" escaped
  case "$hex" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  [ $(( ${#hex} % 2 )) = 0 ] || return 1
  escaped="$(printf '%s' "$hex" | sed 's/../\\x&/g')" || return 1
  printf '%b' "$escaped" > "$out" || return 1
  [ "$(wc -c < "$out")" = $(( ${#hex} / 2 )) ] || return 1
}

# <public-hex> <message-hex> <signature-hex> -> 0 valid, 1 invalid.
wa_release_openssl_verify() {
  local public="$1" message="$2" signature="$3" dir status
  dir="$(mktemp -d "${TMPDIR:-/tmp}/wa-release-openssl.XXXXXX")" || return 1
  if wa_release_hex_to_file "$WA_RELEASE_SPKI_ED25519$public" "$dir/public.der" \
     && wa_release_hex_to_file "$message" "$dir/message" \
     && wa_release_hex_to_file "$signature" "$dir/signature"; then
    openssl pkeyutl -verify -pubin -inkey "$dir/public.der" -keyform DER -rawin \
      -in "$dir/message" -sigfile "$dir/signature" >/dev/null 2>&1
    status=$?
  else
    status=1
  fi
  rm -rf "$dir"
  [ "$status" = 0 ]
}

# Prints the reason OpenSSL cannot be the verifier here, or nothing when it can (probed once per process).
wa_release_openssl_why() {
  if [ -z "$wa_release_openssl_state" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
      wa_release_openssl_state="no openssl on PATH"
    elif ! wa_release_openssl_verify "$WA_RELEASE_SELFTEST_PUBLIC" "$WA_RELEASE_SELFTEST_MESSAGE" "$WA_RELEASE_SELFTEST_SIGNATURE"; then
      wa_release_openssl_state="the openssl here ($(openssl version 2>/dev/null || printf 'unknown version')) cannot verify an ed25519 signature with pkeyutl -rawin"
    else
      wa_release_openssl_state="ok"
    fi
  fi
  [ "$wa_release_openssl_state" = ok ] || printf '%s' "$wa_release_openssl_state"
}

# <signature-file> -> WA_RELEASE_SIG_KEY/_ALG/_SHA256/_HEX, or 6 with the sentence in WA_RELEASE_ANSWER.
# The same rules as release_verify.py's parse_signature, line for line, because the two are judged by the
# same fixtures in tests/fixtures/release-sign/.
wa_release_parse_signature() {
  local file="$1" text line number=0 header=0 field value extra key="" alg="" sha="" sig=""
  [ -r "$file" ] || { WA_RELEASE_ANSWER="$file: cannot be read"; return 6; }
  text="$(cat -- "$file")" || { WA_RELEASE_ANSWER="$file: cannot be read"; return 6; }
  while IFS= read -r line; do
    number=$((number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    if [ "$header" = 0 ]; then
      [ "$line" = "wa-release-signature v1" ] \
        || { WA_RELEASE_ANSWER="$file: line $number is not 'wa-release-signature v1'"; return 6; }
      header=1
      continue
    fi
    field=""; value=""; extra=""
    read -r field value extra <<< "$line"
    case "$field" in
      key|alg|sha256|sig) ;;
      *) WA_RELEASE_ANSWER="$file: line $number is not '<field> <value>'"; return 6 ;;
    esac
    if [ -z "$value" ] || [ -n "$extra" ]; then
      WA_RELEASE_ANSWER="$file: line $number is not '<field> <value>'"
      return 6
    fi
    case "$field" in
      key) key="$value" ;;
      alg) alg="$value" ;;
      sha256) sha="$value" ;;
      sig) sig="$value" ;;
    esac
  done <<< "$text"
  [ "$header" = 1 ] || { WA_RELEASE_ANSWER="$file: no 'wa-release-signature v1' header"; return 6; }
  [ -n "$key" ] || { WA_RELEASE_ANSWER="$file: missing key"; return 6; }
  [ -n "$alg" ] || { WA_RELEASE_ANSWER="$file: missing alg"; return 6; }
  [ -n "$sha" ] || { WA_RELEASE_ANSWER="$file: missing sha256"; return 6; }
  [ -n "$sig" ] || { WA_RELEASE_ANSWER="$file: missing sig"; return 6; }
  [ "$alg" = ed25519 ] || { WA_RELEASE_ANSWER="$file: algorithm '$alg' is not ed25519"; return 6; }
  wa_release_hex_ok "$sha" 64 || { WA_RELEASE_ANSWER="$file: sha256 must be 64 hex characters and sig 128"; return 6; }
  wa_release_hex_ok "$sig" 128 || { WA_RELEASE_ANSWER="$file: sha256 must be 64 hex characters and sig 128"; return 6; }
  WA_RELEASE_SIG_KEY="$key"
  WA_RELEASE_SIG_ALG="$alg"
  WA_RELEASE_SIG_SHA256="$sha"
  WA_RELEASE_SIG_HEX="$sig"
  return 0
}

# <keys-file>... -> WA_RELEASE_KEYS_INDEX, one "<id> <public hex>" line per key, unioned in the same order
# as the other two implementations (the node's list first, then the caller's). A malformed line is a
# refusal, not a line to skip: a key file a reader only partly understands trusts something else.
wa_release_collect_keys() {
  local file text line number header field id public rest
  WA_RELEASE_KEYS_INDEX=""
  for file in "$@"; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    [ -r "$file" ] || { WA_RELEASE_ANSWER="$file: cannot be read"; return 6; }
    text="$(cat -- "$file")" || { WA_RELEASE_ANSWER="$file: cannot be read"; return 6; }
    number=0
    header=0
    while IFS= read -r line; do
      number=$((number + 1))
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -z "$line" ] && continue
      case "$line" in '#'*) continue ;; esac
      if [ "$header" = 0 ]; then
        [ "$line" = "wa-trusted-keys v1" ] \
          || { WA_RELEASE_ANSWER="$file: line $number is not 'wa-trusted-keys v1'"; return 6; }
        header=1
        continue
      fi
      field=""; id=""; public=""; rest=""
      read -r field id public rest <<< "$line"
      if [ "$field" != key ] || [ -z "$id" ] || [ -z "$public" ] || [ -n "$rest" ] \
         || ! wa_release_hex_ok "$public" 64; then
        WA_RELEASE_ANSWER="$file: line $number is not 'key <id> <64 hex public key>'"
        return 6
      fi
      WA_RELEASE_KEYS_INDEX="$WA_RELEASE_KEYS_INDEX$id $(wa_release_lower "$public")
"
    done <<< "$text"
    [ "$header" = 1 ] || { WA_RELEASE_ANSWER="$file: no 'wa-trusted-keys v1' header"; return 6; }
  done
  return 0
}

# <key id> -> the public hex this node trusts for it, or nothing.
wa_release_key_for() {
  printf '%s' "$WA_RELEASE_KEYS_INDEX" | awk -v id="$1" '$1 == id { print $2; exit }'
}

# The trusted key ids, in one line, for the refusal that has to say what this node does trust.
wa_release_key_ids() {
  local ids
  ids="$(printf '%s' "$WA_RELEASE_KEYS_INDEX" | awk 'NF { print $1 }' | sort | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  printf '%s' "${ids:-no trusted key is configured}"
}

# (b) The whole rule over OpenSSL's primitive: the same four refusals, the same codes, the same sentences
# where a reader has to act on them.
wa_release_verify_openssl() {
  local sums="$1"; shift
  local dir sig_file digest announced voucher why sig_key sig_sha sig_hex
  WA_RELEASE_ANSWER=""
  if wa_release_skipped openssl; then WA_RELEASE_ANSWER="skipped (WA_RELEASE_VERIFY_SKIP)"; return 7; fi
  why="$(wa_release_openssl_why)"
  [ -z "$why" ] || { WA_RELEASE_ANSWER="$why"; return 7; }
  [ -r "$sums" ] || { WA_RELEASE_ANSWER="$sums: cannot be read"; return 6; }
  dir="$(dirname -- "$sums")"
  sig_file="$dir/SHA256SUMS.sig"
  # 2 carries its own sentence, which the caller prints - exactly as release_verify.py refuses it.
  [ -f "$sig_file" ] || return 2
  wa_release_parse_signature "$sig_file" || return 6
  # Snapshot it: parsing the rotation announcement below writes the same globals, and the sums' own key is
  # what has to be looked up at the end (measured on the `rotation` fixture, which is why it is there).
  sig_key="$WA_RELEASE_SIG_KEY"; sig_sha="$WA_RELEASE_SIG_SHA256"; sig_hex="$WA_RELEASE_SIG_HEX"
  digest="$(wa_release_sha256 "$sums")" || { WA_RELEASE_ANSWER="no sha256 tool to hash $sums"; return 7; }
  [ "$(wa_release_lower "$sig_sha")" = "$(wa_release_lower "$digest")" ] || {
    WA_RELEASE_ANSWER="$sig_file is about $sig_sha, the sums here are $digest"
    return 3
  }
  wa_release_collect_keys "$@" || return 6
  if [ -f "$dir/TRUSTED-KEYS" ]; then
    [ -f "$dir/TRUSTED-KEYS.sig" ] || {
      WA_RELEASE_ANSWER="a rotation is announced in $dir/TRUSTED-KEYS with no $dir/TRUSTED-KEYS.sig signing it"
      return 5
    }
    announced="$(wa_release_sha256 "$dir/TRUSTED-KEYS")" || { WA_RELEASE_ANSWER="no sha256 tool to hash $dir/TRUSTED-KEYS"; return 7; }
    wa_release_parse_signature "$dir/TRUSTED-KEYS.sig" || return 6
    [ "$(wa_release_lower "$WA_RELEASE_SIG_SHA256")" = "$(wa_release_lower "$announced")" ] || {
      WA_RELEASE_ANSWER="$dir/TRUSTED-KEYS.sig is about $WA_RELEASE_SIG_SHA256, $dir/TRUSTED-KEYS is $announced"
      return 5
    }
    voucher="$(wa_release_key_for "$WA_RELEASE_SIG_KEY")"
    [ -n "$voucher" ] || {
      WA_RELEASE_ANSWER="the rotation in $dir/TRUSTED-KEYS is signed by $WA_RELEASE_SIG_KEY, which is not trusted here"
      return 5
    }
    wa_release_openssl_verify "$voucher" "$announced" "$WA_RELEASE_SIG_HEX" || {
      WA_RELEASE_ANSWER="the rotation in $dir/TRUSTED-KEYS does not verify against the trusted key $WA_RELEASE_SIG_KEY"
      return 5
    }
    # Only now does the announced list become the trust set for the sums.
    wa_release_collect_keys "$@" "$dir/TRUSTED-KEYS" || return 6
  fi
  voucher="$(wa_release_key_for "$sig_key")"
  if [ -z "$voucher" ]; then
    WA_RELEASE_ANSWER="$sig_file is signed by $sig_key, which this node does not trust ($(wa_release_key_ids))"
    return 4
  fi
  wa_release_openssl_verify "$voucher" "$digest" "$sig_hex" || {
    WA_RELEASE_ANSWER="$sig_file does not verify against the trusted key $sig_key"
    return 4
  }
  return 0
}

# (c) The reference implementation. It searches PATH first and then the three places a python3 lands when
# PATH does not have it - which is the sentinel's case, and the reason `~/bin` is on this list: a service's
# PATH is the service manager's, never the operator's login profile.
wa_release_verify_python() {
  local sums="$1"; shift
  local root python="" one answer code keys=() dirs
  WA_RELEASE_ANSWER=""
  if wa_release_skipped python3; then WA_RELEASE_ANSWER="skipped (WA_RELEASE_VERIFY_SKIP)"; return 7; fi
  root="$(wa_release_root)"
  [ -f "$root/scripts/lib/release_verify.py" ] || { WA_RELEASE_ANSWER="$root/scripts/lib/release_verify.py is missing"; return 7; }
  python="$(command -v python3 2>/dev/null)" || python=""
  if [ -z "$python" ]; then
    # WA_RELEASE_PYTHON_DIRS replaces this list for a test that has to prove the "nowhere" sentence on a
    # machine whose /usr/bin/python3 exists. Like the skip list it can only remove a way to verify.
    dirs="${WA_RELEASE_PYTHON_DIRS:-${HOME:-}/bin /usr/bin /usr/local/bin}"
    for one in $dirs; do
      [ -n "$one" ] && [ -x "$one/python3" ] && { python="$one/python3"; break; }
    done
  fi
  [ -n "$python" ] || { WA_RELEASE_ANSWER="no python3 on PATH, and none in ~/bin, /usr/bin or /usr/local/bin"; return 7; }
  for one in "$@"; do [ -n "$one" ] && keys+=(--keys "$one"); done
  answer="$("$python" "$root/scripts/lib/release_verify.py" --sums "$sums" --quiet ${keys[@]+"${keys[@]}"} 2>&1)"; code=$?
  WA_RELEASE_ANSWER="$answer"
  case "$code" in
    0|2|3|4|5|6) return "$code" ;;
    *) WA_RELEASE_ANSWER="$python could not run $root/scripts/lib/release_verify.py (exit $code): ${answer:-no output}"; return 7 ;;
  esac
}

# <code> <sums> -> the ONE sentence a caller's log carries, unchanged from before the backends existed: the
# same prefixes for the same failures, so a doc or a habit that named them still names them.
wa_release_report() {
  case "$1" in
    2) printf 'release_unsigned: %s has no SHA256SUMS.sig - refusing to install from a release that is not signed\n' "$(dirname -- "$2")" >&2 ;;
    3|4|5) printf 'release_signature_invalid: %s\n' "${WA_RELEASE_ANSWER#release_unsigned_or_forged: }" >&2 ;;
    *) printf 'release_unverified: %s\n' "${WA_RELEASE_ANSWER:-the verifier could not run}" >&2 ;;
  esac
}

# <sums-file-or-dir> [extra trusted-keys files] -> 0 when a release is signed by a key this node trusts, or
# the verifier's refusal code. 7 is "no backend on this node could check it", named with what was tried: a
# refusal, never an acceptance, and a caller that would have installed anyway still installs nothing.
wa_release_verify_sums() {
  local sums="$1"; shift
  local root home="${WASM_AGENT_HOME:-${HOME:-}/.wasm-agent}" file backend code
  local keys=() tried=""
  root="$(wa_release_root)"
  [ -d "$sums" ] && sums="$sums/SHA256SUMS"
  while IFS= read -r file; do [ -n "$file" ] && keys+=("$file"); done < <(wa_release_key_files "$root" "$home")
  for file in "$@"; do [ -n "$file" ] && keys+=("$file"); done
  for backend in binary openssl python; do
    "wa_release_verify_$backend" "$sums" ${keys[@]+"${keys[@]}"}
    code=$?
    case "$code" in
      0) return 0 ;;
      2|3|4|5|6) wa_release_report "$code" "$sums"; return "$code" ;;
      *) tried="$tried${tried:+, }$backend (${WA_RELEASE_ANSWER:-could not run})" ;;
    esac
  done
  printf 'release_unverified: no verifier on this node can check %s (tried: %s)\n' "$sums" "$tried" >&2
  return 7
}
