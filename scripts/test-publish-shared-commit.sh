#!/usr/bin/env bash
# May a build be published from a commit nobody else has? No - and "nobody else has" is asked of the REMOTE.
#
# WHAT THIS EXISTS FOR. On 18/11 a node ran a binary built from 8 commits that were on no landed branch. It had
# been published by a helper that fetched a ref into a DETACHED HEAD and built it; the artifact was
# indistinguishable from a landed build, and the next ordinary deploy of main removed the features it carried.
# The first fix asked the LOCAL repository (`git for-each-ref --contains ... refs/remotes/`), and that answer is
# a memory: a ref left behind by a fetch, a ref naming a branch the remote has since deleted, a ref created by
# hand all answer "yes". So the question is now asked of the incoming repository (`git ls-remote`, one shared
# implementation: scripts/lib/shared-commit.sh), and the fixture is a real bare remote with real pushes.
#
# Usage:  bash scripts/test-publish-shared-commit.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/scripts/publish-node-binaries.sh"
SHARED="$ROOT/scripts/lib/shared-commit.sh"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in: $(printf '%s' "$2" | tail -2)" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"
REPO="$WORK/repo"; mkdir -p "$REPO/scripts"
# The publisher sources its own libs from --repo (that is the tree it publishes), so the fixture carries the real
# ones: nothing here is about them, and their absence would end the run before the rule under test.
cp -r "$ROOT/scripts/lib" "$REPO/scripts/lib" 2>/dev/null || true
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com; git -C "$REPO" config user.name test
git -C "$REPO" remote add origin "$REMOTE"
printf 'a\n' > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm 'base: the first commit'
BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" branch -M main
publish() { # <args...> -> PUBLISH_OUT, PUBLISH_RC
  PUBLISH_OUT="$(bash "$PUBLISH" --repo "$REPO" "$@" 2>&1)"; PUBLISH_RC=$?
}

echo "test-publish-shared-commit: a commit no branch on the remote contains"
publish --commit "$BASE" --check
[ "$PUBLISH_RC" != 0 ] && ok "it refused (exit $PUBLISH_RC)" || bad "it published a commit nobody else has"
shows "the refusal names the rule" "$PUBLISH_OUT" "commit_not_on_pushed_branch"
shows "it names the local branch that does contain it, and why that is not enough" "$PUBLISH_OUT" "local branches that contain it"
shows "it names the incident" "$PUBLISH_OUT" "the next deploy of main"
shows "it says the REMOTE was asked, not this clone" "$PUBLISH_OUT" "git ls-remote --heads origin"

echo "test-publish-shared-commit: a stale local remote-tracking ref is NOT an answer"
# The exact hole the review named: this clone believes origin/main is at BASE, and the remote has never had it.
git -C "$REPO" update-ref refs/remotes/origin/main "$BASE"
bash "$SHARED" "$REPO" "$BASE" origin >/dev/null 2>&1
same "the shared answer ignores a local refs/remotes entry the remote does not have" "$?" "1"
publish --commit "$BASE" --check
[ "$PUBLISH_RC" != 0 ] && ok "and the publisher still refuses (exit $PUBLISH_RC)" || bad "a stale refs/remotes ref was accepted as shared"

echo "test-publish-shared-commit: a commit on a pushed branch"
git -C "$REPO" push -q origin main
publish --commit "$BASE" --check
shows "it is published as a shared commit" "$PUBLISH_OUT" "is on a pushed branch: main"
hides "no refusal" "$PUBLISH_OUT" "commit_not_on_pushed_branch"
bash "$SHARED" "$REPO" "$BASE" origin >/dev/null 2>&1
same "...and the shared function agrees" "$?" "0"

