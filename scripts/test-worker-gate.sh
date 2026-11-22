#!/usr/bin/env bash
# scripts/worker-gate.sh, judged against a scratch mission and a stub preflight and CLI.
#
# What is real here: the loop, the message it writes, WHEN it writes <mission>/done and with what, the
# session it resumes (read from the runner's own err.log, the line the node prints), and the round cap.
# What is scripted: the gate and the model (a stub preflight that answers red or green from a plan file, and
# a stub `wa` that records what it was resumed with), because a test may not run the fast path three times
# and may not call a provider.
#
# Nothing here touches ~/Work/missions, the operator's node or a provider: every directory is this
# fixture's, including HOME and WASM_AGENT_HOME.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
SCRIPT=$ROOT/scripts/worker-gate.sh
[ -f "$SCRIPT" ] || { echo "worker-gate: refused(no_script): no such file or directory: $SCRIPT (this tree has no worker-gate.sh: the row cannot judge the base)"; exit 3; }
# A scratch directory where a scratch directory belongs: an inherited TMPDIR on this machine points inside
# the node store, which this row must not write.
WORK=$(TMPDIR=/tmp mktemp -d)
cleanup() { [ -n "${KEEP-}" ] && { printf 'kept %s\n' "$WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT
export HOME=$WORK/user WASM_AGENT_HOME=$WORK/node TMPDIR=$WORK/tmp
export WA_MISSIONS_ROOT=$WORK/missions WA_PREFLIGHT_LAND_ROOT=$WORK/land
mkdir -p "$HOME" "$WASM_AGENT_HOME" "$TMPDIR" "$WORK/missions/demo" "$WORK/land" "$WORK/resumes"
checks=0
ok() { checks=$((checks + 1)); }
fail() { printf 'worker-gate FAILED: %s\n' "$*" >&2; exit 1; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -3)" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3: '$2' IS in: $(printf '%s' "$1" | head -3)" ;; *) ok ;; esac; }

export MISSION_ROOT=$WORK/missions
export WA_STUB_PLAN=$WORK/plan WA_STUB_CALLS=$WORK/calls WA_STUB_RESUMES=$WORK/resumes

# ---- the stub preflight: one answer per line of the plan file, in order, and a report to read the rows from.
cat > "$WORK/missions/preflight.sh" <<'PRE'
#!/usr/bin/env bash
set -uo pipefail
count=0
[ -f "$WA_STUB_CALLS" ] && count=$(cat "$WA_STUB_CALLS")
count=$((count + 1))
echo "$count" > "$WA_STUB_CALLS"
answer=$(sed -n "${count}p" "$WA_STUB_PLAN")
[ -n "$answer" ] || answer=$(tail -1 "$WA_STUB_PLAN")
dir=$WA_MISSIONS_ROOT/$1
case "$answer" in
  green)
    printf '{"ok":true,"failed":[]}\n' > "$dir/preflight.json"
    echo 'preflight green: change/demo on main 1111'
    exit 0 ;;
  red)
    printf '%s\n' '{"ok":false,"why":"1 row(s) failed","failed":[{"row":"scripts/test-a.lua","first_lines":["a failed"]}]}' > "$dir/preflight.json"
    echo 'preflight RED: 1 row(s) failed'
    echo '  - scripts/test-a.lua: a failed'
    exit 1 ;;
  *)
    echo 'preflight: refused(no_verdict): nothing was judged'
    exit 2 ;;
esac
PRE
chmod +x "$WORK/missions/preflight.sh"

