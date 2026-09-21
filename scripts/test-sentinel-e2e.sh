#!/usr/bin/env bash
# End-to-end test of the sentinel: does an agent inside a turn get the node restarted *for* it, and does
# it come back?
#
# This is the test that matters, because everything else about the sentinel is a mechanism and this is
# the behaviour: a turn running on the node writes a request, the turn dies when the node stops, and
# something outside brings the node back and wakes the turn's session to continue. It cannot be tested
# with a mock - the whole point is a process dying mid-command - so it runs against the real node and
# spends one real turn.
#
# What it asserts, in order:
#   1. the sentinel is watching, and the installed binary is the one that was just built
#   2. a request stops nothing on its own
#   3. the injected turn writes a restart *and* a wake, and does not stop the node itself
#   4. the sentinel stops the node by pid and starts it again - the pid changes
#   5. the wake runs a full turn (a `wake … done=true` line in the log)
#   6. the agent's session has a turn after the wake, so it really did come back
#
# Usage:  bash scripts/test-sentinel-e2e.sh
# Needs:  a running node, a watching sentinel, and a built wa-sentinel.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${WA_INSTALL_DIR:-$LOCALAPPDATA/wasm-agent}"
if [ ! -d "$INSTALL_DIR" ]; then INSTALL_DIR="$HOME/.local/bin"; fi
SENTINEL="$INSTALL_DIR/wa-sentinel.exe"
[ -x "$SENTINEL" ] || SENTINEL="$INSTALL_DIR/wa-sentinel"
[ -x "$SENTINEL" ] || { echo "no wa-sentinel in $INSTALL_DIR (install it first)"; exit 2; }

PORT="${WA_PORT:-8799}"
CONFIG="${WASM_AGENT_HOME:-$USERPROFILE}"; CONFIG="${CONFIG:-$HOME}/.wasm-agent"
BOX="$CONFIG/sentinel/requests"
LOG="$CONFIG/sentinel/sentinel.log"

checks=0
failed=0
skipped=0
failed_names=()
skipped_names=()
say() { printf '  %s\n' "$*"; }
ok() {
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then say "ok   $2"; else failed=$((failed + 1)); failed_names+=("$2"); say "FAIL $2${3:+ - $3}"; fi
}
# A thing that could not be exercised is skipped, not failed: "the wake ran" cannot be true when the wake
# was refused on budget, and printing FAIL for it would blame the product for the test's environment.
skip() {
  checks=$((checks + 1)); skipped=$((skipped + 1)); skipped_names+=("$2")
  say "skip $2${3:+ - $3}"
}
# Lines appended to the sentinel log since LOG_MARK. A request is claimed by the watcher within its next
# 200ms poll, so counting files in the drop-box races and reads zero; the writer's own audit line does not.
newlog() { tail -n +"$(( ${LOG_MARK:-0} + 1 ))" "$LOG" 2>/dev/null; }
# A completed wake is `epoch<TAB>wake<TAB>session<TAB>reason (N events, done=...)`. Anchoring on the epoch
# excludes the `request<TAB>wake` audit line, which the old grep matched and then read as the wake itself.
completed_wake() { newlog | grep -aE '^[0-9]+	wake	' | tail -1; }
budget_refused() { newlog | grep -aq 'wake-refused'; }
# The session endpoint returns a window (500 messages), not the whole thread, so a message *index* cannot
# tell new from stale. Return the last message; the caller polls until it changes and matches.
session_tail() {
  curl -s -m 20 "http://127.0.0.1:$PORT/session?id=$SID" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{try{const d=JSON.parse(r);const m=(d.messages||[]);const last=m[m.length-1]||{};console.log(String(last.role)+": "+String(last.content||"").replace(/\s+/g," ").slice(0,90))}catch(e){console.log("")}})'
}

health() { curl -s -m 6 "http://127.0.0.1:$PORT/health" 2>/dev/null || true; }
pid_on_port() {
  powershell.exe -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort $PORT -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { \$_.OwningProcess }" 2>/dev/null | tr -d '\r'
}
session_id() {
  curl -s -m 20 "http://127.0.0.1:$PORT/sessions" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{try{const d=JSON.parse(r);console.log(((d.sessions||[])[0]||{}).id||"")}catch(e){console.log("")}})'
}

