#!/data/data/com.termux/files/usr/bin/sh
# `wa update` on an Android/Termux node: move the installed preview to a PUBLISHED RELEASE,
# without touching the node's own state.
#
# THE CHANNEL IS A RELEASE, NOT A COMPILE. The operator's decision is that releases are the
# channel and a local build is only for testing. The reason is measured, not preferred: this
# device cannot compile this workspace. On the operator's Mi 9 SE every rung of the on-device
# build ladder died inside rustc with `(signal: 11, SIGSEGV)` while compiling
# `cranelift_codegen` (see release-lib.sh and scripts/termux/cross-build-android.sh). So the
# FIRST rung here is `fetch-prebuilt`: resolve `releases/index.json` on main over HTTPS, pick
# the entry for the requested commit (default: the newest release), download that asset,
# check it against the entry, and hand it to the same installer a hand-copied bundle uses.
#
# THE BUILD LADDER IS A FALLBACK AND SAYS SO. It runs only when the index parsed and has no
# entry for the requested commit, and it announces, in the update itself, that the device
# cannot compile this workspace and that a compiler crash is the expected outcome. It is not
# a silent second attempt and it is never reached after a hash mismatch: a mismatch is a
# named refusal, and a mismatch means the publisher and this phone disagree about the bytes.
#
# This is the Termux analogue of `/update`, and deliberately NOT the same route. `/update`
# writes a request for the sentinel, because a node cannot replace itself and a desktop
# install is replaced by a separate process. On the phone there is no sentinel, no service
# and no second process: `wa ui` runs in the foreground and the operator is holding it. So
# the switch is done here, in the open, by a model-free shell command the operator ran.
#
# What it guarantees, and what it refuses:
#   * it reports the installed revision, the requested revision and which channel it would
#     use (`--check` is read-only and exits 0 when it is simply up to date)
#   * it refuses rather than guesses, and every refusal is named: http_client_missing (no
#     curl and no wget), index_unreachable, index_invalid, release_missing_for_commit,
#     hash_mismatch, download_truncated, download_failed, archive_unsafe, and the installed-
#     side refusals below. Nothing is installed on any of them.
#   * it NEVER falls back to building after a hash mismatch, and the only fallback it has is
#     the loud one described above
#   * it fetches the pinned upstream commit into a PRIVATE staging area; the operator's
#     checkout, if any, is never used as a build tree and never modified
#   * it verifies the candidate, switches it in, keeps the previous release for rollback,
#     and says how to roll back
#   * it never runs `wa setup`, never re-asks for a provider key, never rotates identity,
#     and never writes anything under the node's home: `~/.wasm-agent` is not part of a
#     release and must not be. State survives because nothing here knows where it is.
#
# Usage: wa update [--check] [--rollback] [--commit SHA] [--ref REF] [--upstream URL]
#                  [--index URL]
set -eu

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$self_dir/release-lib.sh"
rl_paths

# Only a run that CREATED the lock may remove it: a second run that refused because the lock
# was there must not take the first run's lock away on its way out.
RL_LOCK_HELD=0
acquire_lock() {
  mkdir -p -- "$RL_UPDATE" || rl_fail "update_failed: cannot create $RL_UPDATE"
  chmod 700 "$RL_UPDATE" 2>/dev/null || true
  if ! mkdir "$RL_UPDATE/lock" 2>/dev/null; then
    rl_fail "update_in_progress: $RL_UPDATE/lock exists; another update is running (remove it only if it did not)"
  fi
  RL_LOCK_HELD=1
}
release_lock() {
  [ "${RL_LOCK_HELD:-0}" = 1 ] || return 0
  rmdir "$RL_UPDATE/lock" 2>/dev/null || true
  RL_LOCK_HELD=0
}

action=update
ref_override=
upstream_override=
commit_override=
index_override=
while [ "$#" -gt 0 ]; do
  case "$1" in
    update) action=update; shift ;;
    check) action=check; shift ;;
    rollback) action=rollback; shift ;;
    --check) action=check; shift ;;
    --rollback) action=rollback; shift ;;
    --commit) [ "$#" -ge 2 ] || rl_fail 'commit_value_required'; commit_override=$2; shift 2 ;;
    --ref) [ "$#" -ge 2 ] || rl_fail 'ref_value_required'; ref_override=$2; shift 2 ;;
    --upstream) [ "$#" -ge 2 ] || rl_fail 'upstream_value_required'; upstream_override=$2; shift 2 ;;
    --index) [ "$#" -ge 2 ] || rl_fail 'index_value_required'; index_override=$2; shift 2 ;;
    -h|--help|help) action=help; shift ;;
    *) rl_fail "unknown_update_option: $1" ;;
  esac
