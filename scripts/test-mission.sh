#!/usr/bin/env bash
# Fixture proof for scripts/mission.sh against a scratch repository, a scratch NODE and a stub 'wa'.
#
# The shape every case exists for, measured on avell 18/11: the CLI exits rc=1 while the node keeps
# running that session and writing into the worktree, so liveness from the launcher's pid says
# "finished" and the next launch is a second writer. The stub reproduces exactly that: 'chat' prints the
# session id on stderr and exits with its rc, and the node's own state files - the run lease, the
# session row, the boot claim - are what decide whether a launch is refused.
#
#   bash scripts/test-mission.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
MISSION=${MISSION_UNDER_TEST:-$ROOT/scripts/mission.sh}   # a saved head runs the same fixture
WORK=$(mktemp -d)
HOLD=''
KIDS=''
cleanup() {
  if [ -n "${KEEP-}" ]; then printf 'kept %s\n' "$WORK"; return; fi
  exec 9>&- 2>/dev/null || true
  [ -n "$HOLD" ] && kill "$HOLD" 2>/dev/null
  # Everything this fixture started, and every runner it launched. A child that outlives the script keeps
  # the CALLER's stdout open, so a piped run ('bash scripts/test-mission.sh | tail -3') never sees EOF
  # even though the fixture has already printed its verdict. Measured 18/11 on this node: a mutated run
  # failed after the presence case, left its 'sleep 600' holding the pipe, and two harness shells sat on
  # that line for ten minutes; one of them then ran its own restore step over uncommitted work in this
  # tree. A fixture that fails must exit, not wedge the caller.
  for p in ${KIDS-}; do kill "$p" 2>/dev/null; done
  for f in "$MISSIONS"/*/run.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { printf 'mission fixture FAILED: %s\n' "$*" >&2; exit 1; }
has() { case $1 in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -3)" ;; esac; }
lacks() { case $1 in *"$2"*) fail "$3: '$2' should not be in: $1" ;; *) ok ;; esac; }
field() { printf '%s\n' "$1" | sed -n "s/^$2 *//p" | head -1; }

export REPO=$WORK/repo MISSION_ROOT=$WORK
MISSIONS=$WORK/missions TARGET=$WORK/target NODEHOME=$WORK/node
mkdir -p "$REPO" "$WORK/bin" "$MISSIONS" "$NODEHOME/resources" "$WORK/toolchain"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name fixture
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md && git -C "$REPO" commit -qm 'base commit'

# --- the node: a claim store (session:<id> -> boot) and two boots, one held and one free. The held
#     boot is a real exclusive lock on its lease file, taken by a sqlite3 connection kept open on a
#     fifo - the same lock rust/wa-capabilities takes for a live boot, which is why a probe can tell.
export STUB_STATE=$WORK/node
sqlite3 "$NODEHOME/resources/claims.sqlite" \
  "create table claims(key text primary key, boot text);" || fail 'cannot build the claim store'
sqlite3 "$NODEHOME/resources/boot-held.lease.sqlite" "create table owner(x)" || fail 'cannot build a lease'
sqlite3 "$NODEHOME/resources/boot-free.lease.sqlite" "create table owner(x)" || fail 'cannot build a lease'
mkfifo "$WORK/lease.fifo"
sqlite3 "$NODEHOME/resources/boot-held.lease.sqlite" < "$WORK/lease.fifo" >/dev/null 2>&1 &
HOLD=$!
exec 9> "$WORK/lease.fifo"
printf 'BEGIN EXCLUSIVE;\n' >&9
: > "$STUB_STATE/sessions.tsv"
# The node's own presence table, built with the rest of the node. Before round 5 it was created only where the
# first presence row was planted - well past the first launch - so every early case read a node whose memory.db
# did not exist, and round 5 turns that into an 'unknown' refusal instead of a launch permission.
sqlite3 "$NODEHOME/memory.db" \
  "create table if not exists session_presence(session_id text primary key, pid integer, boot text, role text, started_at real, heartbeat_at real)" \
  || fail 'cannot build the node presence table'

now() { date +%s; }
node_session() { # <id> <state> <age-seconds-or-dash> <title>
  grep -v "^$1	" "$STUB_STATE/sessions.tsv" > "$STUB_STATE/sessions.tmp" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STUB_STATE/sessions.tmp"
  mv "$STUB_STATE/sessions.tmp" "$STUB_STATE/sessions.tsv"
}

# --- the stub 'wa'. 'chat' is the CLI that exits and does NOT settle the node's run.
cat > "$WORK/bin/wa" <<'STUB'
#!/usr/bin/env bash
D=$STUB_STATE
case ${1-} in
  sessions)
    # round 3, item 1: a node that cannot be asked. Its output is empty, not a list.
    [ "${STUB_SESSIONS_FAIL-}" = yes ] && exit 1
    printf '[lua] memory: sessions served natively: component_missing\n'
    while IFS=$'\t' read -r id state age title; do
      [ -n "$id" ] || continue
      printf '%s  %-10s messages=%-3d %-12s %s\n' "$id" master 3 "$state" "$title"
      [ "$state" = unfinished ] && [ "$age" != - ] && printf '      stopped after a tool result with no next step, %ss ago\n' "$age"
    done < "$D/sessions.tsv"
    ;;
  steer)
    if [ -f "$D/steer.$2" ]; then cat "$D/steer.$2"; else printf '{"note":"x","receipts":[],"target":{}}\n'; fi
    ;;
  chat)
    # one fresh session: the id is said on STDERR (lua/core/chat.lua), stdout is the run's own output.
    # The title is the node's own rule, roughly (first line, furniture stripped, 60 chars): the marker
    # this fixture matches on carries none of that furniture.
    id=$STUB_ID
    title=$(printf '%s' "${3-}" | head -1 | tr -d '#*_>|' | sed 's/  */ /g' | cut -c1-60)
    printf 'wa: session %s %s\n' "$id" "$STUB_RESULT" >&2
    printf 'transcript of %s\n' "$id"
    if [ "$STUB_NODE_KEEPS_RUN" = yes ]; then
      # THE FAILURE: the node keeps the session unfinished and its run in flight after the CLI exits
      printf '%s\tunfinished\t0\t%s\n' "$id" "$title" >> "$D/sessions.tsv"
      printf '{"note":"x","receipts":[],"target":{"boot":"boot-held","owner":"master","run_id":"run-of-%s","session_id":"%s","state":"active","updated_at":%s}}\n' \
        "$id" "$id" "$(date +%s)" > "$D/steer.$id"
      sqlite3 "$D/resources/claims.sqlite" \
        "insert into claims(key,boot) values('session:$id','boot-held') on conflict(key) do update set boot=excluded.boot"
    else
      printf '%s\tanswered\t-\t%s\n' "$id" "$title" >> "$D/sessions.tsv"
      printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-%s","session_id":"%s","state":"settled","updated_at":%s}}\n' \
        "$id" "$id" "$(date +%s)" > "$D/steer.$id"
    fi
    exit "$STUB_RC"
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/wa"
printf '# demo brief\n\nBuild the demo thing. Report what you verified.\n' > "$WORK/brief.md"

