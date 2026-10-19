#!/data/data/com.termux/files/usr/bin/bash
# Install a PREBUILT Android arm64 bundle on this phone: no compiler, no network.
#
# WHY. The device stopped being able to compile this workspace: measured on the operator's
# Mi 9 SE, every rung of the on-device build ladder died inside rustc with
# `(signal: 11, SIGSEGV)` while compiling `cranelift_codegen` (the Wasmtime engine), with
# ~2.7 GB available on 8 cores and swap in use. The same dependency at the same version had
# built and installed on that phone before, so this is the device's toolchain and memory
# state, not the source. The runtime is now built on a desktop with the Android NDK
# (`scripts/termux/cross-build-android.sh`) and installed here from bytes.
#
# WHAT THIS GUARANTEES, and how it earns the same trust as `--adopt-existing`:
#   * the operator's hash must describe `bundle.manifest` exactly, so one pasted hash pins
#     the whole bundle;
#   * `bundle.manifest` must describe `installed.sha256`, and `installed.sha256` must
#     describe every file in the bundle and nothing else - a modified, added, missing or
#     truncated member is refused by name;
#   * every `artefact <sha256> <path>` line is checked against the bytes;
#   * the runtime's ELF machine is read from its header, not its filename, and the bundle
#     must be for `aarch64-linux-android` - the only triple this phone can run;
#   * the current installation is copied aside byte-for-byte, verified file by file by
#     manifest, and kept under its own commit as the rollback release;
#   * the switch is the same two-rename, intent-recorded switch every other path uses, so
#     `bash scripts/install-termux.sh --recover` still repairs an interrupted one;
#   * `installed.txt` records `build_profile=cross-android` and
#     `source_provenance=cross-built-android`, so `wa doctor` says where the runtime came
#     from, and `wa update --rollback` keeps working;
#   * `~/.wasm-agent` is never read, copied or written, and `wa setup` is never run.
#
# WHAT IT CANNOT PROVE. The bundle was built on a desktop. Its hashes and its ELF machine
# are checked here; that it actually RUNS on Android is proven by the candidate probe below
# (the new runtime is executed once, against a scratch home, before it is switched in) - and
# by nothing else.
#
# Usage: bash scripts/install-termux.sh --bundle <dir> --manifest-sha256 <sha256>
#        bash scripts/termux/install-bundle.sh --bundle <dir> --manifest-sha256 <sha256>
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
. "$root/scripts/termux/release-lib.sh"
rl_paths

fail() { printf 'termux-bundle: %s\n' "$*" >&2; exit 1; }
note() { printf 'termux-bundle: %s\n' "$*"; }

# The Android guards every Termux entry point uses. A fixture suite on a non-Android host
# must be able to drive the refusals below; it has to say so explicitly, and the bypass is
# named in the output.
if [ "${WA_TERMUX_TEST:-0}" = 1 ]; then
  note 'WA_TERMUX_TEST=1: Android/architecture guards bypassed for the fixture suite'
else
  [ "${PREFIX:-}" = /data/data/com.termux/files/usr ] || fail 'run this inside the Termux app'
  [ "$(uname -o 2>/dev/null || true)" = Android ] || fail 'android_required'
  case "$(uname -m)" in aarch64|arm64) ;; *) fail 'only Android arm64 is supported by this preview' ;; esac
fi

bundle=
manifest_sha=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle) [ "$#" -ge 2 ] || fail 'bundle_dir_required'; bundle=$2; shift 2 ;;
    --manifest-sha256) [ "$#" -ge 2 ] || fail 'manifest_sha256_required'; manifest_sha=$2; shift 2 ;;
    -h|--help|help)
      printf '%s\n' 'usage: install-termux.sh --bundle DIR --manifest-sha256 SHA'
      printf '%s\n' '  --bundle DIR            a prebuilt Android arm64 bundle (contains bundle.manifest)'
      printf '%s\n' '  --manifest-sha256 SHA   sha256 of DIR/bundle.manifest, from the cross-build'
      exit 0
      ;;
    *) fail "unknown_bundle_option: $1 (the options are --bundle DIR and --manifest-sha256 SHA)" ;;
  esac