done

if [ "$action" = help ]; then
  printf '%s\n' 'wa update [--check] [--rollback] [--commit SHA] [--ref REF] [--upstream URL] [--index URL]'
  printf '%s\n' '  --check     report the installed revision, the requested one and the channel; change nothing'
  printf '%s\n' '  --rollback  re-activate the previously installed release'
  printf '%s\n' '  --commit    install the published release for this commit (default: the newest in the index)'
  printf '%s\n' '  --ref       upstream branch, tag or commit (default: the newest published release)'
  printf '%s\n' '  --upstream  git URL of the source (only needed to resolve a branch/tag, or to build)'
  printf '%s\n' '  --index     release index URL (default: the published index on main)'
  exit 0
fi

# One cleanup for every path: the lock, the update staging area, and the temporary index.
work=
staging=
cleanup() {
  release_lock
  if [ -n "$staging" ]; then rm -rf -- "$staging"; fi
  if [ -n "$work" ]; then rm -rf -- "$work"; fi
}

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
  trap cleanup EXIT
  rl_verify_release "$RL_RELEASES/$previous_commit" 0 ||
    rl_fail "rollback_refused: $RL_RELEASES/$previous_commit does not verify"
  rl_activate "$previous_commit"
  rl_note "termux-update: rolled back $current_commit -> $previous_commit"
  rl_note 'termux-update: node state was not part of this and is untouched.'
  exit 0
fi

# ---- what is installed ------------------------------------------------------
#
# A switch interrupted between its two renames leaves the active path absent. `update`
# repairs that here - the launcher runs this file from a private copy, so the updater itself
# is not part of what the rename moves. `--check` repairs nothing: it changes nothing.
if [ "$action" = update ] && [ ! -e "$RL_INSTALL" ] && [ -f "$RL_UPDATE/switch.intent" ]; then
  rl_recover
fi
if [ ! -e "$RL_INSTALL" ]; then
  rl_fail "installed_missing: $RL_INSTALL is missing (if a switch was interrupted, repair it from the checkout: bash scripts/install-termux.sh --recover)"
fi

installed_commit=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
installed_utc=$(rl_get "$RL_INSTALL/installed.txt" installed_utc)
installed_by=$(rl_get "$RL_INSTALL/installed.txt" installed_by)
[ -n "$installed_commit" ] ||
  rl_fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit (run the one-time bootstrap)"

# The installed release is checked BEFORE anything goes to the network: a modified install is
# a refusal whether or not this node has connectivity, and no download should happen for a
# node whose own release no longer matches its manifest.
if ! rl_manifest_verify "$RL_INSTALL"; then
  rl_fail "installed_release_modified: $RL_INSTALL no longer matches its installed.sha256; review it before updating"
fi

# The source remote is only needed to resolve a ref through git, or to build. The release
# channel does not need git at all, so this is no longer a precondition for updating.
upstream_url=${upstream_override:-${WA_TERMUX_UPSTREAM:-}}
if [ -z "$upstream_url" ]; then
  upstream_url=$(rl_get "$RL_INSTALL/installed.txt" source_remote)
fi

ref=${ref_override:-${WA_TERMUX_UPDATE_REF:-}}
if [ -z "$ref" ] && [ -f "$RL_UPDATE/update.conf" ]; then
  ref=$(rl_get "$RL_UPDATE/update.conf" ref)
fi

if [ -n "$commit_override" ]; then
  case "$commit_override" in
    *[!0-9a-fA-F]*)
      rl_fail "commit_invalid: '$commit_override' is not a hexadecimal commit id" ;;
  esac
  if [ "${#commit_override}" -ne 40 ]; then
    rl_fail "commit_invalid: '$commit_override' is ${#commit_override} characters; a commit id is 40"
  fi
fi

# A commit id in --ref is pinned by definition: there is nothing to resolve.
ref_commit=
case "$ref" in
  *[!0-9a-fA-F]*) : ;;
  *) case "${#ref}" in 7|8|12|40|64) ref_commit=$ref ;; esac ;;
esac

# ---- the release index: which channel this node uses ------------------------

if [ -n "$index_override" ]; then
  WA_TERMUX_RELEASE_INDEX_URL=$index_override
  export WA_TERMUX_RELEASE_INDEX_URL
fi
index_url=$(rl_release_index_url)

work=$(mktemp -d) || rl_fail 'staging_failed: cannot create a temporary directory'
trap cleanup EXIT
chmod 700 "$work" 2>/dev/null || true
index_file=$work/index.json
index_flat=$work/index.flat