run() { # <args...> with the fixture's environment
  MISSION_REPO=$REPO MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSIONS_TOOLCHAIN=$WORK/toolchain \
    WA_BIN=$WORK/bin/wa MISSION_NODE_HOME=$NODEHOME bash "$MISSION" "$@" 2>&1
}
status_of() { run status "$1"; }
run_node() { # <node home> <args...> - the same script, against a node home of the case's choosing
  local nh=$1; shift
  MISSION_REPO=$REPO MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSIONS_TOOLCHAIN=$WORK/toolchain \
    WA_BIN=$WORK/bin/wa MISSION_NODE_HOME=$nh bash "$MISSION" "$@" 2>&1
}
# The same read from a node whose lease store does not exist: "cannot tell" must not become "released".
# Round 5: that node still carries a readable memory.db, or the presence read (which now refuses when it cannot
# tell) would answer for the lease store too, and this would stop being a test of one read.
NOCLAIMS=$WORK/node-noclaims; mkdir -p "$NOCLAIMS"
cp "$NODEHOME/memory.db" "$NOCLAIMS/memory.db"
run_nonode() { MISSION_REPO=$REPO MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSIONS_TOOLCHAIN=$WORK/toolchain \
  WA_BIN=$WORK/bin/wa MISSION_NODE_HOME=$NOCLAIMS bash "$MISSION" "$@" 2>&1; }
export STUB_ID=11111111-2222-3333-4444-555555555555
export STUB_RC=0 STUB_RESULT=ok STUB_NODE_KEEPS_RUN=no
# The launch is over when every take in lease.log has its cli-exit. Waiting on the done marker alone
# raced the previous launch's marker, which is a real thing a reader hits too.
wait_done() { # <mission>
  local i=0 takes exits L
  L=$MISSIONS/$1/lease.log
  while [ "$i" -lt 300 ]; do
    if [ -f "$L" ]; then
      takes=$(grep -c '^take ' "$L" 2>/dev/null)
      exits=$(grep -c '^cli-exit ' "$L" 2>/dev/null)
      [ "$takes" -gt 0 ] && [ "$takes" -eq "$exits" ] && return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ================================================================ stage
out=$(run stage demo main "$WORK/brief.md"); rc=$?
[ "$rc" = 0 ] || fail "stage exited $rc: $out"
has "$out" 'staged demo' 'stage names the mission'
MARKER="mission demo in $MISSIONS/demo/wt"
[ "$(head -1 "$MISSIONS/demo/prompt.md")" = "$MARKER" ] && ok \
  || fail "prompt.md must start with the marker the node shows as the session title, got: $(head -1 "$MISSIONS/demo/prompt.md")"
has "$(cat "$MISSIONS/demo/prompt.md")" '## Where you are' 'the prompt still says where the session is'
has "$(cat "$MISSIONS/demo/prompt.md")" "$MISSIONS/demo/wt" 'the prompt still names the worktree'
has "$(cat "$MISSIONS/demo/prompt.md")" 'do not use session_worktree' 'the prompt forbids a session worktree'
has "$(cat "$MISSIONS/demo/run.sh")" 'run.lock' 'the runner takes the lock before the node is asked for a session'
has "$(cat "$MISSIONS/demo/run.sh")" 'lease.log' 'the runner records the take/bind/cli-exit in lease.log'
has "$(cat "$MISSIONS/demo/run.sh")" 'chat --once' 'the runner is one fresh session'
lacks "$(cat "$MISSIONS/demo/run.sh")" --resume 'the runner never resumes'
code_of() { grep -v '^[[:space:]]*#' "$1"; }   # a comment may name the pattern; the code must not use it
lacks "$(code_of "$MISSIONS/demo/run.sh")$(code_of "$MISSION")" 'pkill -f' 'nothing kills by pattern'
lacks "$(code_of "$MISSION")$(code_of "$MISSIONS/demo/run.sh")" 'pgrep -f' 'nothing finds a process by pattern'
out=$(run stage demo main "$WORK/brief.md") && fail 'stage twice must refuse (one branch per mission)' || ok
has "$out" 'already staged' 'the second stage refuses: one worktree, one branch per mission'

# ================================================================ a clean launch the node settles
out=$(run start demo); has "$out" 'started demo' 'start reports the launch'
wait_done demo || fail 'no done marker after the launch (the marker with the rc is the point)'
has "$(cat "$MISSIONS/demo/done")" 'rc=0' 'done carries the rc'
has "$(cat "$MISSIONS/demo/err.log")" '11111111-2222-3333-4444-555555555555' 'the session id is read where the CLI says it: stderr'
has "$(cat "$MISSIONS/demo/lease.log")" 'take ' 'lease.log records the take'
has "$(cat "$MISSIONS/demo/lease.log")" 'bind ' 'lease.log records the moment the node named the session'
has "$(cat "$MISSIONS/demo/lease.log")" 'cli-exit' 'lease.log records the CLI exit as a CLI exit'
has "$(grep 'cli-exit' "$MISSIONS/demo/lease.log")" 'rc=0' 'the CLI exit line carries the rc'
s=$(status_of demo)
case "$(field "$s" run)" in released*) ok ;; *) fail "status run after a settled launch: '$(field "$s" run)'" ;; esac
has "$s" '11111111-2222-3333-4444-555555555555' 'status names the session from the lock, not from run.pid'
[ -f "$MISSIONS/demo/run.lock" ] && fail 'status must release a lock the node says is settled' || ok
has "$(cat "$MISSIONS/demo/lease.log")" 'release ' 'the release is a line in lease.log, with its reason'

