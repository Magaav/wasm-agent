#!/usr/bin/env bash
# Does the push guard refuse a non-main branch push - through the hook git actually consults, at the mode
# git actually requires?
#
# WHAT THIS PINS (2026-10-02). The commit side had a guard with its bypasses measured
# (`scripts/test-main-guard.sh`); the push side had nothing, while this repository's end state is that
# origin carries `main` and nothing else. `.githooks/pre-push` refuses to publish any other ref on the
# declared integration remote - and, because a client-side hook is convenience rather than a boundary,
# this test *measures* the ways around it instead of asserting they do not exist.
#
# TWO THINGS IT DOES NOT TAKE ON TRUST, because the reviewer's finding `pre-push-mode` showed the first
# version of this file could pass while the guard was inert:
#
#   1. THE MODE. The hook was committed 100644 while its two siblings were 100755, and git ignores a hook
#      that is not executable (`git githooks(5)`) - so on every POSIX checkout, including the cloud tree
#      AGENTS.md calls authoritative, the guard never ran. The index mode is asserted here (git's own
#      authority for what a checkout will get), and the worktree bit too where the platform has one.
#   2. THE PATH. The fixture arms the repository's own `core.hooksPath` in its CONFIG and then pushes with
#      plain `git push` - no `-c core.hooksPath=` per command. That per-command override was how the 0644
#      defect stayed invisible: it selected the hook by hand, so it could not observe what a checkout
#      actually consults. Only the deliberate bypass cases pass the config on the command line, and they
#      say so.
#
# What is proven by RUNNING a real `git push` against a real bare remote:
#   1. with the repository's own policy in place, a branch push is refused BY NAME and the remote is
#      UNCHANGED - checked against the remote's refs, not against the hook's exit alone;
#   2. `main` is still pushable (the refusal must not block the sanctioned landing);
#   3. a ref deletion is still allowed (it moves toward the end state) - and the branch does then appear
#      on the remote, so "refused" above was not the remote being unwritable;
#   4. with no `lane-policy.json` the same branch push SUCCEEDS: an absent file means no extra
#      requirement, which is the property the whole policy rests on;
#   5. `remote.main_only: false` also allows it: the decision is the repository's, explicitly.
# Then the bypasses, recorded as the measured boundary: `--no-verify`, `-c core.hooksPath=<empty>`, and a
# checkout whose `core.hooksPath` names somewhere else all publish the branch.
#
# Hermetic: one temp bare remote, one temp work tree, no network, no sentinel, no model. The hook under
# test is the repository's own `.githooks/pre-push`, reached through `core.hooksPath` like a real checkout.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT_DIR/.githooks"
HOOK="$HOOKS/pre-push"

fail() { echo "test-push-guard: $*" >&2; exit 1; }
[ -f "$HOOK" ] || fail "no $HOOK to test"

# --- 0. The hook is executable, in the index and on disk --------------------------------
# `git ls-files -s` prints "<mode> <object> <stage> <path>"; the index mode is what a clone/checkout
# materialises, and on Windows (core.fileMode=false) it is the ONLY authority - MSYS synthesises the
# worktree bit from the shebang, which is exactly why the 0644 defect could not be seen by running the
# hook here. Both are asserted: the index mode always, the worktree bit as a second, weaker signal.
hook_mode() { git -C "$ROOT_DIR" ls-files -s -- "$1" | awk '{print $1}'; }
[ "$(hook_mode .githooks/pre-push)" = "100755" ] \
  || fail ".githooks/pre-push is committed $(hook_mode .githooks/pre-push), not 100755 - git ignores a non-executable hook (git githooks(5)), so the guard would never run on a POSIX checkout (fix: git update-index --chmod=+x .githooks/pre-push)"
for sibling in .githooks/pre-commit .githooks/commit-msg; do
  [ "$(hook_mode "$sibling")" = "100755" ] || fail "$sibling is committed $(hook_mode "$sibling"), not 100755 - the three hooks must agree on the bit that decides whether git runs them"
done
[ -x "$HOOK" ] || fail "$HOOK is not executable in the worktree (index mode is $(hook_mode .githooks/pre-push))"
echo "  hook mode: index $(hook_mode .githooks/pre-push), worktree bit set"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-push-guard-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
git init -q --bare --initial-branch=main "$REMOTE" || fail "cannot init the bare remote"
mkdir -p "$REPO"
git -C "$REPO" init -q --initial-branch=main || fail "cannot init the work tree"
git -C "$REPO" config user.name push-guard-fixture
git -C "$REPO" config user.email push-guard@invalid
git -C "$REPO" config core.autocrlf false
# Git prints paths in its own native spelling (`C:/...` on Windows, where the shell's is `/c/...` or
# `/tmp/...`), so assertions about what the hook named compare against git's spelling of this directory.
REPO_NATIVE="$REPO"
command -v cygpath >/dev/null 2>&1 && REPO_NATIVE="$(cygpath -m "$REPO")"

