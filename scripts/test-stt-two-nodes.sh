#!/usr/bin/env bash
# Two `wa` processes on localhost: the producing node and an `stt_worker` node, end to end over the
# real signed peer call, with a fake recognizer (`scripts/test-stt-fake-worker.py`).
#
#   bash scripts/test-stt-two-nodes.sh
#   WA_BIN=rust/target/release/wa bash scripts/test-stt-two-nodes.sh   # or the binary on PATH
#
# What it proves, and why it cannot be proved in one process:
#
#   1. a note submitted on the producer is decoded by the *worker node* - the library's remote path,
#      the `stt.requests` queue and the signed peer call, with three real processes (a rendezvous,
#      the producer, the worker) and two real node identities;
#   2. the worker node is killed mid-job: the lease lapses on the producer and the producer's own warm
#      worker finishes the same note (`lease_expiries` on the record, `local` in the decode log);
#   3. a note past its five-minute window is refused at enqueue and never decoded by either node -
#      the fake recognizer's own log (one line per decode, a digest, never the audio) is the evidence;
#   4. no node log carries transcript text, and each node ran the role it was configured with.
#
# The fake recognizer writes `<tag> <sha256>` per decode to `WA_TEST_STT_LOG`; the test knows which
# note it submitted and can therefore say *who* decoded it and that the stale note was never decoded.
# A note whose bytes contain `SLOW` decodes for ~10 s, which is the window the kill needs.
#
# Everything runs in a scratch directory on 127.0.0.1; nothing is deployed, nothing is pushed, and the
# only processes killed are the ones listening on this run's own three ports.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Never inherit a node's provider, home or rendezvous: what this script sets is the whole fixture.
while IFS= read -r variable; do
  case "$variable" in
    WA_BIN|WA_PORT|WA_STT_KEEP) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)

BIN="${WA_BIN:-}"
if [ -n "$BIN" ] && [ ! -x "$BIN" ] && [ -x "$BIN.exe" ]; then BIN="$BIN.exe"; fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  BIN=""
  for candidate in "${CARGO_TARGET_DIR:-}/release/wa.exe" rust/target/release/wa.exe rust/target/release/wa; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then BIN="$candidate"; break; fi
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "stt two nodes: SKIPPED (no wa binary; build it with cargo build --release -p wa-host, or set WA_BIN)"
  exit 77
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
PYTHON="${WA_STT_TEST_PYTHON:-$(command -v python || command -v python3 || true)}"
if [ -z "$PYTHON" ]; then
  echo "stt two nodes: SKIPPED (python3 is needed for the fake recognizer)"
  exit 77
fi
if ! command -v node >/dev/null 2>&1; then
  echo "stt two nodes: SKIPPED (node is needed for the port block and JSON reads)"
  exit 77
fi
WORKER_PY="$ROOT/scripts/test-stt-fake-worker.py"
if [ ! -f "$ROOT/lua/core/stt.lua" ]; then
  echo "stt two nodes: FAIL (lua/core/stt.lua is missing: the worker role has no node side)"
  exit 1
fi

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

PORTS="$(node scripts/free-test-port-block.cjs 5)"
RV=$PORTS
PORT_A=$((PORTS + 1))
PORT_AC=$((PORTS + 2))
PORT_B=$((PORTS + 3))
PORT_BC=$((PORTS + 4))

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-stt-two-nodes-XXXXXX")"
mkdir -p "$WORK/models" "$WORK/home-a/.wasm-agent" "$WORK/home-b/.wasm-agent" "$WORK/home-rv/.wasm-agent"
printf 'stt-producer\n' > "$WORK/home-a/.wasm-agent/node.name"
printf 'stt-worker\n' > "$WORK/home-b/.wasm-agent/node.name"
A_LOG="$WORK/decode-a.log"
B_LOG="$WORK/decode-b.log"
: > "$A_LOG"
: > "$B_LOG"

