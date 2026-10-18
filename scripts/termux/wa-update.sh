#!/data/data/com.termux/files/usr/bin/sh
# `wa update` on an Android/Termux node: move the installed source-built preview to a
# reviewed upstream revision, without touching the node's own state.
#
# This is the Termux analogue of `/update`, and deliberately NOT the same route. `/update`
# writes a request for the sentinel, because a node cannot replace itself and a desktop
# install is replaced by a separate process. On the phone there is no sentinel, no service
# and no second process: `wa ui` runs in the foreground and the operator is holding it. So
# the switch is done here, in the open, by a model-free shell command the operator ran.
#
# What it guarantees, and what it refuses:
#   * it reports the installed revision and the upstream revision it would move to
#     (`--check` is read-only and exits 0 when it is simply up to date)
#   * it refuses rather than guesses: unknown installed revision, unknown upstream, an
#     unreachable upstream, a modified installed release, a candidate that is not a
#     descendant of what is installed (downgrade or divergence), a wrong-ABI build, a
#     failed build, a leftover half-switched state, and concurrent runs
#   * it fetches the pinned upstream commit into a PRIVATE staging area; the operator's
#     checkout, if any, is never used as a build tree and never modified
#   * it builds the Android-native runtime and the matching launcher/UI closure from that
#     one tree, verifies the candidate, switches it in, keeps the previous release for
#     rollback, and says how to roll back
#   * it never runs `wa setup`, never re-asks for a provider key, never rotates identity,
#     and never writes anything under the node's home: `~/.wasm-agent` is not part of a
#     release and must not be. State survives because nothing here knows where it is.
#
# Usage: wa update [--check] [--rollback] [--ref REF] [--upstream URL]
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$self_dir/release-lib.sh"
rl_paths

acquire_lock() {
  mkdir -p -- "$RL_UPDATE" || rl_fail "update_failed: cannot create $RL_UPDATE"
  chmod 700 "$RL_UPDATE" 2>/dev/null || true
  if ! mkdir "$RL_UPDATE/lock" 2>/dev/null; then
    rl_fail "update_in_progress: $RL_UPDATE/lock exists; another update is running (remove it only if it did not)"
  fi
}
release_lock() { rmdir "$RL_UPDATE/lock" 2>/dev/null || true; }

action=update
ref_override=
upstream_override=
while [ "$#" -gt 0 ]; do
  case "$1" in
    update) action=update; shift ;;
    check) action=check; shift ;;
    rollback) action=rollback; shift ;;
    --check) action=check; shift ;;
    --rollback) action=rollback; shift ;;
    --ref) [ "$#" -ge 2 ] || rl_fail 'ref_value_required'; ref_override=$2; shift 2 ;;
    --upstream) [ "$#" -ge 2 ] || rl_fail 'upstream_value_required'; upstream_override=$2; shift 2 ;;
    -h|--help|help) action=help; shift ;;
    *) rl_fail "unknown_update_option: $1" ;;
  esac
done

if [ "$action" = help ]; then
  printf '%s\n' 'wa update [--check] [--rollback] [--ref REF] [--upstream URL]'
  printf '%s\n' '  --check     report installed and upstream revisions; change nothing'
  printf '%s\n' '  --rollback  re-activate the previously installed release'
  printf '%s\n' '  --ref       upstream branch, tag or commit to move to (default: the remote default branch)'
  exit 0
fi

# ---- rollback ---------------------------------------------------------------
#
# Before anything that needs the network: rolling back must work on a phone with no
# connectivity and no reachable upstream, which is exactly the state a failed update leaves.

