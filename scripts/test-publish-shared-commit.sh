#!/usr/bin/env bash
# May a build be published from a commit nobody else has? No.
#
# WHAT THIS EXISTS FOR. On 18/11 a node ran a binary built from 8 commits that were on no landed branch. It had
# been published by a helper that fetched a ref into a DETACHED HEAD and built it; the artifact was
# indistinguishable from a landed build, and the next ordinary deploy of main removed the features it carried.
# Nothing in the publishing path had ever asked whether the commit was reachable from a branch anyone else
# could see. This test is that question.
#
# The fixture is a bare git repository: no worktree of this project, no build, no network. Every case stops at
# the rule (the later stages refuse in the fixture because its scripts/lib is absent, and that refusal is not
# what this test reads).
#
# Usage:  bash scripts/test-publish-shared-commit.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in: $(printf '%s' "$2" | tail -2)" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com; git -C "$REPO" config user.name test
printf 'a\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm 'base: the first commit'
BASE="$(git -C "$REPO" rev-parse HEAD)"
publish() { # <args...> -> PUBLISH_OUT, PUBLISH_RC
  PUBLISH_OUT="$(bash "$PUBLISH" --repo "$REPO" "$@" 2>&1)"; PUBLISH_RC=$?
}

echo "test-publish-shared-commit: a commit no pushed branch contains"
publish --commit "$BASE" --check
[ "$PUBLISH_RC" != 0 ] && ok "it refused (exit $PUBLISH_RC)" || bad "it published a commit nobody else has"
shows "the refusal names the rule" "$PUBLISH_OUT" "commit_not_on_pushed_branch"
shows "it names the local branch that does contain it, and why that is not enough" "$PUBLISH_OUT" "local branches that contain it"
shows "it names the incident" "$PUBLISH_OUT" "the next deploy of main would silently remove it"

echo "test-publish-shared-commit: a commit on a pushed branch"
git -C "$REPO" update-ref refs/remotes/origin/main "$BASE"
publish --commit "$BASE" --check
shows "it is published as a shared commit" "$PUBLISH_OUT" "is on a pushed branch: origin/main"
hides "no refusal" "$PUBLISH_OUT" "commit_not_on_pushed_branch"

echo "test-publish-shared-commit: a detached HEAD"
printf 'b\n' > "$REPO/f"; git -C "$REPO" commit -qam 'second: a commit on no branch yet'
UNPUSHED="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q --detach "$UNPUSHED"
publish --commit "$UNPUSHED" --check
[ "$PUBLISH_RC" != 0 ] && ok "detached and unsupported by a pushed branch -> refused (exit $PUBLISH_RC)" || bad "a detached, unpushed commit was published"
shows "the refusal names the rule" "$PUBLISH_OUT" "commit_not_on_pushed_branch"

# ...and detached is not itself the sin: a detached commit that IS on a pushed branch is published, and said.
git -C "$REPO" update-ref refs/remotes/origin/main "$UNPUSHED"
publish --commit "$UNPUSHED" --check
shows "detached but on a pushed branch -> published" "$PUBLISH_OUT" "is on a pushed branch: origin/main"
shows "and it says the HEAD is detached, so a reviewer sees the shape" "$PUBLISH_OUT" "HEAD is detached at"
hides "no refusal" "$PUBLISH_OUT" "commit_not_on_pushed_branch"

echo "test-publish-shared-commit: the named development override"
publish --commit "$UNPUSHED" --check
git -C "$REPO" update-ref -d refs/remotes/origin/main
ALLOW_UNPUSHED_COMMIT=1 PUBLISH_OUT="$(ALLOW_UNPUSHED_COMMIT=1 bash "$PUBLISH" --repo "$REPO" --commit "$UNPUSHED" --check 2>&1)"
shows "it is allowed only when named, and says so" "$PUBLISH_OUT" "ALLOW_UNPUSHED_COMMIT=1"
shows "...and calls the artifact what it is" "$PUBLISH_OUT" "a development artifact"

echo "test-publish-shared-commit: the manifest carries where the commit lives"
grep -q 'pushed_branches=' "$PUBLISH" && ok "the manifest records the branches that contain the build" || bad "the manifest does not say where the commit lives"
grep -q 'unpushed=' "$PUBLISH" && ok "the manifest records the development override" || bad "the manifest does not record unpushed builds"

printf 'test-publish-shared-commit: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
