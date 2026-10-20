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
# WHERE THE CODE LIVES. The verification and switch below are `rl_bundle_install` in
# `scripts/termux/release-lib.sh`, not this file: the published-release channel
# (`wa update`, which downloads the bundle first) runs the SAME function, so a downloaded
# release and a hand-copied bundle are verified and switched by exactly one implementation.
# This script is the operator-facing front end: the Android guards, the options, the staging
# directory, and the messages.
#
# Usage: bash scripts/install-termux.sh --bundle <dir> --manifest-sha256 <sha256>
#        bash scripts/termux/install-bundle.sh --bundle <dir> --manifest-sha256 <sha256>
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
. "$root/scripts/termux/release-lib.sh"
rl_paths

# The message prefix this front end has always used; the shared function prints it too.
RL_BUNDLE_TAG=termux-bundle

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

# The staging directory is this script's to create and to clean. It has to be on the same
# filesystem as the active release, because the switch is two renames.
stage="$RL_BASE/.wasm-agent-bundle.$$"
cleanup() { [ ! -d "$stage" ] || rm -rf -- "$stage"; }
trap cleanup EXIT

rl_bundle_install "$bundle" "$manifest_sha" "$stage"