# ================================================================ THE CASE: the CLI exits, the node keeps writing
export STUB_ID=22222222-3333-4444-5555-666666666666 STUB_RC=1 STUB_RESULT=failed STUB_NODE_KEEPS_RUN=yes
out=$(run start demo); has "$out" 'started demo' 'a launch the node will keep is still launched'
wait_done demo || fail 'the failing launch wrote no done marker'
has "$(cat "$MISSIONS/demo/done")" 'rc=1' 'the done marker keeps the CLI rc=1'
s=$(status_of demo)
case "$(field "$s" run)" in active*) ok ;; *) fail "status must report the node's run as active, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" '22222222-3333-4444-5555-666666666666' 'the active run is named by its session'
has "$(field "$s" run)" 'held boot' 'the verdict rests on the node boot lease, not on a pid'
[ -f "$MISSIONS/demo/run.lock" ] && ok || fail 'the lock must stay: the node is still writing for this mission'
has "$(field "$s" launcher)" 'not liveness' 'status shows the CLI pid and says it is not liveness'
out=$(run start demo) && fail 'a second start must refuse while the node still runs that session' || ok
has "$out" 'refusing' 'the refusal says it refuses'
has "$out" '22222222-3333-4444-5555-666666666666' 'the refusal NAMES the session id'
has "$out" 'second writer' 'the refusal says what a second launch would be'
out=$(run start demo --force) && fail 'start must not take --force at all' || ok
has "$out" 'no --force' 'start says in as many words that it has no --force'
has "$out" 'cleared by hand' 'and that a stuck mission is cleared by hand, not forced past'
out=$(run verify demo true) && fail 'verify must refuse while the node runs that session' || ok
has "$out" 'in flight' 'verify refuses with the reason'
out=$(run clean demo --force) && fail 'clean must refuse while the node runs that session' || ok
has "$out" 'in flight' 'clean refuses: nothing here kills a process'
[ -d "$MISSIONS/demo/wt" ] && ok || fail 'clean --force removed the worktree of a live run'

# ================================================================ the node settles: the observer releases
node_session 22222222-3333-4444-5555-666666666666 answered - "mission demo in $MISSIONS/demo/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-held","owner":"master","run_id":"run-of-22222222","session_id":"22222222-3333-4444-5555-666666666666","state":"settled","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.22222222-3333-4444-5555-666666666666"
s=$(status_of demo)
case "$(field "$s" run)" in released*) ok ;; *) fail "status after the node settled: '$(field "$s" run)'" ;; esac
[ -f "$MISSIONS/demo/run.lock" ] && fail 'the lock must be released once the node says the run settled' || ok
has "$(cat "$MISSIONS/demo/lease.log")" 'by=status' 'lease.log says which observer released it'
export STUB_ID=33333333-4444-5555-6666-777777777777 STUB_RC=0 STUB_RESULT=ok STUB_NODE_KEEPS_RUN=no
out=$(run start demo); has "$out" 'started demo' 'once the node has settled it, a launch is allowed again'
wait_done demo || fail 'the third launch wrote no done marker'
has "$out" 'previous launch finished' 'start says the previous launch finished, and that this is a new session'

# ================================================================ the writer nobody recorded
# Measured on this node 18/11, mission-fabric: the session the mission dir recorded was 'failed', and a
# second session named by no run.lock - 6cdf7ddf, pid 1758185 - had the mission dir itself as its cwd with
# a heartbeat 0s old. A 'start' that asks only about its recorded session launches a second writer there,
# so the node's own presence table (session_presence: session_id, pid, heartbeat_at) is read as well and
# the process's cwd is what ties it to this mission.
presence() { # <session> <pid> <heartbeat-age-seconds>
  sqlite3 "$NODEHOME/memory.db" \
    "insert into session_presence(session_id,pid,boot,role,started_at,heartbeat_at) values('$1',$2,'boot-free','master',strftime('%s','now'),strftime('%s','now')-$3) on conflict(session_id) do update set pid=$2, heartbeat_at=strftime('%s','now')-$3" \
    || fail 'cannot write a presence row'
}
( cd "$MISSIONS/demo" && exec sleep 600 ) </dev/null >/dev/null 2>&1 &   # a process working IN the mission dir, as the CLI does
OTHER=$!
KIDS="$KIDS $OTHER"
sleep 0.2
presence aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$OTHER" 5
s=$(status_of demo)
case "$(field "$s" run)" in active*) ok ;; *) fail "a live process with the mission dir as its cwd must read active, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' 'the verdict names the session the node records for that pid'
has "$(field "$s" run)" "$MISSIONS/demo" 'the verdict says which directory that process works in'
has "$s" 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' 'status prints the writer, distinct from the session this mission records'
out=$(run start demo) && fail 'start must refuse while another session works in this mission directory' || ok
has "$out" 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' 'that refusal NAMES the session the mission never recorded'
has "$out" 'second writer' 'and says what a launch now would be'
out=$(run start demo --force) && fail 'start takes no flag, not even with a writer in the directory' || ok
has "$out" 'no --force' 'and it says so instead of reading a flag that no longer exists'

# Round 4: the heartbeat age is not asked any more. A presence row whose pid still has the mission dir as
# its cwd is a process working here NOW - it refuses whether it beat a second ago or an hour ago, and so
# does a row whose boot lease is held. No age, no lease, no flag.
presence aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$OTHER" 4000
s=$(status_of demo)
case "$(field "$s" run)" in active*) ok ;; *) fail "a quiet process in the mission dir must still read active, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" '4000s ago' 'the heartbeat age is reported, not obeyed'
# the same row, but the node still HOLDS its boot lease: the writer is named for the live pid either way
sqlite3 "$NODEHOME/resources/claims.sqlite" \
  "insert into claims(key,boot) values('session:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','boot-held') on conflict(key) do update set boot=excluded.boot" \
  || fail 'cannot give the quiet presence row a held boot'
out=$(run start demo) && fail 'a writer whose boot lease is held must refuse too' || ok
has "$out" 'clear it by hand' 'and gives the command that clears it by hand'
has "$out" 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' 'naming the session it refuses for'
sqlite3 "$NODEHOME/resources/claims.sqlite" "delete from claims where key='session:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'" \
  || fail 'cannot free the quiet presence row'


# the process is gone: a row with a dead pid is not a writer, and a launch is allowed again
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
# A pid the kernel cannot hand out again: this row is about a process that is GONE, and a real pid the fixture
# later re-uses would make the row mean something else (round 5 reads /proc/<pid> to tell the two cases apart).
DEADPID=2147483647
presence aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$DEADPID" 5
s=$(status_of demo)
case "$(field "$s" run)" in released*) ok ;; *) fail "a presence row whose pid is gone must not refuse a launch, got: '$(field "$s" run)'" ;; esac
out=$(run start demo); has "$out" 'started demo' 'with the stray process gone, a launch is allowed'
wait_done demo || fail 'the launch after the stray process wrote no done marker'

