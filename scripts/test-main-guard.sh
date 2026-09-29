#!/usr/bin/env bash
# Who may commit on `main`, decided by role rather than by a flag the committer types.
#
# The defect this pins: `WASM_AGENT_ALLOW_MAIN=1` was the only way past the guard, and the committing
# process types it - so the guard's real question ("is this the process that owns integration?") was
# answered by the process itself, and a child could answer yes. The authority is now the host's answer
# about the process: `WASM_AGENT_PROVENANCE`, exported by rust/wa-host/src/operations.rs from the
# thread's own task context (`orchestrator` = a run of a session, `child` = a bounded subagent task).
# Hence the two cases that matter most: the orchestrator does not need the old flag, and a child
# exporting it is still refused.
#
# Every case except the last two is the real `git commit` path in a throwaway repository on `main` with
# this tree's two hooks installed through `core.hooksPath`, because git runs pre-commit and commit-msg
# as a pair: changing only the first left the second refusing the orchestrator on `main`, and only an
# end-to-end case shows that. The last two call commit-msg directly, because git stops at the first
# refusal and the second hook is therefore unreachable through `git commit` in the child cases.
#
# The host export itself is not assumed here; it is measured by
# `cargo test --manifest-path rust/Cargo.toml -p wa-host shell_child_carries_the_provenance_the_host_knows`,
# which reads what a shell child actually receives.
#
# Usage:  bash scripts/test-main-guard.sh
# Needs:  git and bash. No build, no node, no network: this runs in about a second.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

checks=0
failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }

S="$(mktemp -d "${TMPDIR:-/tmp}/wa-main-guard-XXXXXX")"
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/hooks"
# A copy, not the tree itself: the fixture runs *these* hooks, and a missing file fails here rather
# than silently running whatever else is installed on the machine.
cp "$ROOT/.githooks/pre-commit" "$ROOT/.githooks/commit-msg" "$S/hooks/"

git init -q --initial-branch=main "$S/repo"
cd "$S/repo"
git config user.name "main guard fixture"
git config user.email "guard@example.invalid"
git config core.hooksPath "$S/hooks"
# The CRLF check below the guard is a different rule, and a fixture that let autocrlf rewrite line
# endings would be testing git's conversion instead of the guard.
git config core.autocrlf false

last_exit=0
last_out=""
# Provenance and flag are passed explicitly and both are cleared otherwise, so a case cannot pass or
# fail because of a variable this suite happened to be started with. One helper, so a `git merge` case
# carries exactly the same environment as a `git commit` case.
git_case() {
  local provenance="$1" flag="$2"
  shift 2
  local env_args=(env -u WASM_AGENT_PROVENANCE -u WASM_AGENT_ALLOW_MAIN)
  [ -n "$provenance" ] && env_args+=("WASM_AGENT_PROVENANCE=$provenance")
  [ -n "$flag" ] && env_args+=("WASM_AGENT_ALLOW_MAIN=$flag")
  last_out="$("${env_args[@]}" git "$@" 2>&1)"
  last_exit=$?
}
commit_case() { git_case "$1" "$2" commit "${@:3}"; }

# A refusal leaves its file staged, and a later success would carry that leftover into the fixture's
# history - so each case starts from a clean tree and stages exactly one file of its own.
stage() {
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then git reset -q HEAD; fi
  git checkout -q -- . 2>/dev/null || true
  git clean -qfd 2>/dev/null || true
  printf 'fixture %s\n' "$1" > "$1.txt"
  git add "$1.txt"
}
trailer() { printf 'Agent: wasm-agent node=fixture role=%s\n' "$1"; }

# --- 1. the orchestrator session lands on main, and does not need the old flag ---------------------
stage orchestrator
commit_case orchestrator "" -m "fixture: the orchestrator session lands on main" -m "$(trailer orchestrator)"
ok "$([ "$last_exit" = "0" ] && echo 1 || echo 0)" \
  "a direct commit on main by the orchestrator session is allowed" "exit $last_exit: $(head -3 <<<"$last_out" | tr '\n' ' ')"
ok "$([ "$(git log -1 --format=%s 2>/dev/null)" = "fixture: the orchestrator session lands on main" ] && echo 1 || echo 0)" \
  "and it really is committed" "$(git log -1 --format=%s 2>/dev/null)"

# --- 2. a child task may not, and is told which provenance was found -------------------------------
stage child
commit_case child "" -m "fixture: a child task reaches for main" -m "$(trailer child)"
ok "$([ "$last_exit" != "0" ] && echo 1 || echo 0)" \
  "a direct commit on main by a child task is refused" "exit $last_exit"
ok "$(grep -q 'provenance: child' <<<"$last_out" && echo 1 || echo 0)" \
  "the refusal names the provenance it found" "$(grep -m1 'provenance:' <<<"$last_out")"
ok "$(grep -q 'a child task does not hold the integration decision' <<<"$last_out" && echo 1 || echo 0)" \
  "and says why it was refused"

# --- 3. the old flag no longer opens main for a child ----------------------------------------------
commit_case child 1 -m "fixture: a child task with the old override" -m "$(trailer child)"
ok "$([ "$last_exit" != "0" ] && echo 1 || echo 0)" \
  "a child exporting WASM_AGENT_ALLOW_MAIN=1 is still refused" "exit $last_exit"
ok "$(grep -q 'WASM_AGENT_ALLOW_MAIN is deliberately not consulted' <<<"$last_out" && echo 1 || echo 0)" \
  "and the refusal says the old flag was not consulted"
ok "$(grep -q 'the override is deliberate' <<<"$last_out" && echo 0 || echo 1)" \
  "the old flag is not offered to a child as the way through, only its own branch is"