if [ "$action" = rollback ]; then
  [ -d "$RL_UPDATE" ] || rl_fail 'rollback_unavailable: no update state recorded on this node'
  rl_recover
  current_commit=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
  previous_commit=$(rl_get "$RL_INSTALL/installed.txt" previous_commit)
  case "$previous_commit" in
    ''|'-') rl_fail 'rollback_unavailable: no previous release is recorded' ;;
  esac
  [ -d "$RL_RELEASES/$previous_commit" ] ||
    rl_fail "rollback_unavailable: $RL_RELEASES/$previous_commit is gone"
  acquire_lock
  trap release_lock EXIT
  rl_verify_release "$RL_RELEASES/$previous_commit" 0 ||
    rl_fail "rollback_refused: $RL_RELEASES/$previous_commit does not verify"
  rl_activate "$previous_commit"
  rl_note "termux-update: rolled back $current_commit -> $previous_commit"
  rl_note 'termux-update: node state was not part of this and is untouched.'
  exit 0
fi

# ---- what is installed, and what is upstream --------------------------------

installed_commit=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
installed_utc=$(rl_get "$RL_INSTALL/installed.txt" installed_utc)
installed_by=$(rl_get "$RL_INSTALL/installed.txt" installed_by)
[ -n "$installed_commit" ] ||
  rl_fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit (run the one-time bootstrap)"

upstream_url=${upstream_override:-${WA_TERMUX_UPSTREAM:-}}
if [ -z "$upstream_url" ]; then
  upstream_url=$(rl_get "$RL_INSTALL/installed.txt" source_remote)
fi
[ -n "$upstream_url" ] ||
  rl_fail "upstream_unknown: $RL_INSTALL/installed.txt records no source_remote; pass --upstream <git-url>, or re-run the one-time bootstrap"

ref=${ref_override:-${WA_TERMUX_UPDATE_REF:-}}
if [ -z "$ref" ] && [ -f "$RL_UPDATE/update.conf" ]; then
  ref=$(rl_get "$RL_UPDATE/update.conf" ref)
fi
[ -n "$ref" ] || ref=HEAD

# A commit id is pinned by definition: there is nothing to resolve, so `--check` can answer
# this offline and an update fetches exactly that object.
upstream_commit=
case "$ref" in
  *[!0-9a-fA-F]*) : ;;
  *) case "${#ref}" in 7|8|12|40|64) upstream_commit=$ref ;; esac ;;
esac

if [ -z "$upstream_commit" ]; then
  if [ "$ref" = HEAD ]; then
    upstream_raw=$(git ls-remote "$upstream_url" HEAD 2>&1) ||
      rl_fail "upstream_unreachable: git ls-remote $upstream_url HEAD failed: $(printf '%s' "$upstream_raw" | tail -n 1)"
  else
    upstream_raw=$(git ls-remote "$upstream_url" "$ref" 2>&1) ||
      rl_fail "upstream_unreachable: git ls-remote $upstream_url $ref failed: $(printf '%s' "$upstream_raw" | tail -n 1)"
  fi
  upstream_commit=$(printf '%s\n' "$upstream_raw" | grep -v '^ref:' | cut -f1 | head -n 1)
  [ -n "$upstream_commit" ] ||
    rl_fail "upstream_revision_unknown: $upstream_url has no ref matching '$ref'"
fi

installed_short=$(printf '%.12s' "$installed_commit")
upstream_short=$(printf '%.12s' "$upstream_commit")

# ---- read-only report -------------------------------------------------------

if [ "$action" = check ]; then
  if ! rl_manifest_verify "$RL_INSTALL"; then
    rl_fail "installed_release_modified: $RL_INSTALL no longer matches its installed.sha256; review it before updating"
  fi
  rl_note "termux-update: installed $installed_short  ($installed_utc${installed_by:+, installed by $installed_by})"
  rl_note "termux-update: upstream  $upstream_short  ($ref from $upstream_url)"
  if [ "$installed_commit" = "$upstream_commit" ]; then
    rl_note 'termux-update: up to date'
    exit 0
  fi
  rl_note "termux-update: 1 update available ($installed_short -> $upstream_short)"
  exit 0
fi

# ---- update -----------------------------------------------------------------