# ================================================================ a run row left behind: stale, and a refusal
# Round 4: a leftover is NOT a launch permission. The node lists the run in flight and its boot lease can
# be taken, so the owner has exited - and that is a state an operator clears with a command, not a flag.
export STUB_ID=44444444-5555-6666-7777-888888888888 STUB_RC=0 STUB_RESULT=ok STUB_NODE_KEEPS_RUN=no
run start demo >/dev/null; wait_done demo || fail 'the fourth launch wrote no done marker'
node_session 44444444-5555-6666-7777-888888888888 unfinished 0 "mission demo in $MISSIONS/demo/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-44444444","session_id":"44444444-5555-6666-7777-888888888888","state":"active","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.44444444-5555-6666-7777-888888888888"
sqlite3 "$NODEHOME/resources/claims.sqlite" "insert into claims(key,boot) values('session:44444444-5555-6666-7777-888888888888','boot-free') on conflict(key) do update set boot=excluded.boot"
s=$(status_of demo)
case "$(field "$s" run)" in stale*) ok ;; *) fail "a run row whose process is gone must read stale, got: '$(field "$s" run)'" ;; esac
out=$(run start demo) && fail 'a stale run row must refuse' || ok
has "$out" 'refusing [stale]' 'the leftover refusal names its state'
has "$out" 'leftover' 'and says the row is a leftover, not a launch permission'
has "$out" 'clear it by hand' 'and gives the command that clears it by hand'
has "$out" 'steering_runs' 'the exact row an operator settles, named'
has "$out" '44444444-5555-6666-7777-888888888888' 'naming the session'
# the operator does exactly that, and the launch is allowed again
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-44444444","session_id":"44444444-5555-6666-7777-888888888888","state":"settled","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.44444444-5555-6666-7777-888888888888"
out=$(run start demo); has "$out" 'started demo' 'once the leftover row is settled by hand, the launch is allowed'

# ================================================================ status/verify/report/clean on a quiet mission
wait_done demo || fail 'the launch after the leftover wrote no done marker'
s=$(status_of demo)
[ "$(field "$s" commits)" = 0 ] && ok || fail "status counted $(field "$s" commits) commits, there are none"
[ "$(field "$s" dirty)" = 0 ] && ok || fail 'status called a clean worktree dirty'
printf 'work\n' > "$MISSIONS/demo/wt/thing.txt"
git -C "$MISSIONS/demo/wt" add thing.txt && git -C "$MISSIONS/demo/wt" commit -qm 'demo commit'
[ "$(field "$(status_of demo)" commits)" = 1 ] && ok || fail 'status missed one commit'
printf 'unsaved\n' > "$MISSIONS/demo/wt/draft.txt"
[ "$(field "$(status_of demo)" dirty)" = 1 ] && ok || fail 'status missed one uncommitted path'
rm -f "$MISSIONS/demo/wt/draft.txt"
out=$(run verify demo pwd); rc=$?
[ "$rc" = 0 ] && ok || fail "verify pwd exited $rc"
has "$out" "$MISSIONS/demo/wt" 'verify runs in the mission worktree'
run verify demo false >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || fail "verify false exited $rc, not 1"
has "$(cat "$MISSIONS/demo/verify.log")" 'rc=1' 'verify records the failing rc'
out=$(run report demo)
has "$out" '-- lease' 'report has a lease section'
has "$out" 'cli-exit' 'report quotes the CLI exit from lease.log'
has "$out" 'no REPORT.md' 'report says the handover file is missing'
mkdir -p "$MISSIONS/demo/wt/docs/missions/reports"
printf '# demo, round 4
' > "$MISSIONS/demo/wt/docs/missions/reports/demo.md"
has "$(status_of demo)" 'docs/missions/reports/demo.md' 'status reads a round report kept under docs/missions/reports/<name>.md'
rm -rf "$MISSIONS/demo/wt/docs"
printf 'dirty\n' >> "$MISSIONS/demo/wt/thing.txt"
out=$(run clean demo) && fail 'clean on a dirty worktree must refuse' || ok
has "$out" 'uncommitted' 'the refusal names the uncommitted paths'
out=$(run clean demo --force) && ok || fail "clean --force failed: $out"
[ -d "$MISSIONS/demo/wt" ] && fail 'clean left the worktree' || ok
git -C "$REPO" show-ref --verify -q refs/heads/change/demo && ok || fail 'clean deleted the branch'
[ -f "$MISSIONS/demo/lease.log" ] && ok || fail 'clean deleted the lease log'
[ -f "$MISSIONS/demo/done" ] && ok || fail 'clean deleted the done marker'
out=$(run clean demo) && ok || fail "the second clean should be a no-op: $out"
[ -f "$MISSIONS/demo/start.flock" ] && fail 'clean left the start lock file' || ok
has "$out" 'already clean' 'the second clean says there is nothing to remove'

# ================================================================ a mission staged before this script
#     (no env file, no lock): the id is in out.log, and the node is asked about it.
legacy=$MISSIONS/legacy; mkdir -p "$legacy"
git -C "$REPO" worktree add -q -b change/legacy "$legacy/wt" main
printf '! run_failed: legacy_provider - a failure in a mission staged by the old launcher\n' > "$legacy/out.log"
printf 'wa: session 55555555-6666-7777-8888-999999999999 ok\n' >> "$legacy/out.log"
node_session 55555555-6666-7777-8888-999999999999 answered - "mission legacy in $legacy/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-legacy","session_id":"55555555-6666-7777-8888-999999999999","state":"settled","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.55555555-6666-7777-8888-999999999999"
s=$(status_of legacy)
[ "$(field "$s" worktree)" = "$legacy/wt" ] && ok || fail "legacy worktree: '$(field "$s" worktree)'"
[ "$(field "$s" session)" = "55555555-6666-7777-8888-999999999999" ] && ok || fail "legacy session: '$(field "$s" session)'"
[ "$(field "$s" failures)" = 1 ] && ok || fail "legacy failures: '$(field "$s" failures)'"
case "$(field "$s" run)" in released*) ok ;; *) fail "legacy run: '$(field "$s" run)'" ;; esac
has "$(run status)" 'name       legacy' 'status with no name lists a mission that has only a worktree'

# ================================================================ the marker match: no lock, no log line, and
#     the only thing tying the session to the mission is the title the node shows.
orphan=$MISSIONS/orphan; mkdir -p "$orphan"
git -C "$REPO" worktree add -q -b change/orphan "$orphan/wt" main
printf '%s\n' "mission orphan in $orphan/wt" > "$orphan/prompt.md"
node_session 66666666-7777-8888-9999-aaaaaaaaaaaa unfinished 0 "mission orphan in $orphan/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-held","owner":"master","run_id":"run-of-orphan","session_id":"66666666-7777-8888-9999-aaaaaaaaaaaa","state":"active","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.66666666-7777-8888-9999-aaaaaaaaaaaa"
sqlite3 "$NODEHOME/resources/claims.sqlite" "insert into claims(key,boot) values('session:66666666-7777-8888-9999-aaaaaaaaaaaa','boot-held') on conflict(key) do update set boot=excluded.boot"
s=$(status_of orphan)
[ "$(field "$s" session)" = "66666666-7777-8888-9999-aaaaaaaaaaaa" ] && ok \
  || fail "the marker must find the session by the node's title, got: '$(field "$s" session)'"
