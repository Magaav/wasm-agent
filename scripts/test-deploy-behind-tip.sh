#!/usr/bin/env bash
# A DEPLOY FROM A TREE BEHIND THE TIP IS A DEPLOY (work retry 4, 27/11). The deploy printed "the tree is on 27b99c8e,
# which is on origin/main ... deploying the tree as it is" and then, two lines later, refused with "this tree is 23
# commit(s) behind origin/main; merge main first". Two owners of one question, adjacent lines, opposite answers - and a
# remote update fast-forwards to a NAMED commit that may sit behind a moving tip, so the stricter one made every such
# update impossible.
#
# The rules are predicates, so this row asserts them directly on a scratch repo:
#   1. ancestry accepts a tree that is ON main but behind its tip, while equality does not;
#   2. the behind-count the note reports is the real distance (so the note says something true);
#   3. a commit that is NOT on main is still refused - the rule keeps its direction;
#   4. the deploy no longer has a `fail` on that count: the phrase it used is gone from scripts/deploy.sh.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"; W=$(mktemp -d "$TMPBASE/wa-behind.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
trap 'rm -rf "$W"' EXIT

git init -q --bare "$W/o.git"; git -C "$W/o.git" symbolic-ref HEAD refs/heads/main
git init -q "$W/t"; cd "$W/t"
git config user.email row; git config user.name row
echo a > f; git add f; git commit -qm A; git branch -M main; git remote add origin "$W/o.git"; git push -q origin main
A=$(git rev-parse HEAD)
git init -q "$W/o2"; cd "$W/o2"; git config user.email row; git config user.name row
git remote add origin "$W/o.git"; git fetch -q origin; git checkout -q -B main origin/main
for n in 1 2 3; do echo "$n" >> f; git commit -qam "B$n"; done
git push -q origin main
cd "$W/t"; git fetch -q origin
M=$(git rev-parse origin/main)
BEHIND=$(git rev-list --count "HEAD..$M")

[ "$BEHIND" = 3 ] && ok 'the fixture is 3 commits behind the tip' || bad "fixture distance is $BEHIND, not 3"
if git merge-base --is-ancestor HEAD "$M"; then ok 'ancestry accepts a tree that is on main but behind its tip'; else bad 'ancestry refused a main commit'; fi
if [ "$(git rev-parse HEAD)" = "$M" ]; then bad 'fixture: equality also passes, so the row proves nothing'; else ok 'equality would have refused it (the rule that made updates impossible)'; fi
# the note the deploy now prints must carry a true count
NOTE="the tree is $BEHIND commit(s) behind origin/main; deploying it as it is"
case "$NOTE" in *'3 commit(s) behind'*) ok 'the note reports the real distance' ;; *) bad "note says the wrong distance: $NOTE" ;; esac
# direction: a side commit is still not main
cd "$W/t"; git checkout -q -B side "$A"; echo s > s.txt; git add s.txt; git commit -qm side; SIDE=$(git rev-parse HEAD)
if git merge-base --is-ancestor "$SIDE" "$M"; then bad 'a commit that is not on main passed the ancestry test'; else ok 'a commit that is not on main is still refused'; fi
# the refusal phrase is gone from the deploy
if grep -qE 'fail "this tree is \$BEHIND' "$ROOT/scripts/deploy.sh"; then bad 'scripts/deploy.sh still refuses a tree for being behind'; else ok 'the deploy no longer refuses a tree for being behind (no fail on $BEHIND)'; fi

printf 'deploy behind tip: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'deploy behind tip ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
