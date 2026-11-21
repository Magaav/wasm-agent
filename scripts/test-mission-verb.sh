#!/usr/bin/env bash
# wa mission launch|start|status|stop, against a SCRATCH missions root, a scratch repository and a stub
# CLI. Nothing here touches ~/Work/missions or a provider: the stub names a session on STDERR the way the
# real CLI does and then stays alive, so 'stop' has a process of this fixture's own to end.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
WA=${WA_BIN:-$(command -v wa)}
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
out=$(mission launch demo HEAD --wa "$WORK/bin/stub-wa" 2>&1)
has "$out" 'already_staged' 'a staged mission is not launched twice'

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

printf 'mission-verb ok (%d checks)\n' "$checks"