case "$(field "$s" run)" in active*) ok ;; *) fail "the matched session's run: '$(field "$s" run)'" ;; esac

# ================================================================ a node whose lease store cannot be read:
#     "active" with an old updated_at must be a REFUSAL, never a release. Measured 18/11 by the other
#     session on this mission: a live run 25 minutes in reported state=active with updated_at 1533 s old,
#     because that field is the run's start, not its last context boundary.
quiet=$MISSIONS/quiet; mkdir -p "$quiet"
git -C "$REPO" worktree add -q -b change/quiet "$quiet/wt" main
printf '%s\n' "MISSION='quiet'" "SESSION='77777777-8888-9999-aaaa-bbbbbbbbbbbb'" "WORKTREE='$quiet/wt'" \
  "NODE='$(hostname -s)'" "LAUNCHER='0'" "LOCKED='2026-11-18T00:00:00Z'" > "$quiet/run.lock"
node_session 77777777-8888-9999-aaaa-bbbbbbbbbbbb unfinished 1533 "mission quiet in $quiet/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-unprobeable","owner":"master","run_id":"run-of-quiet","session_id":"77777777-8888-9999-aaaa-bbbbbbbbbbbb","state":"active","updated_at":%s}}\n' "$(( $(now) - 1533 ))" \
  > "$STUB_STATE/steer.77777777-8888-9999-aaaa-bbbbbbbbbbbb"
s=$(run_nonode status quiet)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "active with an unreadable lease store must refuse, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'nothing here can show the owner is gone' 'and says why it cannot release it'
case "$(field "$s" boot)" in unknown*) ok ;; *) fail "an unreadable store must say unknown, got: '$(field "$s" boot)'" ;; esac

# ================================================================ an unreachable node: unknown, and nothing else
# Measured in this fixture before round 3: a 'wa sessions' that fails left mission_run at 'unknown' and
# start launched, because the launcher of the previous launch had already exited. Round 4 removes the last
# way past it: unknown refuses whether or not a session was ever recorded, and the manual command it names
# is the one that makes the node answer. There is no --force left to try.
out=$(run stage nodead main "$WORK/brief.md"); [ $? = 0 ] || fail "stage nodead: $out"
export STUB_SESSIONS_FAIL=yes
nodead=$MISSIONS/nodead
printf '%s\n' "MISSION='nodead'" "SESSION='aaaaaaaa-1111-2222-3333-444444444444'" "WORKTREE='$nodead/wt'" \
  "NODE='$(hostname -s)'" "LAUNCHER='0'" "LOCKED='2026-11-18T00:00:00Z'" > "$nodead/run.lock"
s=$(status_of nodead)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "a node that cannot be asked must read unknown, got: '$(field "$s" run)'" ;; esac
out=$(run start nodead) && fail 'start must refuse when the node cannot be asked' || ok
has "$out" 'refusing [unknown]' 'the unknown refusal names its state'
has "$out" 'could not be asked' 'and says the node could not be asked'
has "$out" 'aaaaaaaa-1111-2222-3333-444444444444' 'the unknown refusal NAMES the recorded session'
has "$out" 'wa sessions 100' 'and gives the exact command that makes the node answer'
[ -f "$nodead/done" ] && fail 'a refused start must not have launched anything' || ok
rm -f "$nodead/run.lock"
out=$(run start nodead) && fail 'an unanswerable node refuses even with nothing recorded' || ok
has "$out" 'refusing [unknown]' 'and it is the same unknown'
# round 5, item 4: a clean is refused on the same answer. 'active' was its only refusal, so an unknown verdict
# went straight to 'git worktree remove' - a cleanup of a mission whose node could not even be asked.
out=$(run clean nodead) && fail 'clean must refuse when the node cannot be asked' || ok
has "$out" 'refusing [unknown]' 'the unknown refusal names its state'
has "$out" 'a clean removes the worktree' 'and says what it would have done'
[ -d "$nodead/wt" ] && ok || fail 'a refused clean removed the worktree'
export STUB_SESSIONS_FAIL=no

# ================================================================ round 3, item 2: quiet is not gone
# The 300 s window is a guess about the gap between a run's context boundaries; the boot lease is the
# owner's own statement that it has not exited. Measured on this node: a live run whose last boundary was
# 969 s old read 'stale', and --force launched past it. So a held lease is active at ANY age, and stale
# only when the lease can be TAKEN.
out=$(run stage qheld main "$WORK/brief.md"); [ $? = 0 ] || fail "stage qheld: $out"
qheld=$MISSIONS/qheld
node_session bbbbbbbb-1111-2222-3333-444444444444 unfinished 4000 "mission qheld in $qheld/wt"
sqlite3 "$NODEHOME/resources/claims.sqlite" \
  "insert into claims(key,boot) values('session:bbbbbbbb-1111-2222-3333-444444444444','boot-held') on conflict(key) do update set boot=excluded.boot" \
  || fail 'cannot claim a held boot for the quiet session'
printf '{"note":"x","receipts":[],"target":{"boot":"boot-held","owner":"master","run_id":"run-of-qheld","session_id":"bbbbbbbb-1111-2222-3333-444444444444","state":"active","updated_at":%s}}\n' "$(( $(now) - 4000 ))" \
  > "$STUB_STATE/steer.bbbbbbbb-1111-2222-3333-444444444444"
s=$(status_of qheld)
case "$(field "$s" run)" in active*) ok ;; *) fail "a quiet session whose boot lease is held must read active, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'held boot' 'and says which fact decided it: the boot lease is held'
has "$(field "$s" run)" 'bbbbbbbb-1111-2222-3333-444444444444' 'the verdict names the session it matched by title'
out=$(run start qheld) && fail 'a quiet session with a held lease must refuse' || ok
has "$out" 'refusing [active]' 'the refusal names the held lease as active'
has "$out" 'bbbbbbbb-1111-2222-3333-444444444444' 'and names the session'
# the same row, with a lease the probe can take: the owner exited, so the row is a leftover: stale
sqlite3 "$NODEHOME/resources/claims.sqlite" "update claims set boot='boot-free' where key='session:bbbbbbbb-1111-2222-3333-444444444444'"
s=$(status_of qheld)
case "$(field "$s" run)" in stale*) ok ;; *) fail "a quiet session whose lease can be taken must read stale, got: '$(field "$s" run)'" ;; esac
out=$(run start qheld) && fail 'a stale row must refuse' || ok
has "$out" 'refusing [stale]' 'a lease the probe can take is a leftover, and a leftover refuses'
export STUB_ID=eeeeeeee-1111-2222-3333-444444444444 STUB_RC=0 STUB_RESULT=ok STUB_NODE_KEEPS_RUN=no
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-qheld","session_id":"bbbbbbbb-1111-2222-3333-444444444444","state":"settled","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.bbbbbbbb-1111-2222-3333-444444444444"
out=$(run start qheld) && ok || fail "the launch after the operator settled the row failed: $out"
has "$out" 'started qheld' 'and then the launch happens'
wait_done qheld || fail 'the launch of qheld wrote no done marker'