# The pids are read from the listening sockets this run allocated, not from a process name or a
# command line: three unique loopback ports are the fixture's own identity on this machine, and
# `taskkill` needs the Windows pid, which `netstat -ano` gives. Nothing else is ever killed.
winpid_on_port() { # winpid_on_port <port>
  netstat -ano 2>/dev/null | awk -v suffix=":$1" '$1=="TCP" && $4=="LISTENING" && substr($2, length($2)-length(suffix)+1)==suffix {print $5; exit}'
}
kill_pid_tree() { # kill_pid_tree <windows pid>
  [ -n "${1:-}" ] || return 0
  MSYS_NO_PATHCONV=1 taskkill /PID "$1" /T /F >/dev/null 2>&1 || true
}
pid_alive() {
  [ -n "${1:-}" ] || return 1
  case "$1" in *[!0-9]*) return 1 ;; esac
  powershell -NoProfile -Command "(Get-Process -Id $1 -ErrorAction SilentlyContinue) -ne \$null" 2>/dev/null | grep -qi true
}
not_alive() { ! pid_alive "${1:-}"; }

PIDS=()
cleanup() {
  local status=$?
  local port pid name
  for port in "$PORT_A" "$PORT_B" "$RV"; do
    kill_pid_tree "$(winpid_on_port "$port")"
  done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    [ -n "$pid" ] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
  if [ "$status" != "0" ] || [ "${WA_STT_KEEP:-0}" = "1" ]; then
    echo "  fixture logs kept at $WORK" >&2
    for name in rendezvous a b; do
      [ -f "$WORK/$name.log" ] && { echo "  --- $name.log (tail) ---" >&2; tail -25 "$WORK/$name.log" >&2; }
    done
  else
    case "$WORK" in */wa-stt-two-nodes-??????) rm -rf -- "$WORK" 2>/dev/null || true ;; esac
  fi
  return "$status"
}
trap cleanup EXIT

FAILS=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); echo "  ok: $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL: $1" >&2; }
check() { local why="$1"; shift; if "$@"; then pass "$why"; else fail "$why"; fi; }

# One scratch process with the producer's home: the only way to submit a note with the real ids and
# the send time (the kernel's speech call carries neither), and to read a job back. It runs the same
# Lua tree (`WASM_AGENT_LUA_ROOT`) and the same component kv (`HOME`), never the serving threads.
script_run() { # script_run <home-name> <action> [KEY=VALUE ...]
  local home="$1" action="$2"; shift 2
  env -i \
    WA_SCRIPT="$(native "$ROOT/scripts/test-stt-node-script.lua")" \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$WORK/home-$home")" \
    WASM_AGENT_HOME="$(native "$WORK/home-$home")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
    WASM_AGENT_MANAGED=0 WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    WA_STT_ACTION="$action" "$@" \
    "$BIN" --db "$(native "$WORK/script-$home.db")" 2>>"$WORK/script.log"
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
job_state() { local home="$1" job="$2"; script_run "$home" job WA_STT_JOB="$job" 2>/dev/null | jget ok.state; }
is_state() { [ "$(job_state "$1" "$2")" = "$3" ]; }
log_has() { grep -q -- "$2" "$1" 2>/dev/null; }
not_log_has() { ! grep -q -- "$2" "$1" 2>/dev/null; }
log_count() { grep -c -- "$2" "$1" 2>/dev/null | head -1; }
eq() { [ "$1" = "$2" ]; }
ge() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge "${2:-0}" ]; }
no_canary() { ! grep -q 'canary' "$A_LOG" "$WORK/a.log" "$WORK/b.log" 2>/dev/null; }

