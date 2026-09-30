#!/usr/bin/env bash
# The login door in BOTH shapes, because one of them was broken and this test could not see it.
#
# `wa subscription login` shipped loading `scripts/openai-sub-login.lua`, a path the binary's EMBEDDED
# registry does not carry: with a Lua root the door worked, and with no root - the installed shape
# `deploy.sh` ships and `wa-sentinel/src/instance.rs` protects - it died with
# `embedded module missing: scripts/openai-sub-login.lua` while `wa subscription status`, whose every
# call was already in `lua/`, kept working. So this test runs every command twice, once with the root
# deliberately removed and once with it set, and compares the two rather than assuming they agree.
#
# Nothing here needs the network, a credential or a model: `--browser` builds its authorize URL
# locally, and the store and Pi's auth path are pointed at scratch paths under a temporary directory.
#
#   bash scripts/test-subscription-login-door.sh <wa binary> [db path]
set -uo pipefail

BIN="${1:?usage: test-subscription-login-door.sh <wa binary> [db path]}"
DB="${2:-$BIN.sub-login-door.db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PI_AUTH="$WORK/no-such-pi-auth.json"
CHECKS=0
STATUS=0
OUT=""

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "FAIL subscription login door: $*" >&2; exit 1; }
check() {
  CHECKS=$((CHECKS + 1))
  [ "$1" = "yes" ] || fail "$2"
}

# shape <root|noroot> <store dir> <args...>: run `wa subscription ...` in one Lua shape, capturing both
# streams. The store directory is the caller's choice because it carries login-flow state: `status`
# writes nothing and must be compared between shapes byte-for-byte, while a login writes a pending flow
# and must not have one shape resume the other's (measured: sharing it made the second shape report
# "a browser login is already pending" instead of printing its own authorize URL).
shape() {
  local which="$1"; local store_dir="$2"; shift 2
  local name="$WORK/$which.out"
  if [ "$which" = "noroot" ]; then
    env -u WASM_AGENT_LUA_ROOT WASM_AGENT_OPENAI_SUB_STORE="$store_dir/credentials.json" WASM_AGENT_PI_AUTH="$PI_AUTH" \
      "$BIN" --db "$DB-$which" subscription "$@" >"$name" 2>&1
  else
    WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_OPENAI_SUB_STORE="$store_dir/credentials.json" WASM_AGENT_PI_AUTH="$PI_AUTH" \
      "$BIN" --db "$DB-$which" subscription "$@" >"$name" 2>&1
  fi
  STATUS=$?
  OUT="$(cat "$name")"
}

# --- status: both shapes, byte-for-byte the same answer -------------------------------------------
shape noroot "$WORK/status" status
check "$([ "$STATUS" = 0 ] && echo yes)" "status exits 0 with no Lua root (got $STATUS): $OUT"
NOROOT_STATUS="$OUT"
case "$OUT" in
  *"embedded module missing"*) fail "status asked for a module the registry does not carry: $OUT" ;;
esac
case "$OUT" in
  *"openai-sub credential:"*) : ;;
  *) fail "status does not describe the credential: $OUT" ;;
esac
case "$OUT" in
  *"wa subscription login"*) : ;;
  *) fail "status does not name the door that fixes an absent credential: $OUT" ;;
esac

shape root "$WORK/status" status
check "$([ "$STATUS" = 0 ] && echo yes)" "status exits 0 with a Lua root (got $STATUS): $OUT"
check "$([ "$NOROOT_STATUS" = "$OUT" ] && echo yes)" \
  "status answers identically in both shapes; with no root: [$NOROOT_STATUS] with root: [$OUT]"

# --- login --browser: the door itself, in both shapes --------------------------------------------
# The authorize URL carries a fresh state and code_challenge per run, so the two shapes are compared on
# the parts that must not differ: the line that fixes the endpoint and redirect, and the line that says
# a human is still needed.
browser_shape() {
  shape "$1" "$WORK/browser-$1" login --browser
  check "$([ "$STATUS" = 0 ] && echo yes)" "login --browser exits 0 in shape $1 (got $STATUS): $OUT"
  case "$OUT" in
    *"embedded module missing"*) fail "login --browser in shape $1 asked for a module the registry does not carry: $OUT" ;;
  esac
  case "$OUT" in
    *"https://auth.openai.com/oauth/authorize?response_type=code"*) : ;;
    *) fail "login --browser in shape $1 printed no authorize URL: $OUT" ;;
  esac
  case "$OUT" in
    *"waiting for the browser step"*) : ;;
    *) fail "login --browser in shape $1 did not say the human step is outstanding: $OUT" ;;
  esac
  printf '%s\n' "$OUT" | sed -n '1p;/waiting for the browser step/p' >"$WORK/$1.compare"
  # The state and the PKCE challenge are fresh per run by design, so they are normalised before the two
  # shapes are compared; `sort -u` collapses the module's own `host.log` copy of the same line, which
  # reaches the stream because the login emitter prints for a human and logs for the record.
  printf '%s\n' "$OUT" | sed -e 's/code_challenge=[^&]*/code_challenge=<random>/' \
    -e 's/&state=.*$//' | sort -u >"$WORK/$1.url"
}
browser_shape noroot
browser_shape root
check "$([ "$(cat "$WORK/noroot.compare")" = "$(cat "$WORK/root.compare")" ] && echo yes)" \
  "login --browser says the same thing in both shapes: no-root [$(cat "$WORK/noroot.compare")] root [$(cat "$WORK/root.compare")]"
check "$([ "$(cat "$WORK/noroot.url")" = "$(cat "$WORK/root.url")" ] && echo yes)" \
  "login --browser aims at the same endpoint in both shapes: no-root [$(cat "$WORK/noroot.url")] root [$(cat "$WORK/root.url")]"

# --- an unknown subcommand is refused the same way in both shapes --------------------------------
shape noroot "$WORK/nonsense" nonsense
NOROOT_STATUS="$STATUS"
NOROOT_OUT="$OUT"
shape root "$WORK/nonsense" nonsense
check "$([ "$NOROOT_STATUS" = 2 ] && [ "$STATUS" = 2 ] && echo yes)" \
  "an unknown subcommand exits 2 in both shapes (no-root $NOROOT_STATUS, root $STATUS)"
check "$([ "$NOROOT_OUT" = "$OUT" ] && echo yes)" \
  "and says the same thing in both shapes: no-root [$NOROOT_OUT] root [$OUT]"

echo "subscription login door ok ($CHECKS checks, no Lua root and Lua root, no network, no credential)"
