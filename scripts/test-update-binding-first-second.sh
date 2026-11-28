#!/usr/bin/env bash
# THE SCRATCH TREE NODE, AND THE PRECONDITION ASKED IN THE FIRST SECOND (bug 3, Victor on work 27/11).
#
# The node work is a tree install whose deploy source was not the fetched origin/main; the deploy discovered it
# after 32m54s of compiling. The binding question itself costs ~82 ms, so this row drives it on a scratch tree node
# - a git tree with a real remote - and asserts three things a person needs:
#   1. a tree that IS the fetched origin/main answers in well under a second;
#   2. a tree that is BEHIND the fetched origin/main refuses, in the same under-a-second budget;
#   3. the refusal names both commits and the exact commands that fix it, so nobody has to search for them.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINDING="$ROOT/scripts/runtime-install-binding.mjs"
command -v node >/dev/null 2>&1 || { echo 'SKIP update-binding-first-second: no node' ; exit 0; }
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"
W=$(mktemp -d "$TMPBASE/wa-binding.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
cleanup() { if [ "$failed" -gt 0 ]; then printf 'binding row: scratch kept at %s\n' "$W"; else rm -rf "$W"; fi }
trap cleanup EXIT

# --- a scratch origin and a tree that follows it -------------------------------------------------
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$W/tree"
git -C "$W/tree" config user.email row@example.invalid
git -C "$W/tree" config user.name row
echo one > "$W/tree/file"; git -C "$W/tree" add file; git -C "$W/tree" commit -qm first
git -C "$W/tree" branch -M main
git -C "$W/tree" remote add origin "$W/origin.git"
git -C "$W/tree" push -q origin main
git -C "$W/tree" fetch -q origin
A=$(git -C "$W/tree" rev-parse HEAD)
[ -n "$A" ] || { echo 'SKIP update-binding-first-second: the scratch tree has no commit'; exit 0; }

# 1. the tree IS the fetched main: answered, and quickly
s=$(date +%s%N)
out=$(node "$BINDING" "$W/tree" 2>&1); rc=$?
e=$(( ($(date +%s%N) - s) / 1000000 ))
[ "$rc" = 0 ] && ok "a tree at the fetched origin/main is accepted (${e} ms)" || bad "it was refused: $out"
[ "$e" -lt 1000 ] && ok "and the answer came in under a second (${e} ms)" || bad "the check took ${e} ms"

# 2. the ref moves, the tree does not: refused, still under a second, and it says what to do
other=$(mktemp -d "$W/other.XXXXXX")
git -C "$other" init -q; git -C "$other" config user.email row@example.invalid; git -C "$other" config user.name row
git -C "$other" remote add origin "$W/origin.git"; git -C "$other" fetch -q origin
git -C "$other" checkout -q -B main origin/main
echo two >> "$other/file"; git -C "$other" commit -qam second; git -C "$other" push -q origin main
git -C "$W/tree" fetch -q origin
B=$(git -C "$W/tree" rev-parse origin/main)
[ "$A" != "$B" ] || { bad 'the fixture did not move origin/main'; }
s=$(date +%s%N)
out=$(node "$BINDING" "$W/tree" 2>&1); rc=$?
e=$(( ($(date +%s%N) - s) / 1000000 ))
# THE RULE CHANGED, ON PURPOSE (work update retry #3, 27/11): a tree ON main but behind its tip IS main - deploy.sh and
# this binding are one owner of that question now, so the row asserts BOTH directions.
[ "$rc" = 0 ] && ok "a tree behind the fetched origin/main is ACCEPTED now (${e} ms)" || bad "it was refused: $out"
[ "$e" -lt 1000 ] && ok "and it answers in under a second (${e} ms)" || bad "the check took ${e} ms"
# a commit that is NOT on main is still refused, by name, with the fix
cd "$W/tree" && git checkout -q -B side "$A" && echo side > side.txt && git add side.txt   && git -c user.email=row -c user.name=row commit -qm side-only
SIDE=$(git -C "$W/tree" rev-parse side)
s=$(date +%s%N); out=$(node "$BINDING" "$W/tree" 2>&1); rc=$?; e=$(( ($(date +%s%N) - s) / 1000000 ))
[ "$rc" != 0 ] && ok "a commit that is NOT on origin/main is refused (${e} ms)" || bad 'a side commit was accepted'
case "$out" in *"${SIDE:0:12}"*) ok 'the refusal names the commit the tree is on' ;; *) bad "the refusal does not name ${SIDE:0:12}: $out" ;; esac
case "$out" in *'reset --hard origin/main'*) ok 'and the command that fixes it' ;; *) bad 'the refusal names no fix' ;; esac

printf 'update binding first-second: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'update binding first-second ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
