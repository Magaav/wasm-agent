#!/usr/bin/env bash
# Fixture proof for scripts/mission.sh against a scratch repository and a stub 'wa':
# stage, start (one session, a done marker with its rc, a second launch refused), status
# (commits/files/dirty/failures from the real files), verify (the rc is the command's), clean
# (a dirty worktree is refused, --force removes it, the evidence stays, the branch survives).
#
#   bash scripts/test-mission.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
MISSION=$ROOT/scripts/mission.sh
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { printf 'mission fixture FAILED: %s\n' "$*" >&2; exit 1; }
has() { # <text> <needle> <what>
  case $1 in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -3)" ;; esac
}
lacks() { case $1 in *"$2"*) fail "$3: '$2' should not be in: $1" ;; *) ok ;; esac; }
status_of() { # <mission>
  MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSION_REPO=$REPO WA_BIN=$WORK/bin/wa \
    bash "$MISSION" status "$1" 2>&1
}
field() { printf '%s\n' "$1" | sed -n "s/^$2 *//p" | head -1; }

# --- a scratch repository (one commit on main) and a stub wa that prints what the real one prints.
export REPO=$WORK/repo MISSION_ROOT=$WORK
MISSIONS=$WORK/missions TARGET=$WORK/target
mkdir -p "$REPO" "$WORK/bin" "$MISSIONS"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name fixture
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md && git -C "$REPO" commit -qm 'base commit'

export STUB_LOG=$WORK/wa.log
cat > "$WORK/bin/wa" <<'STUB'
#!/usr/bin/env bash
printf 'stub-wa %s\n' "$*" >> "$STUB_LOG"
[ "${STUB_SLEEP:-0}" != 0 ] && sleep "$STUB_SLEEP"
printf 'wa: session 11111111-2222-3333-4444-555555555555 ok\n'
[ "${STUB_FAIL:-0}" = 1 ] && printf '! run_failed: stub_provider - the fixture failure\n'
exit "${STUB_RC:-0}"
STUB
chmod +x "$WORK/bin/wa"
printf '# demo brief\n\nBuild the demo thing. Report what you verified.\n' > "$WORK/brief.md"

run() { # <args...> with the fixture's environment
  MISSION_REPO=$REPO MISSIONS_DIR=$MISSIONS MISSIONS_TARGET_ROOT=$TARGET MISSIONS_TOOLCHAIN=$WORK/toolchain \
    WA_BIN=$WORK/bin/wa bash "$MISSION" "$@" 2>&1
}

# --- stage: a worktree on change/<name>, an env file, the prompt that says where it is, one runner.
out=$(run stage demo main "$WORK/brief.md"); rc=$?
[ "$rc" = 0 ] || fail "stage exited $rc: $out"
has "$out" "staged demo" 'stage names the mission'
[ -d "$MISSIONS/demo/wt" ] && ok || fail 'stage made no worktree at missions/demo/wt'
[ "$(git -C "$MISSIONS/demo/wt" rev-parse --abbrev-ref HEAD)" = change/demo ] && ok || fail 'the worktree is not on change/demo'
has "$(cat "$MISSIONS/demo/env")" "TARGET='$TARGET/m-demo'" 'the env records this mission'"'"'s own build dir'
has "$(cat "$MISSIONS/demo/prompt.md")" "## Where you are" 'the prompt says where the session is'
has "$(cat "$MISSIONS/demo/prompt.md")" "$MISSIONS/demo/wt" 'the prompt names the worktree'
has "$(cat "$MISSIONS/demo/prompt.md")" "$TARGET/m-demo" 'the prompt names the build dir'
has "$(cat "$MISSIONS/demo/prompt.md")" 'do not use session_worktree' 'the prompt forbids a session worktree'
has "$(cat "$MISSIONS/demo/run.sh")" 'export WASM_AGENT_RAW_CODE=codemode' 'the runner turns codemode on'
has "$(cat "$MISSIONS/demo/run.sh")" 'cd "$M" || exit 96' 'the runner runs from the mission dir'
has "$(cat "$MISSIONS/demo/run.sh")" 'CARGO_TARGET_DIR="$TARGET"' 'the runner builds in the mission target dir'
has "$(cat "$MISSIONS/demo/run.sh")" 'chat --once' 'the runner is one fresh session'
lacks "$(cat "$MISSIONS/demo/run.sh")" --resume 'the runner never resumes'
code_of() { grep -v '^[[:space:]]*#' "$1"; }   # a comment may name the pattern; the code must not use it
lacks "$(code_of "$MISSIONS/demo/run.sh")$(code_of "$MISSION")" 'pkill -f' 'nothing kills by pattern'
lacks "$(code_of "$MISSION")$(code_of "$MISSIONS/demo/run.sh")" 'pgrep -f' 'nothing finds a process by pattern'
out=$(run stage demo main "$WORK/brief.md") && fail 'stage twice must refuse (one branch per mission)' || ok
has "$out" 'already staged' 'the second stage refuses: one worktree, one branch per mission'