rl_recover
acquire_lock
staging=
cleanup() {
  release_lock
  if [ -n "$staging" ]; then rm -rf -- "$staging"; fi
}
trap cleanup EXIT

if ! rl_manifest_verify "$RL_INSTALL"; then
  rl_fail "installed_release_modified: $RL_INSTALL no longer matches its installed.sha256; review it before updating"
fi

if [ "$installed_commit" = "$upstream_commit" ]; then
  rl_note "termux-update: already up to date at $installed_short"
  exit 0
fi

# The fetch goes into a private staging area under $RL_UPDATE (mode 700), never into the
# operator's checkout and never next to the release it will replace.
staging=$(mktemp -d "$RL_UPDATE/staging.XXXXXX") || rl_fail 'staging_failed: cannot create a staging area'
chmod 700 "$staging"
rl_note "termux-update: fetching $upstream_short from $upstream_url"
git clone --quiet --no-tags "$upstream_url" "$staging/src" ||
  rl_fail "fetch_failed: could not clone $upstream_url"
git -c advice.detachedHead=false -C "$staging/src" checkout --quiet --detach "$upstream_commit" ||
  rl_fail "upstream_revision_unknown: $upstream_url does not contain $upstream_commit"
if ! git -C "$staging/src" cat-file -e "${installed_commit}^{commit}" 2>/dev/null; then
  rl_fail "installed_revision_unknown_to_upstream: $installed_commit is not in $upstream_url, so an upgrade cannot be proven"
fi
if ! git -C "$staging/src" merge-base --is-ancestor "$installed_commit" "$upstream_commit"; then
  rl_fail "downgrade_or_divergent: $upstream_commit is not a descendant of the installed $installed_commit"
fi
[ "$(git -C "$staging/src" rev-parse HEAD)" = "$upstream_commit" ] ||
  rl_fail "upstream_revision_unknown: the checkout of $upstream_commit did not land there"

built=$(rl_build_wa "$staging/src")
[ "$(git -C "$staging/src" rev-parse HEAD)" = "$upstream_commit" ] ||
  rl_fail 'source_changed_during_build'
if [ -n "$(git -C "$staging/src" status --porcelain --untracked-files=normal)" ]; then
  rl_fail 'source_changed_during_build'
fi

stage_release="$RL_RELEASES/.stage.$$"
mkdir -p -- "$RL_RELEASES" || rl_fail "update_failed: cannot create $RL_RELEASES"
rl_assemble "$staging/src" "$built" "$stage_release" "$upstream_commit" "$upstream_url" \
  "$installed_commit" 'wa-update'
rl_verify_release "$stage_release" ||
  rl_fail 'candidate_refused: the build did not verify (see above); nothing was switched'

if [ -d "$RL_RELEASES/$upstream_commit" ]; then
  # A whole release directory already exists for this commit: a build from an interrupted
  # update, or a rollback target that came back around. Trust it only if it verifies, and
  # never rebuild over it silently.
  if rl_verify_release "$RL_RELEASES/$upstream_commit"; then
    rm -rf -- "$stage_release"
    rl_note "termux-update: reusing the verified release already at $RL_RELEASES/$upstream_commit"
  else
    rl_fail "interrupted_release_present: $RL_RELEASES/$upstream_commit exists and does not verify; remove that directory and retry"
  fi
else
  mv -- "$stage_release" "$RL_RELEASES/$upstream_commit" ||
    rl_fail "update_failed: could not place the release in $RL_RELEASES"
fi

rl_activate "$upstream_commit"

rl_note "termux-update: updated $installed_short -> $upstream_short"
rl_note "termux-update: previous release kept at $RL_RELEASES/$installed_commit"
rl_note 'termux-update: roll back with: wa update --rollback'
rl_note "termux-update: restart the UI to run the new runtime ('wa ui')."
rl_note 'termux-update: node state under ~/.wasm-agent was not read, copied or written.'
