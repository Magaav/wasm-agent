#!/usr/bin/env bash
# Create an agent worktree where agents' worktrees belong: under the node's one root (docs/ONEROOT.md).
#
#   bash scripts/new-worktree.sh <name> [--base <ref>] [--canonical <dir>] [--detach] [--print-path]
#
# WHY. Worktrees were created wherever a session's brief said to put them, which on wa-desktop on 12/11
# meant 42 directories named `~/wt-*` beside the home - ~45 GB that no command owned, that a cleaner
# could not see, and that nobody could tell apart from a draft they still needed. One root means one
# place to look, one place for `wa clean` to judge, and one path to print when a refusal says "make a
# worktree". The root is the state root the node already had, never a second concept:
#
#   <home>/.wasm-agent/worktrees/<name>
#
# where <home> is $WASM_AGENT_HOME when set, else $HOME (the same resolution the node itself uses).
#
# This script only CREATES. It never removes a worktree (that is `wa clean`, with its rules: landed,
# clean, unpinned) and it never edits the canonical checkout.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

name=''
base='origin/main'
canonical=''
detach=0
print_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) base=${2:?}; shift 2 ;;
    --canonical) canonical=${2:?}; shift 2 ;;
    --detach) detach=1; shift ;;
    --print-path) print_only=1; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "new-worktree: unknown option $1" >&2; exit 2 ;;
    *) name=$1; shift ;;
  esac
done

home=${WASM_AGENT_HOME:-$HOME}
root="$home/.wasm-agent"
[ -n "$canonical" ] || canonical="$ROOT"
destination="$root/worktrees/$name"

if [ -z "$name" ]; then
  echo "new-worktree: a name is required (the directory under $root/worktrees)" >&2
  exit 2
fi
case "$name" in
  */*|..|.) echo "new-worktree: the name must be one path component, not '$name'" >&2; exit 2 ;;
esac
if [ "$print_only" = 1 ]; then printf '%s\n' "$destination"; exit 0; fi

mkdir -p "$root/worktrees" || { echo "new-worktree: cannot create $root/worktrees" >&2; exit 1; }
if [ -e "$destination" ]; then
  echo "new-worktree: $destination already exists; refusing to reuse a tree whose state I did not create" >&2
  exit 1
fi

if [ "$detach" = 1 ]; then
  git -C "$canonical" worktree add --detach "$destination" "$base" >&2 || exit 1
else
  branch="change/$name"
  git -C "$canonical" worktree add -b "$branch" "$destination" "$base" >&2 || exit 1
fi
printf '%s\n' "$destination"