# --- 4. a terminal with no session context keeps today's behaviour ---------------------------------
stage human
commit_case "" "" -m "fixture: a terminal with no session context" -m "Agent: pi session=fixture"
ok "$([ "$last_exit" != "0" ] && echo 1 || echo 0)" \
  "no host provenance is still refused, as today" "exit $last_exit"
ok "$(grep -q 'provenance: none' <<<"$last_out" && echo 1 || echo 0)" \
  "the refusal says no provenance was found" "$(grep -m1 'provenance:' <<<"$last_out")"
ok "$(grep -q 'WASM_AGENT_ALLOW_MAIN=1 - the override is deliberate' <<<"$last_out" && echo 1 || echo 0)" \
  "and keeps the visible explicit override"

# --- 5. the human's explicit override still lands on main ------------------------------------------
commit_case "" 1 -m "fixture: the human lands it" -m "Agent: human integrating (WASM_AGENT_ALLOW_MAIN=1)"
ok "$([ "$last_exit" = "0" ] && echo 1 || echo 0)" \
  "the human's explicit override is still honoured" "exit $last_exit: $(head -3 <<<"$last_out" | tr '\n' ' ')"

# --- 6. a provenance nobody can classify must not open main ----------------------------------------
stage employee
commit_case employee 1 -m "fixture: an unclassifiable provenance" -m "$(trailer employee)"
ok "$([ "$last_exit" != "0" ] && echo 1 || echo 0)" \
  "an unrecognised provenance is refused, even with the old flag" "exit $last_exit"
ok "$(grep -q 'provenance: unrecognised' <<<"$last_out" && echo 1 || echo 0)" \
  "and it says which value it saw" "$(grep -m1 'provenance:' <<<"$last_out")"

# --- 7. a merge on main stays allowed, whatever the provenance -------------------------------------
stage branch-work
git checkout -q -b fixture-branch
printf 'fixture branch work\n' > branch.txt
git add branch.txt
git commit -q -m "fixture: work on a branch" -m "$(trailer child)"
git checkout -q main
git_case child "" merge --no-ff fixture-branch -m "merge(fixture-branch): bring the fixture branch"
ok "$([ "$last_exit" = "0" ] && echo 1 || echo 0)" \
  "a merge on main is allowed even from a child: the normal landing path" "exit $last_exit: $(head -3 <<<"$last_out" | tr '\n' ' ')"
ok "$([ "$(git rev-list --count --first-parent HEAD 2>/dev/null)" -ge 3 ] && [ "$(git rev-parse -q --verify HEAD^2 >/dev/null 2>&1 && echo 1 || echo 0)" = "1" ] && echo 1 || echo 0)" \
  "and it is a real merge with two parents"

# --- 8. the CRLF check below the guard is not weakened by any of this ------------------------------
stage crlf
printf 'fixture crlf\r\nsecond line\r\n' > crlf.txt
git add crlf.txt
commit_case orchestrator "" -m "fixture: a CRLF file under an allowed provenance"
ok "$([ "$last_exit" != "0" ] && echo 1 || echo 0)" \
  "a CRLF file is still refused, under a provenance that is allowed" "exit $last_exit"
ok "$(grep -q 'CRLF' <<<"$last_out" && echo 1 || echo 0)" \
  "and it is the CRLF rule that refused, not the branch guard" "$(grep -m1 'CRLF' <<<"$last_out")"

# --- 9. the second hook agrees with the first ------------------------------------------------------
# Reached directly: `git commit` stops at pre-commit's refusal, so the child cases above never ran this
# file. Inconsistent hooks are the failure this catches - it is exactly how the orchestrator was left
# refused on main after pre-commit alone had been changed.
printf 'fixture: the trailer under judgement\n\n%s\n' "$(trailer child)" > "$S/message.txt"
env -u WASM_AGENT_ALLOW_MAIN WASM_AGENT_PROVENANCE=child bash "$ROOT/.githooks/commit-msg" "$S/message.txt" >"$S/commit-msg-child.txt" 2>&1
child_msg_exit=$?
ok "$([ "$child_msg_exit" != "0" ] && echo 1 || echo 0)" \
  "commit-msg refuses a child's trailer on main too" "exit $child_msg_exit"
ok "$(grep -q 'provenance: child' "$S/commit-msg-child.txt" && echo 1 || echo 0)" \
  "and names the same provenance pre-commit named"
env -u WASM_AGENT_ALLOW_MAIN WASM_AGENT_PROVENANCE=orchestrator bash "$ROOT/.githooks/commit-msg" "$S/message.txt" >"$S/commit-msg-orchestrator.txt" 2>&1
orchestrator_msg_exit=$?
ok "$([ "$orchestrator_msg_exit" = "0" ] && echo 1 || echo 0)" \
  "commit-msg accepts the orchestrator's trailer, so the pair agrees" "exit $orchestrator_msg_exit: $(head -2 "$S/commit-msg-orchestrator.txt" | tr '\n' ' ')"

# --- 10. nothing was committed by the cases that were refused --------------------------------------
SUBJECTS="$(git log --first-parent --format=%s main 2>/dev/null)"
ok "$([ "$(printf '%s\n' "$SUBJECTS" | wc -l | tr -d ' ')" = "3" ] && echo 1 || echo 0)" \
  "main holds exactly the three allowed commits" "$(tr '\n' '|' <<<"$SUBJECTS")"
ok "$(grep -q 'reaches for main' <<<"$SUBJECTS" && echo 0 || echo 1)" \
  "and no refused case left a commit behind"

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "main guard ok ($checks checks)"
else
  echo "main guard FAILED ($failed of $checks)"
fi
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"