# The policy the repository declares, with the one decision this test reads.
write_policy() { # main_only(true|false)
  cat > "$REPO/lane-policy.json" <<POLICY
{
  "schema": 1,
  "contract": "fixture: what a lane must reach to be ended",
  "end_state": {"statement": "origin carries only main"},
  "gate": {"on": "release"},
  "deploy": {"when": "after the release gate"},
  "remote": {"main_only": $1, "name": "origin", "push_guard": "fixture"},
  "checks": {"enter": [["node", "scripts/test.sh"]], "exit": [["node", "scripts/test.sh"]]}
}
POLICY
}

write_policy true
echo "fixture" > "$REPO/seed"
git -C "$REPO" add -A
git -C "$REPO" -c core.hooksPath= commit -qm "fixture: seed"
git -C "$REPO" remote add origin "$REMOTE"
# A second remote ref, created BEFORE the hook path is armed: case 3 needs a non-main ref to delete, and the
# guard (correctly) refuses to CREATE one once it is armed - so it cannot be staged through the guard.
git -C "$REPO" push -q origin main:refs/heads/A-branch-that-must-not-need-hooks || fail "cannot stage the deletion fixture"

# The repository's own hook directory, armed the way a checkout arms it - in CONFIG, once. Every push
# below is a plain `git push` unless the case is deliberately about the hook NOT being consulted, so what
# runs is whatever this path and this mode select.
git -C "$REPO" config core.hooksPath "$HOOKS"
# Git for Windows rewrites a path-valued config to its native spelling (`/c/...` is stored as `C:/...`),
# so the check compares the two spellings of the same directory rather than the literal string.
configured_hooks="$(git -C "$REPO" config core.hooksPath)"
[ -n "$configured_hooks" ] || fail "the fixture did not arm core.hooksPath"
command -v cygpath >/dev/null 2>&1 && configured_hooks="$(cygpath -u "$configured_hooks")"
[ "${configured_hooks%/}" = "${HOOKS%/}" ] || fail "the fixture armed core.hooksPath as '$configured_hooks', not '$HOOKS'"
# Commits that touch `main` are made with the hook path emptied for that one command: the commit guards
# are pinned by scripts/test-main-guard.sh and would refuse a child's commit on main (this process has
# WASM_AGENT_PROVENANCE=child), while the subject here is the PUSH side.
commit_on_main() { git -C "$REPO" -c core.hooksPath= commit -qm "$1"; }

git -C "$REPO" push -q origin main || fail "the initial main push must be allowed"
MAIN_TIP="$(git -C "$REPO" rev-parse HEAD)"

remote_refs() { git -C "$REPO" ls-remote --heads origin | sed 's/[[:space:]].*//' | sort; }
# The tip a push is expected to publish is the branch's tip at the moment of the push.
tip() { git -C "$REPO" rev-parse HEAD; }

# 1. A branch push is refused by name, and the remote does not move.
git -C "$REPO" switch -qc change/fixture-push
echo "branch work" > "$REPO/branch.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture: a branch commit"
BRANCH_TIP="$(git -C "$REPO" rev-parse HEAD)"
BEFORE_REFS="$(remote_refs)"
REFUSAL="$(git -C "$REPO" push origin change/fixture-push 2>&1)"
REFUSAL_STATUS=$?
echo "$REFUSAL" | sed 's/^/    /'
[ "$REFUSAL_STATUS" -ne 0 ] || fail "a non-main branch push was allowed while lane-policy.json declares main_only"
echo "$REFUSAL" | grep -q 'refusing to publish a branch other than' || fail "the refusal does not say what it refused"
echo "$REFUSAL" | grep -q "refs/heads/change/fixture-push" || fail "the refusal does not name the ref it refused"
echo "$REFUSAL" | grep -q "remote.main_only=true" || fail "the refusal does not name the declaration that refused it"
# The refusal names THIS repository's hook and the fixture's own policy file, so the run above proves the
# repository's hook was consulted (and not some other pre-push the machine happens to have).
echo "$REFUSAL" | grep -qF "$REPO_NATIVE/lane-policy.json" || fail "the refusal does not name the policy file it read ($REPO_NATIVE/lane-policy.json)"
[ "$(remote_refs)" = "$BEFORE_REFS" ] || fail "the refused push still changed the remote's refs"
[ -z "$(git -C "$REPO" ls-remote --heads origin refs/heads/change/fixture-push)" ] || fail "the refused branch exists on the remote"
[ "$(git -C "$REPO" rev-parse refs/heads/change/fixture-push)" = "$BRANCH_TIP" ] || fail "the local branch moved"