echo "test-publish-shared-commit: a commit that is an ancestor of a pushed branch"
git -C "$REPO" checkout -q -b work
printf 'b\n' > "$REPO/g"; git -C "$REPO" add g; git -C "$REPO" commit -qm 'second: on a branch, not yet pushed'
SECOND="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" push -q origin work
bash "$SHARED" "$REPO" "$BASE" origin >/dev/null 2>&1
same "an ancestor of a pushed head is shared (containment, not equality)" "$?" "0"
printf 'c\n' > "$REPO/h"; git -C "$REPO" add h; git -C "$REPO" commit -qm 'third: on no branch yet'
UNPUSHED="$(git -C "$REPO" rev-parse HEAD)"
bash "$SHARED" "$REPO" "$UNPUSHED" origin >/dev/null 2>&1
same "a commit above every pushed head is not shared" "$?" "1"

echo "test-publish-shared-commit: a detached HEAD"
git -C "$REPO" checkout -q --detach "$UNPUSHED"
publish --commit "$UNPUSHED" --check
[ "$PUBLISH_RC" != 0 ] && ok "detached and unsupported by a pushed branch -> refused (exit $PUBLISH_RC)" || bad "a detached, unpushed commit was published"
shows "the refusal names the rule" "$PUBLISH_OUT" "commit_not_on_pushed_branch"
git -C "$REPO" push -q origin "$UNPUSHED:refs/heads/work"
publish --commit "$UNPUSHED" --check
shows "detached but on a pushed branch -> published" "$PUBLISH_OUT" "is on a pushed branch: work"
shows "and it says the HEAD is detached, so a reviewer sees the shape" "$PUBLISH_OUT" "HEAD is detached at"
hides "no refusal" "$PUBLISH_OUT" "commit_not_on_pushed_branch"

echo "test-publish-shared-commit: a remote that cannot be asked is not a pass"
bash "$SHARED" "$REPO" "$BASE" nosuchremote >/dev/null 2>&1
same "an unknown remote answers 2 (cannot tell), never 0" "$?" "2"
git -C "$REPO" remote set-url origin "$WORK/gone.git"
publish_out="$(bash "$PUBLISH" --repo "$REPO" --commit "$UNPUSHED" --check 2>&1)"; publish_rc=$?
[ "$publish_rc" != 0 ] && ok "the publisher refuses when it cannot ask (exit $publish_rc)" || bad "the publisher published without asking anyone"
shows "...and says the question could not be answered" "$publish_out" "could not ask the remote"
shows "...and names the way to make it answerable" "$publish_out" "git fetch origin"
git -C "$REPO" remote set-url origin "$REMOTE"

echo "test-publish-shared-commit: the named development override"
out="$(ALLOW_UNPUSHED_COMMIT=1 bash "$PUBLISH" --repo "$REPO" --commit "$UNPUSHED" --check 2>&1)"
shows "it is allowed only when named, and says so" "$out" "ALLOW_UNPUSHED_COMMIT=1"
shows "...and calls the artifact what it is" "$out" "a development artifact"

echo "test-publish-shared-commit: the manifest carries where the commit lives"
grep -q 'pushed_branches=' "$PUBLISH" && ok "the manifest records the branches that contain the build" || bad "the manifest does not say where the commit lives"
shows "...from the remote's own answer" "$(grep -n 'pushed_branches=' "$PUBLISH")" 'PUSHED_BRANCHES'
grep -q 'unpushed=' "$PUBLISH" && ok "the manifest records the development override" || bad "the manifest does not record unpushed builds"

echo "test-publish-shared-commit: one shared answer for every publisher"
for user in scripts/publish-node-binaries.sh scripts/publish-components.sh scripts/codemode-build.mjs scripts/ship-wave.mjs scripts/lib/fast-binary.sh scripts/deploy.sh; do
  if grep -q 'shared-commit.sh\|wa_commit_shared\|commitShared' "$ROOT/$user"; then ok "$user asks the one shared question"; else bad "$user has its own idea of 'pushed'"; fi
done
if grep -q 'for-each-ref --contains "$COMMIT" --format=.%(refname:short). refs/remotes/' "$PUBLISH"; then bad "publish-node-binaries.sh still trusts local remote-tracking refs"; else ok "publish-node-binaries.sh no longer trusts local remote-tracking refs"; fi

printf 'test-publish-shared-commit: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