start_node() { # start_node <a|b> <port> <client-port>
  local name="$1" port="$2" client="$3"
  local home="$WORK/home-$name" tag="local" role="producer" producer=""
  if [ "$name" = "b" ]; then tag="worker"; role="worker"; producer="stt-producer"; fi
  env -i \
    PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
    TEMP="${TEMP:-}" TMP="${TMP:-}" \
    HOME="$(native "$home")" \
    WASM_AGENT_HOME="$(native "$home")" \
    WASM_AGENT_LUA_ROOT="$(native "$ROOT")" \
    WASM_AGENT_MANAGED=0 \
    WASM_AGENT_RENDEZVOUS="http://127.0.0.1:$RV" WASM_AGENT_RELAY= \
    WASM_AGENT_ENDPOINT="127.0.0.1:$port" \
    WASM_AGENT_STT_ROLE="$role" \
    ${producer:+WASM_AGENT_STT_PRODUCER="$producer"} \
    WASM_AGENT_STT_LEASE_MS=8000 \
    WASM_AGENT_STT_HEARTBEAT_MS=2000 \
    WASM_AGENT_STT_GRACE_MS=3000 \
    WA_STT_PYTHON="$(native "$PYTHON")" \
    WA_STT_WORKER="$(native "$WORKER_PY")" \
    WA_STT_MODELS="$(native "$WORK/models")" \
    WA_TEST_STT_LOG="$(native "$WORK/decode-$name.log")" \
    WA_TEST_STT_TAG="$tag" \
    WA_TEST_STT_SEGMENTS=6 \
    WA_TEST_STT_SEGMENT_MS=700 \
    "$BIN" --db "$(native "$WORK/$name.db")" serve --port "$port" --client-port "$client" \
      --ui "$(native "$ROOT/ui")" > "$WORK/$name.log" 2>&1 &
  echo $!
}

echo "stt two nodes: rendezvous 127.0.0.1:$RV, producer :$PORT_A, worker :$PORT_B, work $WORK"

# The identities first: a local rendezvous makes a master only of the node ids its operator names
# (`WASM_AGENT_NETWORK_ADMINS`); with none, every node registers as a guest and a guest may not call a
# peer (`forbidden_role`). That is the correct default, and the reason this fixture says who its
# operators are before anything starts. A node's id exists as soon as its home has a key.
ID_A="$(script_run a identity 2>/dev/null | jget ok.node_id)"
ID_B="$(script_run b identity 2>/dev/null | jget ok.node_id)"
if [ -z "$ID_A" ] || [ -z "$ID_B" ]; then
  echo "FAIL: could not read the two node identities ($ID_A / $ID_B)" >&2
  exit 1
fi
if [ "$ID_A" = "$ID_B" ]; then echo "FAIL: the two homes share one node identity" >&2; exit 1; fi

env -i PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" SYSTEMDRIVE="${SYSTEMDRIVE:-}" WINDIR="${WINDIR:-}" \
  TEMP="${TEMP:-}" TMP="${TMP:-}" \
  HOME="$(native "$WORK/home-rv")" WASM_AGENT_HOME="$(native "$WORK/home-rv")" WASM_AGENT_MANAGED=0 \
  WASM_AGENT_NETWORK_ADMINS="$ID_A,$ID_B" \
  "$BIN" --db "$(native "$WORK/rv.db")" rendezvous --port "$RV" --bind 127.0.0.1 \
  > "$WORK/rendezvous.log" 2>&1 &
RV_PID=$!
PIDS+=("$RV_PID")
if ! wait_until 30 "the rendezvous on :$RV" up "$RV"; then echo "FAIL: the rendezvous did not start"; exit 1; fi

PID_A="$(start_node a "$PORT_A" "$PORT_AC")"
PIDS+=("$PID_A")
PID_B="$(start_node b "$PORT_B" "$PORT_BC")"
PIDS+=("$PID_B")
if ! wait_until 60 "the producer on :$PORT_A" up "$PORT_A"; then echo "FAIL: the producing node did not start"; exit 1; fi
if ! wait_until 60 "the worker on :$PORT_B" up "$PORT_B"; then echo "FAIL: the worker node did not start"; exit 1; fi
PID_B_WIN="$(winpid_on_port "$PORT_B")"
if [ -z "$PID_B_WIN" ]; then echo "FAIL: could not find the worker node's process id" >&2; exit 1; fi
pass "three processes are up (rendezvous, producer, worker)"