# ================================================================ round 3, item 3: cannot tell is not released
# The session list's unfinished branch answered 'released' when the boot lease could not be probed (no
# sqlite3, no store, an unreadable one). That is the same 'cannot tell' the run-lease branch already
# refuses, so it is active here too - for a session with an age and for one with none.
noage=$MISSIONS/noage; mkdir -p "$noage"
git -C "$REPO" worktree add -q -b change/noage "$noage/wt" main
printf '%s\n' "mission noage in $noage/wt" > "$noage/prompt.md"
node_session cccccccc-1111-2222-3333-444444444444 unfinished - "mission noage in $noage/wt"
s=$(run_nonode status noage)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "an unfinished session with no age and an unprobeable lease must refuse, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'nothing here can show it is settled' 'and says so instead of releasing it'
node_session cccccccc-1111-2222-3333-444444444444 unfinished 4000 "mission noage in $noage/wt"
s=$(run_nonode status noage)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "a quiet unfinished session with an unprobeable lease must refuse, got: '$(field "$s" run)'" ;; esac
case "$(field "$s" boot)" in unknown*) ok ;; *) fail "the boot read must say unknown: '$(field "$s" boot)'" ;; esac

# the same class from the run lease: a state of 'unknown' is the node saying it cannot tell, not a release
printf '{"note":"x","receipts":[],"target":{"boot":"boot-held","owner":"master","run_id":"run-of-quiet","session_id":"77777777-8888-9999-aaaa-bbbbbbbbbbbb","state":"unknown","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.77777777-8888-9999-aaaa-bbbbbbbbbbbb"
sqlite3 "$NODEHOME/resources/claims.sqlite" \
  "insert into claims(key,boot) values('session:77777777-8888-9999-aaaa-bbbbbbbbbbbb','boot-held') on conflict(key) do update set boot=excluded.boot" \
  || fail 'cannot claim a boot for the unknown-state session'
s=$(status_of quiet)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "a run lease that answers 'unknown' must not release a held boot, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" "answered 'unknown'" 'and says the run lease answered nothing usable'

# ================================================================ ONE START AT A TIME: flock -n, one launch
# Round 3 held the check-and-launch window with 'mkdir $M/start.lock' and cleared a dead holder with
# 'rm -rf'. Two starts could then both clear it and both take it. Round 4 uses one kernel lock instead:
# flock -n on $M/start.flock, held until the launch has a run.pid and dropped by the kernel when the holder
# exits. There is no dead lock left behind to clear, and two starts cannot both get past the check.
out=$(run stage race main "$WORK/brief.md"); [ $? = 0 ] || fail "stage race: $out"
race=$MISSIONS/race
# A runner that takes 300 ms to write run.pid: the window an operator's second start opens anyway (bash
# start-up under load), made deterministic so the fixture can prove the exclusion instead of hoping for it.
sed -i '2i sleep 0.3' "$race/run.sh"
bash -n "$race/run.sh" || fail 'the slowed runner does not parse'
export STUB_ID=ffffffff-1111-2222-3333-444444444444 STUB_RC=0 STUB_RESULT=ok STUB_NODE_KEEPS_RUN=no
start_bg() { # <mission> <log>
  ( MISSION_REPO=$REPO MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSIONS_TOOLCHAIN=$WORK/toolchain \
    WA_BIN=$WORK/bin/wa MISSION_NODE_HOME=$NODEHOME bash "$MISSION" start "$1" >"$2" 2>&1 ) &
}
start_bg race "$WORK/race-1"; r1=$!
sleep 0.1
start_bg race "$WORK/race-2"; r2=$!
wait "$r1" "$r2"
wins=$(grep -l 'started race' "$WORK/race-1" "$WORK/race-2" 2>/dev/null | wc -l)
[ "$wins" = 1 ] && ok || fail "two starts 100 ms apart must make ONE launch, made $wins: $(cat "$WORK/race-1") | $(cat "$WORK/race-2")"
loser=$(grep -L 'started race' "$WORK/race-1" "$WORK/race-2" | head -1)
has "$(cat "$loser")" 'start.flock' 'the start that lost says which lock stopped it'
has "$(cat "$loser")" 'refusing' 'and refuses instead of launching'
has "$(cat "$loser")" 'nothing to clear' 'and says the kernel releases it: no dead lock to clear by hand'
wait_done race || fail 'the winning launch wrote no done marker'

# round 4, item 2: two starts clearing a DEAD lock. A leftover lock FILE - a start killed before it could
# launch - is not a lock any more: the kernel dropped it with the process. Planted, it must neither stop a
# launch nor let two launches through.
: > "$race/start.flock"
start_bg race "$WORK/dead-1"; d1=$!
sleep 0.1
start_bg race "$WORK/dead-2"; d2=$!
wait "$d1" "$d2"
wins=$(grep -l 'started race' "$WORK/dead-1" "$WORK/dead-2" 2>/dev/null | wc -l)
[ "$wins" = 1 ] && ok || fail "a leftover lock FILE must not let two starts launch, made $wins: $(cat "$WORK/dead-1") | $(cat "$WORK/dead-2")"
wait_done race || fail 'the launch beside the leftover lock file wrote no done marker'

# a start already inside its window: a real holder of the lock. The second start refuses, names the file,
# and there is nothing to pass it with.
( exec 9>>"$race/start.flock"; flock -n 9 || exit 9; sleep 30 ) & HOLDER=$!
KIDS="$KIDS $HOLDER"
sleep 0.2
out=$(run start race) && fail 'a start must refuse while another start holds the window' || ok
has "$out" 'start.flock' 'the refusal names the lock file'
has "$out" 'refusing' 'and refuses instead of launching'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
out=$(run start race) && ok || fail "once the holder exits, the kernel has released it and the launch happens: $out"
wait_done race || fail 'the launch after the holder exited wrote no done marker'

# ================================================================ round 4, item 3(a): a live launcher whose
# new session is not yet named. The runner has taken run.lock (SESSION='' until the node names one) and
# run.pid names the process standing in the window, so nothing but alive_launcher can catch it.
out=$(run stage launch main "$WORK/brief.md"); [ $? = 0 ] || fail "stage launch: $out"
launch=$MISSIONS/launch
printf '%s\n' "MISSION='launch'" "SESSION=''" "WORKTREE='$launch/wt'" "NODE='$(hostname -s)'" \
  "LAUNCHER='0'" "LOCKED='$(date -u +%FT%TZ)'" > "$launch/run.lock"