if ! rl_release_index_fetch "$index_file"; then
  case $RL_FETCH_CLASS in
    http_client_missing)
      rl_fail "http_client_missing: this node has neither curl nor wget, so the release index $index_url cannot be read (install one: pkg install curl). Nothing was installed, and there is no fallback: releases are the channel."
      ;;
    local_url_refused)
      rl_fail "index_unreachable: $RL_FETCH_DETAIL. Nothing was installed."
      ;;
    *)
      rl_fail "index_unreachable: $index_url could not be fetched ($RL_FETCH_DETAIL). Nothing was installed, and this is not a reason to compile on the device."
      ;;
  esac
fi
rl_release_index_parse "$index_file" "$index_flat" ||
  rl_fail "$RL_INDEX_ERROR: $index_url: $RL_INDEX_DETAIL. Nothing was installed."

# ---- which revision is being asked for, and is it published? ----------------

target_commit=
target_from=
if [ -n "$commit_override" ]; then
  target_commit=$(printf '%s' "$commit_override" | tr 'A-F' 'a-f')
  target_from="--commit"
elif [ -n "$ref_commit" ]; then
  target_commit=$(printf '%s' "$ref_commit" | tr 'A-F' 'a-f')
  target_from="--ref $ref"
elif [ -n "$ref" ]; then
  [ -n "$upstream_url" ] ||
    rl_fail "upstream_unknown: $RL_INSTALL/installed.txt records no source_remote; pass --upstream <git-url>, or use --commit <sha> to name a published release"
  upstream_raw=$(git ls-remote "$upstream_url" "$ref" 2>&1) ||
    rl_fail "upstream_unreachable: git ls-remote $upstream_url $ref failed: $(printf '%s' "$upstream_raw" | tail -n 1)"
  target_commit=$(printf '%s\n' "$upstream_raw" | grep -v '^ref:' | cut -f1 | head -n 1)
  [ -n "$target_commit" ] ||
    rl_fail "upstream_revision_unknown: $upstream_url has no ref matching '$ref'"
  target_from="$ref from $upstream_url"
elif [ "${RL_INDEX_COUNT:-0}" -gt 0 ]; then
  # The channel's own answer: the newest published release. No git, no upstream, no build.
  target_commit=$(rl_release_latest_commit "$index_flat") ||
    rl_fail "release_missing_for_commit: the index $index_url parsed but names no release"
  target_from='the newest published release'
else
  # A bootstrap index: no release has been published yet, so the only revision anyone can
  # name is the upstream's. This still ends in the loud fallback below.
  [ -n "$upstream_url" ] ||
    rl_fail "upstream_unknown: $RL_INSTALL/installed.txt records no source_remote and $index_url publishes no release; pass --upstream <git-url> or --commit <sha>"
  upstream_raw=$(git ls-remote "$upstream_url" HEAD 2>&1) ||
    rl_fail "upstream_unreachable: git ls-remote $upstream_url HEAD failed: $(printf '%s' "$upstream_raw" | tail -n 1)"
  target_commit=$(printf '%s\n' "$upstream_raw" | grep -v '^ref:' | cut -f1 | head -n 1)
  [ -n "$target_commit" ] ||
    rl_fail "upstream_revision_unknown: $upstream_url has no HEAD"
  target_from="$upstream_url (the index publishes no release yet)"
fi

installed_short=$(printf '%.12s' "$installed_commit")
target_short=$(printf '%.12s' "$target_commit")

entry=$(rl_release_entry_for "$index_flat" "$target_commit" || true)
channel=source-build
release_size=
release_url=
release_manifest=
release_target=
release_ndk=
release_rustc=
release_built=
if [ -n "$entry" ]; then
  channel=fetch-prebuilt
  IFS=$RL_TAB read -r _c _cs release_manifest release_url release_size release_target \
    release_ndk release_rustc release_built <<EOF
$entry
EOF
fi

# ---- read-only report -------------------------------------------------------

if [ "$action" = check ]; then
  rl_note "termux-update: installed  $installed_short  ($installed_utc${installed_by:+, installed by $installed_by})"
  rl_note "termux-update: target     $target_short  (from $target_from)"
  if [ "${RL_INDEX_COUNT:-0}" -gt 0 ]; then
    _newest_short=$(rl_release_latest_commit "$index_flat" | cut -c1-12)
    _newest_line=$(rl_release_entry_for "$index_flat" "$(rl_release_latest_commit "$index_flat")")
    IFS=$RL_TAB read -r _a _b _c2 _d _e _f _ndk0 _rustc0 _built0 <<EOF
