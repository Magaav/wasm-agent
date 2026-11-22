#!/usr/bin/env bash
# wa mission launch|start|status|stop, against a SCRATCH missions root, a scratch repository and a stub
# CLI. Nothing here touches ~/Work/missions or a provider: the stub names a session on STDERR the way the
# real CLI does and then stays alive, so 'stop' has a process of this fixture's own to end.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
WA=${WA_BIN:-$(command -v wa)}
# THIS ROW NEVER READS ITS CALLER'S STDIN. `wa chat --once` treats a stdin that is not a terminal as a queue of
# prompts (docs/SCRIPTED-RUNS.md), so a child that inherited the caller's stdin ATE THE REST OF IT - measured
# 22/11 by scripts/test-discriminates.sh, whose row list arrives on stdin: six tests were listed and three ran,
# the other three consumed as extra prompts by a row's `wa chat --once`. One line, before anything starts a CLI.
exec </dev/null

[ -n "$WA" ] || { echo "mission-verb: no wa on PATH"; exit 3; }
WORK=$(mktemp -d)
KIDS=''
cleanup() {
  [ -n "${KEEP-}" ] && { printf 'kept %s\n' "$WORK"; return; }
  for pid in $KIDS; do
    case $pid in ''|*[!0-9]*) continue ;; esac
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || true
    case $cmd in *"$WORK"*) kill "$pid" 2>/dev/null ;; esac
  done
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { printf 'mission-verb FAILED: %s\n' "$*" >&2; exit 1; }
has() { case $1 in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -2)" ;; esac; }

# The scratch everything lives in. WASM_AGENT_HOME is NOT $HOME: the node's store hangs off it, and a row
# given the user home writes the operator's real node.
export HOME=$WORK/user WASM_AGENT_HOME=$WORK/node
[ "$WASM_AGENT_HOME" = "$HOME" ] && fail 'the scratch home must not be the node home'
mkdir -p "$HOME" "$WASM_AGENT_HOME" "$WORK/missions"
unset WASM_AGENT_VAULT_URL WASM_AGENT_VAULT_DIR WASM_AGENT_VAULT_KEYSTORE WASM_AGENT_VAULT_PASSPHRASE
export WASM_AGENT_LUA_ROOT=$ROOT WASM_AGENT_DB=$WASM_AGENT_HOME/memory.db
export WASM_AGENT_LLM_API_KEY=fixture WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:9/fixture
export MISSION_ROOT=$WORK/missions MISSION_REPO=$WORK/repo MISSION_START_WAIT_SECONDS=10

REPO=$WORK/repo
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name fixture
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md && git -C "$REPO" commit -qm 'base commit'

mkdir -p "$WORK/bin"
cat > "$WORK/bin/stub-wa" <<'STUB'
#!/usr/bin/env bash
first=${1-}
case $first in
  chat) echo "wa: session 11111111-2222-3333-4444-555555555555 ok" >&2; sleep 300; exit 0 ;;
  steer) printf '{"note":"fixture","receipts":[],"target":{}}\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/stub-wa"

mission() { "$WA" mission "$@"; }
mkdir -p "$MISSION_ROOT/demo"
printf 'Do nothing: this is a stub mission.\n' > "$MISSION_ROOT/demo/brief.md"

# --- launch
out=$(mission launch demo HEAD --wa "$WORK/bin/stub-wa" 2>&1)
has "$out" '"ok":true' 'launch reports ok'
M=$MISSION_ROOT/demo
[ -e "$M/wt/.git" ] || fail 'launch did not create the worktree'
ok
for f in env prompt.md run.sh; do [ -s "$M/$f" ] || fail "launch did not write $f"; ok; done
head -1 "$M/prompt.md" | grep -q "^mission demo in " || fail 'the prompt does not start with the marker'
ok
has "$(cat "$M/env")" "BRANCH='change/demo'" 'the env names the branch'
# The runner never picks an execution path of its own: native run(code=...) is the one path (Victor 21/11).
grep -q '^export WASM_AGENT_RAW_CODE' "$M/run.sh" && fail 'run.sh exports WASM_AGENT_RAW_CODE (a second execution path)'
ok
grep -q '^unset WASM_AGENT_RAW_CODE' "$M/run.sh" || fail 'run.sh does not clear an inherited WASM_AGENT_RAW_CODE'
ok
out=$(mission launch demo HEAD --wa "$WORK/bin/stub-wa" 2>&1)
has "$out" 'already_staged' 'a staged mission is not launched twice'

