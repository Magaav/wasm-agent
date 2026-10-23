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
  env -u WA_COORDINATOR_SESSION -u WA_JOB_EVENT_FILE \
      WA_INSTALL_DIR="$TMP/install" WA_HEALTH_FILE="$TMP/health.json" WA_STALE_QUIET_S=0 \
      WA_STALE_DRY_RUN=0 WA_STALE_COMPACT=0 WA_SENTINEL_BIN="$TMP/sentinel-stub" \
      PATH="$TMP/bin:$PATH" "$@" bash scripts/on-stale.sh >"$TMP/out" 2>&1
  printf '%s' "$?"
}
# Idle-compaction cases: the same clean/idle fixture, but compaction is on and the fake curl records
# the request body. WA_JOB_EVENT_FILE is passed per case (or deliberately unset) so the event seam is
# the only thing that varies.
run_compact() {
  env -u WA_COORDINATOR_SESSION -u WA_JOB_EVENT_FILE \
      WA_INSTALL_DIR="$TMP/install" WA_HEALTH_FILE="$TMP/health.json" WA_STALE_QUIET_S=0 \
      WA_STALE_DRY_RUN=1 WA_STALE_COMPACT=1 PATH="$TMP/bin:$PATH" "$@" \
      bash scripts/on-stale.sh >"$TMP/out" 2>&1
  printf '%s' "$?"
}

mkdir -p "$TMP/install" "$TMP/bin"
# A fake curl. The decision cases disable idle compaction, so their only curl is the owner read.
# A POST is answered with a fixed compaction reply and its body recorded, so the idle-compaction cases
# can assert what was *sent* without a node. Nothing here reaches the network.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    -X) : ;;
    POST) post=1 ;;
  esac
done
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-d" ]; then printf '%s' "\$arg" > "$TMP/compact-body"; fi
  prev="\$arg"
done
if [ -n "\${post:-}" ]; then cat "$TMP/compact-reply.json" 2>/dev/null; exit 0; fi
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

# 11-14. The idle compaction targets the session the event names, not the newest main session.
# The event seam is the whole point: with several main threads, "newest on this node" is another
# thread, so these cases assert the request body, and that a malformed event posts nothing at all.
printf '{"node_state":{"state":"idle","busy_threads":0,"subagents_running":0,"subagents_queued":0,"queue":0}}' > "$TMP/health.json"
printf 'commit=%s\nsha256=x\n' "$head8" > "$TMP/install/installed.txt"
printf '{"ok":true,"compacted":false,"percent":12.5}\n' > "$TMP/compact-reply.json"
rm -f "$TMP/install/on-stale-state.json"

event_session='70963391-e2ff-44ed-8187-00cc77afcddc'
printf '{"session":"%s","run_id":41,"at":1792780000}\n' "$event_session" > "$TMP/event-good.json"
rm -f "$TMP/compact-body"
rc="$(run_compact WA_JOB_EVENT_FILE="$TMP/event-good.json")"
posted="$(cat "$TMP/compact-body" 2>/dev/null)"
[ "$rc" = 0 ] && [ -e "$TMP/compact-body" ] \
  && grep -Fq "\"session_id\":\"$event_session\"" "$TMP/compact-body" \
  && grep -Fq '"min_percent":40' "$TMP/compact-body" \
  && grep -q "targeted at the event session $event_session" "$TMP/out" \
  && grep -q 'idle compaction' "$TMP/out" \
  && ok "the event's own session id is forwarded to /compact with the 40 threshold ($rc)" \
  || bad "event-targeted compact: rc=$rc body=$posted out=$(cat "$TMP/out")"

# 12. serde writes the event's keys sorted, so the id must not depend on "session" coming first.
printf '{"at":1792780000,"run_id":7,"session":"%s"}\n' "$event_session" > "$TMP/event-sorted.json"
rm -f "$TMP/compact-body"
rc="$(run_compact WA_JOB_EVENT_FILE="$TMP/event-sorted.json")"
[ "$rc" = 0 ] && grep -Fq "\"session_id\":\"$event_session\"" "$TMP/compact-body" \
  && ok "a reordered event payload still names its session ($rc)" \
  || bad "sorted event: rc=$rc body=$(cat "$TMP/compact-body" 2>/dev/null) out=$(cat "$TMP/out")"