$_newest_line
EOF
    rl_note "termux-update: index      $index_url"
    rl_note "termux-update:            $RL_INDEX_COUNT release(s); newest $_newest_short (built ${_built0:-unknown}, ${_f:-unknown}, NDK ${_ndk0:-unknown}, rustc ${_rustc0:-unknown})"
  else
    rl_note "termux-update: index      $index_url"
    rl_note 'termux-update:            0 releases: this is the bootstrap index, nothing is published yet'
  fi
  if [ "$channel" = fetch-prebuilt ]; then
    rl_note "termux-update: channel it would use: fetch-prebuilt ($target_short is published; sha256(bundle.manifest)=$release_manifest, $release_size bytes, $release_url)"
  else
    rl_note "termux-update: channel it would use: source-build on this device (NO release is published for $target_short; this is the fallback rung)"
    rl_warn "WARNING: this device cannot compile this workspace. On the operator's phone every rung of the build ladder died in rustc with (signal: 11, SIGSEGV) while compiling cranelift_codegen; the expected outcome of that fallback is compiler_crash_build_refused and no release installed."
    rl_warn 'the released way to move this node is a published release: see docs/release/RELEASE_INDEX.md'
  fi
  if [ "$installed_commit" = "$target_commit" ]; then
    rl_note 'termux-update: up to date'
    exit 0
  fi
  rl_note "termux-update: 1 update available ($installed_short -> $target_short)"
  exit 0
fi

# ---- update -----------------------------------------------------------------

if [ "$installed_commit" = "$target_commit" ] && [ "$channel" = source-build ]; then
  rl_note "termux-update: already up to date at $installed_short"
  exit 0
fi

acquire_lock

if [ "$channel" = fetch-prebuilt ]; then
  # ---- rung 1: the published release ----------------------------------------
  if [ "$installed_commit" = "$target_commit" ] &&
     [ "$(rl_get "$RL_INSTALL/installed.txt" bundle_manifest_sha256)" = "$release_manifest" ]; then
    rl_note "termux-update: already up to date at $installed_short (this published bundle is installed)"
    exit 0
  fi
  if [ "$installed_commit" = "$target_commit" ]; then
    rl_note "termux-update: $target_short is already the installed revision, but not from this published bundle; installing the bundle"
  fi
  staging=$(mktemp -d "$RL_UPDATE/staging.XXXXXX") || rl_fail 'staging_failed: cannot create a staging area'
  chmod 700 "$staging"
  rl_note "termux-update: channel    fetch-prebuilt"
  rl_note "termux-update: fetching the published release $target_short"
  rl_note "termux-update:            $release_url ($release_size bytes)"
  rl_note "termux-update:            index entry pins sha256(bundle.manifest)=$release_manifest"
  # Every refusal inside this call is named and fatal: a bad download, a truncated asset, an
  # unsafe archive, or a bundle whose manifest does not hash to the pinned value. None of
  # them falls through to the build ladder.
  rl_release_fetch "$index_flat" "$target_commit" "$staging" ||
    rl_fail "download_failed: the release for $target_short could not be fetched; nothing was installed"
  release_bundle=$RL_RELEASE_BUNDLE
  release_manifest=$RL_RELEASE_MANIFEST_SHA
  rl_note "termux-update: verified   sha256(bundle.manifest) matches the index entry"
  RL_BUNDLE_TAG=termux-update
  rl_bundle_install "$release_bundle" "$release_manifest" "$staging/bundle-stage"
  if [ "$RL_BUNDLE_RESULT" = already-installed ]; then
    rl_note "termux-update: nothing changed: this bundle is already installed"
    exit 0
  fi
  rl_note "termux-update: updated $installed_short -> $target_short"
  rl_note "termux-update: previous release kept at $RL_RELEASES/$installed_commit"
  rl_note 'termux-update: roll back with: wa update --rollback'
  rl_note "termux-update: restart the UI to run the new runtime ('wa ui')."
  rl_note 'termux-update: node state under ~/.wasm-agent was not read, copied or written.'
  exit 0
fi

# ---- rung 2: build on this device (fallback only) ---------------------------
#
# Reached for exactly one reason: the index parsed, and it publishes no release for the
# requested commit. That is said loudly and before the build starts, because the expected
# outcome on this hardware is a compiler crash, not a release.

