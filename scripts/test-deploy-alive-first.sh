#!/usr/bin/env bash
# ALIVE-FIRST: the deploy says it is running BEFORE it does any network work, and nobody else may take that record
# away (25/11, Fable's G).
#
# THE HOLE. scripts/deploy.sh wrote its alive file AFTER the lock claim - which is after the components preflight, the
# git fetches, the program DOWNLOAD and provisioning. On a compile install that stretch is seconds; on a DOWNLOAD
# install (every fleet node) it is the whole download, 49 s on work and minutes on a slow link. During it nothing
# said a deploy was alive, so lua/core/deploy_pause.lua released every paused session into a paid turn that found no
# install coming.
#
# WHAT IS ASSERTED HERE, and what is NOT:
#   1. the ORDER, read off the script itself: the write's line comes before the components preflight, the git
#      fetches, the download and the lock claim, and the line it prints is the one an operator is told to expect;
#   2. the RECORD'S OWNERSHIP, against the real functions: a record naming a LIVE holder is not taken over (the
#      write refuses by name), a clear from another process leaves it alone, a dead holder's record is not a
#      blocker, and our own record is cleared by us;
#   3. NOT the 30 s slow-download run through a paced channel and a paused session - that needs a real deploy and a
#      real pause, and it is named as pending rather than faked here (scripts/test-deploy-alive.lua and
#      test-deploy-alive-hold.sh, from the release-node-updates landing, are the reader's own rows).
#
#   bash scripts/test-deploy-alive-first.sh
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/deploy-alive.sh"

root="$(wa_scratch_root wa-deploy-alive-first)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
SLEEPER=""
cleanup() { [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
line_of() { grep -n -- "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }

DEPLOY="$ROOT/scripts/deploy.sh"

# ---- 1. the order, read off the script ----------------------------------------------------------------
ALIVE_LINE="$(line_of 'wa_deploy_alive_write "$DEPLOY_ALIVE_DIR"' "$DEPLOY")"
PREFLIGHT_LINE="$(line_of 'wa_components_preflight "$ROOT"' "$DEPLOY")"
FETCH_LINE="$(line_of 'git fetch -q origin' "$DEPLOY")"
DOWNLOAD_LINE="$(line_of 'wa_node_binaries_prepare "$ROOT"' "$DEPLOY")"
LOCK_LINE="$(line_of 'wa_deploy_lock_claim "$DEPLOY_LOCK"' "$DEPLOY")"
for pair in "preflight:$PREFLIGHT_LINE" "a git fetch:$FETCH_LINE" "the program download:$DOWNLOAD_LINE" "the lock claim:$LOCK_LINE"; do
  name="${pair%%:*}"; line="${pair#*:}"
  ok "$([ -n "$ALIVE_LINE" ] && [ -n "$line" ] && [ "$ALIVE_LINE" -lt "$line" ] && echo 1)" \
    "the alive record is written BEFORE $name" "alive at ${ALIVE_LINE:-none}, $name at ${line:-none}"
done
ok "$(grep -q 'deploy: running state written (pid' "$DEPLOY" && echo 1)" \
  "and the deploy says so, in the words an operator is told to expect" "$(grep -n 'running state written' "$DEPLOY" | head -1)"

# ---- 2. the record's ownership, against the real functions --------------------------------------------
DATA="$W/data"
PATH_ALIVE="$(wa_deploy_alive_path "$DATA")"
# a process that is alive and is NOT us, with the start time the record will carry
sleep 30 & SLEEPER=$!
HOLDER_START="$(wa_deploy_alive_start_time "$SLEEPER" 2>/dev/null)"
[ -n "$HOLDER_START" ] || { echo "FAIL cannot read a pid's start time (/proc): the ownership rule cannot be tested"; exit 1; }
mkdir -p "$DATA"
printf '{"pid":%s,"since":%s,"bound_seconds":1800,"pid_start":%s,"commit":"holder","by":"another-deploy"}\n' \
  "$SLEEPER" "$(date +%s)" "$HOLDER_START" > "$PATH_ALIVE"
OUT="$(wa_deploy_alive_write "$DATA" 1800 ours 2>&1)"; RC=$?
ok "$([ "$RC" = 3 ] && echo 1)" "a live holder's record is NOT taken over (the write refuses, exit 3)" "rc=$RC out=$OUT"
ok "$(printf '%s' "$OUT" | grep -q 'refused(deploy_alive_held)' && echo 1)" "and the refusal names the holder" "$OUT"
ok "$(grep -q '"pid":'"$SLEEPER" "$PATH_ALIVE" && echo 1)" "and the file still names the holder, not us" "$(cat "$PATH_ALIVE")"
wa_deploy_alive_clear "$DATA"
ok "$([ -f "$PATH_ALIVE" ] && echo 1)" "a clear from another process leaves the holder's record alone" "$( [ -f "$PATH_ALIVE" ] && echo present || echo MISSING )"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
OUT="$(wa_deploy_alive_write "$DATA" 1800 ours 2>&1)"; RC=$?
ok "$([ "$RC" = 0 ] && echo 1)" "a record whose pid is GONE is not a blocker: the write replaces it" "rc=$RC out=$OUT"
ok "$(grep -q '"pid":'"$$" "$PATH_ALIVE" && echo 1)" "and the record now names us" "$(cat "$PATH_ALIVE")"
wa_deploy_alive_clear "$DATA"
ok "$([ ! -f "$PATH_ALIVE" ] && echo 1)" "and we clear our own record" ""

# THE CONTRACT MOVED (Fable 25/11, change/guards-before-alive). "First act" is now "after the local guards,
# before 0e and before any network": a record written before a refusal is a record a deploy that never ran took,
# and it paused sessions it never used. The four checks above are unchanged and still hold; these are the new
# sentence on the same line_of/ALIVE_LINE.
G_TURN="$(grep -n 'cannot deploy from a turn running on the node it would replace' "$DEPLOY" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
G_CLI="$(grep -n 'deploying from a CLI turn needs a sentinel supervising the node' "$DEPLOY" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
G_INSTALL="$(grep -n 'refused(install_dir_missing)' "$DEPLOY" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
ZERO_E="$(grep -n '^# 0e\.' "$DEPLOY" | head -1 | cut -d: -f1)"
for pair in "the node-turn refusal:$G_TURN" "the cli-turn refusal:$G_CLI" "install_dir_missing:$G_INSTALL"; do
  name=${pair%%:*}; line=${pair#*:}
  ok "$([ -n "$line" ] && [ -n "$ALIVE_LINE" ] && [ "$ALIVE_LINE" -gt "$line" ] && echo 1)" \
    "the alive record is written AFTER $name" "alive at ${ALIVE_LINE:-none}, $name at ${line:-none}"
done
ok "$([ -n "$ZERO_E" ] && [ -n "$ALIVE_LINE" ] && [ "$ALIVE_LINE" -lt "$ZERO_E" ] && echo 1)" \
  "and BEFORE 0e, the first thing that asks the network" "alive at ${ALIVE_LINE:-none}, 0e at ${ZERO_E:-none}"

printf 'test-deploy-alive-first: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