# ---- the stub CLI: it records the session and the message it was resumed with, and touches nothing.
cat > "$WORK/wa" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
session=$3
# Counted by ARGUMENT files only: each resume writes two files, and counting both made the second resume
# look like the third.
count=$(ls -1 "$WA_STUB_RESUMES"/*.args 2>/dev/null | wc -l)
count=$((count + 1))
printf '%s\n' "$*" > "$WA_STUB_RESUMES/$count.args"
printf '%s\n' "${@: -1}" > "$WA_STUB_RESUMES/$count.message"
[ "${WA_STUB_REFUSE:-}" ] && exit 9
# A DEPLOY WAITING ON THE NODE (22/11): the node's own refusal, word for word, as `wa chat --once` prints it -
# exit 2 and the sentence on stdout, which is what scripts/worker-gate.sh reads.
refuse_upto=${WA_STUB_DEPLOY_WAIT:-0}
if { [ "${refuse_upto}" -gt 0 ] && [ "$count" -le "$refuse_upto" ]; } || [ "${WA_STUB_DEPLOY_FOREVER:-}" = 1 ]; then
  printf 'deploy_waiting: waiting for the install of 8082b42e1111 (deploy request 1795341684727384607-2971842-00000000000000000000, asked 2s ago). This node starts no new turn while a build is waiting for it or being installed - a turn in flight is exactly what keeps the node from going idle - and this turn did not start. Nothing was lost: this is a wait, not a failure. To stop waiting, withdraw the request: wa-sentinel request withdraw 1795341684727384607-2971842-00000000000000000000\n'
  exit 2
fi
exit 0
STUB
chmod +x "$WORK/wa"
export WA_BIN=$WORK/wa

reset() { rm -f "$WA_STUB_CALLS" "$WORK/missions/demo/done" "$WORK/missions/demo/preflight.json"; rm -rf "$WA_STUB_RESUMES"; mkdir -p "$WA_STUB_RESUMES"; }
resumes() { ls -1 "$WA_STUB_RESUMES" 2>/dev/null | grep -c 'args$' || true; }

# ---- 1. a worker whose own rc was not 0 is not asked: its rc stands, and the gate is not called at all
reset
printf 'red\n' > "$WA_STUB_PLAN"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 7 2>&1); code=$?
[ "$code" = 0 ] || fail "a non-zero worker rc is not a gate failure (got $code): $out"; ok
[ -f "$WA_STUB_CALLS" ] && fail 'the gate was asked for a run whose rc was not 0'
ok
has "$(cat "$WORK/missions/demo/done")" 'rc=7 preflight=not_asked rounds=0' 'done keeps the rc and says the gate was not asked'

# ---- 2. green at the first ask: no resume, and done says exactly that
reset
printf 'green\n' > "$WA_STUB_PLAN"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
[ "$code" = 0 ] || fail "a green preflight exits 0 (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'rc=0 preflight=green rounds=0' 'done records green with no round'
[ "$(resumes)" = 0 ] || fail 'a green gate resumed the worker'
ok

# ---- 3. red, red, green: the SAME session is resumed twice with the rows, and the third ask is green
reset
printf 'red\nred\ngreen\n' > "$WA_STUB_PLAN"
printf 'wa: session 11111111-2222-3333-4444-555555555555 ok\n' > "$WORK/missions/demo/err.log"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
[ "$code" = 0 ] || fail "the run ends green after two rounds (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'rc=0 preflight=green rounds=2' 'done counts the two rounds it took'
[ "$(cat "$WA_STUB_CALLS")" = 3 ] || fail "the gate was asked three times, not $(cat "$WA_STUB_CALLS")"; ok
[ "$(resumes)" = 2 ] || fail "the worker was resumed twice, not $(resumes)"; ok
has "$(cat "$WA_STUB_RESUMES/1.args")" 'chat --resume 11111111-2222-3333-4444-555555555555 --once' 'it resumes the session the runner named'
has "$(cat "$WA_STUB_RESUMES/1.message")" 'scripts/test-a.lua: a failed' 'the message carries the row that failed'
has "$(cat "$WA_STUB_RESUMES/1.message")" 'do not weaken a test' 'and the instruction not to weaken a test'
has "$(cat "$WA_STUB_RESUMES/1.message")" 'Round 1 of 3' 'and which round this is'
has "$(cat "$WA_STUB_RESUMES/1.message")" 'preflight.json' 'and where the whole report is'
has "$(cat "$WA_STUB_RESUMES/2.message")" 'Round 2 of 3' 'the second round says it is the second'

# ---- 4. still red after three rounds: recorded red, three resumes, and that is the answer
reset
printf 'red\n' > "$WA_STUB_PLAN"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
[ "$code" = 1 ] || fail "a mission still red after the last round exits 1 (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'rc=0 preflight=red rounds=3' 'done records red after three rounds'
[ "$(resumes)" = 3 ] || fail "three rounds, three resumes: got $(resumes)"; ok
has "$out" 'NOT done' 'and says the mission is not done'

# ---- 5. red with no session to resume: it does not invent one, and it says so
reset
printf 'red\n' > "$WA_STUB_PLAN"
rm -f "$WORK/missions/demo/err.log"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
[ "$code" = 1 ] || fail "a red gate with no session exits 1 (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'preflight=red rounds=0' 'no round happened'
[ "$(resumes)" = 0 ] || fail 'it resumed something with no session named'
ok
has "$out" 'no session to resume' 'and the refusal is named'

# ---- 6. a preflight that judged nothing is neither green nor red, and the worker is not sent to fix rows
reset
printf 'refuse\n' > "$WA_STUB_PLAN"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
[ "$code" = 1 ] || fail "a refusal exits 1 (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'preflight=refused rounds=0' 'done records refused'
[ "$(resumes)" = 0 ] || fail 'a refusal resumed the worker'
ok

# ---- 7. no preflight installed: recorded unknown, and the worker's own rc stands
reset
mv "$WORK/missions/preflight.sh" "$WORK/preflight.sh.off"
out=$(bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
[ "$code" = 0 ] || fail "no preflight is not a failure of the worker (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'rc=0 preflight=unknown rounds=0' 'done says the gate was not asked'
mv "$WORK/preflight.sh.off" "$WORK/missions/preflight.sh"

# ---- 8. A REFUSED RESUME IS NOT A ROUND (22/11, review MUST 3). While a deploy waits for or installs on the
# node, `wa chat --once` refuses a NEW turn by name and exits 2 with `deploy_waiting` - nothing was asked and
# nothing answered. Counting that as one of the three rounds recorded a mission red that nobody worked on.
reset
printf 'red\nred\ngreen\n' > "$WA_STUB_PLAN"
printf 'wa: session 11111111-2222-3333-4444-555555555555 ok\n' > "$WORK/missions/demo/err.log"
# The stub refuses the first TWO resumes with the node's own words, then runs.
export WA_STUB_DEPLOY_WAIT=2
out=$(WORKER_GATE_DEPLOY_STEP=1 WORKER_GATE_DEPLOY_WAIT=30 bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
unset WA_STUB_DEPLOY_WAIT
[ "$code" = 0 ] || fail "the run still ends green (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'rc=0 preflight=green rounds=2' 'the two WAITED resumes were not charged as rounds'
[ "$(cat "$WA_STUB_CALLS")" = 3 ] || fail "the gate was asked three times, not $(cat "$WA_STUB_CALLS")"; ok
[ "$(resumes)" = 4 ] || fail "two refused asks and two real resumes, not $(resumes)"; ok
has "$out" 'round 1 is not spent' 'the wait is said out loud, and that it costs no round'
has "$out" 'asks again' 'and that it asks again'
has "$(cat "$WA_STUB_RESUMES/3.message")" 'Round 1 of 3' 'the turn that finally ran was still round 1'

# ---- 9. a wait that never ends is refused by name, and no round is charged for it
reset
printf 'red\nred\ngreen\n' > "$WA_STUB_PLAN"
printf 'wa: session 11111111-2222-3333-4444-555555555555 ok\n' > "$WORK/missions/demo/err.log"
export WA_STUB_DEPLOY_FOREVER=1
out=$(WORKER_GATE_DEPLOY_STEP=1 WORKER_GATE_DEPLOY_WAIT=2 bash "$SCRIPT" "$WORK/missions/demo" 0 2>&1); code=$?
unset WA_STUB_DEPLOY_WAIT WA_STUB_DEPLOY_FOREVER
[ "$code" = 1 ] || fail "a wait that never ends exits 1 (got $code): $out"; ok
has "$(cat "$WORK/missions/demo/done")" 'preflight=refused rounds=0' 'it is a refusal, not a red, and no round was spent'
has "$out" 'nothing ran, and no round was spent' 'and it says exactly that'

printf 'worker-gate ok (%d checks)\n' "$checks"