# --- the runner `wa mission launch` writes waits out a deploy refusal (22/11, review MUST 3)
# While a deploy waits for or installs on the node, `wa chat --once` refuses a NEW turn by name and exits 2.
# The runner used to write that rc=2 into `done` - a mission that never ran, read as a failed turn - so it must
# wait and ask again. Driven here, not grepped: a stub that refuses its first turn and then answers, and the
# mission's own files are what the check reads.
mkdir -p "$MISSION_ROOT/refused"
printf 'Do nothing either: this is a stub mission too.\n' > "$MISSION_ROOT/refused/brief.md"
cat > "$WORK/bin/refuse-wa" <<'STUB'
#!/usr/bin/env bash
D=$(dirname "$0")
case ${1-} in
  chat)
    n=$(cat "$D/deploy.left" 2>/dev/null || echo 0)
    case ${n:-0} in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      echo $((n - 1)) > "$D/deploy.left"
      printf 'deploy_waiting: waiting for the install of 8082b42e1111 (deploy request 1795341684727384607-2971842-00000000000000000000, asked 2s ago). This node starts no new turn while a build is waiting for it or being installed; nothing was lost, and the work starts again once the swap is done.\n'
      exit 2
    fi
    echo "wa: session 33333333-4444-5555-6666-777777777777 ok" >&2
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/refuse-wa"
echo 1 > "$WORK/bin/deploy.left"
out=$(mission launch refused HEAD --wa "$WORK/bin/refuse-wa" 2>&1)
has "$out" '"ok":true' 'the mission whose turn will be refused is staged'
R=$MISSION_ROOT/refused
out=$(WA_DEPLOY_WAIT_STEP=1 WA_DEPLOY_WAIT_LIMIT=60 bash "$R/run.sh" 2>&1); code=$?
[ "$code" = 0 ] || fail "the runner exits with the turn that finally ran (got $code): $out"
ok
has "$(cat "$R/done")" 'rc=0' 'the refusal was waited out, not recorded as the mission run'
has "$(cat "$R/out.log")" 'deploy-wait' 'the wait is in the mission log'
has "$(cat "$R/lease.log")" 'deploy-wait' 'and in lease.log, where an operator looks for a launch'

# --- ...and a wait that never ends is recorded as itself, with the line that says nothing ran
echo 0 > "$WORK/bin/deploy.left"
cat > "$WORK/bin/refuse-always-wa" <<'STUB'
#!/usr/bin/env bash
case ${1-} in
  chat) printf 'deploy_waiting: waiting for the install of 8082b42e1111; nothing was lost, this is a wait.\n'; exit 2 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/refuse-always-wa"
mkdir -p "$MISSION_ROOT/never"
printf 'Never.\n' > "$MISSION_ROOT/never/brief.md"
out=$(mission launch never HEAD --wa "$WORK/bin/refuse-always-wa" 2>&1)
has "$out" '"ok":true' 'the always-refused mission is staged'
N=$MISSION_ROOT/never
out=$(WA_DEPLOY_WAIT_STEP=1 WA_DEPLOY_WAIT_LIMIT=2 bash "$N/run.sh" 2>&1); code=$?
[ "$code" = 2 ] || fail "a wait that never ends exits 2, the refusal itself (got $code): $out"
ok
has "$(cat "$N/done")" 'rc=2' 'done carries the refusal, not a failed turn'
has "$(cat "$N/out.log")" 'gave up after' 'and the log says the wait ended and nothing ran'

# --- start
out=$(mission start demo 2>&1)
has "$out" '"ok":true' 'start reports ok'
has "$out" '11111111-2222-3333-4444-555555555555' 'start reports the session id the CLI printed'
# run.lock is written by the RUNNER the moment the CLI names the session, which is one step after the
# run.pid 'start' waits for. The wait is bounded and about the runner's own write, not about a clock.
session=''
for i in $(seq 1 50); do
  session=$(sed -n "s/^SESSION='\(.*\)'$/\1/p" "$M/run.lock" 2>/dev/null)
  [ -n "$session" ] && break
  sleep 0.1
done
[ "$session" = '11111111-2222-3333-4444-555555555555' ] || fail "run.lock does not carry the session id: '$session'"
ok
cli=$(cat "$M/run.pid" 2>/dev/null)
[ -n "$cli" ] && kill -0 "$cli" 2>/dev/null || fail 'start did not leave a live CLI process it named'
KIDS="$KIDS $cli"
ok
launcher=$(cat "$M/launch.pid" 2>/dev/null)
[ -n "$launcher" ] || fail 'start did not record the launcher pid'
KIDS="$KIDS $launcher"
ok

