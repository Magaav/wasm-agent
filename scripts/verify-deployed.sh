#!/usr/bin/env bash
# Is the definition of "deployed" true right now, on this machine?
#
#   bash scripts/verify-deployed.sh [--commit SHA] [--capability NAME] [--port N] [--install-dir DIR]
#
# Deployed means all three hold, and nothing weaker:
#
#   1. the install record names the expected commit - `origin/main`'s head, or the commit `--commit` names;
#   2. the installed artefacts are that commit's bytes - every UI asset `scripts/upgrade.sh` ships
#      (`UI_FILES`), compared against the commit itself, not against whatever the working tree happens to
#      contain;
#   3. the node is live: `/health` answers with `"ok":true`, and with `--capability NAME` that name is in
#      `capabilities.names`.
#
# Why a second verifier beside `verify-install.sh`: they answer different questions. `verify-install.sh`
# compares the install to the *build tree* (installed binary == built binary, shipped scripts == repo, the
# watcher is watching); it is the question a deploy asks after it installs. This script compares the install
# to a *commit* and asks the live node, so it can be run from any checkout, at any later time, to answer the
# one question a coordinator must answer before saying "deployed". `--commit <sha>` verifies a specific
# published commit instead of whatever `origin/main` points at now.
#
# It reads only: no fetch (a fetch writes refs), no build, no install, no restart, no request. A mismatch
# exits non-zero and prints the check that failed with both values - expected and actual. Run it from a
# checkout, not from `<install>/scripts`: it needs commit history, so unlike `verify-install.sh` it is not
# shipped into the install.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT=""
CAPABILITY=""
PORT_ARG=""
INSTALL_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; [ -n "$COMMIT" ] || { printf 'verify-deployed: --commit needs a value\n' >&2; exit 2; }; shift 2 ;;
    --capability) CAPABILITY="${2:-}"; [ -n "$CAPABILITY" ] || { printf 'verify-deployed: --capability needs a value\n' >&2; exit 2; }; shift 2 ;;
    --port) PORT_ARG="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_ARG="${2:-}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'verify-deployed: unknown argument %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done

PORT="${PORT_ARG:-${WA_PORT:-8799}}"

# The one expression for "where does this machine's node live", shared with deploy.sh and verify-install.sh.
# A verifier with its own idea of the install directory can pass while the machine runs another one.
WA_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/service-target.sh"
[ -f "$WA_LIB" ] && . "$WA_LIB"
if [ -n "$INSTALL_ARG" ]; then
  INSTALL_DIR="$INSTALL_ARG"
elif command -v wa_install_target >/dev/null 2>&1; then
  INSTALL_DIR="$(wa_install_target)"
else
  INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
  [ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
fi

# The repo whose commits are the expected bytes. `WA_DEPLOY_ROOT` is the same override deploy.sh and
# verify-install.sh honour, so a verifier can be pointed at the tree that published the commit.
REPO="${WA_DEPLOY_ROOT:-$ROOT}"
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO="$ROOT"
fi

checks=0; failed=0
record() { # status name detail
  checks=$((checks + 1))
  case "$1" in fail) failed=$((failed + 1)) ;; esac
  case "$1" in
    ok)   printf '  ok   %s - %s\n' "$2" "${3:-}" ;;
    fail) printf '  FAIL %s - %s\n' "$2" "${3:-}" ;;
  esac
}

sha() { # file -> sha256, empty when unreadable
  [ -f "$1" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" 2>/dev/null | awk '{print $1}'
  else shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'; fi
}
short() { printf '%.12s' "${1:-<none>}"; }

printf 'verify-deployed: %s @ %s, node :%s\n' "$INSTALL_DIR" "${COMMIT:-origin/main}" "$PORT"

# --- 1. the record names the expected commit -------------------------------------------------------------
EXPECTED_FULL=""
if [ -n "$COMMIT" ]; then
  if EXPECTED_FULL="$(git -C "$REPO" rev-parse --verify --quiet "${COMMIT}^{commit}" 2>/dev/null)"; then :; else
    record fail "installed commit == expected commit" \
      "expected ${COMMIT} (--commit), actual: ${COMMIT} is not a commit in ${REPO} - the expectation cannot be read, so nothing below it can be trusted"
    printf 'verify-deployed: FAILED (1 of %d)\n' "$checks"
    exit 1
  fi
  EXPECTED_LABEL="$COMMIT"
else
  if EXPECTED_FULL="$(git -C "$REPO" rev-parse --verify --quiet "origin/main^{commit}" 2>/dev/null)"; then :; else
    record fail "installed commit == expected commit" \
      "expected origin/main, actual: ${REPO} has no origin/main ref (this verifier never fetches, so the ref must already exist)"
    printf 'verify-deployed: FAILED (1 of %d)\n' "$checks"
    exit 1
  fi
  EXPECTED_LABEL="origin/main"
fi

RECORD_FILE="$INSTALL_DIR/installed.txt"
if [ ! -f "$RECORD_FILE" ]; then
  record fail "installed commit == expected commit" "expected $(short "$EXPECTED_FULL") (${EXPECTED_LABEL}), actual: no ${RECORD_FILE}"
  printf 'verify-deployed: FAILED (1 of %d)\n' "$checks"
  exit 1
fi
RECORD_COMMIT="$(sed -n 's/^commit=//p' "$RECORD_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ -z "$RECORD_COMMIT" ]; then
  record fail "installed commit == expected commit" \
    "expected $(short "$EXPECTED_FULL") (${EXPECTED_LABEL}), actual: installed.txt records no commit="
  ACTUAL_FULL=""
