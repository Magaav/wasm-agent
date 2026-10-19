#!/data/data/com.termux/files/usr/bin/bash
# The one-time bootstrap for a Termux preview installed before `wa update` existed.
#
# WHY THIS EXISTS. The installer refuses an existing install on purpose - it must not
# overwrite a running or stateful installation silently - and a preview built before this
# revision carries a launcher with no `update` verb and an installed.txt with no
# `source_remote` for an updater to follow. Neither of those can be fixed in place without
# guessing which revision is installed. So this once, the operator runs this script from a
# fresh checkout, and it does four things and nothing else:
#
#   1. it refuses unless the facts it needs are on disk (exact path in every refusal),
#   2. it copies the existing installation aside, byte-for-byte, as the rollback release,
#   3. it builds the checkout revision and switches it in, so the launcher now has
#      `wa update` and the record now names the upstream it came from,
#   4. it prints what changed and how to roll back.
#
# It never runs `wa setup`, never asks for or rotates a provider key, and never clears
# state: node state lives in ~/.wasm-agent, outside the install directory, and if any state
# is found INSIDE the install directory this refuses rather than move it.
#
# Usage: bash scripts/install-termux.sh --adopt-existing
#        bash scripts/termux/adopt-existing.sh [--upstream <git-url>]
# Requires: a wasm-agent checkout at the revision you intend to run, clean.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
. "$root/scripts/termux/release-lib.sh"
rl_paths

fail() { printf 'termux-adopt: %s\n' "$*" >&2; exit 1; }
note() { printf 'termux-adopt: %s\n' "$*"; }

# The Android guards. A fixture suite on a non-Android host must be able to drive the
# refusals below; it has to say so explicitly, and the bypass is named in the output.
if [ "${WA_TERMUX_TEST:-0}" = 1 ]; then
  note 'WA_TERMUX_TEST=1: Android/architecture guards bypassed for the fixture suite'
else
  [ "${PREFIX:-}" = /data/data/com.termux/files/usr ] || fail 'run this inside the Termux app'
  [ "$(uname -o 2>/dev/null || true)" = Android ] || fail 'android_required'
  case "$(uname -m)" in aarch64|arm64) ;; *) fail 'only Android arm64 is supported by this preview' ;; esac
fi

upstream=${WA_TERMUX_UPSTREAM_URL:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --upstream) [ "$#" -ge 2 ] || fail 'upstream_value_required'; upstream=$2; shift 2 ;;
    *) fail "unknown_adopt_option: $1" ;;
  esac
done

[ -f "$root/rust/Cargo.toml" ] || fail "source_checkout_required: $root/rust/Cargo.toml"
[ -f "$root/scripts/termux/wa-update.sh" ] ||
  fail "checkout_predates_update_support: $root/scripts/termux/wa-update.sh (check out a revision that has 'wa update')"
command -v git >/dev/null 2>&1 || fail 'git_required_for_source_checkout'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] ||
  fail 'dirty_source: commit or stash the checkout before adopting it'

# ---- the existing installation, or an exact missing fact --------------------

[ -e "$RL_INSTALL" ] ||
  fail "no_existing_installation: $RL_INSTALL (nothing to adopt; run 'bash scripts/install-termux.sh' for a fresh install)"
if [ -L "$RL_INSTALL" ]; then
  fail "already_adopted: $RL_INSTALL is a managed release link; run 'wa update' instead"
fi
[ -d "$RL_INSTALL" ] || fail "not_a_directory: $RL_INSTALL"
[ -f "$RL_INSTALL/installed.txt" ] ||
  fail "installed_metadata_missing: $RL_INSTALL/installed.txt (cannot tell which revision is installed)"
existing_commit=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
[ -n "$existing_commit" ] ||
  fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit"
[ -x "$RL_INSTALL/wa" ] || fail "runtime_missing: $RL_INSTALL/wa"
[ -f "$RL_INSTALL/bin/wa" ] || fail "launcher_missing: $RL_INSTALL/bin/wa"

if offending=$(rl_state_inside "$RL_INSTALL"); then
  fail "state_inside_install: $offending (node state must live in ~/.wasm-agent, not in the runtime directory; move it before adopting)"
