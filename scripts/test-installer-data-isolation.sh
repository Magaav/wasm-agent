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
echo "installer data isolation ok ($checked row(s) checked, $runs installer invocation(s), all with their own state dir)"
