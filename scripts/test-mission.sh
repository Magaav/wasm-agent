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
MISSION=$ROOT/scripts/mission.sh
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
# The same read from a node whose lease store does not exist: "cannot tell" must not become "released".
run_nonode() { MISSION_REPO=$REPO MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSIONS_TOOLCHAIN=$WORK/toolchain \
  WA_BIN=$WORK/bin/wa MISSION_NODE_HOME=$WORK/no-such-node bash "$MISSION" "$@" 2>&1; }
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
out=$(run start demo --force) && fail '--force must not launch alongside a run the node reports active' || ok
has "$out" 'refusing' '--force refuses too'
has "$out" 'no wa verb that cancels' 'and says what it cannot do: there is no wa verb that cancels a run'
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
sqlite3 "$NODEHOME/memory.db" \
  "create table if not exists session_presence(session_id text primary key, pid integer, boot text, role text, started_at real, heartbeat_at real)" \
  || fail 'cannot build the node presence table'
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
out=$(run start demo --force) && fail '--force must not launch next to a live process in the mission dir' || ok
has "$out" 'refusing' '--force refuses a live writer too'

# the same process, quiet for longer than the window: stale, refused without --force, still named
presence aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$OTHER" 4000
s=$(status_of demo)
case "$(field "$s" run)" in stale*) ok ;; *) fail "a quiet leftover process must read stale, got: '$(field "$s" run)'" ;; esac
out=$(run start demo) && fail 'a quiet leftover must refuse without --force' || ok
has "$out" 'refusing' 'the leftover refusal refuses'

# the process is gone: a row with a dead pid is not a writer, and a launch is allowed again
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
presence aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "$OTHER" 5
s=$(status_of demo)
case "$(field "$s" run)" in released*) ok ;; *) fail "a presence row whose pid is gone must not refuse a launch, got: '$(field "$s" run)'" ;; esac
out=$(run start demo); has "$out" 'started demo' 'with the stray process gone, a launch is allowed'
wait_done demo || fail 'the launch after the stray process wrote no done marker'

# ================================================================ a run row left behind: stale, and --force
export STUB_ID=44444444-5555-6666-7777-888888888888 STUB_RC=0 STUB_RESULT=ok STUB_NODE_KEEPS_RUN=no
run start demo >/dev/null; wait_done demo || fail 'the fourth launch wrote no done marker'
node_session 44444444-5555-6666-7777-888888888888 unfinished 0 "mission demo in $MISSIONS/demo/wt"
printf '{"note":"x","receipts":[],"target":{"boot":"boot-free","owner":"master","run_id":"run-of-44444444","session_id":"44444444-5555-6666-7777-888888888888","state":"active","updated_at":%s}}\n' "$(now)" \
  > "$STUB_STATE/steer.44444444-5555-6666-7777-888888888888"
sqlite3 "$NODEHOME/resources/claims.sqlite" "insert into claims(key,boot) values('session:44444444-5555-6666-7777-888888888888','boot-free') on conflict(key) do update set boot=excluded.boot"
s=$(status_of demo)
case "$(field "$s" run)" in stale*) ok ;; *) fail "a run row whose process is gone must read stale, got: '$(field "$s" run)'" ;; esac
out=$(run start demo) && fail 'a stale run row must refuse without --force' || ok
has "$out" 'refusing' 'the stale refusal refuses'
out=$(run start demo --force) && ok || fail '--force must pass a run row the node says is a leftover'
has "$out" '--force:' 'and says what it is forcing past'
has "$(cat "$MISSIONS/demo/lease.log")" 'forced past a stale lease' 'lease.log records what the force stepped past'

# ================================================================ status/verify/report/clean on a quiet mission
wait_done demo || fail 'the forced launch wrote no done marker'
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
printf 'dirty\n' >> "$MISSIONS/demo/wt/thing.txt"
out=$(run clean demo) && fail 'clean on a dirty worktree must refuse' || ok
has "$out" 'uncommitted' 'the refusal names the uncommitted paths'
out=$(run clean demo --force) && ok || fail "clean --force failed: $out"
[ -d "$MISSIONS/demo/wt" ] && fail 'clean left the worktree' || ok
git -C "$REPO" show-ref --verify -q refs/heads/change/demo && ok || fail 'clean deleted the branch'
[ -f "$MISSIONS/demo/lease.log" ] && ok || fail 'clean deleted the lease log'
[ -f "$MISSIONS/demo/done" ] && ok || fail 'clean deleted the done marker'
out=$(run clean demo) && ok || fail "the second clean should be a no-op: $out"
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
case "$(field "$s" run)" in active*) ok ;; *) fail "active with an unreadable lease store must refuse, got: '$(field "$s" run)'" ;; esac
has "$(field "$s" run)" 'nothing here can show the owner is gone' 'and says why it cannot release it'
case "$(field "$s" boot)" in unknown*) ok ;; *) fail "an unreadable store must say unknown, got: '$(field "$s" boot)'" ;; esac

printf 'mission fixture: %s checks ok\n' "$checks"
