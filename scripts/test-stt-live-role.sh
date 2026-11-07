#!/usr/bin/env bash
# The speech role changed on a *running* node (docs/WHATSAPP-TRANSCRIPTION.md, "Changing the role
# live"): three real `wa` processes on localhost (a producer, a worker, a guest), a fake recognizer,
# and the worker node switched off/on three times while notes are flowing.
#
#   bash scripts/test-stt-live-role.sh
#   WA_BIN=<install>/wa bash scripts/test-stt-live-role.sh
#
# What it proves, and why one process cannot:
#
#   1. `wa stt role off` on the worker node takes effect on its next housekeeping tick, with no
#      restart: the next note is decoded by the producer's own warm worker and never by the worker
#      node;
#   2. `wa stt role worker`, and the same change made *remotely* by a master through
#      `wa call <node> services '{"action":"stt","set_role":"..."}'`, take effect the same way - three
#      switches, six notes, every note decoded exactly once. The fake recognizer's log names the
#      process that decoded each digest, so "lost" and "decoded twice" are visible as a count of
#      decodes per note that is not 1, and a lost lease as `lease_expiries` on the job;
#   3. `WASM_AGENT_STT_ROLE` in the environment still outranks the stored setting;
#   4. a guest node's remote `set_role` is refused (`forbidden_role`) and changes nothing.
#
# Everything is localhost, in a scratch directory, with a fresh temp home per node: no rendezvous
# outside this run, no deploy, no push, no real node touched. The only processes killed are the ones
# this run started (by the pid of the listening socket it allocated).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Never inherit a node's provider, home or rendezvous: what this script sets is the whole fixture.
while IFS= read -r variable; do
  case "$variable" in
    WA_BIN|WA_PORT|WA_STT_KEEP|CARGO_TARGET_DIR) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)

BIN="${WA_BIN:-}"
if [ -n "$BIN" ] && [ ! -x "$BIN" ] && [ -x "$BIN.exe" ]; then BIN="$BIN.exe"; fi
if [ -z "${BIN:-}" ] || [ ! -x "$BIN" ]; then
  BIN=""
  for candidate in "${CARGO_TARGET_DIR:-}/release/wa.exe" rust/target/release/wa.exe rust/target/release/wa; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then BIN="$candidate"; break; fi
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "stt live role: SKIPPED (no wa binary; build it with cargo build --release -p wa-host, or set WA_BIN)"
  exit 77
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
PYTHON="${WA_STT_TEST_PYTHON:-$(command -v python || command -v python3 || true)}"
if [ -z "$PYTHON" ]; then
  echo "stt live role: SKIPPED (python is needed for the fake recognizer)"
  exit 77
fi
if ! command -v node >/dev/null 2>&1; then
  echo "stt live role: SKIPPED (node is needed for the port block and JSON reads)"
  exit 77
fi

WORKER_PY="$ROOT/scripts/test-stt-fake-worker.py"
if [ ! -f "$WORKER_PY" ] || [ ! -f "$ROOT/lua/core/stt.lua" ]; then
  echo "stt live role: FAIL (the fake worker or lua/core/stt.lua is missing)"
  exit 1
fi

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

PORTS="$(node scripts/free-test-port-block.cjs 8)"
RV=$PORTS
PORT_A=$((PORTS + 1)); PORT_AC=$((PORTS + 2))
PORT_B=$((PORTS + 3)); PORT_BC=$((PORTS + 4))
PORT_C=$((PORTS + 5)); PORT_CC=$((PORTS + 6))

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-stt-live-role-XXXXXX")"
for name in a b c rv; do mkdir -p "$WORK/home-$name/.wasm-agent"; done
mkdir -p "$WORK/models"
printf 'stt-live-producer\n' > "$WORK/home-a/.wasm-agent/node.name"
printf 'stt-live-worker\n' > "$WORK/home-b/.wasm-agent/node.name"
printf 'stt-live-guest\n' > "$WORK/home-c/.wasm-agent/node.name"
A_LOG="$WORK/decode-a.log"
B_LOG="$WORK/decode-b.log"
: > "$A_LOG"
: > "$B_LOG"