# 2. main is still pushable - a guard that blocks the sanctioned landing is a guard against working.
git -C "$REPO" switch -q main
echo "main work" > "$REPO/main.txt"
git -C "$REPO" add -A
commit_on_main "fixture: a main commit"
git -C "$REPO" push -q origin main || fail "pushing main was refused"
[ "$(git -C "$REPO" ls-remote --heads origin refs/heads/main | awk '{print $1}')" = "$(tip)" ] \
  || fail "origin/main is not the pushed tip after an allowed main push"

# 3. A deletion is a move toward the declared end state, so it is allowed - and it proves the remote is
#    writable, which is what makes "the remote did not change" above mean something. (The ref was created
#    before the hook path was armed: the guard refuses to CREATE a non-main ref, which is case 1.)
git -C "$REPO" ls-remote --heads origin refs/heads/A-branch-that-must-not-need-hooks >/dev/null || fail "deletion fixture was not created"
git -C "$REPO" push -q origin :A-branch-that-must-not-need-hooks || fail "a ref deletion must stay allowed"
[ -z "$(git -C "$REPO" ls-remote --heads origin refs/heads/A-branch-that-must-not-need-hooks)" ] || fail "the deletion did not remove the remote ref"

# 4. An absent policy adds no requirement: the same push now goes through.
git -C "$REPO" switch -q change/fixture-push
git -C "$REPO" rm -q lane-policy.json
git -C "$REPO" commit -qm "fixture: withdraw the lane policy"
ALLOWED="$(git -C "$REPO" push origin change/fixture-push 2>&1)"
ALLOWED_STATUS=$?
echo "$ALLOWED" | sed 's/^/    /'
[ "$ALLOWED_STATUS" -eq 0 ] || fail "with no lane-policy.json the branch push was refused anyway"
echo "$ALLOWED" | grep -q 'no lane-policy.json in this repository' || fail "the allowed push did not say why it was allowed"
[ "$(git -C "$REPO" ls-remote --heads origin refs/heads/change/fixture-push | awk '{print $1}')" = "$(tip)" ] \
  || fail "the allowed branch push did not reach the remote"
git -C "$REPO" push -q origin :change/fixture-push || fail "cannot clean up the allowed branch"

# 5. The declared-but-false case is allowed too: the decision is the repository's, explicitly.
write_policy false
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture: declare main_only false"
git -C "$REPO" push -q origin change/fixture-push || fail "main_only=false must allow a branch push"
echo "    main_only=false allowed the branch push"
git -C "$REPO" push -q origin :change/fixture-push || fail "cannot clean up the main_only=false branch"

# 6. MEASURED BYPASSES. Not assertions about what cannot happen: each one publishes the branch for real,
#    and each is printed with its exit status so the record says what the boundary is. The unskippable
#    enforcement point is remote-side (branch protection or a pre-receive hook), not this file.
write_policy true
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture: restore the policy for the bypass measurements"
BYPASS_REPORT=""
measure_bypass() { # label command...
  local label="$1"; shift
  git -C "$REPO" push -q origin :change/fixture-push 2>/dev/null || true
  local out status landed="no"
  out="$("$@" 2>&1)"
  status=$?
  if [ "$(git -C "$REPO" ls-remote --heads origin refs/heads/change/fixture-push | awk '{print $1}')" = "$(tip)" ]; then landed="yes"; fi
  BYPASS_REPORT="$BYPASS_REPORT
  $label: exit $status, branch published: $landed"
  git -C "$REPO" push -q origin :change/fixture-push 2>/dev/null || true
}
measure_bypass "--no-verify" git -C "$REPO" push --no-verify origin change/fixture-push
measure_bypass "-c core.hooksPath=<empty>" git -C "$REPO" -c core.hooksPath= push origin change/fixture-push
measure_bypass "core.hooksPath pointing elsewhere" git -C "$REPO" -c core.hooksPath="$WORK/no-hooks" push origin change/fixture-push
printf '%s\n' "  measured bypasses of the push guard:$BYPASS_REPORT"

echo "push guard ok (hook committed 100755 and reached through core.hooksPath; branch push refused by name with the remote unchanged; main and deletions allowed; absent policy and main_only=false add no requirement; 3 bypasses measured)"
