#!/usr/bin/env bash
# "Is this commit on a branch anybody else can see?" - one answer, asked of the INCOMING repository.
#
# WHY. On 18/11 a node ran a binary built from 8 commits that were on no landed branch, and the artifact was
# indistinguishable from a landed one. The publisher's check asked the LOCAL repository instead:
#
#     git for-each-ref --contains "$COMMIT" refs/remotes/
#
# and any ref under refs/remotes/ answers that question, including refs that are local-only, refs left behind by
# a fetch that has since been superseded, and refs naming a branch the remote has deleted. A commit pushed,
# force-pushed away and rebuilt locally was "on a pushed branch" forever, because the memory of the push stayed.
#
# The only source that says what the incoming repository has NOW is the remote itself: `git ls-remote`. So the
# question is asked there, and the answer is three-valued: shared (0), not shared (1), and cannot tell (2 - no
# remote, an unreachable remote, a remote head this clone has never fetched). Callers refuse on 1 AND on 2
# unless the operator names an override, because "I could not ask" is not "it is fine".
#
# Sourced by the shell publishers; executable by the ones that are not shell (scripts/codemode-build.mjs,
# scripts/ship-wave.mjs), which run it as:
#
#     bash scripts/lib/shared-commit.sh <repository> <commit> [remote]
#
# and read the exit code (0 shared, 1 not shared, 2 cannot tell).

# wa_commit_shared <repository> <commit> [remote=origin] -> prints the branch names (one per line) on 0.
wa_commit_shared() {
  local repo="${1:-}" commit="${2:-}" remote="${3:-origin}"
  local heads line sha branch found='' unverifiable=0
  [ -n "$repo" ] && [ -n "$commit" ] || return 2
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 2
  command -v git >/dev/null 2>&1 || return 2
  # The commit has to be an object HERE to be compared with anything; a publisher that cannot name the bytes it
  # built has a different problem.
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || return 2
  heads="$(git -C "$repo" ls-remote --heads "$remote" 2>/dev/null)" || return 2
  # An empty list is an answer, not a failure: this remote has no branches (a fresh one, or one whose branches
  # were all deleted), so no branch contains the commit. */

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha="${line%%[[:space:]]*}"
    branch="${line#*[[:space:]]}"
    case "$branch" in refs/heads/*) branch="${branch#refs/heads/}" ;; esac
    [ -n "$sha" ] || continue
    if [ "$sha" = "$commit" ]; then found="$found$branch "; continue; fi
    if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then unverifiable=$((unverifiable + 1)); continue; fi
    if git -C "$repo" merge-base --is-ancestor "$commit" "$sha" 2>/dev/null; then found="$found$branch "; fi
  done <<< "$heads"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  # No branch contains it - but if some remote head could not even be compared (never fetched here), the honest
  # answer is "cannot tell", not "no".
  [ "$unverifiable" -gt 0 ] && return 2
  return 1
}

# When executed rather than sourced: the CLI the non-shell publishers use.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  branches="$(wa_commit_shared "$@")"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$branches" ;;
    1) printf 'not-shared: %s is reachable from no branch on the remote\n' "${2:-?}" >&2 ;;
    *) printf 'unknown: could not ask the remote what it has (no remote, unreachable, or a head this clone has not fetched)\n' >&2 ;;
  esac
  exit "$rc"
fi