elif ACTUAL_FULL="$(git -C "$REPO" rev-parse --verify --quiet "${RECORD_COMMIT}^{commit}" 2>/dev/null)"; then
  if [ "$ACTUAL_FULL" = "$EXPECTED_FULL" ]; then
    record ok "installed commit == expected commit" "installed.txt $(short "$ACTUAL_FULL"), expected $(short "$EXPECTED_FULL") (${EXPECTED_LABEL})"
  else
    record fail "installed commit == expected commit" \
      "expected $(short "$EXPECTED_FULL") (${EXPECTED_LABEL}), actual installed.txt $(short "$ACTUAL_FULL") (commit=$RECORD_COMMIT)"
  fi
else
  ACTUAL_FULL=""
  record fail "installed commit == expected commit" \
    "expected $(short "$EXPECTED_FULL") (${EXPECTED_LABEL}), actual installed.txt commit=$RECORD_COMMIT (not a commit in ${REPO})"
fi

# --- 2. the installed artefacts are that commit's bytes ---------------------------------------------------
# The UI shipping closure, mirroring `UI_FILES` in scripts/upgrade.sh. Every file there is copied from the
# built tree into <install>/ui by an upgrade; comparing them to the commit is what makes "that commit is
# what users load" a checked fact rather than a story about the deploy log.
UI_FILES="app.js components.js style.css index.html render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png"
UI_DIR="$INSTALL_DIR/ui"
for asset in $UI_FILES; do
  expected="$(git -C "$REPO" show "$EXPECTED_FULL:ui/$asset" 2>/dev/null | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')"
  actual="$(sha "$UI_DIR/$asset")"
  [ -f "$UI_DIR/$asset" ] || actual="missing"
  if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
    record ok "ui/$asset == commit" "expected $(short "$expected"), actual $(short "$actual")"
  elif [ -z "$expected" ]; then
    record fail "ui/$asset == commit" "expected ui/$asset at $(short "$EXPECTED_FULL") (${EXPECTED_LABEL}), actual: not in that commit"
  else
    record fail "ui/$asset == commit" "expected $(short "$expected") (${EXPECTED_LABEL}), actual $(short "$actual") ($UI_DIR/$asset)"
  fi
done

# --- 3. the node is live ----------------------------------------------------------------------------------
HEALTH="$(curl -s -m 6 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
if [ -z "$HEALTH" ]; then
  record fail "node answers /health on $PORT" "expected an HTTP answer from http://127.0.0.1:$PORT/health, actual: no response (is the node down?)"
else
  HEALTH_OK="$(printf '%s' "$HEALTH" | grep -o '"ok":\(true\|false\)' | head -1 | cut -d: -f2)"
  if [ "$HEALTH_OK" = "true" ]; then
    record ok "node answers /health on $PORT" "expected \"ok\":true, actual \"ok\":true"
  else
    record fail "node answers /health on $PORT" "expected \"ok\":true, actual \"ok\":${HEALTH_OK:-<not reported>}\""
  fi
  if [ -n "$CAPABILITY" ]; then
    NAMES="$(printf '%s' "$HEALTH" | sed -n 's/.*"capabilities":{[^}]*"names":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d ' "')"
    if printf '%s\n' "$NAMES" | grep -Fxq -- "$CAPABILITY"; then
      record ok "capability $CAPABILITY is present" "expected \"$CAPABILITY\" in capabilities.names, actual: present"
    else
      record fail "capability $CAPABILITY is present" "expected \"$CAPABILITY\" in capabilities.names, actual: absent (the node reports $(printf '%s\n' "$NAMES" | grep -c . ) capabilities)"
    fi
  fi
fi

# --- verdict ----------------------------------------------------------------------------------------------
if [ "$failed" -eq 0 ]; then
  printf 'verify-deployed: PASS (%d checks)\n' "$checks"
  exit 0
fi
printf 'verify-deployed: FAILED (%d of %d)\n' "$failed" "$checks"
exit 1