winpid_on_port() { # winpid_on_port <port>
  netstat -ano 2>/dev/null | awk -v suffix=":$1" '$1=="TCP" && $4=="LISTENING" && substr($2, length($2)-length(suffix)+1)==suffix {print $5; exit}'
}
kill_pid_tree() { # kill_pid_tree <windows pid>
  [ -n "${1:-}" ] || return 0
  MSYS_NO_PATHCONV=1 taskkill /PID "$1" /T /F >/dev/null 2>&1 || true
}

PIDS=()
cleanup() {
  local status=$?
  local port pid name
  for port in "$PORT_A" "$PORT_B" "$PORT_C" "$RV"; do kill_pid_tree "$(winpid_on_port "$port")"; done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    [ -n "$pid" ] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
  if [ "$status" != "0" ] || [ "${WA_STT_KEEP:-0}" = "1" ]; then
    echo "  fixture logs kept at $WORK" >&2
    for name in rendezvous a b c; do
      [ -f "$WORK/$name.log" ] && { echo "  --- $name.log (tail) ---" >&2; tail -20 "$WORK/$name.log" >&2; }
    done
  else
    case "$WORK" in */wa-stt-live-role-??????) rm -rf -- "$WORK" 2>/dev/null || true ;; esac
  fi
  return "$status"
}
trap cleanup EXIT

FAILS=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); echo "  ok: $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL: $1" >&2; }
check() { local why="$1"; shift; if "$@"; then pass "$why"; else fail "$why"; fi; }
eq() { [ "$1" = "$2" ]; }
log_has() { grep -q -- "$2" "$1" 2>/dev/null; }
log_count() { grep -c -- "$2" "$1" 2>/dev/null | head -1; }
json_has() { printf '%s' "$1" | grep -q -- "$2"; }
lines_of() { wc -l < "$1" | tr -d ' '; }
new_line_since() { # new_line_since <file> <line-count-before> <pattern>
  tail -n "+$(( $2 + 1 ))" "$1" 2>/dev/null | grep -q -- "$3"
}

