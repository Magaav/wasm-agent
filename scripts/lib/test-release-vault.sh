#!/usr/bin/env bash
# A scratch wa-vault for tests: a real vault process, its own data directory, its own ports, and a
# `release-signing` key made through the admin API - so a test signs releases the way the publisher does,
# with the vault's signer, and never touches the operator's running vault.
#
#   . scripts/lib/test-release-vault.sh
#   test_release_vault_start || fail "the scratch vault did not start"
#   trap 'test_release_vault_stop' EXIT
#   # from here the two variables the operator tooling reads are set for this shell:
#   #   WA_VAULT_ADMIN_URL, WA_VAULT_ADMIN_TOKEN   (that is what scripts/lib/release-signing.sh reads)
#   # and TEST_RELEASE_VAULT_KEYS names a trusted-keys file with the key it created, for the verifying side.
#
# Refuses to start when python3 or curl is missing (the caller reports that as a SKIP: a test that cannot
# sign cannot tell a refusal from a bug).
# Not under the repository: a scratch vault's data directory is scratch, and `mktemp -d` owns it.
test_release_vault_start() {
  command -v python3 >/dev/null 2>&1 || return 7
  command -v curl >/dev/null 2>&1 || return 7
  local root="${TEST_RELEASE_VAULT_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
  [ -f "$root/vault/wa_vault.py" ] || return 7
  TEST_RELEASE_VAULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wa-vault-test.XXXXXX")" || return 7
  TEST_RELEASE_VAULT_LOG="$TEST_RELEASE_VAULT_DIR/vault.log"
  TEST_RELEASE_VAULT_KEYS="$TEST_RELEASE_VAULT_DIR/trusted-keys.txt"
  TEST_RELEASE_VAULT_TOKEN="$(python3 -c 'print("t"*40)')"
  local admin proxy ready=0
  admin="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)" || return 7
  proxy="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)" || return 7
  WA_VAULT_DATA="$TEST_RELEASE_VAULT_DIR/data" WA_VAULT_ADMIN_TOKEN="$TEST_RELEASE_VAULT_TOKEN" \
  WA_VAULT_ADMIN_PORT="$admin" WA_VAULT_PROXY_PORT="$proxy" WA_VAULT_BIND=127.0.0.1 \
  PYTHONDONTWRITEBYTECODE=1 python3 "$root/vault/wa_vault.py" > "$TEST_RELEASE_VAULT_LOG" 2>&1 &
  TEST_RELEASE_VAULT_PID=$!
  local attempt
  for attempt in $(seq 1 200); do
    if python3 - "$admin" <<'PY' 2>/dev/null
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
    pass
PY
    then ready=1; break; fi
    sleep 0.05
  done
  [ "$ready" = 1 ] || return 8
  local created key_id public
  created="$(curl -fsS -m 20 -X POST -H "X-Vault-Token: $TEST_RELEASE_VAULT_TOKEN" \
    -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$admin/api/release-signing/key")" || return 8
  key_id="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key_id"])')" || return 8
  public="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')" || return 8
  printf 'wa-trusted-keys v1\nkey %s %s\n' "$key_id" "$public" > "$TEST_RELEASE_VAULT_KEYS"
  export WA_VAULT_ADMIN_URL="http://127.0.0.1:$admin"
  export WA_VAULT_ADMIN_TOKEN="$TEST_RELEASE_VAULT_TOKEN"
  export WA_RELEASE_KEYS="$TEST_RELEASE_VAULT_KEYS"
  TEST_RELEASE_VAULT_KEY_ID="$key_id"
  return 0
}

test_release_vault_stop() {
  [ -n "${TEST_RELEASE_VAULT_PID:-}" ] && kill "$TEST_RELEASE_VAULT_PID" 2>/dev/null
  TEST_RELEASE_VAULT_PID=""
  [ -n "${TEST_RELEASE_VAULT_DIR:-}" ] && rm -rf "$TEST_RELEASE_VAULT_DIR"
  TEST_RELEASE_VAULT_DIR=""
  return 0
}

# <dir> -> `SHA256SUMS` for that directory and its signature from the scratch vault. This is what the
# publisher does for a set it built; a test fixture is a set that was not built, and it has to be signed the
# same way or the release it stands for is one a node refuses.
test_release_sign_dir() {
  local dir="$1" name
  command -v wa_release_sign_sums >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/release-signing.sh"
  ( cd "$dir" || return 2
    for name in *; do
      [ -f "$name" ] || continue
      case "$name" in SHA256SUMS|SHA256SUMS.sig|TRUSTED-KEYS|TRUSTED-KEYS.sig) continue ;; esac
      sha256sum -- "$name"
    done > SHA256SUMS ) || return 2
  wa_release_sign_sums "$dir/SHA256SUMS" "$dir/SHA256SUMS.sig"
}
