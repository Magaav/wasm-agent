#!/usr/bin/env bash
# Sign a release's SHA256SUMS with wa-vault's `release-signing` key: the ONE command a signing host runs,
# locally or on the node that can reach the vault's admin listener.
#
#   bash scripts/sign-release.sh <SHA256SUMS> [<SHA256SUMS.sig>]
#
# WHY A SCRIPT AND NOT A LINE INSIDE THE PIPELINE. The vault's admin listener answers on the machine that
# runs the vault - measured 13/11: 127.0.0.1:8801 on the operator's laptop, on the loopback interface, so
# nothing else may reach it - and the host that BUILDS a release is not always that machine. `wa land`
# therefore builds with `WA_RELEASE_SIGN_DEFER=1`, signs HERE (on the node whose WA_VAULT_ADMIN_URL is set)
# and hands the signature back. One command means the local path and the remote path are the same code.
#
# What it does NOT do: verify. Verification belongs to the party that decides trust - the publisher under
# deferral, `scripts/publish-artifacts-branch.sh` before a release file enters a commit, and every node
# before it installs (`scripts/lib/release-signing.sh`, `rust/wa-host/src/release.rs`) - against the trusted
# keys of the tree that ships. A signature made with a key this project does not trust is refused by them,
# by name, and never here by a guess.
#
# Exit codes are the signing library's, so a caller can decide:
#   0 signed; 2 a missing argument or file; 3 no token / unusable admin origin / no curl or python3;
#   7 no sha256 tool; 8 the vault is unreachable or refused to sign.
set -uo pipefail
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SELF_DIR/.." && pwd)"
LIB="$ROOT/scripts/lib/release-signing.sh"
[ -f "$LIB" ] || LIB="$SELF_DIR/lib/release-signing.sh"
[ -f "$LIB" ] || { printf 'sign-release: signing_library_missing: %s (scripts/lib/release-signing.sh is not beside this script)\n' "$LIB" >&2; exit 2; }
# shellcheck source=lib/release-signing.sh
. "$LIB"
SUMS="${1:-}"
OUT="${2:-}"
[ -n "$SUMS" ] || { printf 'usage: sign-release.sh <SHA256SUMS> [<SHA256SUMS.sig>]\n' >&2; exit 2; }
[ -n "$OUT" ] || OUT="$SUMS.sig"
[ -f "$SUMS" ] || { printf 'sign-release: sums_missing: %s\n' "$SUMS" >&2; exit 2; }
printf 'sign-release: signing %s with the wa-vault release-signing key at %s\n' "$SUMS" "$(wa_release_admin_url)"
wa_release_sign_sums "$SUMS" "$OUT" || exit $?
printf 'sign-release: signed %s (key %s, sha256 %s)\n' "$OUT" \
  "$(sed -n 's/^key //p' "$OUT")" "$(sed -n 's/^sha256 //p' "$OUT")"