# --- start: detached, slow enough to still be running when the second launch is attempted.
export STUB_SLEEP=2
out=$(run start demo); has "$out" 'started demo' 'start reports the launch'
running=$(status_of demo)
has "$running" 'running    yes' 'status sees the launch running'
out=$(run start demo) && fail 'a second start while running must refuse' || ok
has "$out" 'already running' 'the refusal says why'
wait_done() { local i=0; while [ "$i" -lt 100 ]; do [ -f "$MISSIONS/demo/done" ] && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
wait_done || fail 'no done marker after the launch (the marker with the rc is the point)'
has "$(cat "$MISSIONS/demo/done")" 'rc=0' 'done carries the rc'
has "$(cat "$WORK/wa.log")" 'chat --once' 'the stub was launched as one session'
has "$(cat "$MISSIONS/demo/out.log")" '--- launch' 'out.log records the launch'
has "$(cat "$MISSIONS/demo/out.log")" '11111111-2222-3333-4444-555555555555' 'the session id is in the log'
unset STUB_SLEEP

# --- status: counts what the files say. One ^! run_failed line in the log is one failure.
export STUB_FAIL=1
run start demo >/dev/null; wait_done || fail 'the second launch wrote no done marker'
s=$(status_of demo)
[ "$(field "$s" failures)" = 1 ] && ok || fail "status counted $(field "$s" failures) failures, the log has 1"
[ "$(field "$s" commits)" = 0 ] && ok || fail "status counted $(field "$s" commits) commits, there are none"
[ "$(field "$s" files)" = 0 ] && ok || fail "status counted $(field "$s" files) files, there are none"
[ "$(field "$s" dirty)" = 0 ] && ok || fail 'status called a clean worktree dirty'
[ "$(field "$s" done)" = 'rc=0 ' ] || case "$(field "$s" done)" in rc=0*) ok ;; *) fail "status done: $(field "$s" done)" ;; esac
unset STUB_FAIL
printf 'work\n' > "$MISSIONS/demo/wt/thing.txt"
git -C "$MISSIONS/demo/wt" add thing.txt && git -C "$MISSIONS/demo/wt" commit -qm 'demo commit'
s=$(status_of demo)
[ "$(field "$s" commits)" = 1 ] && ok || fail "status counted $(field "$s" commits) commits, there is 1"
[ "$(field "$s" files)" = 1 ] && ok || fail "status counted $(field "$s" files) files, there is 1"
printf 'unsaved\n' > "$MISSIONS/demo/wt/draft.txt"
[ "$(field "$(status_of demo)" dirty)" = 1 ] && ok || fail 'status missed one uncommitted path'
rm -f "$MISSIONS/demo/wt/draft.txt"

# --- verify: the command's own rc, run in the mission worktree, recorded.
out=$(run verify demo pwd); rc=$?
[ "$rc" = 0 ] && ok || fail "verify true-like exited $rc"
has "$out" "$MISSIONS/demo/wt" 'verify runs in the mission worktree'
has "$(cat "$MISSIONS/demo/verify.log")" '--- verify' 'verify records itself'
run verify demo false >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || fail "verify false exited $rc, not 1"
has "$(cat "$MISSIONS/demo/verify.log")" 'rc=1' 'verify records the failing rc'

# --- report: the handover shows the failure, the verify rc and the missing REPORT.md.
out=$(run report demo)
has "$out" '-- failures' 'report has a failures section'
has "$out" 'stub_provider' 'report quotes the real failure line'
has "$out" 'rc=1' 'report quotes the verify rc'
has "$out" 'no REPORT.md' 'report says the handover file is missing'

# --- clean: a dirty worktree is refused, --force removes it, the evidence and the branch stay.
printf 'dirty\n' >> "$MISSIONS/demo/wt/thing.txt"
out=$(run clean demo) && fail 'clean on a dirty worktree must refuse' || ok
has "$out" 'uncommitted' 'the refusal names the uncommitted paths'
out=$(run clean demo --force) && ok || fail "clean --force failed: $out"
[ -d "$MISSIONS/demo/wt" ] && fail 'clean left the worktree' || ok
git -C "$REPO" show-ref --verify -q refs/heads/change/demo && ok || fail 'clean deleted the branch (the commits are the result)'
[ -f "$MISSIONS/demo/out.log" ] && ok || fail 'clean deleted the log'
[ -f "$MISSIONS/demo/done" ] && ok || fail 'clean deleted the done marker'
out=$(run clean demo) && ok || fail "the second clean should be a no-op, not an error: $out"
has "$out" 'already clean' 'the second clean says there is nothing to remove'
has "$(run status)" 'name       demo' 'status with no name lists the mission'

printf 'mission fixture: %s checks ok\n' "$checks"