jget() { # jget <dotted.path>  (reads JSON on stdin; empty on any failure)
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{let v=JSON.parse(s);for(const k of process.argv[1].split(".")){v=v==null?undefined:v[k]}process.stdout.write(v===undefined||v===null?"":String(v))}catch(e){process.stdout.write("")}})' "$1"
}
sha_of() { node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$1"; }
hello() { curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$1/health" 2>/dev/null; }
up() { [ "$(hello "$1")" = "200" ]; }
wait_until() { # wait_until <seconds> <description> <command...>
  local deadline=$(( $(date +%s) + $1 )) what="$2"; shift 2
  while [ "$(date +%s)" -lt "$deadline" ]; do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 0.5; done
  echo "  (timed out waiting for $what)" >&2
  return 1
}

# One scratch process sharing a node's HOME (its key and its queue) with its own ledger file: the
# same escape hatch the two-node fixture uses, for `wa call` and for submitting a note with a send
# time. `env -i` is the whole environment, so nothing of this shell's node leaks in.
node_cli() { # node_cli <home-name> <args...>
  local home="$1"; shift
  env -i \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$home")" WASM_AGENT_HOME="$(native "$WORK/home-$home")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    "$BIN" --db "$(native "$WORK/cli-$home.db")" "$@"
}
node_script() { # node_script <home-name> [VAR=VALUE ...] -- runs scripts/test-stt-node-script.lua
  local home="$1"; shift
  env -i \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$home")" WASM_AGENT_HOME="$(native "$WORK/home-$home")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    WA_SCRIPT="$(native "$ROOT/scripts/test-stt-node-script.lua")" "$@" \
    "$BIN" --db "$(native "$WORK/cli-$home.db")" 2>>"$WORK/script.log"
}

# `wa stt role ...` against the *serving node's own ledger*: that is where the setting lives, and
# reading it back from there is what makes this the operator's command and not a mock.
role_set() { # role_set <home-name> <role> [producer]
  local home="$1" role="$2" producer="${3:-}"
  env -i \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$home")" WASM_AGENT_HOME="$(native "$WORK/home-$home")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    "$BIN" --db "$(native "$WORK/$home.db")" stt role "$role" ${producer:+--producer "$producer"}
}
role_status() { # role_status <home-name> [VAR=VALUE ...]
  local home="$1"; shift
  env -i \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$home")" WASM_AGENT_HOME="$(native "$WORK/home-$home")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    "$@" "$BIN" --db "$(native "$WORK/$home.db")" stt status
}

submit_note() { # submit_note <home-name> <msg>
  local home="$1" msg="$2"
  local note="$WORK/$msg.txt"
  printf 'voice note %s %s\n' "$msg" "$(date +%s%N)" > "$note"
  node_script "$home" WA_STT_ACTION=submit WA_STT_AUDIO="$(native "$note")" WA_STT_MSG="$msg"
}
job_view() { # job_view <home-name> <job>
  node_script "$1" WA_STT_ACTION=job WA_STT_JOB="$2"
}
job_state_is() { [ "$(job_view "$1" "$2" | jget ok.state)" = "$3" ]; }
status_is() { [ "$(role_status "$1" | jget "$2")" = "$3" ]; }
status_has() { role_status "$1" | grep -q -- "$2"; }

start_node() { # start_node <a|b|c> <port> <client-port> [VAR=VALUE ...]
  local name="$1" port="$2" client="$3"; shift 3
  env -i \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$name")" WASM_AGENT_HOME="$(native "$WORK/home-$name")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    WASM_AGENT_ENDPOINT="127.0.0.1:$port" \
    WA_STT_PYTHON="$(native "$PYTHON")" \
    WA_STT_WORKER="$(native "$WORKER_PY")" \
    WA_STT_MODELS="$(native "$WORK/models")" \
    WA_TEST_STT_LOG="$(native "$WORK/decode-$name.log")" \
    WA_TEST_STT_TAG="$( [ "$name" = b ] && echo worker || echo local )" \
    WA_TEST_STT_SEGMENTS=2 WA_TEST_STT_SEGMENT_MS=200 \
    WA_TEST_STT_SLOW_SEGMENTS=40 WA_TEST_STT_SLOW_SEGMENT_MS=400 "$@" \
    "$BIN" --db "$(native "$WORK/$name.db")" serve --port "$port" --client-port "$client" \
      --ui "$(native "$ROOT/ui")" > "$WORK/$name.log" 2>&1 &
  echo $!
}

echo "stt live role: rendezvous 127.0.0.1:$RV, producer :$PORT_A, worker :$PORT_B, guest :$PORT_C, work $WORK"

ID_A="$(node_script a WA_STT_ACTION=identity | jget ok.node_id)"
ID_B="$(node_script b WA_STT_ACTION=identity | jget ok.node_id)"
ID_C="$(node_script c WA_STT_ACTION=identity | jget ok.node_id)"
if [ -z "$ID_A" ] || [ -z "$ID_B" ] || [ -z "$ID_C" ] || [ "$ID_A" = "$ID_B" ] || [ "$ID_B" = "$ID_C" ]; then
  echo "FAIL: could not read three distinct node identities ($ID_A / $ID_B / $ID_C)" >&2
  exit 1
fi
pass "three distinct node identities exist"

# C is a rendezvous *admin* on purpose: a guest cannot even list peers (`/nodes` answers 403), so the
# interesting refusal - the target's own - needs a caller that can reach it. B trusts only A as an
# operator (`WASM_AGENT_TRUSTED_MASTERS`), which is what makes C a non-admin from B's side.
env -i PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
  TEMP="${TEMP:-}" TMP="${TMP:-}" \
  HOME="$(native "$WORK/home-rv")" WASM_AGENT_HOME="$(native "$WORK/home-rv")" WASM_AGENT_MANAGED=0 \
  WASM_AGENT_NETWORK_ADMINS="$ID_A,$ID_B,$ID_C" \
  "$BIN" --db "$(native "$WORK/rv.db")" rendezvous --port "$RV" --bind 127.0.0.1 \
  > "$WORK/rendezvous.log" 2>&1 &
PIDS+=("$!")
if ! wait_until 30 "the rendezvous on :$RV" up "$RV"; then echo "FAIL: the rendezvous did not start"; exit 1; fi

# The roles come from the *setting*, not from the environment: an environment value would outrank
# every change made afterwards, which is exactly what the last checks prove it still does.
SET_A="$(role_set a producer)"
SET_B="$(role_set b worker stt-live-producer)"
SET_C="$(role_set c off)"
check "the producer's role is stored ($SET_A)" json_has "$SET_A" '"ok":true'
check "the worker's role and producer are stored ($SET_B)" json_has "$SET_B" '"ok":true'
check "the setting, not the environment, is what the node reads" json_has "$SET_B" '"source":"setting"'
check "the third node is stored off, so it only serves and calls" json_has "$SET_C" '"ok":true'

PID_A="$(start_node a "$PORT_A" "$PORT_AC" WASM_AGENT_STT_GRACE_MS=8000)"; PIDS+=("$PID_A")
PID_B="$(start_node b "$PORT_B" "$PORT_BC" WASM_AGENT_TRUSTED_MASTERS="$ID_A")"; PIDS+=("$PID_B")
PID_C="$(start_node c "$PORT_C" "$PORT_CC")"; PIDS+=("$PID_C")
for node in "producer $PORT_A" "worker $PORT_B" "guest $PORT_C"; do
  set -- $node
  if ! wait_until 60 "the $1 on :$2" up "$2"; then echo "FAIL: the $1 node did not start"; exit 1; fi
done
pass "three nodes are up"
check "the producer node booted in its stored role" wait_until 30 "the producer's boot line" log_has "$WORK/a.log" "role=producer.*(boot)"
check "the worker node booted in its stored role" wait_until 30 "the worker's boot line" log_has "$WORK/b.log" "role=worker.*(boot)"

wait_peers() { [ -n "$(node_script a WA_STT_ACTION=peers | jget ok.peers.1.name)" ]; }
if ! wait_until 90 "the nodes to register with the rendezvous" wait_peers; then
  echo "FAIL: the nodes never saw each other"; exit 1
fi
if ! wait_until 90 "the producer to admit the worker" log_has "$WORK/a.log" "worker attached:"; then
  fail "the producer never admitted the worker"
else
  pass "the producer admitted the worker ($(grep -o 'worker attached: .*' "$WORK/a.log" | head -1))"
fi
sleep 1

queue_is() { # queue_is <done> <dead> <expired> <ready>
  local status
  status="$(node_script a WA_STT_ACTION=status)"
  eq "$(printf '%s' "$status" | jget ok.queue.done)" "$1" &&
    eq "$(printf '%s' "$status" | jget ok.queue.dead)" "$2" &&
    eq "$(printf '%s' "$status" | jget ok.queue.expired)" "$3" &&
    eq "$(printf '%s' "$status" | jget ok.queue.ready)" "$4"
}

# ---- the switches --------------------------------------------------------------------------------
ensure_worker() { # ensure_worker <label>: a switch that changes nothing is not a switch
  if [ "$(role_status b | jget role)" = "worker" ]; then
    pass "$1: the worker node is already a worker, nothing to apply"
  else
    switch_on "$1" cli
  fi
}

switch_off() { # switch_off <round> <cli|remote>
  local round="$1" how="$2" answer mark
  mark="$(lines_of "$WORK/b.log")"
  if [ "$how" = "remote" ]; then
    answer="$(node_cli a call stt-live-worker services '{"action":"stt","set_role":"off"}')"
    check "round $round: a master's remote set_role answers ok ($answer)" json_has "$answer" '"ok":true'
    check "round $round: the remote change is audited" json_has "$answer" '"audited":true'
  else
    answer="$(role_set b off)"
    check "round $round: wa stt role off answers ok ($answer)" json_has "$answer" '"ok":true'
  fi
  # Any *new* line of the node's own log saying `role=off` is the running node applying the change:
  # a CLI switch is only visible there (it is another process), a remote one is applied in-process
  # and then confirmed by the tick. Counting new lines, not total ones, keeps a switch that logs
  # twice from being read as two switches - and one wait cannot be satisfied by an earlier round.
  if wait_until 20 "the worker node to reconfigure itself off" \
      new_line_since "$WORK/b.log" "$mark" 'role=off'; then
    pass "round $round: the running worker node applied the switch (its own log says role=off)"
  else
    fail "round $round: the worker node never applied the switch ($how)"
  fi
  sleep 2   # a take already in flight settles; the thread is idle before the next note is submitted
}

switch_on() { # switch_on <round> <cli|remote>
  local round="$1" how="$2" answer mark
  mark="$(lines_of "$WORK/b.log")"
  if [ "$how" = "remote" ]; then
    answer="$(node_cli a call stt-live-worker services '{"action":"stt","set_role":"worker","producer":"stt-live-producer"}')"
    check "round $round: a master's remote set_role worker answers ok ($answer)" json_has "$answer" '"ok":true'
  else
    answer="$(role_set b worker stt-live-producer)"
    check "round $round: wa stt role worker answers ok ($answer)" json_has "$answer" '"ok":true'
  fi
  if wait_until 20 "the worker node to reconfigure itself as a worker" \
      new_line_since "$WORK/b.log" "$mark" 'role=worker'; then
    pass "round $round: the running worker node applied the switch (its own log says role=worker)"
  else
    fail "round $round: the worker node never applied the switch ($how)"
  fi
  sleep 2
}

note() { # note <name> <expect: worker|local>
  local msg="$1" expect="$2" answer job sha lapses in_a in_b
  answer="$(submit_note a "$msg")"
  job="$(printf '%s' "$answer" | jget ok.job)"
  if [ -z "$job" ]; then fail "the producer enqueued $msg: $answer"; return 1; fi
  sha="$(sha_of "$WORK/$msg.txt")"
  if wait_until 150 "$msg to settle" job_state_is a "$job" done; then
    pass "$msg settled done (job $job)"
  else
    fail "$msg never reached done ($(job_view a "$job" | jget ok.state))"
  fi
  in_a="$(log_count "$A_LOG" "$sha")"; in_b="$(log_count "$B_LOG" "$sha")"
  if [ "$(( ${in_a:-0} + ${in_b:-0} ))" = "1" ]; then
    pass "$msg was decoded exactly once (local=${in_a:-0} worker=${in_b:-0})"
  else
    fail "$msg was decoded $(( ${in_a:-0} + ${in_b:-0} )) times (local=${in_a:-0} worker=${in_b:-0})"
  fi
  lapses="$(job_view a "$job" | jget ok.lease_expiries)"
  check "$msg left no lease behind (lease_expiries=$lapses)" eq "${lapses:-x}" 0
  case "$expect" in
    worker) check "$msg was decoded by the worker node, not the producer" eq "${in_b:-0}" 1 ;;
    local)  check "$msg was decoded by the producer itself, not the worker" eq "${in_a:-0}" 1 ;;
  esac
}

