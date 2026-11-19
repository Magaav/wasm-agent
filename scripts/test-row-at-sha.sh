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
# item 8 of the node-ops round, stated as its own case: a base that SKIPPED the row never ran it, so a
# failure here is NEW (this change is not exonerated), never pre_existing.
check 77 1 new_failure 'a skip at the base and a failure here is a new failure, not pre_existing'
check 77 2 new_failure 'any nonzero change code behind a base skip is a new failure'
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
# EACH SIDE RAN WITH ITS OWN HOME AND LEDGER (item 7 of the node-ops round). Both calls used
# "$scratch/home" before, so the base row read the ledger the change row had just written - and a row
# about a restore or a first run would grade the other side's state. The worker now prints both paths as
# fields, so this is the run's own answer and not a reading of its logs.
base_home="$(printf '%s\n' "$out" | sed -n 's/^base_home=//p')"
change_home="$(printf '%s\n' "$out" | sed -n 's/^change_home=//p')"
[ -n "$base_home" ] && [ -n "$change_home" ] || fail "the comparison did not name both homes, so the separate-ledger rule was not checked: $out"
[ "$base_home" != "$change_home" ] || fail "both sides of the comparison ran with the SAME home ($base_home), so they shared one ledger"
case "$change_home" in "$base_home"/*) fail "the change side home ($change_home) is inside the base side home ($base_home): one ledger" ;; esac
case "$base_home" in "$change_home"/*) fail "the base side home ($base_home) is inside the change side home ($change_home): one ledger" ;; esac
case "$base_home" in */base/*) ;; *) fail "the base side home is not under the base side root: $base_home" ;; esac
case "$change_home" in */change/*) ;; *) fail "the change side home is not under the change side root: $change_home" ;; esac
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

# (4) THE NODE VERB, wa test --at <sha> <row> (item 8 of the node-ops round). The same comparison behind one
# command, in its own scratch home (never the operator store). It RUNS a real row and asserts the row's
# answer; the refusals are the verb's own, not the worker's class= line.
nodebin="$(command -v wa || true)"
[ -n "$nodebin" ] || fail 'no wa on PATH, so the node verb cannot be exercised'
verb_home="$SCRATCH/home-verb"
mkdir -p "$verb_home/.wasm-agent" || fail "cannot create the verb scratch home $verb_home"
verb() { # <wa args...> -> $verb_out, $verb_code
  set +e
  verb_out="$(WASM_AGENT_HOME="$verb_home" WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_MANAGED=0 \
    "$nodebin" --db "$verb_home/.wasm-agent/ledger.db" "$@" 2>&1)"
  verb_code=$?
  set -e
}
verb test --at "$sha" "$row"
[ "$verb_code" = 0 ] || fail "wa test exited $verb_code, not 0, for a row that passes on both sides: $verb_out"
case "$verb_out" in *"class=still_passing"*) ;; *) fail "wa test did not print class=still_passing: $verb_out" ;; esac
case "$verb_out" in *"base_code=0"*) ;; *) fail "wa test did not print base_code=0: $verb_out" ;; esac
case "$verb_out" in *"change_code=0"*) ;; *) fail "wa test did not print change_code=0: $verb_out" ;; esac
verb test --at "$sha" "$row" --json
case "$verb_out" in *'"class":"still_passing"'*) ;; *) fail "wa test --json did not answer the class as JSON: $verb_out" ;; esac
verb test "$row"
[ "$verb_code" = 2 ] || fail "wa test with no --at exited $verb_code, not 2: $verb_out"
case "$verb_out" in *row_at_sha_commit_required*) ;; *) fail "wa test with no --at did not name the missing commit: $verb_out" ;; esac
verb test --at "$sha"
[ "$verb_code" = 2 ] || fail "wa test with no row exited $verb_code, not 2: $verb_out"
case "$verb_out" in *row_at_sha_row_required*) ;; *) fail "wa test with no row did not name the missing row: $verb_out" ;; esac
verb test --at "$sha" "$row" --bogus
[ "$verb_code" = 2 ] || fail "wa test with an unknown option exited $verb_code, not 2: $verb_out"
case "$verb_out" in *row_at_sha_unknown_option*) ;; *) fail "wa test with an unknown option did not name it: $verb_out" ;; esac
# THE COMMIT IS VALIDATED BEFORE A SHELL EXISTS (item 5 of the node-ops round). A --at that is not hex is
# refused by name, and the proof that nothing ran is the file a command substitution would have created.
# A caller's argument reaching a shell is the class of defect, so the assertion is the EFFECT: the file
# does not exist afterwards, and the refusal names it.
pwn_marker="$SCRATCH/pwned-by-at"
rm -f "$pwn_marker"
verb test --at "$(printf '%s' '$(touch ')""$pwn_marker')' scripts/test-row-at-sha.sh
[ "$verb_code" = 2 ] || fail "wa test with a --at that runs a command exited $verb_code, not 2: $verb_out"
case "$verb_out" in *row_at_sha_bad_commit*) ;; *) fail "wa test did not refuse a non-hex --at by name: $verb_out" ;; esac
[ ! -e "$pwn_marker" ] || fail "wa test EXECUTED the --at argument's command substitution: $pwn_marker exists"
# A refusal the WORKER answers (a row absent at that commit) reaches the caller with the worker's own code
# and text: a refusal is not a comparison that failed.
if [ -n "$base_sha" ]; then
  verb test --at "$base_sha" scripts/test-row-at-sha.sh
  [ "$verb_code" = 2 ] || fail "wa test on a row absent at the base exited $verb_code, not 2: $verb_out"
  case "$verb_out" in *row_at_sha_row_absent_at_base*) ;; *) fail "wa test did not pass the worker's absent-at-base refusal through: $verb_out" ;; esac
fi

echo 'test-row-at-sha: ok (four classes and the skip convention, a real comparison with no worktree left behind, every refusal named, the wa test verb run for real, and a --at that is a command substitution refused before any shell runs - proved by the file it would have created not existing, and the base and change sides run with separate homes and separate ledgers)'
