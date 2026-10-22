#!/usr/bin/env bash
# Test the onStale decision, not the schedule. Every case feeds a fixed /health payload (WA_HEALTH_FILE)
# and a fixed installed.txt, because the thing being asserted is: WHEN may this node act, and when must it
# refuse. A test that races a live node's own state would prove nothing about the decision.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/on-stale-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail=0; checks=0

ok()   { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad()  { checks=$((checks+1)); fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
run()  { WA_INSTALL_DIR="$TMP/install" WA_HEALTH_FILE="$TMP/health.json" WA_STALE_QUIET_S=0 WA_STALE_DRY_RUN=1 \
          bash scripts/on-stale.sh >"$TMP/out" 2>&1; printf '%s' "$?"; }

mkdir -p "$TMP/install"
# A CLEAN fixture tree with its own origin: the script refuses a dirty worktree by design, so testing it
# against this repository (which its author is editing) could only ever test the refusal.
git init -q --bare "$TMP/origin.git" || exit 1
git init -q "$TMP/tree" || exit 1
git -C "$TMP/tree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one || exit 1
git -C "$TMP/tree" branch -M main
git -C "$TMP/tree" remote add origin "$TMP/origin.git"
git -C "$TMP/tree" push -q origin main || exit 1
git -C "$TMP/tree" fetch -q origin
printf '%s\n' "$TMP/tree" > "$TMP/install/runtime-worktree.txt"
head8="$(git -C "$TMP/tree" rev-parse --short=8 origin/main)"

# 1. busy: never act.
printf '{"node_state":{"state":"busy","busy_threads":1,"subagents_running":0,"subagents_queued":0,"queue":0}}' > "$TMP/health.json"
printf 'commit=%s\nsha256=x\n' "$head8" > "$TMP/install/installed.txt"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'not stale' "$TMP/out" && ok "busy node is not acted on ($rc)" || bad "busy node: rc=$rc out=$(cat "$TMP/out")"

# 2. upgrading: never stack a second install.
printf '{"node_state":{"state":"upgrading"},"upgrading":{"state":"upgrading","phase":"stopping"}}' > "$TMP/health.json"
rm -f "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'already in progress' "$TMP/out" && ok "an install in progress is not stacked ($rc)" || bad "upgrading: rc=$rc out=$(cat "$TMP/out")"

# 3. idle but the install record cannot name a commit: REFUSE, loudly.
printf '{"node_state":{"state":"idle","busy_threads":0,"subagents_running":0,"subagents_queued":0,"queue":0}}' > "$TMP/health.json"
printf 'commit=unknown\nbranch=unknown\ndirty=unknown\n' > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 2 ] && grep -q 'REFUSED' "$TMP/out" && ok "commit=unknown is a refusal, not a silent exit ($rc)" || bad "unknown record: rc=$rc out=$(cat "$TMP/out")"

# 4. idle and already on origin/main: nothing to do.
printf 'commit=%s\nsha256=x\n' "$head8" > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'nothing to do' "$TMP/out" && ok "up-to-date install does nothing ($rc)" || bad "up to date: rc=$rc out=$(cat "$TMP/out")"

# 5. idle and behind: STALE, and in dry run it stops before building.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'STALE' "$TMP/out" && grep -q 'dry run' "$TMP/out" && ok "behind + idle is the one case that acts ($rc)" || bad "stale: rc=$rc out=$(cat "$TMP/out")"

# 6. the edge is remembered: the same (installed -> head) pair does not act twice.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
printf '{"last_busy_at":0,"acted_key":"deadbee1->%s","head":"%s","at":1}\n' "$head8" "$head8" > "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'already acted' "$TMP/out" && ok "one edge, one request ($rc)" || bad "dedupe: rc=$rc out=$(cat "$TMP/out")"

printf '\n%s checks, %s failed\n' "$checks" "$fail"
[ "$fail" -eq 0 ] && { printf 'ok onStale decision\n'; exit 0; }
printf 'FAIL onStale decision\n'; exit 1
