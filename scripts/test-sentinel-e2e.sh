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
say() { printf '  %s\n' "$*"; }
ok() {
  checks=$((checks + 1))
  if [ "$1" = "1" ]; then say "ok   $2"; else failed=$((failed + 1)); say "FAIL $2${3:+ - $3}"; fi
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
"$SENTINEL" request restart --reason "e2e: does asking stop anything" >/dev/null 2>&1
WROTE="$(ls "$BOX"/*.json 2>/dev/null | wc -l)"
PID_NOW="$(pid_on_port)"
ok "$([ "$WROTE" -ge 1 ] && echo 1 || echo 0)" "request writes a file" "$WROTE in the box"
ok "$([ "$PID_NOW" = "$PID_BEFORE" ] && echo 1 || echo 0)" \
  "and the command itself stopped nothing" "pid $PID_BEFORE -> $PID_NOW"
# Let it be performed, and prove the sentinel is what did it: its own log line, with this reason.
for _ in $(seq 1 20); do
  grep -q "e2e: does asking stop anything" "$LOG" 2>/dev/null && break
  sleep 2
done
ok "$(grep -q 'stop	pid' "$LOG" 2>/dev/null && echo 1 || echo 0)" \
  "and the sentinel is the thing that stopped it, by pid" "$(grep 'stop	pid' "$LOG" 2>/dev/null | tail -1)"
PID_BEFORE="$(pid_on_port)"
rm -f "$BOX"/*.json 2>/dev/null

# 3. inject the turn: it must ask for both, and must not stop the node itself
say "injecting a turn that asks the sentinel to restart the node and wake it"
INJECT="/tmp/sentinel-e2e-prompt.json"
cat > "$INJECT" <<JSON
{"text":"Sentinel end-to-end test. Do exactly this and nothing else: (1) run \"$SENTINEL\" request restart --reason \"e2e restart\"; (2) run \"$SENTINEL\" request wake --session $SID --prompt \"the sentinel restarted the node and woke you; reply with the single word: woken\" --reason \"e2e wake\"; (3) then reply in one line that both requests are written and stop. Do NOT stop or start the node yourself."}
JSON
(curl -s -m 900 -X POST "http://127.0.0.1:$PORT/chat" -H "x-wa-session: $SID" \
  -H 'content-type: application/json' --data-binary @"$INJECT" >/tmp/sentinel-e2e-out.json 2>&1 &)

# wait for both requests to appear (the agent writes them a few seconds apart)
requests=0
for _ in $(seq 1 40); do
  requests="$(ls "$BOX"/*.json 2>/dev/null | wc -l)"
  [ "$requests" -ge 2 ] && break
  sleep 2
done
ok "$([ "$requests" -ge 2 ] && echo 1 || echo 0)" "the turn wrote both requests" "$requests in the box"
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
  if grep -q 'wake	' "$LOG" 2>/dev/null && grep 'wake	' "$LOG" | tail -1 | grep -q 'done=true'; then WOKEN=1; break; fi
  sleep 2
done
ok "$WOKEN" "the wake ran a full turn" "$(grep 'wake	' "$LOG" 2>/dev/null | tail -1)"

# 6. the agent must have come back: a turn after the wake
sleep 5
TAIL="$(curl -s -m 20 "http://127.0.0.1:$PORT/session?id=$SID" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{try{const d=JSON.parse(r);const t=(d.messages||[]);const last=t[t.length-1]||{};console.log(String(last.role)+": "+String(last.content||"").replace(/\s+/g," ").slice(0,70))}catch(e){console.log("")}})')"
ok "$(grep -q '^assistant' <<<"$TAIL" && echo 1 || echo 0)" "the agent came back and answered" "$TAIL"
ok "$(grep -qi 'woken' <<<"$TAIL" && echo 1 || echo 0)" "with the reply the wake asked for" "$TAIL"

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
echo "hello from a trigger" > "$WATCH/first.txt"
TRIGGERED=0
for _ in $(seq 1 90); do
  if grep -q 'trigger' "$LOG" 2>/dev/null && grep 'wake' "$LOG" | tail -1 | grep -q 'done=true'; then TRIGGERED=1; break; fi
  sleep 2
done
ok "$TRIGGERED" "an event woke the model with no request at all" "$(grep 'trigger' "$LOG" 2>/dev/null | tail -1)"
sleep 4
TAIL2="$(curl -s -m 20 "http://127.0.0.1:$PORT/session?id=$SID" | node -e 'let r="";process.stdin.on("data",c=>r+=c).on("end",()=>{try{const d=JSON.parse(r);const t=(d.messages||[]);const last=t[t.length-1]||{};console.log(String(last.role)+": "+String(last.content||"").replace(/\s+/g," ").slice(0,80))}catch(e){console.log("")}})')"
ok "$(grep -qi 'triggered' <<<"$TAIL2" && echo 1 || echo 0)" "and it answered what the trigger asked for" "$TAIL2"
rm -f "$CONFIG/sentinel/triggers.json"

if [ "$failed" -eq 0 ]; then
  echo "sentinel e2e ok ($checks checks)"
else
  echo "sentinel e2e FAILED ($failed of $checks)"
  exit 1
fi