# Both nodes must be registered before a call can be admitted (`Admission` only admits the owner's own
# nodes, and the rendezvous is where it learns them).
wait_peers() { [ "$(script_run a peers 2>/dev/null | jget ok.peers.1.name)" = "stt-worker" ]; }
if ! wait_until 90 "the worker to register with the rendezvous" wait_peers; then
  echo "FAIL: the two nodes never saw each other"
  exit 1
fi
pass "the rendezvous lists both nodes"
# ... and admitted: the producer logs the first `take` from a worker it has learned, which is also
# what sets the presence the grace applies to. Waiting for that line is what makes "remote wins" a
# measurement instead of a race with the producer's first refusals.
if ! wait_until 90 "the producer to admit the worker" log_has "$WORK/a.log" "worker attached:"; then
  fail "the producer never admitted the worker"
else
  pass "the producer admitted the worker (take from $(grep -o 'worker attached: .*' "$WORK/a.log" | head -1))"
fi
sleep 1

# ---- 0. a warm-up note ---------------------------------------------------------------------------
# The producer prefers a remote it has *seen*: an admitted `take` is what makes the grace apply. A note
# submitted before that is decoded by the producer itself - the policy's named risk, not a bug - so the
# measured note comes after one that has warmed that path.
NOTE_0="$WORK/note-0.txt"
printf 'voice note zero %s\n' "$(date +%s%N)" > "$NOTE_0"
SUBMIT_0="$(script_run a submit WA_STT_AUDIO="$(native "$NOTE_0")" WA_STT_MSG=note-0 2>/dev/null)"
JOB_0="$(printf '%s' "$SUBMIT_0" | jget ok.job)"
if [ -z "$JOB_0" ]; then fail "the producer enqueued the warm-up note: $SUBMIT_0"; else pass "the warm-up note is job $JOB_0"; fi
if wait_until 90 "the warm-up note to settle" is_state a "$JOB_0" done; then
  pass "the warm-up note settled; the remote path has now been seen"
else
  fail "the warm-up note never settled (state $(job_state a "$JOB_0"))"
fi
sleep 2

# ---- 1. a note is decoded by the other node -------------------------------------------------------
NOTE_1="$WORK/note-1.txt"
printf 'voice note one %s\n' "$(date +%s%N)" > "$NOTE_1"
SHA_1="$(sha_of "$NOTE_1")"
SUBMIT_1="$(script_run a submit WA_STT_AUDIO="$(native "$NOTE_1")" WA_STT_MSG=note-1 2>/dev/null)"
JOB_1="$(printf '%s' "$SUBMIT_1" | jget ok.job)"
if [ -z "$JOB_1" ]; then fail "the producer enqueued the note: $SUBMIT_1"; else pass "the producer enqueued note 1 as job $JOB_1"; fi
if wait_until 90 "job $JOB_1 to be settled" is_state a "$JOB_1" done; then
  pass "the note was settled (state done)"
else
  fail "job $JOB_1 never reached done (state $(job_state a "$JOB_1"))"
fi
JOB_1_VIEW="$(script_run a job WA_STT_JOB="$JOB_1" 2>/dev/null)"
CHARS_1="$(printf '%s' "$JOB_1_VIEW" | jget ok.chars)"
check "the settled job carries its transcript length (chars=$CHARS_1), not the audio" ge "$CHARS_1" 1
SEEN_1="$(printf '%s' "$JOB_1_VIEW" | jget ok.segments_seen)"
check "the segments streamed back before the settle (segments=$SEEN_1)" ge "$SEEN_1" 1
check "the audio was inline, so no fetch handle was needed" eq "$(printf '%s' "$JOB_1_VIEW" | jget ok.audio)" inline
check "the worker node decoded note 1" log_has "$B_LOG" "worker $SHA_1"
check "the producer's own worker did not decode note 1" not_log_has "$A_LOG" "local $SHA_1"