( cd "$launch" && exec sleep 600 ) </dev/null >/dev/null 2>&1 &    # the launcher, cwd = the mission dir
LPID=$!
KIDS="$KIDS $LPID"
sleep 0.2
printf '%s\n' "$LPID" > "$launch/run.pid"
out=$(run start launch) && fail 'a live launcher that has not named its session must refuse a launch' || ok
has "$out" 'refusing [launcher]' 'the launcher refusal names its state'
has "$out" "$LPID" 'and names the pid standing in the window'
has "$out" "rm $launch/run.pid" 'and gives the exact file an operator removes after checking'
[ -f "$launch/done" ] && fail 'the refused launch must not have started anything' || ok
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
rm -f "$launch/run.pid" "$launch/run.lock"
out=$(run start launch); has "$out" 'started launch' 'with the launcher gone and nothing recorded, it launches'
wait_done launch || fail 'the launch after the planted launcher wrote no done marker'

# ================================================================ round 4, item 3(d): a session that is
# STARTING - listed unfinished, no run row yet, no claim row and no lease file. Round 3 read a boot claim it
# could not find as a boot the probe could take, so it said 'stale' and --force launched through it.
out=$(run stage starting main "$WORK/brief.md"); [ $? = 0 ] || fail "stage starting: $out"
starting=$MISSIONS/starting
node_session dddddddd-1111-2222-3333-444444444444 unfinished 0 "mission starting in $starting/wt"
printf '%s\n' "MISSION='starting'" "SESSION='dddddddd-1111-2222-3333-444444444444'" "WORKTREE='$starting/wt'" \
  "NODE='$(hostname -s)'" "LAUNCHER='0'" "LOCKED='$(date -u +%FT%TZ)'" > "$starting/run.lock"
rm -f "$STUB_STATE/steer.dddddddd-1111-2222-3333-444444444444"   # the CLI has not got as far as a run row
s=$(status_of starting)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "a starting session must refuse a launch, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'STARTING' 'and says the session is starting: no run row, no claim, no lease file'
out=$(run start starting) && fail 'a session that is starting must refuse a launch' || ok
has "$out" 'refusing [unknown]' 'the refusal names its state'
has "$out" 'wa steer dddddddd-1111-2222-3333-444444444444 --status' 'and gives the exact command to read it again'

# ================================================================ round 4, item 3(c): unknown AND a writer
# the harness started. The node cannot be asked at all, and memory.db still names a live process working in
# the mission dir. It must refuse, and name the writer rather than only the silence.
export STUB_SESSIONS_FAIL=yes
( cd "$starting" && exec sleep 600 ) </dev/null >/dev/null 2>&1 &
HPID=$!
KIDS="$KIDS $HPID"
sleep 0.2
presence eeeeeeee-ffff-0000-1111-222222222222 "$HPID" 0
out=$(run start starting) && fail 'unknown plus a writer in the mission dir must refuse' || ok
has "$out" 'refusing [active]' 'the writer is the reason, and not the silence of the node'
has "$out" 'eeeeeeee-ffff-0000-1111-222222222222' 'and the refusal names the session the harness started'
has "$out" "$starting" 'and the directory that process works in'
export STUB_SESSIONS_FAIL=no
kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
sqlite3 "$NODEHOME/memory.db" "delete from session_presence where session_id='eeeeeeee-ffff-0000-1111-222222222222'" \
  || fail 'cannot drop the harness writer presence row'
rm -f "$starting/run.lock"

# ================================================================ round 3, item 6: a log is not a session id
# The id goes from run.lock / err.log / out.log into SQL (claims.sqlite). 36 characters of [0-9a-f-], or
# nothing: a quote in a log line must never become part of a query.
badid=$MISSIONS/badid; mkdir -p "$badid"
git -C "$REPO" worktree add -q -b change/badid "$badid/wt" main
INJ="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"
[ "${#INJ}" = 36 ] || fail 'the fixture injection string is not 36 characters long'
printf '%s\n' "MISSION='badid'" "SESSION='$INJ'" "WORKTREE='$badid/wt'" "NODE='$(hostname -s)'" \
  "LAUNCHER='0'" "LOCKED='2026-11-18T00:00:00Z'" > "$badid/run.lock"
s=$(status_of badid)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "a recorded session id that is not an id must refuse, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'not a session id' 'and the reason is the id: it never becomes part of a query'
case "$(field "$s" boot)" in unknown*) ok ;; *) fail "the boot read must be unknown for a non-id: '$(field "$s" boot)'" ;; esac
rm -f "$badid/run.lock"
printf 'wa: session zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz ok\n' > "$badid/out.log"
s=$(status_of badid)
[ "$(field "$s" session)" = '-' ] && ok || fail "a log line that is not a session id must not be read as one: '$(field "$s" session)'"

# ================================================================ round 5, item 1: the presence read's "cannot
# tell" is 'unknown', never 'no writer'. node_presence answers rc 2 when the node's memory.db cannot be read,
# and round 4's writers_check turned that rc 2 into "no writer": mission_run said 'released' and start LAUNCHED
# past a read it could not make.
out=$(run stage nomem main "$WORK/brief.md"); [ $? = 0 ] || fail "stage nomem: $out"
nomem=$MISSIONS/nomem
NOMEM=$WORK/node-nomem; mkdir -p "$NOMEM/resources"       # a node with a claim store and NO memory.db at all
cp "$NODEHOME/resources/claims.sqlite" "$NOMEM/resources/claims.sqlite"
s=$(run_node "$NOMEM" status nomem)
case "$(field "$s" run)" in unknown*) ok ;; *) fail "a node with no memory.db must read unknown, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'memory.db' 'the reason names the file it could not read'
has "$(field "$s" run)" 'cannot be told' 'and says what it cannot tell: where the writers are'
out=$(run_node "$NOMEM" start nomem) && fail 'start must refuse when the presence read cannot be made' || ok
has "$out" 'refusing [unknown]' 'the refusal names the state'
has "$out" 'cannot be read' 'and quotes the read that failed'
has "$out" 'memory.db' 'and the file it names'
[ -f "$nomem/done" ] && fail 'a refused start must not have launched anything' || ok
[ -f "$nomem/run.lock" ] && fail 'a refused start must not have taken the run lock' || ok
# the same node, with a memory.db this user cannot read - the shape the brief's row names
if [ "$(id -u)" = 0 ]; then
  printf 'note: running as root, so chmod 000 is still readable - the unreadable-memory.db case is skipped\n'