done
[ -n "$bundle" ] || fail 'bundle_dir_required: pass --bundle <dir> (the prebuilt bundle directory)'
[ -n "$manifest_sha" ] ||
  fail 'manifest_sha256_required: pass --manifest-sha256 <sha256 of the bundle'"'"'s bundle.manifest>'

# ---- the pasted hash, before anything else is read --------------------------

case "$manifest_sha" in
  *[!0-9a-fA-F]*)
    fail "manifest_sha256_invalid: '$manifest_sha' is not a hexadecimal sha256 (64 hex characters)"
    ;;
esac
if [ "${#manifest_sha}" -ne 64 ]; then
  fail "manifest_sha256_invalid: '$manifest_sha' is ${#manifest_sha} characters; a sha256 is 64"
fi
manifest_sha=$(printf '%s' "$manifest_sha" | tr 'A-F' 'a-f')

[ -d "$bundle" ] || fail "bundle_missing: $bundle is not a directory (copy the bundle out of shared storage first)"
[ -f "$bundle/bundle.manifest" ] ||
  fail "bundle_incomplete: $bundle/bundle.manifest is missing; this is not a prebuilt bundle"
actual_sha=$(rl_sha256 "$bundle/bundle.manifest")
if [ "$actual_sha" != "$manifest_sha" ]; then
  fail "bundle_manifest_sha256_mismatch: you passed $manifest_sha but $bundle/bundle.manifest is $actual_sha (a partial copy, a modified bundle, or the wrong hash; nothing was changed)"
fi

# From here the manifest, every member, the per-artefact hashes and the ELF machine are
# checked. `bundle.manifest` is the envelope, not a member, so the release manifest written
# at build time excludes it - the same exclusion this verification uses.
RL_MANIFEST_EXCLUDE=bundle.manifest
rl_bundle_verify "$bundle" ||
  fail "bundle_refused: $bundle did not verify (see above); nothing was switched, installed or changed"

bundle_commit=$(rl_get "$bundle/bundle.manifest" source_commit)
bundle_tree=$(rl_get "$bundle/bundle.manifest" source_tree_sha256)
bundle_ndk=$(rl_get "$bundle/bundle.manifest" ndk_version)
bundle_rustc=$(rl_get "$bundle/bundle.manifest" rustc_version)
bundle_target=$(rl_get "$bundle/bundle.manifest" target_triple)
[ -n "$bundle_commit" ] ||
  fail "bundle_manifest_incomplete: $bundle/bundle.manifest records no source_commit; cannot record what is installed"
bundle_remote=$(rl_get "$bundle/installed.txt" source_remote)
[ -n "$bundle_remote" ] || bundle_remote='-'
recorded_commit=$(rl_get "$bundle/installed.txt" source_commit)
if [ "$recorded_commit" != "$bundle_commit" ]; then
  fail "bundle_manifest_mismatch: installed.txt records source_commit='$recorded_commit' but bundle.manifest records '$bundle_commit'"
fi
if offending=$(rl_state_inside "$bundle"); then
  fail "state_in_bundle: $offending is inside the bundle; that is node state, not runtime bytes - do not install this bundle"
fi

# ---- what is installed right now, and the rollback release ------------------