# ---- 2. a stale note is refused and never decoded --------------------------------------------------
NOTE_2="$WORK/note-2.txt"
printf 'voice note two (old) %s\n' "$(date +%s%N)" > "$NOTE_2"
SHA_2="$(sha_of "$NOTE_2")"
NOW_MS="$(node -e 'process.stdout.write(String(Date.now()))')"
OLD_MS=$((NOW_MS - 600000))
SUBMIT_2="$(script_run a submit WA_STT_AUDIO="$(native "$NOTE_2")" WA_STT_MSG=note-2 WA_STT_SENT_AT="$OLD_MS" 2>/dev/null)"
REFUSAL="$(printf '%s' "$SUBMIT_2" | jget refused)"
check "a note past its window is refused at enqueue ($REFUSAL)" bash -c "printf '%s' '$REFUSAL' | grep -q '^stale:'"
sleep 2
check "the stale note was never decoded by the worker node" not_log_has "$B_LOG" "$SHA_2"
check "the stale note was never decoded by the producer" not_log_has "$A_LOG" "$SHA_2"
DONE_2="$(script_run a status 2>/dev/null | jget ok.queue.done)"
check "the stale note never became a job (queue done=$DONE_2)" eq "$DONE_2" 2

# ---- 3. the worker node is killed mid-job; the producer's own worker finishes ----------------------
NOTE_3="$WORK/note-3.txt"
printf 'voice note three SLOW %s\n' "$(date +%s%N)" > "$NOTE_3"
SHA_3="$(sha_of "$NOTE_3")"
SUBMIT_3="$(script_run a submit WA_STT_AUDIO="$(native "$NOTE_3")" WA_STT_MSG=note-3 2>/dev/null)"
JOB_3="$(printf '%s' "$SUBMIT_3" | jget ok.job)"
if [ -z "$JOB_3" ]; then fail "the producer enqueued the long note: $SUBMIT_3"; else pass "the producer enqueued the long note as job $JOB_3"; fi
if wait_until 30 "the worker node to start decoding job $JOB_3" log_has "$B_LOG" "worker $SHA_3"; then
  pass "the worker node started the long note"
else
  fail "the worker node never started the long note"
fi
# Kill the worker node while it is decoding: no settle, no heartbeat, the lease is all that is left.
# The fixture's lease is 8 s (a product node uses 60 s): long enough that a healthy remote never loses
# it to its own late heartbeat under the pump, short enough that the recovery is observable here.
sleep 1
kill_pid_tree "$PID_B_WIN"
if wait_until 10 "the worker process to be gone" not_alive "$PID_B_WIN"; then
  pass "the worker node was killed mid-decode"
else
  fail "the worker node did not stop when killed"
fi
if wait_until 180 "job $JOB_3 to be finished by the producer" is_state a "$JOB_3" done; then
  pass "the producer's own worker finished the note after the lease lapsed"
else
  fail "job $JOB_3 did not finish after the worker died (state $(job_state a "$JOB_3"))"
fi
JOB_3_VIEW="$(script_run a job WA_STT_JOB="$JOB_3" 2>/dev/null)"
LAPSES="$(printf '%s' "$JOB_3_VIEW" | jget ok.lease_expiries)"
check "the lease lapse is on the record (lease_expiries=$LAPSES)" ge "$LAPSES" 1
check "the producer decoded the long note itself" log_has "$A_LOG" "local $SHA_3"
ONCE="$(log_count "$B_LOG" "worker $SHA_3")"
check "the worker decoded it once, not twice (at-least-once: $ONCE)" eq "$ONCE" 1
DONE_3="$(script_run a status 2>/dev/null | jget ok.queue.done)"
check "the queue settled three notes and dropped one (done=$DONE_3)" eq "$DONE_3" 3

# ---- 4. nothing logged the transcript, and the roles are what the operator asked for ----------------
check "no node log carries transcript text" no_canary
check "the producer ran as the producer" log_has "$WORK/a.log" "role=producer"
check "the worker ran as the worker" log_has "$WORK/b.log" "role=worker"

echo
if [ "$FAILS" != "0" ]; then
  echo "stt two nodes FAILED ($FAILS of $CHECKS checks)" >&2
  exit 1
fi
echo "stt two nodes ok ($CHECKS checks)"
