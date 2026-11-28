#!/bin/bash
# A FORGOTTEN SWAP MUST BE A LINE - AND IT MUST ACCUSE THE RIGHT COPY (28/11).
#
# MEASURED: every tip printed "NOT GRADED" for hours after the fix had LANDED, because the loop runs from a copy under
# _orch that a human swaps between landings (factory/MAP.md) and a running shell loop sources its lib once, at start.
#
# THEN THE FIRST REAL SWAP SHOWED THE CHECK ACCUSING THE WRONG SIDE: _orch was refreshed at 21:53 while the checkout's
# working tree sat commits behind main at 16:32, so the loop wrote "the running lib differs - swap _orch" about work
# somebody had JUST done, and a reader would have swapped a fresh copy over itself. Truth is origin/main, not a working
# tree, and the useful fact is which side is BEHIND.
#
# This row drives the check against a throwaway repo in both directions.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "health-swap-visible: $*"; exit 1; }
loop=factory/health-loop.sh
[ -f "$loop" ] || fail 'factory/health-loop.sh is missing'

grep -q 'wa_factory_selfcheck' "$loop" || fail 'the loop has no self-check, so a stale _orch copy is silent again'
grep -q 'origin/main:factory/lib/main-binary.sh' "$loop" || fail 'the self-check compares with a working tree, not with origin/main'
grep -q 'swap _orch per factory/MAP.md' "$loop" || fail 'the self-check does not say what to do about a stale copy'
grep -q 'orch(health): factory lib' "$loop" || fail 'a grading line does not name the factory lib that produced it'

grep -q 'AHEAD of origin/main' "$loop" || fail 'the self-check cannot tell a copy that is AHEAD from one that is stale'

body=$(awk '/^wa_factory_selfcheck\(\)/,/^}/' "$loop")
[ -n "$body" ] || fail 'could not lift wa_factory_selfcheck out of the loop'

ask() { # <root> -> the note, with HERE and C as the loop would set them
  HERE="$1/mine" C="$1/origin" bash -c "$body"$'\nwa_factory_selfcheck' 2>&1
}

make_repo() { # <dir> <commit-date>
  local dir=$1 when=$2
  mkdir -p "$dir/origin/factory/lib" "$dir/mine/lib" || return 1
  printf 'landed v1\n' > "$dir/origin/factory/lib/main-binary.sh"
  git -C "$dir/origin" init -q -b main 2>/dev/null
  git -C "$dir/origin" add -A 2>/dev/null
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$dir/origin" -c user.email=t@example.invalid -c user.name=t commit -q -m base 2>/dev/null
  git -C "$dir/origin" update-ref refs/remotes/origin/main HEAD 2>/dev/null
  printf 'running v2\n' > "$dir/mine/lib/main-binary.sh"
}

work=$(mktemp -d "${TMPDIR:-/tmp}/swapcheck.XXXXXX") || fail 'no temp dir'
trap 'rm -rf "$work"' EXIT

# THE RUNNING COPY IS OLDER THAN MAIN: that is the forgotten swap, and it must be named as STALE.
# main changed the lib AFTER this copy was taken: 15:30 against a copy made at 15:23.
make_repo "$work/stale" '2026-11-27T15:30:00' || fail 'could not build the throwaway repo'
touch -d '2026-11-27T15:23:00' "$work/stale/mine/lib/main-binary.sh"
note=$(ask "$work/stale")
[ -n "$note" ] || fail 'a running copy OLDER than origin/main produced no note at all'
case "$note" in *STALE*) ;; *) fail "an out-of-date copy is not called STALE: $note" ;; esac
case "$note" in *'swap _orch'*) ;; *) fail "the note does not say what to do: $note" ;; esac

# THE RUNNING COPY IS NEWER THAN MAIN: somebody already swapped, and the checkout is what is behind. Accusing the
# running copy here - which the first version did - makes a reader swap a fresh copy over itself.
make_repo "$work/ahead" '2026-11-27T15:23:00' || fail 'could not build the second throwaway repo'
touch "$work/ahead/mine/lib/main-binary.sh"
note=$(ask "$work/ahead")
case "$note" in *AHEAD*) ;; *) fail "a copy NEWER than main is not called AHEAD: ${note:-<no note>}" ;; esac
case "$note" in *STALE*) fail "a copy NEWER than main was called STALE, which invites a pointless swap: $note" ;; esac

# AND THE SAME FILE AS origin/main IS QUIET.
cp "$work/stale/origin/factory/lib/main-binary.sh" "$work/stale/mine/lib/main-binary.sh"
quiet=$(ask "$work/stale")
[ -z "$quiet" ] || fail "an identical copy still produced a note: $quiet"

echo "health swap visible ok (stale is named, ahead is named as ahead, identical is quiet, every grading line carries the lib)"