existing_commit=
if [ -e "$RL_INSTALL" ] || [ -L "$RL_INSTALL" ]; then
  if [ -L "$RL_INSTALL" ]; then
    fail "install_is_a_link: $RL_INSTALL is a symbolic link; this installer replaces a directory (use 'wa update')"
  fi
  [ -d "$RL_INSTALL" ] || fail "not_a_directory: $RL_INSTALL"
  [ -f "$RL_INSTALL/installed.txt" ] ||
    fail "installed_metadata_missing: $RL_INSTALL/installed.txt (cannot tell which revision is installed, so it cannot be the rollback release)"
  existing_commit=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
  [ -n "$existing_commit" ] ||
    fail "installed_revision_unknown: $RL_INSTALL/installed.txt has no source_commit"
  if offending=$(rl_state_inside "$RL_INSTALL"); then
    fail "state_inside_install: $offending (node state must live in ~/.wasm-agent, not in the runtime directory; move it before installing)"
  fi
  rl_manifest_verify "$RL_INSTALL" ||
    fail "installed_release_modified: $RL_INSTALL no longer matches its installed.sha256; refusing to take it as the rollback release"
  if [ -e "$RL_PREFIX/bin/wa" ] && [ ! -L "$RL_PREFIX/bin/wa" ]; then
    # On the phone this is fatal: a plain file at $PREFIX/bin/wa would keep running an
    # older launcher after the switch. The published fixture suite says it is standing in
    # for the phone and announces the skip; a Windows host cannot represent a symlink at
    # all, so pretending otherwise would only make the suite lie.
    if [ "${WA_TERMUX_TEST:-0}" = 1 ]; then
      note "WA_TERMUX_TEST=1: $RL_PREFIX/bin/wa is not a symlink on this host (no symlinks here); the launcher guard is skipped for the fixture suite"
    else
      fail "launcher_not_symlink: $RL_PREFIX/bin/wa is not the expected symlink to $RL_INSTALL/bin/wa"
    fi
  fi
  # Already exactly this bundle? Then there is nothing to do, and nothing to move. This is
  # the common repeat case - the operator ran the install twice, or the same bundle was
  # rebuilt byte-identically - and the check matters: without it the second run would try to
  # take the ACTIVE release as the rollback copy under a name this bundle itself already
  # put there (the case where the same revision was installed from source first), and refuse
  # over a conflict that is not one. The active release has just been verified against its
  # own manifest above, and the bundle hash it records is what it was switched in from.
  if [ "$(rl_get "$RL_INSTALL/installed.txt" bundle_manifest_sha256)" = "$manifest_sha" ]; then
    note "this bundle is already installed ($bundle_commit); nothing to do"
    if [ "$(rl_get "$RL_INSTALL/installed.txt" previous_commit)" != '-' ]; then
      note 'roll back with: wa update --rollback'
    fi
    exit 0
  fi
else
  if [ -e "$RL_PREFIX/bin/wa" ] || [ -L "$RL_PREFIX/bin/wa" ]; then
    fail "launcher_exists: $RL_PREFIX/bin/wa exists but no installation is at $RL_INSTALL"
  fi
fi

mkdir -p -- "$RL_RELEASES" "$RL_UPDATE" || fail "cannot create $RL_RELEASES"
chmod 700 "$RL_UPDATE" 2>/dev/null || true

if [ -n "$existing_commit" ]; then
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
    note "backing up the current installation to $backup"
    cp -a "$RL_INSTALL" "$backup" || fail "backup_failed: could not copy $RL_INSTALL to $backup"
    after=$(mktemp)
    rl_manifest "$backup" "$after"
    if ! cmp -s "$before" "$after"; then
      rm -f "$before" "$after"
      fail "backup_mismatch: the copy in $backup does not match $RL_INSTALL file by file"
    fi
    rm -f "$before" "$after"
    rl_manifest "$backup" "$backup/installed.sha256"
    note 'backup verified: every file and byte of the current installation is preserved'
  fi
fi

# ---- name the release, keeping anything already at that name ----------------

# The release directory is named by the commit the bundle was built from. A different
# directory can legitimately hold that name - the rollback copy taken above is exactly that
# when the same revision is installed from source first and then from a cross-built bundle -
# so on any clash this release is named by its bundle hash instead of overwriting what is
# there. The name is decided BEFORE the release is written, because the release records it:
# `release_key` is what makes two releases of the same commit - one built on the phone, one
# cross-built here - distinguishable to the switch and to `wa update --rollback`.
release_key=$bundle_commit
reuse=0
if [ -e "$RL_RELEASES/$release_key" ]; then
  if [ "$(rl_get "$RL_RELEASES/$release_key/installed.txt" bundle_manifest_sha256)" = "$manifest_sha" ] &&
     rl_manifest_verify "$RL_RELEASES/$release_key"; then
    reuse=1
  else
    release_key="$bundle_commit+bundle.$(printf '%.12s' "$manifest_sha")"
  fi