rl_warn "WARNING: no published release for $target_short"
rl_warn "  index:  $index_url ($RL_INDEX_COUNT entry/entries, none for $target_short)"
rl_warn '  fallback: build on this device. THIS DEVICE CANNOT COMPILE THIS WORKSPACE:'
rl_warn '  on the operator phone every rung of the build ladder died in rustc with'
rl_warn '  (signal: 11, SIGSEGV) while compiling cranelift_codegen. A compiler crash is'
rl_warn '  the expected result of this rung, and then nothing is installed.'
rl_warn '  the released channel is a published release; to publish one see'
rl_warn '  docs/release/RELEASE_INDEX.md (publisher: scripts/termux/cross-build-android.sh)'
[ -n "$upstream_url" ] ||
  rl_fail "upstream_unknown: $RL_INSTALL/installed.txt records no source_remote and no release is published for $target_short; pass --upstream <git-url>"

# The fetch goes into a private staging area under $RL_UPDATE (mode 700), never into the
# operator's checkout and never next to the release it will replace.
staging=$(mktemp -d "$RL_UPDATE/staging.XXXXXX") || rl_fail 'staging_failed: cannot create a staging area'
chmod 700 "$staging"
rl_note "termux-update: fetching $target_short from $upstream_url"
git clone --quiet --no-tags "$upstream_url" "$staging/src" ||
  rl_fail "fetch_failed: could not clone $upstream_url"
git -c advice.detachedHead=false -C "$staging/src" checkout --quiet --detach "$target_commit" ||
  rl_fail "upstream_revision_unknown: $upstream_url does not contain $target_commit"
if ! git -C "$staging/src" cat-file -e "${installed_commit}^{commit}" 2>/dev/null; then
  rl_fail "installed_revision_unknown_to_upstream: $installed_commit is not in $upstream_url, so an upgrade cannot be proven"
fi
if ! git -C "$staging/src" merge-base --is-ancestor "$installed_commit" "$target_commit"; then
  rl_fail "downgrade_or_divergent: $target_commit is not a descendant of the installed $installed_commit"
fi
[ "$(git -C "$staging/src" rev-parse HEAD)" = "$target_commit" ] ||
  rl_fail "upstream_revision_unknown: the checkout of $target_commit did not land there"

built=$(rl_build_wa "$staging/src")
built_profile=$(rl_build_profile_of_bin "$built")
[ "$(git -C "$staging/src" rev-parse HEAD)" = "$target_commit" ] ||
  rl_fail 'source_changed_during_build'
if [ -n "$(git -C "$staging/src" status --porcelain --untracked-files=normal)" ]; then
  rl_fail 'source_changed_during_build'
fi

stage_release="$RL_RELEASES/.stage.$$"
mkdir -p -- "$RL_RELEASES" || rl_fail "update_failed: cannot create $RL_RELEASES"
rl_assemble "$staging/src" "$built" "$stage_release" "$target_commit" "$upstream_url" \
  "$installed_commit" 'wa-update' "$built_profile"
rl_verify_release "$stage_release" ||
  rl_fail 'candidate_refused: the build did not verify (see above); nothing was switched'

if [ -d "$RL_RELEASES/$target_commit" ]; then
  # A whole release directory already exists for this commit: a build from an interrupted
  # update, or a rollback target that came back around. Trust it only if it verifies, and
  # never rebuild over it silently.
  if rl_verify_release "$RL_RELEASES/$target_commit"; then
    rm -rf -- "$stage_release"
    rl_note "termux-update: reusing the verified release already at $RL_RELEASES/$target_commit"
  else
    rl_fail "interrupted_release_present: $RL_RELEASES/$target_commit exists and does not verify; remove that directory and retry"
  fi
else
  mv -- "$stage_release" "$RL_RELEASES/$target_commit" ||
    rl_fail "update_failed: could not place the release in $RL_RELEASES"
fi

rl_activate "$target_commit"

# The release built here was NOT a published one, and the next `wa update` will still have
# no release for this commit unless one is published for it.
rl_warn "this revision was BUILT ON THIS DEVICE, not fetched from the release index; no release is published for $target_short"
if [ "$built_profile" = dev ]; then
  rl_note 'termux-update: this revision was built with the debug/unoptimized profile: the optimized build did not finish on this device, so the runtime is slower. "wa doctor" reports it.'
fi
rl_note "termux-update: updated $installed_short -> $target_short"
rl_note "termux-update: previous release kept at $RL_RELEASES/$installed_commit"
rl_note 'termux-update: roll back with: wa update --rollback'
rl_note "termux-update: restart the UI to run the new runtime ('wa ui')."
rl_note 'termux-update: node state under ~/.wasm-agent was not read, copied or written.'