# 13. An event with no top-level session id is NOT a reason to let the route pick the newest
#     session: skip, and say which event could not be trusted. The unrelated staleness check still runs.
printf '{"run_id":9,"at":1792780000}\n' > "$TMP/event-missing.json"
rm -f "$TMP/compact-body"
rc="$(run_compact WA_JOB_EVENT_FILE="$TMP/event-missing.json")"
[ "$rc" = 0 ] && [ ! -e "$TMP/compact-body" ] \
  && grep -q 'MALFORMED EVENT' "$TMP/out" && grep -q "$TMP/event-missing.json" "$TMP/out" \
  && grep -q 'nothing to do' "$TMP/out" \
  && ok "a missing event session skips /compact visibly and the stale observation still runs ($rc)" \
  || bad "missing session: rc=$rc body=$(cat "$TMP/compact-body" 2>/dev/null) out=$(cat "$TMP/out")"

# 14. Event text is data: an id outside the safe set is refused for the request, not interpolated.
printf '{"session":"bad id; touch %s/pwned","run_id":9,"at":1792780000}\n' "$TMP" > "$TMP/event-hostile.json"
rm -f "$TMP/compact-body" "$TMP/pwned"
rc="$(run_compact WA_JOB_EVENT_FILE="$TMP/event-hostile.json")"
[ "$rc" = 0 ] && [ ! -e "$TMP/compact-body" ] && [ ! -e "$TMP/pwned" ] \
  && grep -q 'MALFORMED EVENT' "$TMP/out" && grep -q 'safe id set' "$TMP/out" \
  && ok "an unsafe event session id is refused and never executed ($rc)" \
  || bad "hostile session: rc=$rc body=$(cat "$TMP/compact-body" 2>/dev/null) out=$(cat "$TMP/out")"

# 15. No event file (a manual/direct run) keeps the route's latest-main selection, and the log says
#     that is a fallback rather than event targeting.
rm -f "$TMP/compact-body"
rc="$(run_compact)"
[ "$rc" = 0 ] && grep -Fq '{"min_percent":40}' "$TMP/compact-body" \
  && ! grep -q 'session_id' "$TMP/compact-body" \
  && grep -q 'latest-main fallback' "$TMP/out" && grep -q 'not event-targeted' "$TMP/out" \
  && ok "a manual run keeps the documented latest-main fallback and says so ($rc)" \
  || bad "manual fallback: rc=$rc body=$(cat "$TMP/compact-body" 2>/dev/null) out=$(cat "$TMP/out")"

# 16. The hook inventory must describe the event path truthfully: the event session is used, with
#     the manual fallback, and never the old "latest main session only" claim. Also a shell syntax check.
bash -n scripts/on-stale.sh && bash -n scripts/test-on-stale.sh && ok "on-stale and its test parse as shell" || bad "bash -n failed for on-stale/test-on-stale"
! grep -q 'latest main session only' lua/core/hook_events.lua && grep -q 'event.*session' lua/core/hook_events.lua \
  && grep -q 'latest-main fallback' lua/core/hook_events.lua \
  && ok "the hook inventory names the event session and the manual fallback" \
  || bad "hook inventory still claims latest-main-only: $(grep -n 'run_finished' -A 3 lua/core/hook_events.lua | head -8)"
! grep -q 'summarizes the latest main session' docs/CONTEXT-COMPACTION.md \
  && grep -q 'session_id' docs/CONTEXT-COMPACTION.md \
  && ok "the compaction doc no longer claims the idle path only takes the latest session" \
  || bad "docs/CONTEXT-COMPACTION.md still claims latest-main-only selection"

printf '\n%s checks, %s failed\n' "$checks" "$fail"
[ "$fail" -eq 0 ] && { printf 'ok onStale decision\n'; exit 0; }
printf 'FAIL onStale decision\n'; exit 1