# A warm-up note: the producer prefers a remote it has *seen*, and an admitted take is what makes the
# grace apply. Either node decoding it is correct, so nothing is asserted about who did.
warm_job="$(submit_note a warm | jget ok.job)"
if [ -n "$warm_job" ] && wait_until 150 "the warm-up note to settle" job_state_is a "$warm_job" done; then
  pass "the warm-up note settled (job $warm_job); the remote path has now been seen"
else
  fail "the warm-up note never settled"
fi
sleep 2

for round in 1 2 3; do
  # One round switches locally, the next remotely (a master's `wa call`), so both operator paths are
  # exercised against a live node and neither is only unit-tested.
  off_how="cli"; [ "$round" = "2" ] && off_how="remote"
  on_how="remote"; [ "$round" = "2" ] && on_how="cli"
  note "on-$round" worker
  switch_off "$round" "$off_how"
  note "off-$round" local
  switch_on "$round" "$on_how"
done

# ---- the queue: everything settled, nothing dead ------------------------------------------------
note "final" worker

# ---- a switch *mid-decode*: the note is finished and settled by the node that took it -----------
# This is the "no lost lease" case. A settle nobody answers would lapse the lease, and the producer's
# own worker would decode the same note a second time. `SLOW` makes the fake recognizer decode for
# ~16 s, so the switch lands while the worker node is holding the lease.
ensure_worker "mid"
mid_mark="$(lines_of "$WORK/b.log")"
mid_answer="$(submit_note a SLOW-midswitch)"
mid_job="$(printf '%s' "$mid_answer" | jget ok.job)"
mid_sha="$(sha_of "$WORK/SLOW-midswitch.txt")"
if [ -z "$mid_job" ]; then
  fail "the producer enqueued the long note: $mid_answer"