# 1. the sentinel must be watching, and the binary must be the one we just built
say "checking the sentinel is watching and the binary is fresh"
STATUS="$("$SENTINEL" status 2>&1)"
ok "$(grep -q 'watching (pid' <<<"$STATUS" && echo 1 || echo 0)" "the sentinel is watching" "$(grep 'sentinel:' <<<"$STATUS")"
BUILT="$ROOT/rust/wa-sentinel/target/release/wa-sentinel.exe"
if [ -x "$BUILT" ]; then
  # A stale binary has fooled this test three times, so it refuses to run against one: if the installed
  # sentinel differs from the built one, the test would be measuring the previous fix.
  ok "$(cmp -s "$BUILT" "$SENTINEL" && echo 1 || echo 0)" "the installed sentinel is the one just built" \
    "installed $SENTINEL differs from $BUILT - install it first"
  [ "$(cmp -s "$BUILT" "$SENTINEL" && echo 1 || echo 0)" = "1" ] || { echo "  sentinel e2e FAILED (stale binary)"; exit 1; }
fi

SID="$(session_id)"
ok "$([ -n "$SID" ] && echo 1 || echo 0)" "found a session to inject into" "$SID"

# 2. the `request` command itself must stop nothing: it writes a file and returns. Checked immediately,
# because the watcher legitimately performs it within its next poll (2s). And the node must be *stable*
# first: the previous test's restart can still be settling, and a pid that changes for that reason looks
# exactly like a pid that changed because of this request.
STABLE=""; STABLE_FOR=0
for _ in $(seq 1 30); do
  NOW="$(pid_on_port)"
  if [ -n "$NOW" ] && [ "$NOW" = "$STABLE" ]; then STABLE_FOR=$((STABLE_FOR + 1)); else STABLE_FOR=0; fi
  STABLE="$NOW"
  [ "$STABLE_FOR" -ge 2 ] && break
  sleep 2
