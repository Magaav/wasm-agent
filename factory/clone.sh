#!/usr/bin/env bash
# THE FACTORY RUNS FROM A CLONE THAT FOLLOWS origin/main (factory-is-small-and-tested, 27/11).
#
# WHAT HAPPENED: the health loop ran a COPY of factory/health-loop.sh + lib/main-binary.sh kept in
# ~/Work/missions/_orch. Queues #123 and #142 landed on main and changed nothing for three hours, because the loop that
# judges a landing was executing code from the day the copy was made - and the copy differs from the tree (measured 27/11:
# `diff` says so on health-loop.sh itself).
#
# So a factory service runs `<clone>/factory/<script>.sh`, where the clone is THIS repository's clone that is fetched and
# fast-forwarded to origin/main before the run (`--refresh`, which the units call as ExecStartPre). A hand copy is never a
# service again: scripts/test-factory-runs-from-a-clone.mjs refuses a unit that points outside a clone.
#
# Costs nothing when nothing moved: one `git fetch`, then a `merge --ff-only` that is a no-op.
set -uo pipefail

CLONE="${WA_FACTORY_CLONE:-$HOME/wasm-agent/factory-clone}"
REMOTE="${WA_FACTORY_REMOTE:-origin}"
BRANCH="${WA_FACTORY_BRANCH:-main}"
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --refresh) : ;;
    --path) echo "$CLONE"; exit 0 ;;
    --quiet) QUIET=1 ;;
    -h|--help)
      echo "usage: factory/clone.sh [--refresh] [--path] [--quiet]"
      echo "  --refresh   fetch origin and fast-forward the clone to origin/main (what the units run as ExecStartPre)"
      echo "  --path      print the clone's path and exit"
      exit 0 ;;
    *) echo "factory/clone.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || echo "factory clone: $*"; }

if [ ! -d "$CLONE/.git" ]; then
  say "no clone at $CLONE; creating it from $REMOTE"
  mkdir -p "$(dirname "$CLONE")" || exit 1
  git clone --quiet --branch "$BRANCH" "$REMOTE" "$CLONE" 2>/dev/null || {
    # `origin` is an SSH alias in this fleet; fall back to the canonical repo's own URL when the alias is not resolvable here.
    url=$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null) || {
      echo "factory clone: cannot clone - no $REMOTE and no origin to copy" >&2; exit 1; }
    git clone --quiet --branch "$BRANCH" "$url" "$CLONE" || exit 1
  }
fi

[ "$QUIET" = 1 ] || say "following $REMOTE/$BRANCH in $CLONE"
git -C "$CLONE" fetch --quiet "$REMOTE" "$BRANCH" || { echo "factory clone: fetch failed; refusing to run stale factory code" >&2; exit 1; }
git -C "$CLONE" merge --quiet --ff-only "$REMOTE/$BRANCH" || {
  echo "factory clone: $CLONE is not a fast-forward of $REMOTE/$BRANCH - a service must not run ahead of main, and must not
resolve this itself; reset the clone or name another with WA_FACTORY_CLONE" >&2
  exit 1
}
if [ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
  git -C "$CLONE" checkout --quiet "$BRANCH" || exit 1
fi
say "at $(git -C "$CLONE" rev-parse --short HEAD) ($(git -C "$CLONE" log -1 --format=%s | cut -c1-60))"
exit 0