else
  pass "the producer enqueued the long note as job $mid_job"
fi
if wait_until 60 "the worker node to start the long decode" log_has "$B_LOG" "$mid_sha"; then
  pass "the worker node is decoding the long note (its recognizer logged the digest)"
else
  fail "the worker node never started the long note"
fi
role_set b off > /dev/null
if wait_until 180 "the long note to settle after the switch" job_state_is a "$mid_job" done; then
  pass "the note finished and settled after the switch, so the lease was not lost"
else
  fail "the long note never settled after the switch ($(job_view a "$mid_job" | jget ok.state))"
fi
mid_in_a="$(log_count "$A_LOG" "$mid_sha")"; mid_in_b="$(log_count "$B_LOG" "$mid_sha")"
check "the long note was decoded once, by the worker (local=${mid_in_a:-0} worker=${mid_in_b:-0})" \
  eq "$(( ${mid_in_a:-0} ))|$(( ${mid_in_b:-0} ))" "0|1"
mid_lapses="$(job_view a "$mid_job" | jget ok.lease_expiries)"
check "the long note left no lease behind (lease_expiries=$mid_lapses)" eq "${mid_lapses:-x}" 0
check "the switch was applied by the running node (a new role=off line)" \
  new_line_since "$WORK/b.log" "$mid_mark" 'role=off'
