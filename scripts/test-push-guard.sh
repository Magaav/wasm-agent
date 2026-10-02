#!/usr/bin/env bash
# Does the push guard refuse a non-main branch push, and is it honest about what it is?
#
# WHAT THIS PINS (2026-10-02). The commit side had a guard with its bypasses measured
# (`scripts/test-main-guard.sh`); the push side had nothing, while this repository's end state is that
# origin carries `main` and nothing else. `.githooks/pre-push` now refuses to publish any other ref on the
# declared integration remote - and, because a client-side hook is convenience rather than a boundary,
# this test *measures* the ways around it instead of asserting they do not exist.
#
# Four things are proven by RUNNING a real `git push` against a real bare remote:
#   1. with the repository's own policy in place, a branch push is refused BY NAME and the remote is
#      UNCHANGED - the refusal is checked against the remote's refs, not against the hook's exit alone;
#   2. `main` is still pushable (the refusal must not block the sanctioned landing);
#   3. a ref deletion is still allowed (it moves toward the end state) - and the branch does then appear
#      on the remote, so "refused" above was not the remote being unwritable;
#   4. with no `lane-policy.json` the same branch push SUCCEEDS: an absent file means no extra
#      requirement, which is the property the whole policy rests on.
# Then the bypasses, recorded as the measured boundary: `--no-verify`, `-c core.hooksPath=<empty>`, and a
# checkout whose `core.hooksPath` does not name this directory all publish the branch.
#
# Hermetic: one temp bare remote, one temp work tree, no network, no sentinel, no model. The hook under
# test is the repository's own `.githooks/pre-push`, addressed by absolute path.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT_DIR/.githooks/pre-push"

fail() { echo "test-push-guard: $*" >&2; exit 1; }
[ -f "$HOOK" ] || fail "no $HOOK to test"

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
git -C "$REPO" remote add origin "$REMOTE"
# The hook under test, addressed by absolute path and passed per command rather than written into the
# fixture's config: the repository's OTHER hooks (pre-commit, commit-msg) refuse a direct commit on `main`
# by provenance, and this fixture has to make ordinary commits to have something to push. Every push below
# goes through `push_guarded` unless the case is deliberately about the hook NOT being consulted.
HOOKS="$ROOT_DIR/.githooks"
push_guarded() { git -C "$REPO" -c core.hooksPath="$HOOKS" push "$@"; }

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
git -C "$REPO" commit -qm "fixture: seed"
push_guarded -q origin main || fail "the initial main push must be allowed"
MAIN_TIP="$(git -C "$REPO" rev-parse HEAD)"

remote_refs() { git -C "$REPO" ls-remote --heads origin | sed 's/[[:space:]].*//' | sort; }
remote_heads() { git -C "$REPO" ls-remote --heads origin | awk '{print $2}' | sort; }
# The tip that a push is expected to publish is the branch's tip at the moment of the push, not the tip it
# had several commits ago: each case below adds a commit before it pushes.
tip() { git -C "$REPO" rev-parse HEAD; }

# 1. A branch push is refused by name, and the remote does not move.
git -C "$REPO" switch -qc change/fixture-push
echo "branch work" > "$REPO/branch.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture: a branch commit"
BRANCH_TIP="$(git -C "$REPO" rev-parse HEAD)"
BEFORE_REFS="$(remote_refs)"
REFUSAL="$(push_guarded origin change/fixture-push 2>&1)"
REFUSAL_STATUS=$?
echo "$REFUSAL" | sed 's/^/    /'
[ "$REFUSAL_STATUS" -ne 0 ] || fail "a non-main branch push was allowed while lane-policy.json declares main_only"
echo "$REFUSAL" | grep -q 'refusing to publish a branch other than' || fail "the refusal does not say what it refused"
echo "$REFUSAL" | grep -q "refs/heads/change/fixture-push" || fail "the refusal does not name the ref it refused"
echo "$REFUSAL" | grep -q "remote.main_only=true" || fail "the refusal does not name the declaration that refused it"
[ "$(remote_refs)" = "$BEFORE_REFS" ] || fail "the refused push still changed the remote's refs"
[ -z "$(remote_heads | grep -v refs/heads/main || true)" ] || fail "the refused branch exists on the remote"
# The refusal is the hook's, not the remote's: the branch is still only local.
[ "$(git -C "$REPO" rev-parse refs/heads/change/fixture-push)" = "$BRANCH_TIP" ] || fail "the local branch moved"

# 2. main is still pushable - a guard that blocks the sanctioned landing is a guard against working.
git -C "$REPO" switch -q main
echo "main work" > "$REPO/main.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture: a main commit"
push_guarded -q origin main || fail "pushing main was refused"
[ "$(git -C "$REPO" ls-remote --heads origin refs/heads/main | awk '{print $1}')" = "$(git -C "$REPO" rev-parse HEAD)" ] \
  || fail "origin/main is not the pushed tip after an allowed main push"

# 3. A deletion is a move toward the declared end state, so it is allowed - and it proves the remote is
#    writable, which is what makes "the remote did not change" above mean something.
git -C "$REPO" push -q origin change/fixture-push:A-branch-that-must-not-need-hooks || fail "cannot stage the deletion fixture"
git -C "$REPO" ls-remote --heads origin refs/heads/A-branch-that-must-not-need-hooks >/dev/null || fail "deletion fixture was not created"
push_guarded -q origin :A-branch-that-must-not-need-hooks || fail "a ref deletion must stay allowed"

# 4. An absent policy adds no requirement: the same push now goes through.
git -C "$REPO" switch -q change/fixture-push
git -C "$REPO" rm -q lane-policy.json
git -C "$REPO" commit -qm "fixture: withdraw the lane policy"
ALLOWED="$(push_guarded origin change/fixture-push 2>&1)"
ALLOWED_STATUS=$?
echo "$ALLOWED" | sed 's/^/    /'
[ "$ALLOWED_STATUS" -eq 0 ] || fail "with no lane-policy.json the branch push was refused anyway"
echo "$ALLOWED" | grep -q 'no lane-policy.json in this repository' || fail "the allowed push did not say why it was allowed"
[ "$(git -C "$REPO" ls-remote --heads origin refs/heads/change/fixture-push | awk '{print $1}')" = "$(tip)" ] \
  || fail "the allowed branch push did not reach the remote"
push_guarded -q origin :change/fixture-push || fail "cannot clean up the allowed branch"

# 5. The declared-but-false case is allowed too: the decision is the repository's, explicitly.
write_policy false
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture: declare main_only false"
push_guarded -q origin change/fixture-push || fail "main_only=false must allow a branch push"
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
measure_bypass "--no-verify" git -C "$REPO" -c core.hooksPath="$HOOKS" push --no-verify origin change/fixture-push
measure_bypass "-c core.hooksPath=<empty>" git -C "$REPO" -c core.hooksPath= push origin change/fixture-push
measure_bypass "core.hooksPath pointing elsewhere" git -C "$REPO" -c core.hooksPath="$WORK/no-hooks" push origin change/fixture-push
printf '%s\n' "  measured bypasses of the push guard:$BYPASS_REPORT"

echo "push guard ok (branch push refused by name with the remote unchanged; main and deletions allowed; absent policy and main_only=false add no requirement; 3 bypasses measured)"
