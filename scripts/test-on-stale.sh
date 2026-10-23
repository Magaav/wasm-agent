#!/usr/bin/env bash
# Test the onStale decision, not the schedule. Every case feeds a fixed /health payload (WA_HEALTH_FILE)
# and a fixed installed.txt, because the thing being asserted is: WHEN may this node act, and when must it
# refuse or hold. A test that races a live node's own state would prove nothing about the decision.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/on-stale-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail=0; checks=0

ok()   { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad()  { checks=$((checks+1)); fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
run()  { env -u WA_COORDINATOR_SESSION WA_INSTALL_DIR="$TMP/install" WA_HEALTH_FILE="$TMP/health.json" WA_STALE_QUIET_S=0 WA_STALE_DRY_RUN=1 \
          WA_STALE_COMPACT=0 bash scripts/on-stale.sh >"$TMP/out" 2>&1; printf '%s' "$?"; }
# A non-dry run with its own PATH/owner fixture and a sentinel stub that records its arguments. It never
# installs anything: the stub only writes the argv it was given.
run_stale() {
  env -u WA_COORDINATOR_SESSION \
      WA_INSTALL_DIR="$TMP/install" WA_HEALTH_FILE="$TMP/health.json" WA_STALE_QUIET_S=0 \
      WA_STALE_DRY_RUN=0 WA_STALE_COMPACT=0 WA_SENTINEL_BIN="$TMP/sentinel-stub" \
      PATH="$TMP/bin:$PATH" "$@" bash scripts/on-stale.sh >"$TMP/out" 2>&1
  printf '%s' "$?"
}

mkdir -p "$TMP/install" "$TMP/bin"
# A fake curl: the script disables idle compaction for these cases, so the only curl is the owner read.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
cat "$TMP/owner.json" 2>/dev/null
EOF
# The sentinel stub records the request argv; it is never a real installer.
cat > "$TMP/sentinel-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/request-args"
printf 'requested deploy: %s\n' "\$*"
EOF
chmod +x "$TMP/bin/curl" "$TMP/sentinel-stub"

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
head40="$(git -C "$TMP/tree" rev-parse origin/main)"

# 1. aggregate busy (including subagents) is not a veto here: /compact is the authority on a
# real main run. With compaction disabled for the fixture, no install request is made.
printf '{"node_state":{"state":"busy","busy_threads":1,"subagents_running":0,"subagents_queued":0,"queue":0}}' > "$TMP/health.json"
printf 'commit=%s
sha256=x
' "$head8" > "$TMP/install/installed.txt"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'nothing to do' "$TMP/out" && ok "busy/subagent state does not block the maintenance check ($rc)" || bad "busy node: rc=$rc out=$(cat "$TMP/out")"

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

# 5. idle and behind: STALE, and in dry run it stops before proving a deploy target or building.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'STALE' "$TMP/out" && grep -q 'would be HELD' "$TMP/out" && ok "behind + idle is the one case that acts, and dry run names the held prerequisite ($rc)" || bad "stale: rc=$rc out=$(cat "$TMP/out")"

# 6. the edge is remembered: the same (installed -> head) pair does not act twice.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
printf '{"last_busy_at":0,"acted_key":"deadbee1->%s","head":"%s","at":1}\n' "$head8" "$head8" > "$TMP/install/on-stale-state.json"
rc="$(run)"
[ "$rc" = 0 ] && grep -q 'already acted' "$TMP/out" && ok "one edge, one request ($rc)" || bad "dedupe: rc=$rc out=$(cat "$TMP/out")"

# 7. stale but no proved parent session: a visible hold, not a guessed session and not a request.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json" "$TMP/install/on-stale-held.json" "$TMP/request-args"
printf '{"session":{"id":"parent-fixture","user_id":"owner-fixture"}}\n' > "$TMP/owner.json"
rc="$(run_stale)"
[ "$rc" = 2 ] && grep -q 'HELD (deploy_parent_session_unproved)' "$TMP/out" \
  && grep -q '"code":"deploy_parent_session_unproved"' "$TMP/install/on-stale-held.json" \
  && [ ! -e "$TMP/request-args" ] \
  && ok "an unproved parent session is held visibly, with no request ($rc)" \
  || bad "session hold: rc=$rc out=$(cat "$TMP/out") held=$(cat "$TMP/install/on-stale-held.json" 2>/dev/null) args=$(cat "$TMP/request-args" 2>/dev/null)"

# 8. stale with a session the node cannot prove an owner for: another visible hold, still no request.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json" "$TMP/install/on-stale-held.json" "$TMP/request-args"
printf '{"error":"unknown_session"}\n' > "$TMP/owner.json"
rc="$(run_stale WA_COORDINATOR_SESSION=parent-fixture)"
[ "$rc" = 2 ] && grep -q 'HELD (deploy_owner_unproved)' "$TMP/out" \
  && grep -q '"code":"deploy_owner_unproved"' "$TMP/install/on-stale-held.json" \
  && [ ! -e "$TMP/request-args" ] \
  && ok "an unproved owner is held visibly, with no request ($rc)" \
  || bad "owner hold: rc=$rc out=$(cat "$TMP/out") held=$(cat "$TMP/install/on-stale-held.json" 2>/dev/null) args=$(cat "$TMP/request-args" 2>/dev/null)"

# 9. stale with a proved source/session/owner: exactly one deploy request, never upgrade and never a build.
printf 'commit=deadbee1\nsha256=x\n' > "$TMP/install/installed.txt"
rm -f "$TMP/install/on-stale-state.json" "$TMP/install/on-stale-held.json" "$TMP/request-args"
printf '{"session":{"id":"parent-fixture","user_id":"owner-fixture"}}\n' > "$TMP/owner.json"
rc="$(run_stale WA_COORDINATOR_SESSION=parent-fixture)"
args="$(cat "$TMP/request-args" 2>/dev/null)"
[ "$rc" = 0 ] && grep -q 'deploy requested' "$TMP/out" \
  && grep -Fq -- "request deploy --expected-sha $head40 --owner owner-fixture --session parent-fixture" "$TMP/request-args" \
  && ! grep -Fq -- "upgrade" "$TMP/request-args" \
  && ! grep -Fq -- "--binary" "$TMP/request-args" \
  && [ ! -e "$TMP/install/on-stale-held.json" ] \
  && grep -q "\"acted_key\":\"deadbee1->$head8\"" "$TMP/install/on-stale-state.json" \
  && ok "proved values request deploy with the full SHA and no installer in onStale ($rc)" \
  || bad "deploy request: rc=$rc out=$(cat "$TMP/out") args=$args state=$(cat "$TMP/install/on-stale-state.json" 2>/dev/null)"

# 10. the observer is event-triggered, not a 30-second schedule.
grep -q '"topic": "node.run_finished"' jobs/on-stale.json   && ok "onStale is triggered by a main-run completion event"   || bad "onStale job trigger is not node.run_finished: $(cat jobs/on-stale.json)"

printf '\n%s checks, %s failed\n' "$checks" "$fail"
[ "$fail" -eq 0 ] && { printf 'ok onStale decision\n'; exit 0; }
printf 'FAIL onStale decision\n'; exit 1
