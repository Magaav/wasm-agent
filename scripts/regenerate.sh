#!/usr/bin/env bash
# Regenerate every derived file this tree commits, from scripts/generators.txt, on THIS tree.
#
#   bash scripts/regenerate.sh [--root <dir>] [--quiet]   run every generator, print what changed
#   bash scripts/regenerate.sh --outputs                  print the declared output paths, one per line
#
# The landing's merge step and the preflight run it on the MERGED tree (lua/core/land.lua, M.regenerate)
# and put what it wrote into the merge commit. That is the one place two branches that are each correct
# alone are visible together, and it is where a derived file used to go stale: land243 added refusal
# codes, land244's narrowed gate never ran the refusal row, and main was red from bfad4f8f (21/11).
#
# What it guarantees, and why each line of that is here rather than in the caller:
#   * a generator that FAILS is a named failure, never a pass. All the generators are still run (so one
#     run names every one that is broken) and the exit is 1 at the end;
#   * the exact set of files it wrote is PRINTED as machine-readable lines the caller parses
#     ('regenerate: changed <path>', 'regenerate: changed_count <n>'), because "did the merge commit need
#     amending" is a question about bytes, not about a generator's own opinion;
#   * a DECLARED OUTPUT THAT DOES NOT EXIST after a successful run is a failure by name: a registry line
#     that names the wrong path would otherwise let a merge resolve a conflict it must not touch;
#   * a tree that is not a git worktree is REFUSED (exit 2): without git there is no way to tell what a
#     generator wrote, and an unknown answer here would put a stale file in a landing while saying nothing;
#   * a missing registry is not an error - a fork of this tree may not have one - but it is NAMED on stdout,
#     because "nothing to regenerate" and "I did not look" must not read the same;
#   * it changes nothing but the generated files: it runs no git command that writes (no add, no commit).
#     Staging and amending belongs to the caller, which is the only party that knows the commit.
#
# Timing: every generator runs under timeout (REGENERATE_TIMEOUT, default 300 s each) so a generator that
# hangs cannot hang a landing without a name.
set -uo pipefail
usage() { sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
root=$(pwd)
quiet=0
outputs_only=0
while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || { echo "regenerate: refused(root_missing): --root needs a directory" >&2; exit 2; }; root=$2; shift 2 ;;
    --quiet) quiet=1; shift ;;
    --outputs) outputs_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "regenerate: refused(unknown_argument): $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -d "$root" ] || { echo "regenerate: refused(root_missing): $root is not a directory" >&2; exit 2; }
root=$(cd "$root" && pwd -P) || { echo "regenerate: refused(root_unreadable): cannot cd into the tree" >&2; exit 2; }
registry=$root/scripts/generators.txt
limit=${REGENERATE_TIMEOUT:-300}

# One registry line -> '<outputs>\t<command>'. Blank/comment lines and malformed lines are skipped here
# and reported by the run loop, so a broken line is named where a reader is looking for a run.
lines() { sed -n '/^[[:space:]]*[^#[:space:]]/p' "$registry" 2>/dev/null; }

if [ "$outputs_only" = 1 ]; then
  [ -f "$registry" ] || exit 0
  while IFS= read -r line; do
    spec=${line%% = *}
    [ "$spec" = "$line" ] && continue          # no " = ": reported as malformed by a run, not printed here
    printf '%s\n' "$spec" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
  done <<< "$(lines)"
  exit 0
fi

# WHAT CHANGED IS A GIT QUESTION. Asked first, so a tree without git is refused before any generator runs
# and could have written a file nothing recorded.
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "regenerate: refused(not_a_worktree): $root is not in a git worktree, so what a generator writes cannot be told" >&2
  exit 2
}
if command -v timeout >/dev/null 2>&1; then run_to() { timeout "$limit" "$@"; }
else run_to() { "$@"; }; fi

say() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }

if [ ! -f "$registry" ]; then
  say "regenerate: no registry at scripts/generators.txt - this tree declares no derived file, nothing was run"
  printf 'regenerate: changed_count 0\n'
  exit 0
fi

# WHAT THE RUN CHANGED, not what the tree happens to owe: a snapshot before the generators run, so a
# caller's own uncommitted work (a landing tree is clean, but a hand run is not) is never reported as a
# generator's output.
before=$(git -C "$root" status --porcelain 2>/dev/null | sed -e 's/^...//' | sort)
generators=0
failed=0
declared=''
while IFS= read -r line; do
  spec=${line%% = *}
  cmd=${line#* = }
  if [ "$spec" = "$line" ]; then
    failed=$((failed + 1))
    echo "regenerate: FAILED (malformed line, want '<output>[,<output>...] = <command>'): $line"
    continue
  fi
  cmd=$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$cmd" ] || { failed=$((failed + 1)); echo "regenerate: FAILED (a line with outputs and no command): $line"; continue; }
  generators=$((generators + 1))
  say "regenerate: running $cmd"
  out=$(cd "$root" && run_to bash -c "$cmd" 2>&1)
  code=$?
  # A generator's own output is evidence: the last non-empty line is what a reader needs when it fails.
  last=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
  if [ "$code" != 0 ]; then
    failed=$((failed + 1))
    if [ "$code" = 124 ]; then
      echo "regenerate: FAILED $cmd (timed out after ${limit}s)"
    else
      echo "regenerate: FAILED $cmd (exit $code): ${last:-(no output)}"
    fi
    continue
  fi
  say "regenerate: ok $cmd${last:+ ($last)}"
  # EVERY DECLARED OUTPUT EXISTS, or the line is wrong and the merge must not trust it.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    declared="$declared$path
"
    case $path in
      /*|*..*) failed=$((failed + 1)); echo "regenerate: FAILED $cmd (output '$path' is not a repo-relative path)" ; continue ;;
    esac
    [ -e "$root/$path" ] || { failed=$((failed + 1)); echo "regenerate: FAILED $cmd (declared output '$path' does not exist after a successful run)"; }
  done <<< "$(printf '%s\n' "$spec" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')"
done <<< "$(lines)"

# The files this changed, exactly: untracked included, because a generator that ADDS a file adds it to the
# merge commit too, and a caller that only looked at tracked diffs would leave it behind.
after=$(git -C "$root" status --porcelain 2>/dev/null | sed -e 's/^...//' | sort)
count=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  # A rename reads "old -> new"; the file that exists now is the new one.
  path=${path##* -> }
  # Already dirty before this run: not this run's writing, so not reported as such.
  grep -qxF "$path" <<< "$before" && continue
  printf 'regenerate: changed %s\n' "$path"
  count=$((count + 1))
done <<< "$after"
printf 'regenerate: changed_count %s\n' "$count"
if [ "$count" = 0 ]; then
  say "regenerate: $generators generator(s) left the tree unchanged"
else
  say "regenerate: $count file(s) written by $generators generator(s) - the caller must commit them"
fi
[ "$failed" = 0 ] || { echo "regenerate: $failed generator line(s) FAILED - a derived file here is NOT trustworthy" >&2; exit 1; }
exit 0
