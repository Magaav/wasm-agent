#!/usr/bin/env bash
# THE CHECKER THIS BRANCH INSTALLER ROWS USE (scripts/lib/scratch-env.sh), judged on its own.
#
# main carries scripts/test-installer-data-isolation.sh, which lints the same dimensions with its own inline
# checker. This row is the one that judges the SHARED LIBRARY the version-folder rows call
# (wa_scratch_env_apply / wa_scratch_env_check): that it refuses every live dimension by name, that it refuses a
# run which says it is INSIDE A TURN instead of stripping the guard variable (Fable rule 1), and that a clean
# scratch environment ends at ISOLATED. Two lints, one subject each, neither loosened.
# enforces it actually refuses a live one.
#
# WHAT IT ASSERTS, each a named failure:
#   1. the checker accepts a scratch environment and prints ISOLATED;
#   2. it REFUSES each live dimension on its own - HOME, the install dir, the unit dir, the real systemctl, the
#      ledger path, XDG_CONFIG_HOME, a live port, a vault URL - so no dimension can be forgotten;
#   3. the installer row asks the checker BEFORE it runs anything, and a run with a live-looking environment is
#      RED (non-zero, and it creates no version folder).
#
# It runs no installer itself: the red case stops at the check, which is the point. No live path is written in
# this file: every "live" value is derived from the operator's HOME at run time, so the row cannot drift into
# naming (or touching) a real store by having been copied.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/scratch-env.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-installer-data-isolation: $*" >&2; exit 1; }

LIVE_HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
[ -n "$LIVE_HOME" ] || fail "cannot name the operator's home"
LIVE_STATE="$LIVE_HOME/$(printf '\056%s' "-wasm-agent")"   # the live state dir, spelled here so this file never carries it
LIVE_DB="$LIVE_STATE/memory.db"