else
  DENIED=$WORK/node-denied; mkdir -p "$DENIED/resources"
  cp "$NODEHOME/memory.db" "$DENIED/memory.db"; chmod 000 "$DENIED/memory.db"
  cp "$NODEHOME/resources/claims.sqlite" "$DENIED/resources/claims.sqlite"
  s=$(run_node "$DENIED" status nomem)
  case "$(field "$s" run)" in unknown*) ok ;; *) fail "an unreadable memory.db must read unknown, got: '$(field "$s" run)'" ;; esac
  has "$(field "$s" run)" 'unreadable' 'the reason says the file is unreadable'
  out=$(run_node "$DENIED" start nomem) && fail 'start must refuse on an unreadable memory.db' || ok
  has "$out" 'refusing [unknown]' 'and that refusal is unknown too'
  chmod 644 "$DENIED/memory.db"
fi
# and with a memory.db that reads and holds no writer, the same mission is released: the refusal was the read
s=$(status_of nomem)
case "$(field "$s" run)" in released*) ok ;; *) fail "with a readable memory.db and no writer, nomem must be released, got: '$(field "$s" run)'" ;; esac

# ================================================================ round 5, item 2: a live process whose cwd
# cannot be read. /proc/<pid> still existing means the process is there, so readlink failing is NOT "it exited".
# pid 1 is another user's process: its /proc entry exists and its cwd is unreadable for a normal user - the same
# shape hidepid gives every other user's process.
if readlink /proc/1/cwd >/dev/null 2>&1; then
  printf 'note: /proc/1/cwd is readable here (root?) - the unreadable-cwd case is skipped\n'
else
  out=$(run stage noread main "$WORK/brief.md"); [ $? = 0 ] || fail "stage noread: $out"
  noread=$MISSIONS/noread
  presence ffffffff-2222-3333-4444-555555555555 1 0
  s=$(status_of noread)
  case "$(field "$s" run)" in unknown*) ok ;; *) fail "a live pid whose cwd cannot be read must read unknown, got: '$(field "$s" run)'" ;; esac
  has "$(field "$s" run)" 'pid 1' 'the reason names the pid it could not place'
  has "$(field "$s" run)" 'cannot be read' 'and says its cwd could not be read'
  out=$(run start noread) && fail 'start must refuse while a live process it cannot place is running' || ok
  has "$out" 'refusing [unknown]' 'the refusal names the state'
  has "$out" 'pid 1' 'and the pid it could not place'
  [ -f "$noread/done" ] && fail 'a refused start must not have launched anything' || ok
  sqlite3 "$NODEHOME/memory.db" "delete from session_presence where session_id='ffffffff-2222-3333-4444-555555555555'" \
    || fail 'cannot drop the unreadable-cwd row'
  out=$(run start noread); has "$out" 'started noread' 'with the unplaceable process gone, the launch happens'
  wait_done noread || fail 'the launch after the unreadable-cwd row wrote no done marker'
fi

# ================================================================ round 5, item 3: the start window closes on
# run.pid, never on a clock. A runner that ENDS before writing one (95 wrong node, 96 cannot cd, 98 no env)
# launched nothing, and round 4 printed "started" for it after 5 s and returned 0.
out=$(run stage early main "$WORK/brief.md"); [ $? = 0 ] || fail "stage early: $out"
early=$MISSIONS/early
sed -i '2i exit 95' "$early/run.sh"
bash -n "$early/run.sh" || fail 'the early-exit runner does not parse'
out=$(run start early) && fail 'a runner that exits before writing run.pid must not be reported as started' || ok
has "$out" 'refusing [launcher]' 'the refusal names the state'
has "$out" 'rc=95' "and carries the runner's own exit"
lacks "$out" 'started early' 'and never says the mission started'
[ -f "$early/done" ] && fail 'the refused launch wrote a done marker' || ok
[ -s "$early/run.pid" ] && fail 'the refused launch left a run.pid' || ok
# a runner that is SLOW to write it: start waits for the marker instead of calling the launch done after 5 s
out=$(run stage slow main "$WORK/brief.md"); [ $? = 0 ] || fail "stage slow: $out"
slow=$MISSIONS/slow
sed -i '2i sleep 6' "$slow/run.sh"
bash -n "$slow/run.sh" || fail 'the slow runner does not parse'
out=$(run start slow) || fail "the slow runner's start failed: $out"
has "$out" 'started slow' 'a slow runner is still a launch'
[ -s "$slow/run.pid" ] && ok || fail 'start printed started before the runner had written run.pid (the 5 s cap)'
wait_done slow || fail 'the slow launch wrote no done marker'

# ================================================================ round 5, item 4: clean refuses anything that
# is not 'released'. 'active' was its only refusal, so a leftover row (stale) and a read that could not be made
# (unknown, above) went through to 'git worktree remove'.
out=$(run stage leftover main "$WORK/brief.md"); [ $? = 0 ] || fail "stage leftover: $out"
leftover=$MISSIONS/leftover
node_session 12121212-3434-5656-7878-909090909090 unfinished 0 "mission leftover in $leftover/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-leftover","session_id":"12121212-3434-5656-7878-909090909090","state":"active","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.12121212-3434-5656-7878-909090909090"
sqlite3 "$NODEHOME/resources/claims.sqlite" "insert into claims(key,boot) values('session:12121212-3434-5656-7878-909090909090','boot-free') on conflict(key) do update set boot=excluded.boot" \
  || fail 'cannot give the leftover row a free boot'
s=$(status_of leftover)
case "$(field "$s" run)" in stale*) ok ;; *) fail "the leftover mission must read stale, got: '$(field "$s" run)'" ;; esac
out=$(run clean leftover) && fail 'clean must refuse a leftover (stale) run' || ok
has "$out" 'refusing [stale]' 'the refusal names the leftover'
has "$out" 'clear it by hand' 'and gives the command that clears it by hand'
has "$out" 'steering_runs' 'the exact row an operator settles, named'
[ -d "$leftover/wt" ] && ok || fail 'a refused clean removed the worktree of a leftover mission'
out=$(run clean leftover --force) && fail '--force must not clean past a leftover either' || ok
[ -d "$leftover/wt" ] && ok || fail 'clean --force removed the worktree of a leftover mission'
# the operator settles the row by hand: then a clean is allowed, and it is the clean that removes the worktree
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-leftover","session_id":"12121212-3434-5656-7878-909090909090","state":"settled","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.12121212-3434-5656-7878-909090909090"
out=$(run clean leftover) || fail "the clean after the row was settled failed: $out"
has "$out" 'removed worktree' 'and it is the clean that removes it'
[ -d "$leftover/wt" ] && fail 'the clean left the worktree' || ok

printf 'mission fixture: %s checks ok\n' "$checks"