fi

if [ -e "$PREFIX/bin/wa" ] && [ ! -L "$PREFIX/bin/wa" ]; then
  fail "launcher_not_symlink: $PREFIX/bin/wa is not the expected symlink to $RL_INSTALL/bin/wa"
fi

# ---- the upstream the checkout came from ------------------------------------

if [ -z "$upstream" ]; then
  upstream=$(git -C "$root" remote get-url origin 2>/dev/null || true)
fi
[ -n "$upstream" ] ||
  fail "upstream_url_unknown: the checkout has no 'origin' remote; pass --upstream <git-url>"

head_commit=$(git -C "$root" rev-parse HEAD)
note "existing install: $existing_commit in $RL_INSTALL"
note "checkout to adopt: $head_commit from $upstream"

mkdir -p -- "$RL_RELEASES" "$RL_UPDATE" || fail "cannot create $RL_RELEASES"
chmod 700 "$RL_UPDATE" 2>/dev/null || true

# ---- 1. the backup: the existing install, copied aside and proved equal -----

backup="$RL_RELEASES/$existing_commit"
if [ -d "$backup" ]; then
  before=$(mktemp)
  after=$(mktemp)
  rl_manifest "$RL_INSTALL" "$before"
  rl_manifest "$backup" "$after"
  if cmp -s "$before" "$after"; then
    note "backup already present and identical: $backup"
  else
    rm -f "$before" "$after"
    fail "backup_conflict: $backup exists and is not identical to $RL_INSTALL; move it aside"
  fi
  rm -f "$before" "$after"
  rl_manifest "$RL_INSTALL" "$backup/installed.sha256"
else
  before=$(mktemp)
  rl_manifest "$RL_INSTALL" "$before"
  note "backing up the existing install to $backup"
  cp -a "$RL_INSTALL" "$backup" || fail "backup_failed: could not copy $RL_INSTALL to $backup"
  after=$(mktemp)
  rl_manifest "$backup" "$after"
  if ! cmp -s "$before" "$after"; then
    rm -f "$before" "$after"
    fail "backup_mismatch: the copy in $backup does not match $RL_INSTALL file by file"
  fi
  rm -f "$before" "$after"
  # Record the manifest inside the backup, so a rollback to it can be verified later.
  rl_manifest "$backup" "$backup/installed.sha256"
  note 'backup verified: every file and byte of the existing install is preserved'
fi

# ---- 2. build the checkout revision as a new release ------------------------

built=$(rl_build_wa "$root")
built_profile=$(rl_build_profile_of_bin "$built")
[ "$(git -C "$root" rev-parse HEAD)" = "$head_commit" ] || fail 'source_changed_during_build'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'source_changed_during_build'

stage_release="$RL_RELEASES/.adopt.$$"
rl_assemble "$root" "$built" "$stage_release" "$head_commit" "$upstream" "$existing_commit" \
  'adopt-existing' "$built_profile"
rl_verify_release "$stage_release" || fail 'candidate_refused: the build did not verify (see above); nothing was switched'

if [ -d "$RL_RELEASES/$head_commit" ]; then
  if rl_verify_release "$RL_RELEASES/$head_commit"; then
    rm -rf -- "$stage_release"
    note "reusing the verified release already at $RL_RELEASES/$head_commit"
  else
    fail "interrupted_release_present: $RL_RELEASES/$head_commit exists and does not verify; remove that directory and retry"
  fi
else
  mv -- "$stage_release" "$RL_RELEASES/$head_commit" || fail "cannot place the release in $RL_RELEASES"
fi

# ---- 3. switch it in, keeping the old install as the rollback ---------------

rl_activate "$head_commit"

if [ "$built_profile" = dev ]; then
  note 'the runtime was built with the debug/unoptimized profile: the optimized build did not finish on this device; it works, and it is slower'
fi
note "adopted: $existing_commit -> $head_commit"
note "rollback release kept at $RL_RELEASES/$existing_commit"
note "next: 'wa update --check' then 'wa update' for every update after this one."
note 'node state under ~/.wasm-agent was not read, copied or written.'