switch_on "mid2" cli

check "the queue settled all 9 notes and dropped none (done=$(node_script a WA_STT_ACTION=status | jget ok.queue.done), dead=$(node_script a WA_STT_ACTION=status | jget ok.queue.dead), expired=$(node_script a WA_STT_ACTION=status | jget ok.queue.expired), ready=$(node_script a WA_STT_ACTION=status | jget ok.queue.ready))" \
  queue_is 9 0 0 0

# ---- the environment still wins -----------------------------------------------------------------
overridden="$(role_status b WASM_AGENT_STT_ROLE=producer)"
check "WASM_AGENT_STT_ROLE still outranks the stored setting (role=$(printf '%s' "$overridden" | jget role), source=$(printf '%s' "$overridden" | jget role_source))" \
  json_has "$overridden" '"role_source":"env"'
check "the stored setting is still reported next to it" json_has "$overridden" '"role":"worker"'

# ---- a non-admin caller is refused --------------------------------------------------------------
# `access log` is the node's own audit trail (`access_events`): one row per applied `stt.set_role`,
# naming the caller. A refusal must not add one.
audit_rows() { # audit_rows <home-name>
  env -i PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$1")" WASM_AGENT_HOME="$(native "$WORK/home-$1")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    "$BIN" --db "$(native "$WORK/$1.db")" access log 2>/dev/null | grep -o 'stt.set_role' | wc -l | tr -d ' '
}
BEFORE_AUDIT="$(audit_rows b)"
guest_call="$(node_cli c call stt-live-worker services '{"action":"stt","set_role":"off"}')"
check "a caller this node does not list as an operator is refused ($guest_call)" json_has "$guest_call" '"error":"forbidden_role"'
check "the refused call did not change the worker's setting" status_has b '"role":"worker"'
check "the refused call added no audit row (rows=$BEFORE_AUDIT -> $(audit_rows b))" eq "$(audit_rows b)" "$BEFORE_AUDIT"

echo
if [ "$FAILS" != "0" ]; then
  echo "stt live role FAILED ($FAILS of $CHECKS checks)" >&2
  exit 1
fi
echo "stt live role ok ($CHECKS checks)"