# --- a second start while the run is live refuses, by name
out=$(mission start demo 2>&1)
has "$out" 'launch_refused' 'a second start is refused while a run is live'
has "$out" 'second writer' 'the refusal says why it matters'

# --- status
out=$(mission status demo 2>&1)
has "$out" '"name":"demo"' 'status names the mission'
has "$out" '11111111-2222-3333-4444-555555555555' 'status reports the recorded session'
has "$out" 'change/demo' 'status reports the branch'

# --- stop: the run really ends, and done carries its rc
out=$(mission stop demo 2>&1)
has "$out" 'stopped' 'stop reports what it stopped'
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.1; done
kill -0 "$cli" 2>/dev/null && fail 'stop did not end the CLI process'
ok
for i in $(seq 1 50); do [ -s "$M/done" ] && break; sleep 0.1; done
has "$(cat "$M/done" 2>/dev/null)" 'rc=' 'done carries the rc of a stopped run'

# --- refusals that name the reason
out=$(mission launch '../escape' HEAD 2>&1)
has "$out" 'name_must' 'a name that is a path is refused'
out=$(mission start nothere 2>&1)
has "$out" 'not_staged' 'an unstaged mission is not started'

# --- resume: the verb exists, refuses by name when there is nothing to resume, and never reports
# "resumed" for a session that was not found.
out=$(mission resume nothere 2>&1)
has "$out" 'not_staged' 'resume refuses an unstaged mission by name'
out=$(mission resume demo 2>&1)
if printf '%s' "$out" | grep -q 'not_a_hiccup'; then
  ok
elif printf '%s' "$out" | grep -q 'no_session'; then
  ok
else
  fail "resume did not refuse by name: $out"
fi

# --- preflight: the verb runs the mission's own preflight.sh and reports its verdict with its exit code.
# The script is the one implementation (scripts/preflight.sh, symlinked into the missions root); the verb
# never re-implements it, so what is judged here is the plumbing: the arguments, the exit code, the report
# read back, an unknown answer that is refused by name, and a root with no script at all.
cat > "$MISSION_ROOT/preflight.sh" <<'PRE'
#!/usr/bin/env bash
name=${1:?}; dir=$MISSION_ROOT/$name
mode=$(cat "$dir/preflight.mode" 2>/dev/null || echo green)
if [ "$mode" = red ]; then
  printf '{"ok":false,"main_sha":"1111","tree_sha":"2222","seconds":9,"why":"1 row(s) failed","failed":[{"row":"scripts/test-a.lua","first_lines":["a failed"]}]}\n' > "$dir/preflight.json"
  echo 'preflight RED: 1 row(s) failed'
  exit 1
fi
printf '{"ok":true,"main_sha":"1111","tree_sha":"2222","seconds":7,"failed":[]}\n' > "$dir/preflight.json"
printf 'preflight green: change/%s\n' "$name"
exit 0
PRE
chmod +x "$MISSION_ROOT/preflight.sh"
out=$(mission preflight demo 2>&1); code=$?
[ "$code" = 0 ] || fail "a green preflight verb exits 0 (got $code): $out"; ok
has "$out" '"preflight":"green"' 'the verb says green'
has "$out" '"ok":true' 'and carries the report it read back'
has "$out" '"seconds":7' 'with the seconds the script measured'
has "$out" '"effect":"none"' 'a preflight touches no node'
printf 'red\n' > "$MISSION_ROOT/demo/preflight.mode"
out=$(mission preflight demo 2>&1); code=$?
[ "$code" = 1 ] || fail "a red preflight verb exits 1, the script's own code (got $code): $out"; ok
has "$out" '"preflight":"red"' 'the verb says red'
has "$out" 'scripts/test-a.lua' 'and names the row that failed'
out=$(mission preflight nothere 2>&1)
has "$out" 'no_mission' 'a mission that is not there is refused by name'
rm -f "$MISSION_ROOT/preflight.sh"
out=$(mission preflight demo 2>&1)
has "$out" 'preflight_script_missing' 'a missions root with no preflight.sh is refused by name, not run empty'
has "$out" 'ln -s' 'and the refusal carries the command that installs it'


printf 'mission-verb ok (%d checks)\n' "$checks"
