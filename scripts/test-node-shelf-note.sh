#!/usr/bin/env bash
# THE SHELF NOTE: what the build path says about the published builds it did not use (bug 2, Victor on work 27/11).
#
# "no published binary for this commit" was true and useless on its own: it never said whether the shelf held anything,
# or how stale it was, so "the factory is behind" had to be inferred from a screenshot. The sentence now names the tag
# and the distance - and refuses to invent a distance it cannot measure.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/lib/node-binaries.sh"
[ -r "$LIB" ] || { echo "SKIP node-shelf-note: $LIB not readable"; exit 0; }
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"
W=$(mktemp -d "$TMPBASE/wa-shelf.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
trap 'rm -rf "$W"' EXIT

# a scratch tree with three commits, so "behind by N" is a number that can be checked by hand
git init -q "$W/tree"; cd "$W/tree"
git config user.email row; git config user.name row
for n in 1 2 3; do echo "$n" > "f$n"; git add "f$n"; git commit -qm "commit $n"; done
C1=$(git rev-parse HEAD~2); HEAD_SHA=$(git rev-parse HEAD)
TAG="node-$(printf '%s' "$C1" | cut -c1-12)"
# shellcheck disable=SC1090
. "$LIB"

note=$(wa_node_shelf_note "$TAG" "$HEAD_SHA")
case "$note" in *"$TAG"*) ok 'the note names the newest published tag' ;; *) bad "no tag in: $note" ;; esac
case "$note" in *'2 commit(s) behind this tree'*) ok 'and how far behind, measured from the tag commit to HEAD' ;; *) bad "no distance in: $note" ;; esac

note2=$(wa_node_shelf_note "" "$HEAD_SHA")
case "$note2" in *'empty or unreadable'*) ok 'an empty shelf says the list is empty or unreadable' ;; *) bad "unexpected: $note2" ;; esac

note3=$(wa_node_shelf_note 'node-000000000000' "$HEAD_SHA")
case "$note3" in *'cannot be measured here'*) ok 'a tag whose commit this tree does not have gets no invented distance' ;; *) bad "unexpected: $note3" ;; esac

note4=$(wa_node_shelf_note 'wheel-1.2' "$HEAD_SHA")
case "$note4" in *'the newest published build is wheel-1.2'*) ok 'a tag that is not node-<sha12> is named without arithmetic' ;; *) bad "unexpected: $note4" ;; esac

printf 'node shelf note: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'node shelf note ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