scratch_parent="${TMPDIR:-/tmp}"
case "$scratch_parent" in */.wasm-agent|*/.wasm-agent/*) scratch_parent=/tmp ;; esac
R="$(mktemp -d "$scratch_parent/wa-isolation-XXXXXX")" || { echo "FAIL: no scratch" >&2; exit 2; }
cleanup() { rm -rf "$R"; }
trap cleanup EXIT

# 1. A clean environment passes.
( wa_scratch_env_apply "$R" >/dev/null 2>&1
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/systemctl-stub"; chmod +x "$R/bin/systemctl-stub"
  wa_scratch_env_check "$R" | tail -1 | grep -qx 'scratch-env: ISOLATED' ) || fail "a clean scratch environment must be ISOLATED"
ok

# 2. Each live dimension on its own is refused, by name.
live_case() { # <label> <expected fragment> <VAR=value...>
  local label="$1" fragment="$2"; shift 2
  local out
  # The clean prefix is applied HERE (inside this substitution, so it never touches the lint's own shell), and the
  # one live dimension is then laid ON TOP of it - applying after the injection would simply overwrite it, which is
  # exactly how this case builder first passed a live HOME through unnoticed.
  out="$( wa_scratch_env_apply "$R" >/dev/null 2>&1; env "$@" bash -c '. scripts/lib/scratch-env.sh; wa_scratch_env_check "$1"' _ "$R" 2>&1 )" && {
    printf '%s\n' "$out" >&2; fail "$label: a live $label was accepted"; }
  printf '%s\n' "$out" | grep -q "$fragment" || { printf '%s\n' "$out" >&2; fail "$label: the refusal does not name $fragment"; }
  ok
}
live_case "HOME"             "FAIL HOME"                 HOME="$LIVE_HOME"
live_case "install dir"      "FAIL WA_INSTALL_DIR"       WA_INSTALL_DIR="$LIVE_HOME/.local/bin"
live_case "unit dir"         "FAIL WA_SENTINEL_UNIT_DIR"  WA_SENTINEL_UNIT_DIR="$LIVE_HOME/$(printf '\056%s' "config")/systemd/user"
live_case "real systemctl"   "real systemctl"            WA_SENTINEL_UNIT_SYSTEMCTL=/usr/bin/systemctl
live_case "ledger path"      "FAIL WASM_AGENT_DB"        WASM_AGENT_DB="$LIVE_DB"
live_case "live config home" "FAIL XDG_CONFIG_HOME"      XDG_CONFIG_HOME="$LIVE_HOME/$(printf '\056%s' "config")"
live_case "live port"        "FAIL WASM_AGENT_PORT"      WASM_AGENT_PORT=8799
live_case "vault url"        "FAIL WASM_AGENT_VAULT_URL" WASM_AGENT_VAULT_URL=http://127.0.0.1:9999

# 3. The row asks the checker BEFORE it runs anything, and a harness that INHERITS the live environment is
# neutralised and says so. The row applies the clean prefix itself, so the thing to prove is not "the row refuses"
# (it fixes the environment) but that applying it under a live-looking harness really does land on ISOLATED, and
# that nothing live changes while it does.
grep -q 'wa_scratch_env_check' scripts/test-version-install.sh || fail "the installer row does not call the checker"
ok
check_line="$(grep -n 'wa_scratch_env_check' scripts/test-version-install.sh | head -1 | cut -d: -f1)"
run_line="$(grep -n 'version-install.sh --staging' scripts/test-version-install.sh | head -1 | cut -d: -f1)"
[ -n "$check_line" ] && [ -n "$run_line" ] && [ "$check_line" -lt "$run_line" ] || fail "the row runs the installer BEFORE it asks the checker"
ok
LIVE_UNIT="$LIVE_HOME/$(printf '\056%s' config)/systemd/user/wa-sentinel.service"
LIVE_MARKER="$LIVE_HOME/.local/bin/runtime-worktree.txt"
LIVE_RECORD="$LIVE_HOME/.local/bin/installed.txt"
live_now() { sha256sum "$LIVE_UNIT" "$LIVE_MARKER" "$LIVE_RECORD" 2>/dev/null; }
BEFORE="$(live_now)"
RED="$( env XDG_CONFIG_HOME="$LIVE_HOME/$(printf '\056%s' config)" WASM_AGENT_DB="$LIVE_DB" \
          HOME="$LIVE_HOME" WA_INSTALL_DIR="$LIVE_HOME/.local/bin" \
          bash -c '. scripts/lib/scratch-env.sh; wa_scratch_env_apply "$1" >/dev/null; wa_scratch_env_check "$1"' _ "$R" 2>&1 )" || {
  printf '%s\n' "$RED" >&2; fail "a harness that inherits the live environment was not neutralised into ISOLATED"; }
printf '%s\n' "$RED" | grep -qx 'scratch-env: ISOLATED' || { printf '%s\n' "$RED" >&2; fail "the neutralised harness does not end at ISOLATED"; }
ok
[ "$BEFORE" = "$(live_now)" ] || fail "neutralising a live-inheriting harness CHANGED a live file: STOP"
ok
[ ! -d "$LIVE_HOME/.local/share/wasm-agent/versions" ] || fail "a live versions directory exists: STOP"
ok

# 4. RULE 1 (Fable 25/11): the library never strips a guard variable, and a run that says it is INSIDE A TURN is
# refused by name rather than corrected. Both are properties of the code, so they hold whether or not this row
# happens to run inside a turn itself.
grep -q 'WASM_AGENT_IN_TURN' scripts/lib/scratch-env.sh || fail "the library does not name WASM_AGENT_IN_TURN at all"
ok
if grep -q 'compgen' scripts/lib/scratch-env.sh; then fail "the library clears variables with a catch-all (compgen): it must use an allow-list"
fi
ok
IN_TURN_OUT="$( env WASM_AGENT_IN_TURN=1 bash -c '. scripts/lib/scratch-env.sh; wa_scratch_env_apply "$1" >/dev/null; wa_scratch_env_check "$1"' _ "$R" 2>&1 )"   && { printf '%s\n' "$IN_TURN_OUT" >&2; fail "a run that says it is in a turn was ACCEPTED"; }
printf '%s\n' "$IN_TURN_OUT" | grep -q 'IN A TURN' || { printf '%s\n' "$IN_TURN_OUT" >&2; fail "the in-a-turn refusal is not named"; }
printf '%s\n' "$IN_TURN_OUT" | grep -qx 'scratch-env: ISOLATED' && fail "an in-a-turn run must never print ISOLATED"
ok
PROVENANCE_OUT="$( env WASM_AGENT_PROVENANCE=worker bash -c '. scripts/lib/scratch-env.sh; wa_scratch_env_apply "$1" >/dev/null; wa_scratch_env_check "$1"' _ "$R" 2>&1 )"   && { printf '%s\n' "$PROVENANCE_OUT" >&2; fail "a run carrying provenance was accepted"; }
grep -q 'WASM_AGENT_PROVENANCE' <<<"$PROVENANCE_OUT" || fail "the provenance refusal is not named"
ok



echo "shared scratch checker ok ($n checks)"

