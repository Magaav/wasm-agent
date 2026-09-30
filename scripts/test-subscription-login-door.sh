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

# --- the printed instruction and the behaviour must agree -----------------------------------------
# The door prints: `re-run with --code <the address you landed on>`. Before this section existed, that
# spelling was a trap: a bare `--code` reached `M.login("device")`, which ignores the pasted address
# and overwrites the pending browser flow - so the user who followed the sentence lost the login the
# sentence had just started. Measured in the installed shape (no Lua root): the pending flow file read
# `"flow":"browser"`, and after the printed sentence ran the stored credential said
# `"source":"login:device"`, i.e. a different login had replaced it. This runs the sentence itself and
# requires the BROWSER flow to complete, against the credential lane's own stand-in for the auth host -
# that fixture is a node server, so without node this part is skipped visibly rather than passing.
if ! command -v node >/dev/null 2>&1; then
  echo "subscription login door: the printed-sentence check SKIPPED - node not on PATH (the auth stand-in is a node server)"
else
  MOCK_DIR="$WORK/mock"; mkdir -p "$MOCK_DIR"
  node "$ROOT/scripts/lib/openai-sub-auth-mock.mjs" --dir "$MOCK_DIR" >"$WORK/mock.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 50); do grep -q '^ready ' "$WORK/mock.log" && break; sleep 0.2; done
  export WASM_AGENT_OPENAI_SUB_AUTH_BASE="http://127.0.0.1:$(sed -n 's/^ready //p' "$WORK/mock.log" | head -1)"
  shape noroot "$WORK/sentence" login --browser
  check "$([ "$STATUS" = 0 ] && echo yes)" "the door starts a browser login with no Lua root (got $STATUS): $OUT"
  check "$([ "$(printf '%s' "$OUT" | grep -c 're-run with --code <the address you landed on>')" -ge 1 ] && echo yes)" \
    "the door prints the instruction this section is about: $OUT"
  # Quote-free regexes on purpose: a pattern written as '\"flow\":\"browser\"' inside single quotes is a
  # literal backslash-quote and never equals the bytes it is compared with - the first draft of this
  # check failed on exactly that, which is the same class of mistake as the defect it is testing for.
  grep -qE 'flow.{1,4}browser' "$WORK/sentence/login-flow.json" && PENDING=browser || PENDING=other
  check "$([ "$PENDING" = browser ] && echo yes)" "and what is pending is the browser flow (flow file: $PENDING)"
  PASTED="http://localhost:1455/auth/callback?code=PASTED-CODE&state=$(printf '%s' "$OUT" | sed -n 's/.*[?&]state=\([0-9a-f]\{32\}\).*/\1/p' | head -1)"
  # The sentence, verbatim: `wa subscription login --code <the address you landed on>`.
  shape noroot "$WORK/sentence" login --code "$PASTED"
  check "$([ "$STATUS" = 0 ] && echo yes)" "the printed sentence exits 0 in the installed shape (got $STATUS): $OUT"
  grep -qE 'source.{1,4}login:browser' "$WORK/sentence/credentials.json" && SOURCE=login:browser \
    || SOURCE="$(grep -oE 'source.{1,4}[a-z:]+' "$WORK/sentence/credentials.json" | head -1)"
  check "$([ "$SOURCE" = login:browser ] && echo yes)" \
    "and the BROWSER flow completed: the stored credential says $SOURCE, not login:device"
  # And a bare --code with nothing pending is refused by name, not turned into a device login.
  shape noroot "$WORK/nothing-pending" login --code "http://localhost:1455/auth/callback?code=X&state=deadbeef"
  check "$([ "$STATUS" != 0 ] && echo yes)" "a bare --code with no pending browser flow fails (got $STATUS): $OUT"
  check "$([ "$(printf '%s' "$OUT" | grep -c 'flow_expired')" -ge 1 ] && echo yes)" \
    "and it names flow_expired: $OUT"
  check "$([ "$(printf '%s' "$OUT" | grep -c 'codex/device')" = 0 ] && echo yes)" \
    "and printed no device-code line, so no device login was started: $OUT"
  unset WASM_AGENT_OPENAI_SUB_AUTH_BASE
  kill $MOCK_PID 2>/dev/null
  wait $MOCK_PID 2>/dev/null
fi

echo "subscription login door ok ($CHECKS checks, no Lua root and Lua root, no network beyond the local
stand-in for the auth host, no credential)"
