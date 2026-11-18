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
# remote, an unreachable remote). Callers refuse on 1 AND on 2 unless the operator names an override, because
# "I could not ask" is not "it is fine".
#
# A HEAD THIS CLONE HAS NOT FETCHED IS NOT A "CANNOT TELL" ANY MORE. `git ls-remote` reports a sha per branch and
# the containment question ("is this commit an ancestor of that head?") is a git question about an OBJECT. On a
# fast-moving main the remote's head is routinely one this clone has never fetched, so every publish answered
# "unknown" and refused work that was perfectly shared (round-3 item 7). The heads the remote reports are
# fetched ONCE, into refs/remotes/<remote>/*, and the question is asked again with the objects here. Only a
# fetch that FAILS leaves the answer unknown, and it says which fetch failed and why.
#
# Sourced by the shell publishers; executable by the ones that are not shell (scripts/codemode-build.mjs,
# scripts/ship-wave.mjs), which run it as:
#
#     bash scripts/lib/shared-commit.sh <repository> <commit> [remote]
#
# and read the exit code (0 shared, 1 not shared, 2 cannot tell).

# How long the one fetch may take. Bounded for the same reason every other network step here is: a publish that
# hangs on a stalled remote is worse than one that says it could not ask.
WA_SHARED_FETCH_TIMEOUT="${WA_SHARED_FETCH_TIMEOUT:-60}"

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
  # ONE FETCH, WHEN A HEAD THE REMOTE NAMED IS NOT HERE. The heads are fetched together (one round trip, one
  # timeout) instead of one sha at a time, because a remote may refuse a bare "fetch this sha" that it happily
  # serves as a branch.
  local absent=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha="${line%%[[:space:]]*}"
    [ -n "$sha" ] || continue
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || absent=1
  done <<< "$heads"
  if [ "$absent" = 1 ]; then
    local guard='' fetched=1
    command -v timeout >/dev/null 2>&1 && guard=timeout
    if [ -n "$guard" ]; then
      "$guard" "$WA_SHARED_FETCH_TIMEOUT" git -C "$repo" fetch --quiet --no-tags "$remote" \
        "+refs/heads/*:refs/remotes/$remote/*" >/dev/null 2>&1 || fetched=0
    else
      git -C "$repo" fetch --quiet --no-tags "$remote" \
        "+refs/heads/*:refs/remotes/$remote/*" >/dev/null 2>&1 || fetched=0
    fi
    if [ "$fetched" != 1 ]; then
      # The one remaining cause of "cannot tell": the objects are still not here and the fetch that would have
      # brought them failed. Said out loud, because the caller's refusal quotes this.
      printf 'unknown: could not fetch the heads %s reported (git -C %s fetch %s failed or timed out after %ss), so a head this clone has never seen cannot be compared
' \
        "$remote" "$repo" "$remote" "$WA_SHARED_FETCH_TIMEOUT" >&2
    else
      printf 'note: fetched %s once, because a head it reported was not here
' "$remote" >&2
    fi
  fi

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
