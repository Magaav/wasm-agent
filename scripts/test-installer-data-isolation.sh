#!/usr/bin/env bash
# The lint this leak earns: a test that runs the INSTALLER must name its own data dir.
#
# The failure it prevents (24/11, twice in one afternoon): scripts/test-upgrade-idle.sh ran upgrade.sh with
# the inherited environment. upgrade.sh writes the deploy-pending signal before it waits -
# `DEPLOY_SIGNAL_DIR="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}"` (upgrade.sh:648), written
# with `to ${COMMIT:-unknown}` (:659) - so one run of a test wrote ~/.wasm-agent/deploy-pending.json and
# every running session on the machine paused after its step; the node never resumed them, because no
# install was coming. A test that touches the operator's data dir is not a test, it is an outage.
#
# What counts as RUNNING the installer, and what does not:
#   runs     `bash .../upgrade.sh`, `bash .../deploy.sh`, `sh`, `source`/`.` of one, `$(...)` of one, and a
#            copy of one that is then executed (a fixture that stands in for the real script)
#   does not `bash -n` (a syntax check runs nothing), grep/cat/sed/awk reads, and a stub whose NAME is
#            upgrade.sh or deploy.sh under the test's own $WORK
# A file that runs one must set WASM_AGENT_DATA, WASM_AGENT_HOME or HOME somewhere (the usual shape is a
# run() wrapper), and the row it runs must have been fixed to do so.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fails=0
checked=0
runs=0
for file in scripts/test-*.sh; do
  case "$file" in scripts/test-installer-data-isolation.sh) continue ;; esac
  [ -f "$file" ] || continue
  checked=$((checked + 1))
  # Does the file name its own state dir at all?
  sets=no
  if grep -qE '(WASM_AGENT_DATA|WASM_AGENT_HOME|HOME)=' "$file"; then sets=yes; fi
  # Which lines EXECUTE the installer? The line has to put bash/sh/source/. in front of something that IS
  # the installer - a path ending upgrade.sh or deploy.sh, or a variable the file fills with one. A line
  # that merely mentions $DEPLOY (an extract, a grep, an assignment to another name) runs nothing.
  while IFS= read -r hit; do
    line="${hit%%:*}"
    text="${hit#*:}"
    case "$text" in '#'*) continue ;; esac
    printf '%s' "$text" | grep -qE 'bash -n' && continue
    printf '%s' "$text" | grep -qE '\$WORK/(stub-)?[A-Za-z0-9_.-]*(upgrade|deploy)\.sh' && continue
    if printf '%s' "$text" | grep -qE '(^|[;|&(=]|\$\()[[:space:]]*(bash|sh|source|\.)[[:space:]]+[^|;&]*((upgrade|deploy)\.sh|[$][A-Z_]*(UPGRADE|DEPLOY))'; then
      runs=$((runs + 1))
      if [ "$sets" = no ]; then
        echo "installer-data-isolation FAILED: $file:$line runs the installer with the inherited state dir:" >&2
        echo "    $text" >&2
        echo "    set WASM_AGENT_DATA (or WASM_AGENT_HOME and HOME) to a scratch directory for that run" >&2
        fails=$((fails + 1))
      fi
    fi
  done < <(grep -nE '(upgrade|deploy)\.sh|["$]\$?[A-Z_]*(UPGRADE|DEPLOY)["$]' "$file" 2>/dev/null || true)
done

# The rule must be able to fail: the two rows this round fixed are named, so a regression in either is red.
for must in scripts/test-upgrade-idle.sh scripts/test-glibc-floor.sh; do
  grep -qE '(WASM_AGENT_DATA|WASM_AGENT_HOME)=' "$must" \
    || { echo "installer-data-isolation FAILED: $must no longer names its own state dir" >&2; fails=$((fails + 1)); }
done

[ "$fails" = 0 ] || { echo "installer-data-isolation: $fails file(s) run the installer with the real state dir" >&2; exit 1; }

# ---- THE SIX THINGS AROUND THE STATE DIR (25/11, mission release-node-updates, Fable's G condition) --------
# The lint above asks one question: does the row name its own STATE DIR? The night of 24-25/11 showed five more
# things a scratch installer run must not inherit, and each of them was a live one: WA_INSTALL_DIR unset (which
# means the operator's ~/.local/bin), the systemd unit dir (an inherited XDG_CONFIG_HOME is where the LIVE
# wa-sentinel.service lives - two scratch runs rewrote it that night), WA_SENTINEL_UNIT_SYSTEMCTL left as the
# real systemctl, WASM_AGENT_DB naming the operator's ledger, and the node's port 8799/8800.
#
# scripts/lib/install-isolation.sh answers all six for the environment the run WILL use, and its answer is what
# the harnesses below call before they start an installer. The rows here prove the guard refuses a live
# environment (the RED row the condition asks for), passes a scratch one, and that the harnesses call it.
. "$ROOT/scripts/lib/install-isolation.sh" || { echo "installer isolation FAILED: no scripts/lib/install-isolation.sh" >&2; exit 1; }

