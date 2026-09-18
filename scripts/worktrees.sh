#!/usr/bin/env bash
# Who is working where, and whether any of it can still merge.
#
# The board was previously discoverable only by asking git the right questions, which
# meant a branch could sit for a day at 49 commits of drift and be found in the middle
# of an unrelated task. This prints the answer: how far each worktree's branch has
# drifted from main, whether it has uncommitted work, and whether it still merges.
#
# Two columns matter most:
#   ahead 0    - the branch is already in main; its worktree is a reaping candidate
#   CONFLICT   - the branch no longer merges; it needs a rebase before anyone reviews
set -uo pipefail
cd "$(dirname "$0")/.."

git fetch -q origin 2>/dev/null || true
main=origin/main
main_head=$(git log --oneline -1 "$main")
echo "main: $main_head"
echo

printf '%-18s %-20s %6s %7s %6s  %s\n' WORKTREE BRANCH AHEAD BEHIND DIRTY MERGE
git worktree list --porcelain \
  | awk '/^worktree /{path=$2} /^branch /{print path "\t" $2}' \
  | while IFS=$'\t' read -r path ref; do
      name=$(basename "$path")
      branch=${ref#refs/heads/}
      [ "$branch" = "main" ] && continue
      base=$(git merge-base "$branch" "$main" 2>/dev/null) || { printf '%-18s %-20s %6s %7s %6s  %s\n' "$name" "$branch" "?" "?" "?" "unknown branch"; continue; }
      ahead=$(git rev-list --count "$main..$branch")
      behind=$(git rev-list --count "$base..$main")
      dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      if git merge-tree --write-tree "$main" "$branch" >/dev/null 2>&1; then
        merge=clean
      else
        merge=CONFLICT
      fi
      printf '%-18s %-20s %6s %7s %6s  %s\n' "$name" "$branch" "$ahead" "$behind" "$dirty" "$merge"
    done

cat <<'NOTES'

Reading it:
  ahead 0    already in main - the worktree can be reaped
  behind N   commits main has that the branch has never seen; drift is time, not skill
  dirty N    uncommitted work: the branch may say merged while the worktree says in
             progress, and neither can be reviewed. Commit it or drop it.
  CONFLICT   it no longer merges. Rebase before review, and expect it to shrink.

Before reporting a task done:  git rebase origin/main
                               git merge-tree --write-tree origin/main HEAD
NOTES
