#!/usr/bin/env bash
# A RELEASE DOOR NAMES A MISSING INSTALL BEFORE IT EXECS ANYTHING (installer-refuses-a-target, item 11 - 25/11)
#
# MEASURED 25/11: a node installed from a v0.1.1 bundle has no `scripts/release-install.sh`. A release door that stayed open
# across such an install exec'd a missing file, bash exited 127, and the door answered "failed" - a word that names nothing an
# operator can act on. The wrapper in `lua/core/remote_update.lua` now checks the path ON THE PEER, before the exec, and
# answers `release_install_missing` with a code of its own (78).
#
# This row proves both halves:
#   1. STATIC - the wrapper's body carries the guard and it comes BEFORE the exec;
#   2. BEHAVIOURAL - the guard line, run in a shell against a directory that has no release-install.sh, says
#      `release_install_missing` and exits 78 instead of 127.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

BODY="lua/core/remote_update.lua"
# Both lines are found INSIDE request_release: the file has several wrappers, and the first `exec bash` in it belongs to
# another one (measured: the naive grep compared the guard against request_binary's exec and called it a failure).
start=$(grep -n 'local function request_release' "$BODY" | head -1 | cut -d: -f1)
guard_line=$(awk -v from="${start:-1}" 'NR >= from && /release_install_missing/ {print NR; exit}' "$BODY")
exec_line=$(awk -v from="${start:-1}" 'NR >= from && /exec bash/ {print NR; exit}' "$BODY")
if [ -z "$guard_line" ]; then
  bad "$BODY carries no release_install_missing guard"
elif [ -z "$exec_line" ]; then
  bad "$BODY no longer execs the release script; this row must be re-read"
elif [ "$guard_line" -lt "$exec_line" ]; then
  ok "the guard (line $guard_line) comes before the exec (line $exec_line)"
else
  bad "the guard (line $guard_line) comes AFTER the exec (line $exec_line) - a check that late never runs"
fi

# ---- behavioural: the guard's own shell, against an install with no release script -------------------------------------
S="$(mktemp -d "${TMPDIR:-/tmp}/wa-release-door.XXXXXX")"
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/install/scripts"
script="$S/install/scripts/release-install.sh"
GUARD="if [ ! -f '$script' ]; then echo \"release_install_missing: '$script' is not on this node, so this release door has nothing to run; install the release bundle or name an install with one\" >&2; exit 78; fi"
out=$(bash -c "$GUARD; exec bash '$script' whatever" 2>&1); rc=$?
if [ "$rc" -eq 78 ]; then ok "the guard exits 78, not 127"; else bad "the guard exited $rc (wanted 78 - bash's own 127 is the defect)"; fi
case "$out" in
  *release_install_missing*) ok "and it says so by name: $(printf '%s' "$out" | head -1 | cut -c1-80)" ;;
  *) bad "the guard did not name the refusal: $(printf '%s' "$out" | head -1)" ;;
esac
printf '#!/bin/sh\necho ran\n' > "$script"; chmod +x "$script"
out=$(bash -c "$GUARD; exec bash '$script' whatever" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q ran; then
  ok "and an install that HAS the script is not touched by the guard"
else
  bad "the guard refused an install that has the script (rc=$rc, $out)"
fi

if [ "$failed" -gt 0 ]; then echo "release-door-names-a-missing-install: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "release-door-names-a-missing-install ok ($checks checks)"