REAL_HOME="${HOME:-}"
SCRATCH_ROOT="${TMPDIR:-/tmp}"
case "$SCRATCH_ROOT" in "$REAL_HOME"|"$REAL_HOME"/*) SCRATCH_ROOT=/tmp ;; esac
PROBE="$(CDPATH= cd -- "$SCRATCH_ROOT" && pwd -P)/wa-isolation-probe-$$"
mkdir -p "$PROBE/home" "$PROBE/install" "$PROBE/units" "$PROBE/bin" "$PROBE/config" || exit 1
trap 'rm -rf "$PROBE"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$PROBE/bin/systemctl-stub"; chmod +x "$PROBE/bin/systemctl-stub"

checks=0; guard_failed=0
say_ok() { checks=$((checks + 1)); }
say_bad() { checks=$((checks + 1)); guard_failed=$((guard_failed + 1)); echo "installer isolation FAILED: $1" >&2; }

# RED: an inherited, live-looking environment is refused, and every reason is named. The home the run would use
# is an argument, because `env -i` drops everything this shell had.
live=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$REAL_HOME" \
  WA_INSTALL_DIR="$REAL_HOME/.local/bin" XDG_CONFIG_HOME="$REAL_HOME/.config" \
  WASM_AGENT_DB="$REAL_HOME/.wasm-agent/memory.db" WASM_AGENT_PORT=8799 WASM_AGENT_CLIENT_PORT=8800 \
  bash -c '. "$1/scripts/lib/install-isolation.sh"; wa_install_isolation_guard "$2" "$3"' _ "$ROOT" "$PROBE" "$REAL_HOME" 2>&1)
rc=$?
[ "${rc:-0}" != 0 ] && say_ok || say_bad 'a live-looking environment was NOT refused by the isolation guard'
for needle in "WA_INSTALL_DIR = $REAL_HOME/.local/bin" \
              "WA_SENTINEL_UNIT_DIR = $REAL_HOME/.config/systemd/user" \
              "WA_SENTINEL_UNIT_SYSTEMCTL is systemctl, the real systemctl" \
              "WASM_AGENT_DB = $REAL_HOME/.wasm-agent/memory.db" \
              "WASM_AGENT_PORT = 8799 is a live port" \
              "the data dir = $REAL_HOME/.wasm-agent"; do
  printf '%s\n' "$live" | grep -Fq "$needle" && say_ok || say_bad "the refusal does not name: $needle"
done

# GREEN: a scratch environment passes, so the guard is a check and not a wall.
green=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$PROBE/home" WASM_AGENT_HOME="$PROBE/home" \
  WA_INSTALL_DIR="$PROBE/install" XDG_CONFIG_HOME="$PROBE/config" WA_SENTINEL_UNIT_DIR="$PROBE/units" \
  WA_SENTINEL_UNIT_SYSTEMCTL="$PROBE/bin/systemctl-stub" WASM_AGENT_PORT=17999 WASM_AGENT_CLIENT_PORT=18000 \
  bash -c '. "$1/scripts/lib/install-isolation.sh"; wa_install_isolation_guard "$2" "$3"; echo "answer=$?"' _ "$ROOT" "$PROBE" "$PROBE/home" 2>&1)
printf '%s\n' "$green" | grep -q 'answer=0' && say_ok || say_bad "a fully scratch environment was refused: $green"

# THE HARNESSES CALL IT: a harness that runs an installer cannot quietly lose the isolation it was given.
for harness in scripts/test-bootstrap-gate.sh scripts/test-release-install-exec.sh scripts/test-linux-release-fetch.sh; do
  grep -Fq 'install-isolation.sh' "$harness" && say_ok || say_bad "$harness does not source scripts/lib/install-isolation.sh"
  grep -Fq 'wa_install_isolation_guard' "$harness" && say_ok || say_bad "$harness does not run the isolation guard before its installer"
  grep -Fq 'WA_SENTINEL_UNIT_DIR' "$harness" && say_ok || say_bad "$harness does not name a scratch unit dir"
done

[ "$guard_failed" = 0 ] || exit 1
echo "installer isolation ok ($checks checks: a live environment is refused, a scratch one passes, and the installer harnesses call the guard)"

echo "installer data isolation ok ($checked row(s) checked, $runs installer invocation(s), all with their own state dir)"
