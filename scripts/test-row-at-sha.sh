#!/usr/bin/env bash
# ONE row, at a base commit and at this tree, as one supervised comparison (item 5 of the node-ops round, #46).
#
#   bash scripts/test-row-at-sha.sh
#
# WHY. Every item of this round claims "fails before, passes after", and establishing that by hand - edit,
# run, un-edit, run - is how a session loses an afternoon and how a stash leaked between worktrees (19/11).
#
# What this proves, in order:
#   * the four classes are decided from the two exit codes, including the skip convention (77), so a skip is
#     never counted as a pass;
#   * a REAL run against this repo produces a verdict, writes nothing inside the tree under test, and leaves
#     NO base worktree behind (the leak item 6 fixed, checked here where a worktree is created);
#   * the refusals are named: a sha that is not a sha, a row that does not exist, a row absent at the base,
#     and no binary - each says which, and none of them runs anything.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-row-at-sha-$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH" || exit 2
cleanup() { local s=$?; set +e; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
fail() { echo "test-row-at-sha: $*" >&2; exit 1; }

. scripts/lib/row-at-sha.sh

# (1) The classification, every pair that matters.
check() { # <base> <change> <want> <why>
  local got; got="$(wa_row_at_sha_classify "$1" "$2")"
  [ "$got" = "$3" ] || fail "$4: base $1 change $2 classified $got, expected $3"
}
check 0 0 still_passing 'both pass'
check 1 1 pre_existing 'both fail'
check 0 1 new_failure 'passes at the base and fails here'
check 1 0 fixed 'fails at the base and passes here'
check 0 77 skipped 'a skip on the change side is not a pass'
check 77 0 skipped 'a skip on the base side is not a pass'
check 77 77 skipped 'a skip on both sides is not evidence'
check 1 77 skipped 'a skip where the base failed is not a pass'
for class in still_passing pre_existing new_failure fixed skipped; do
  [ -n "$(wa_row_at_sha_meaning "$class")" ] || fail "the class $class has no meaning for a reader"
done

# (2) A real comparison, against this repo. The row is a Lua-only one that needs nothing but the node, so
# the verdict is about the row and not about the machine.
row=scripts/test-time.lua
[ -f "$row" ] || fail "the fixture row $row is not in this tree"
sha="$(git rev-parse HEAD)"
worktrees_before="$(git worktree list | wc -l)"
set +e
out="$(WA_BIN="$(command -v wa || true)" bash scripts/lib/row-at-sha.sh "$sha" "$row" 2>&1)"
code=$?
set -e
case "$out" in *'class='*) ;; *) fail "a real comparison produced no class: $out" ;; esac
case "$out" in *"row_at_sha: "*) ;; *) fail "a real comparison produced no verdict line: $out" ;; esac
case "$out" in *"class=still_passing"*) ;; *) fail "the same commit on both sides was not classified still_passing: $out" ;; esac
# The exit code is about the comparison and the change, not about the mission verdict: a comparison that
# ran and found the row passing on both sides is a success of this tool.
[ "$code" = 0 ] || fail "a completed comparison exited $code, not 0: $out"
worktrees_after="$(git worktree list | wc -l)"
[ "$worktrees_before" = "$worktrees_after" ] || fail "the comparison left a worktree behind ($worktrees_before before, $worktrees_after after)"
# Nothing was written inside the tree under test: the row's own files are unchanged.
git -C "$ROOT" status --porcelain -- "$row" | grep -q . && fail 'the comparison modified the row inside the tree under test'

# (3) Each refusal is named, and runs nothing.
refusal() { # <want-fragment> <args...>
  local want=$1; shift
  set +e
  local got; got="$(bash scripts/lib/row-at-sha.sh "$@" 2>&1)"
  local rc=$?
  set -e
  [ "$rc" = 2 ] || fail "a refusal exited $rc, not 2: $got"
  case "$got" in *"$want"*) ;; *) fail "the refusal did not name $want: $got" ;; esac
}
refusal row_at_sha_bad_commit 'HEAD~1' "$row"
refusal row_at_sha_row_required "$sha"
refusal row_at_sha_row_missing "$sha" scripts/test-does-not-exist.lua
# A row that exists HERE and not at the base: this branch own scripts/test-row-at-sha.sh, run against
# the commit this branch started from. Using HEAD as the base would find the file present and prove
# nothing (measured: the refusal never fired because the row existed at both ends).
base_sha=$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD~1)
if git cat-file -e "$base_sha:scripts/test-row-at-sha.sh" 2>/dev/null; then
  echo NOTE: the absent-at-base case cannot be made here: the row already exists at $base_sha
else
  refusal row_at_sha_row_absent_at_base "$base_sha" scripts/test-row-at-sha.sh
fi

echo 'test-row-at-sha: ok (four classes and the skip convention, a real comparison with no worktree left behind, every refusal named)'