fi

# ---- stage the bundle as a release directory --------------------------------

stage="$RL_BASE/.wasm-agent-bundle.$$"
cleanup() { [ ! -d "$stage" ] || rm -rf -- "$stage"; }
trap cleanup EXIT
mkdir -p -- "$stage/bin" "$stage/ui"
install -m 755 "$bundle/wa" "$stage/wa" || fail 'assemble_failed: wa'
install -m 755 "$bundle/bin/wa" "$stage/bin/wa" || fail 'assemble_failed: bin/wa'
install -m 755 "$bundle/bin/wa-update" "$stage/bin/wa-update" ||
  fail 'assemble_failed: bin/wa-update'
install -m 644 "$bundle/bin/release-lib.sh" "$stage/bin/release-lib.sh" ||
  fail 'assemble_failed: bin/release-lib.sh'
for _a in $RL_UI_ASSETS; do
  install -m 644 "$bundle/ui/$_a" "$stage/ui/$_a" || fail "assemble_failed: ui/$_a"
done
install -m 644 "$bundle/LICENSE" "$stage/LICENSE" || fail 'assemble_failed: LICENSE'
rl_write_installed "$stage/installed.txt" "$bundle_commit" "$bundle_remote" \
  "${existing_commit:--}" 'bundle-install' 'cross-android' 'cross-built-android' "$release_key"
# The build facts, kept where `wa doctor`, an operator and a later update can all read them.
{
  printf 'bundle_manifest_sha256=%s\n' "$manifest_sha"
  printf 'target_triple=%s\n' "$bundle_target"
  printf 'source_tree_sha256=%s\n' "$bundle_tree"
  printf 'ndk_version=%s\n' "$bundle_ndk"
  printf 'rustc_version=%s\n' "$bundle_rustc"
} >> "$stage/installed.txt"
rl_manifest "$stage" "$stage/installed.sha256"
rl_verify_release "$stage" ||
  fail 'candidate_refused: the staged release did not verify (see above); nothing was switched'

if [ "$reuse" = 1 ]; then
  rm -rf -- "$stage"
  note "reusing the verified release already at $RL_RELEASES/$release_key"
fi

if [ -z "$existing_commit" ]; then
  mv -- "$stage" "$RL_INSTALL" || fail "install_failed: cannot place $RL_INSTALL"
  trap - EXIT
else
  if [ "$reuse" = 0 ]; then
    mv -- "$stage" "$RL_RELEASES/$release_key" ||
      fail "install_failed: cannot place the release in $RL_RELEASES"
    trap - EXIT
  fi
  rl_activate "$release_key"
fi

if [ ! -e "$RL_PREFIX/bin/wa" ] && [ ! -L "$RL_PREFIX/bin/wa" ]; then
  ln -s "$RL_INSTALL/bin/wa" "$RL_PREFIX/bin/wa" ||
    fail "launcher_failed: cannot link $RL_PREFIX/bin/wa"
fi

# ---- what was installed, and what is still unproven -------------------------

note "installed $bundle_commit, cross-built for $bundle_target (NDK ${bundle_ndk:-unknown}, rustc ${bundle_rustc:-unknown})"
note "bundle manifest sha256: $manifest_sha"
if [ -n "$existing_commit" ]; then
  note "previous release kept at $RL_RELEASES/$existing_commit; roll back with: wa update --rollback"
fi
note 'this runtime was NOT compiled on this phone: "wa doctor" reports build_profile=cross-android'
note 'node state under ~/.wasm-agent was not read, copied or written, and wa setup was not run.'
note 'restart the UI to run the new runtime: Ctrl-C, then wa ui'