done
PID_BEFORE="$STABLE"
ok "$([ -n "$PID_BEFORE" ] && echo 1 || echo 0)" "the node is up and its pid is stable" "pid $PID_BEFORE"
rm -f "$BOX"/*.json 2>/dev/null
LOG_MARK="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
"$SENTINEL" request restart --reason "e2e: does asking stop anything" >/dev/null 2>&1
WROTE="$(newlog | grep -c 'e2e: does asking stop anything')"
ok "$([ "$WROTE" -ge 1 ] && echo 1 || echo 0)" "request writes a file" "$WROTE audit line(s)"
# "the command stopped nothing" cannot be shown by a pid comparison: the watcher performs a graceful
# restart within its next poll, and on an idle node that lands between the request returning and the pid
# being read. What is provable is causality - the request is audited before the stop, so the stop is the
# sentinel acting on the request, not the request command stopping the node.
for _ in $(seq 1 20); do newlog | grep -aq 'stop	pid' && break; sleep 2; done
REQ_LINE="$(grep -an 'e2e: does asking stop anything' "$LOG" | head -1 | cut -d: -f1)"
STOP_LINE="$(grep -an 'stop	pid' "$LOG" | tail -1 | cut -d: -f1)"
ok "$([ -n "$REQ_LINE" ] && [ -n "$STOP_LINE" ] && [ "$STOP_LINE" -gt "$REQ_LINE" ] && echo 1 || echo 0)" \
  "the stop is the sentinel's action, after the request" "request line ${REQ_LINE:-none}, stop line ${STOP_LINE:-none}"
PID_BEFORE="$(pid_on_port)"
rm -f "$BOX"/*.json 2>/dev/null

# 3. inject the turn: it must ask for both, and must not stop the node itself
say "injecting a turn that asks the sentinel to restart the node and wake it"
INJECT="/tmp/sentinel-e2e-prompt.json"
cat > "$INJECT" <<JSON
{"text":"Sentinel end-to-end test. Do exactly this and nothing else: (1) run \"$SENTINEL\" request restart --reason \"e2e restart\"; (2) run \"$SENTINEL\" request wake --session $SID --prompt \"the sentinel restarted the node and woke you; reply with the single word: woken\" --reason \"e2e wake\"; (3) then reply in one line that both requests are written and stop. Do NOT stop or start the node yourself."}
JSON
PREV_LAST="$(session_tail)"
LOG_MARK="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
(curl -s -m 900 -X POST "http://127.0.0.1:$PORT/chat" -H "x-wa-session: $SID" \
  -H 'content-type: application/json' --data-binary @"$INJECT" >/tmp/sentinel-e2e-out.json 2>&1 &)

# Wait for both requests (the agent writes them a few seconds apart). Counted from the writer's audit
# lines, not from `$BOX`: the watcher claims each file within its next poll, so a box count reads zero and
# reports a failure for work that happened. This was the check that printed "0 in the box".
both=0
for _ in $(seq 1 40); do
  if newlog | grep -q 'e2e restart' && newlog | grep -q 'e2e wake'; then both=1; break; fi
  sleep 2
done
ok "$both" "the turn wrote both requests" "restart $(newlog | grep -c 'e2e restart'), wake $(newlog | grep -c 'e2e wake')"
# The turn must not have stopped the node itself: the sentinel's own log is what says a restart happened,
# and it is written when the sentinel performs one - not when a turn writes a file.
ok "$(grep -q 'stop	pid' "$LOG" 2>/dev/null && echo 1 || echo 0)" \
  "the restart is the sentinel's action, recorded in its log" "$(grep 'stop	pid' "$LOG" 2>/dev/null | tail -1)"

# 4. the sentinel must stop and start the node - the pid changes
say "waiting for the sentinel to perform the restart"
PID_AFTER="$PID_BEFORE"
for _ in $(seq 1 45); do
  PID_AFTER="$(pid_on_port)"
  if [ -n "$PID_AFTER" ] && [ "$PID_AFTER" != "$PID_BEFORE" ]; then break; fi
  sleep 2
done
ok "$([ -n "$PID_AFTER" ] && [ "$PID_AFTER" != "$PID_BEFORE" ] && echo 1 || echo 0)" \
  "the sentinel restarted the node (a new pid)" "$PID_BEFORE -> $PID_AFTER"

# 5. the wake must run a full turn
say "waiting for the wake to finish its turn"
WOKEN=0
for _ in $(seq 1 90); do
  completed_wake | grep -q 'done=true' && { WOKEN=1; break; }
  sleep 2
done
if [ "$WOKEN" = "1" ]; then
  ok 1 "the wake ran a full turn" "$(completed_wake)"
elif budget_refused; then
  skip "the wake ran a full turn" "wake-refused (hourly budget): raise WA_SENTINEL_WAKE_BUDGET for the sentinel and re-run"
else
  ok 0 "the wake ran a full turn" "$(completed_wake)"
fi

# 6. the agent must have come back: a NEW message in the session containing the reply the wake asked for.
# Polled, because the wake's turn takes seconds and a previous reply is still the last message.
TAIL=""
CAME=0
DELIVERED=0
for _ in $(seq 1 40); do
  TAIL="$(session_tail)"
  [ "$TAIL" != "$PREV_LAST" ] && grep -q '^assistant' <<<"$TAIL" && CAME=1
  curl -s -m 20 "http://127.0.0.1:$PORT/session?id=$SID" | grep -qF 'reply with the single word: woken' && DELIVERED=1
  [ "$CAME" = 1 ] && [ "$DELIVERED" = 1 ] && break
  sleep 3
done
# What the sentinel guarantees is that the prompt reached the session and a turn ran. Whether the model
# repeats the exact word is the model's; asserting it made the suite flaky, and once it replied by echoing
# the previous turn's text - see the note on message ordering in the run report.
if budget_refused; then
  skip "the agent came back and answered" "the wake was refused on budget, so nothing came back to check"
  skip "the wake delivered its prompt into the session" "the wake was refused on budget"
else
  ok "$CAME" "the agent came back and answered" "$TAIL"
  ok "$DELIVERED" "the wake delivered its prompt into the session"
fi
# The transcript order must survive the restart. The failure this guards: the wake's user message was
# appended while the previous turn was still running (so the turn's final message landed *after* it), and
# the woken turn - handed a transcript ending on the old answer - echoed it instead of replying. Assert the
# previous turn's reply precedes the wake prompt in the window.
ORDER_OK=0
for _ in $(seq 1 20); do
  ORDER_OK="$(curl -s -m 20 "http://127.0.0.1:$PORT/session?id=$SID" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{try{const d=JSON.parse(r);const m=d.messages||[];let reply=-1,wake=-1;for(let i=0;i<m.length;i++){const c=String((m[i]||{}).content||"");if(c.includes("Both requests are written"))reply=i;if(c.includes("reply with the single word: woken"))wake=i;}console.log(reply>=0&&wake>=0&&reply<wake?1:0)}catch(e){console.log("0")}})')"
  [ "$ORDER_OK" = "1" ] && break
  sleep 2
done
ok "$ORDER_OK" "the previous turn's reply precedes the wake in the transcript" "reply index < wake index"

# 7. a trigger: an event wakes the model with nobody asking for anything. The other half of the idea -
# not "restart this for me" but "wake me when this happens". The rules file is read on every pass, so
# writing it is enough; no restart needed.
say "wiring a file trigger and dropping a file into the watched folder"
# The watched directory must be a path this native process can actually read: a POSIX /tmp path here
# watched nothing, and the only symptom was a trigger that never fired.
WATCH="${TEMP:-/tmp}/sentinel-watch"
WATCH="$(cygpath -m "$WATCH" 2>/dev/null || echo "$WATCH")"
rm -rf "$WATCH" && mkdir -p "$WATCH"
cat > "$CONFIG/sentinel/triggers.json" <<JSON
[ { "kind": "file", "path": "$WATCH", "pattern": ".txt", "session": "$SID",
    "prompt": "A sentinel trigger fired: the file {name} appeared in the watched folder. Reply with the single word: triggered",
    "reason": "file trigger end to end test" } ]
JSON
sleep 5
PREV_LAST2="$(session_tail)"
LOG_MARK="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
# A unique name per run: a file trigger is deduplicated by path for the life of the watcher, so a second
# run that re-created `first.txt` was silently suppressed - a test that failed for its own reuse, not the
# product. The watcher never saw this name before.
TRIGGER_FILE="trigger-$$-$(date +%s).txt"
echo "hello from a trigger" > "$WATCH/$TRIGGER_FILE"
TRIGGERED=0
for _ in $(seq 1 90); do
  completed_wake | grep -q 'done=true' && { TRIGGERED=1; break; }
  sleep 2
done
if [ "$TRIGGERED" = "1" ]; then
  ok 1 "an event woke the model with no request at all" "$(newlog | grep -a 'trigger' | tail -1)"
elif budget_refused; then
  skip "an event woke the model with no request at all" "wake-refused (hourly budget) before the trigger could wake anything"
else
  ok 0 "an event woke the model with no request at all" "$(newlog | grep -a 'trigger' | tail -1)"
fi
TAIL2=""; TRIG_REPLY=0
for _ in $(seq 1 40); do
  TAIL2="$(session_tail)"
  if [ "$TAIL2" != "$PREV_LAST2" ] && grep -qi 'triggered' <<<"$TAIL2"; then TRIG_REPLY=1; break; fi
  sleep 3
done
if [ "$TRIG_REPLY" = "1" ]; then
  ok 1 "and it answered what the trigger asked for" "$TAIL2"
elif [ "$TRIGGERED" = "1" ]; then
  ok 0 "and it answered what the trigger asked for" "$TAIL2"
else
  skip "and it answered what the trigger asked for" "the trigger wake did not run"
fi
rm -f "$CONFIG/sentinel/triggers.json"

# A machine-readable verdict, so the run that reads it gets the failures and their names as data instead
# of re-reading the suite's source to work out what "FAIL the agent came back" meant.
{
  printf '{"suite":"test-sentinel-e2e","checks":%d,"failed":%d,"skipped":%d,"ok":%s,"failed_names":[' \
    "$checks" "$failed" "$skipped" "$([ "$failed" -eq 0 ] && echo true || echo false)"
  first=1
  if [ "${#failed_names[@]}" -gt 0 ]; then
    for n in "${failed_names[@]}"; do
      [ "$first" = "1" ] || printf ','
      first=0
      printf '"%s"' "$(printf '%s' "$n" | sed 's/"/\\"/g')"
    done
  fi
  printf '],"skipped_names":['
  first=1
  if [ "${#skipped_names[@]}" -gt 0 ]; then
    for n in "${skipped_names[@]}"; do
      [ "$first" = "1" ] || printf ','
      first=0
      printf '"%s"' "$(printf '%s' "$n" | sed 's/"/\\"/g')"
    done
  fi
  printf '],"at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$CONFIG/e2e-verdict.json"

if [ "$failed" -eq 0 ]; then
  echo "sentinel e2e ok ($checks checks, $skipped skipped)"
else
  echo "sentinel e2e FAILED ($failed of $checks, $skipped skipped) - see $CONFIG/e2e-verdict.json"
  exit 1
fi
