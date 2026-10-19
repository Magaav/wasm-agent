#!/usr/bin/env bash
# Build the Android arm64 `wa` node on a DESKTOP, and pack it as a prebuilt bundle the
# phone installs without a compiler.
#
# WHY THIS EXISTS. The phone cannot reliably compile this workspace any more: the measured
# failure on the operator's Mi 9 SE (Android 10, arm64-v8a, Termux 0.118.3, rustc 1.98.1)
# was rustc killed by a signal - `(signal: 11, SIGSEGV)` - on every rung of the on-device
# build ladder, with `cranelift_codegen` (the Wasmtime engine, pulled in by wa-host) as the
# last crate in every log, on a device holding ~2.7 GB available on 8 cores with swap in use.
# The same dependency, at the same version, was already installed successfully on that phone
# earlier, so the code did not change; the phone's toolchain and memory state did. Fighting
# the on-device compiler further is the wrong lever: build the runtime where a compiler has
# room, and let the phone install an artefact.
#
# WHAT IT GUARANTEES. The bundle contains exactly the closure the on-device installer
# produces (the runtime, the launcher, the updater and its library, the UI asset list,
# LICENSE, installed.txt) plus `bundle.manifest`, which records what produced the bytes:
# target triple, NDK version and provenance, rustc version and commit, the source commit and
# tree, the host, and a sha256 per artefact. `bundle.manifest`'s own sha256 is what the
# operator pastes into the phone-side installer, so one hash pins the whole bundle.
#
# WHAT IT DOES NOT PROVE. An artefact cross-built here is verified by hashes, by the
# installer's ELF/triple check, and by running it on the phone as part of the install
# candidate check - which is the only place a cross-built Android binary is actually proven
# to execute. Nothing in this script claims the bundle runs.
#
# The toolchain is used as it is found. Nothing is downloaded implicitly (the Rust analogue
# of the repository's `GOTOOLCHAIN=local` rule): a missing Android std in the local rustc is
# a named refusal with the exact command, never an automatic install.
#
# Usage:
#   bash scripts/termux/cross-build-android.sh [--ndk DIR] [--out DIR] [--api N]
#                                             [--check] [--no-archive]
#   --ndk DIR       Android NDK root (default: $WA_ANDROID_NDK, $ANDROID_NDK_HOME,
#                   $ANDROID_NDK_ROOT, $ANDROID_HOME/ndk/<version>, ~/android-ndk-r27d)
#   --out DIR       output directory (default: <repo>/build/android-bundle, not versioned)
#   --api N         Android API level for the linker/clang target (default: 21)
#   --check         resolve and print the toolchain and the exact build command; build nothing
#   --no-archive    build the bundle directory only, without the .tar.gz runner archive
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
. "$root/scripts/termux/release-lib.sh"

fail() { printf 'cross-build-android: %s\n' "$*" >&2; exit 1; }
note() { printf 'cross-build-android: %s\n' "$*"; }

target_triple=aarch64-linux-android
ndk=
out=
android_api=21
check_only=0
archive=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ndk) [ "$#" -ge 2 ] || fail 'ndk_value_required'; ndk=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail 'out_value_required'; out=$2; shift 2 ;;
    --api) [ "$#" -ge 2 ] || fail 'api_value_required'; android_api=$2; shift 2 ;;
    --check) check_only=1; shift ;;
    --no-archive) archive=0; shift ;;
    -h|--help|help)
      sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "unknown_option: $1 (the options are --ndk DIR, --out DIR, --api N, --check, --no-archive)" ;;
  esac
done
case "$android_api" in *[!0-9]*|'') fail "api_invalid: $android_api" ;; esac

[ -f "$root/rust/Cargo.toml" ] || fail "not_a_checkout: $root/rust/Cargo.toml is missing"
[ -f "$root/scripts/termux/release-lib.sh" ] || fail "not_a_checkout: $root/scripts/termux/release-lib.sh is missing"

# ---- the toolchain, as it is found on this machine --------------------------

# The NDK ships one `toolchains/llvm/prebuilt/<host>` per supported build host, so which one
# is used follows the host this script runs on, not a guess.
ndk_host_dir() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) printf 'windows-x86_64' ;;
    Darwin) printf 'darwin-x86_64' ;;
    *) printf 'linux-x86_64' ;;
  esac
}

resolve_ndk() {
  for _candidate in \
    "$ndk" \
    "${WA_ANDROID_NDK:-}" \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "${ANDROID_HOME:+$ANDROID_HOME/ndk/27.3.13750724}" \
    "${HOME:+$HOME/android-ndk-r27d}" \
    "${HOME:+$HOME/Android/Sdk/ndk/27.3.13750724}" \
    "${HOME:+$HOME/Library/Android/sdk/ndk/27.3.13750724}"
  do
    [ -n "$_candidate" ] || continue
    if [ -f "$_candidate/source.properties" ]; then printf '%s' "$_candidate"; return 0; fi
  done
  return 1
}

ndk_root=$(resolve_ndk) || fail 'ndk_missing: no Android NDK found; pass --ndk DIR or set ANDROID_NDK_HOME (see the README section "Installing from a prebuilt bundle" for the exact download, version and hash this repository was verified against)'
ndk_version=$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ndk_root/source.properties" | head -n 1)
[ -n "$ndk_version" ] || fail "ndk_unusable: $ndk_root/source.properties records no Pkg.Revision"

ndk_bin="$ndk_root/toolchains/llvm/prebuilt/$(ndk_host_dir)/bin"
clang="$ndk_bin/clang"
[ -x "$clang" ] || clang="$ndk_bin/clang.exe"
[ -x "$clang" ] || fail "ndk_unusable: no clang under $ndk_bin (is $ndk_root a full NDK for this host?)"
llvm_ar="$ndk_bin/llvm-ar"
[ -x "$llvm_ar" ] || llvm_ar="$ndk_bin/llvm-ar.exe"
[ -x "$llvm_ar" ] || fail "ndk_unusable: no llvm-ar under $ndk_bin"

command -v git >/dev/null 2>&1 || fail 'git_required'
cargo_bin=${CARGO:-cargo}
command -v "$cargo_bin" >/dev/null 2>&1 || [ -x "$cargo_bin" ] ||
  fail "cargo_required: '$cargo_bin' is not on PATH"

rustc_line=$(rustc -Vv) || fail 'rustc_required'
rustc_version=$(printf '%s\n' "$rustc_line" | sed -n 's/^rustc //p' | head -n 1)
rustc_commit=$(printf '%s\n' "$rustc_line" | sed -n 's/^commit-hash: //p' | head -n 1)
host_triple=$(printf '%s\n' "$rustc_line" | sed -n 's/^host: //p' | head -n 1)
[ -n "$rustc_version" ] && [ -n "$host_triple" ] || fail 'rustc_version_unknown: rustc -Vv did not report a version and host'

# The Android std must already be in this rustc. Installing it is the operator's decision,
# exactly like `pkg install rust` on the phone - this script does not reach for a download.
sysroot=$(rustc --print sysroot) || fail 'rustc_sysroot_unknown'
[ -d "$sysroot/lib/rustlib/$target_triple/lib" ] ||
  fail "rust_target_missing: this rustc ($rustc_version) has no $target_triple std; install it first: rustup target add $target_triple"

# ---- what a build of this tree would be ------------------------------------

[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] ||
  fail 'dirty_source: commit or stash the checkout; a bundle must name the commit it was built from'
source_commit=$(git -C "$root" rev-parse HEAD)
source_tree=$(git -C "$root" rev-parse 'HEAD^{tree}')
source_remote=$(git -C "$root" remote get-url origin 2>/dev/null || true)
[ -n "$source_remote" ] || source_remote='-'

out=${out:-$root/build/android-bundle}
bundle=$out/wa-android-bundle

cc_env=CC_aarch64_linux_android
ar_env=AR_aarch64_linux_android
linker_env=CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
cflags_env=CFLAGS_aarch64_linux_android

# One clang driver, asked for the target explicitly. The NDK's versioned wrappers
# (`aarch64-linux-android<api>-clang`) are shell scripts or .cmd files, which a native
# desktop cargo/cc-rs cannot exec on every host; `clang --target=...` does the same job
# from one path on all of them, and the NDK clang finds its own sysroot next to itself.
target_flag="--target=$target_triple$android_api"
build_env=(
  "CC_aarch64_linux_android=$clang"
  "CFLAGS_aarch64_linux_android=$target_flag"
  "AR_aarch64_linux_android=$llvm_ar"
  "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$clang"
  "RUSTFLAGS=-C link-arg=$target_flag"
)
build_cmd=(
  "$cargo_bin" build --release --locked --target "$target_triple"
  --manifest-path "$root/rust/Cargo.toml" -p wa-host --bin wa
)

if [ "$check_only" = 1 ]; then
  note "ndk:     $ndk_root (version $ndk_version)"
  note "clang:   $clang"
  note "ar:      $llvm_ar"
  note "rustc:   $rustc_version ($rustc_commit), host $host_triple"
  note "target:  $target_triple (api $android_api)"
  note "source:  $source_commit (tree $source_tree) from $source_remote"
  note "out:     $out"
  note 'env for the build (one line per variable):'
  for _v in "${build_env[@]}"; do note "  $_v"; done
  note 'command:'
  note "  ${build_cmd[*]}"
  exit 0
fi

# ---- the build --------------------------------------------------------------

note "building $target_triple with NDK $ndk_version ($clang)"
note "source $source_commit, rustc $rustc_version ($rustc_commit)"
env "${build_env[@]}" "${build_cmd[@]}" ||
  fail "build_failed: cargo build --locked --target $target_triple exited non-zero; nothing was assembled"

bin=$root/rust/target/$target_triple/release/wa
[ -f "$bin" ] || fail "build_output_missing: $bin"

built_abi=$(rl_elf_abi "$bin")
[ "$built_abi" = aarch64 ] ||
  fail "wrong_abi: $bin is $built_abi, not an aarch64 ELF; the toolchain did not produce an Android arm64 binary"

[ "$(git -C "$root" rev-parse HEAD)" = "$source_commit" ] || fail 'source_changed_during_build'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] || fail 'source_changed_during_build'

# ---- the bundle: the on-device release closure, plus the manifest -----------

# `bundle.manifest` is not a member of the closure: it is the envelope that describes the
# closure, so the release manifest excludes it by name and the bundle's own hash chain is
# `sha256(bundle.manifest) -> sha256(installed.sha256) -> every file`.
RL_MANIFEST_EXCLUDE=bundle.manifest

rm -rf -- "$bundle"
mkdir -p -- "$bundle/bin" "$bundle/ui"
install -m 755 "$bin" "$bundle/wa" || fail "assemble_failed: $bundle/wa"
install -m 755 "$root/scripts/termux/wa" "$bundle/bin/wa" || fail 'assemble_failed: bin/wa'
install -m 755 "$root/scripts/termux/wa-update.sh" "$bundle/bin/wa-update" ||
  fail 'assemble_failed: bin/wa-update'
install -m 644 "$root/scripts/termux/release-lib.sh" "$bundle/bin/release-lib.sh" ||
  fail 'assemble_failed: bin/release-lib.sh'
for _a in $RL_UI_ASSETS; do
  install -m 644 "$root/ui/$_a" "$bundle/ui/$_a" || fail "ui_asset_missing: $root/ui/$_a"
done
install -m 644 "$root/LICENSE" "$bundle/LICENSE" || fail "license_missing: $root/LICENSE"
# The record a release carries on the phone: same shape, cross-build provenance. The
# installer rewrites the activation fields (installed_utc, previous_commit, installed_by)
# when it switches this bundle in; everything here describes the build itself.
rl_write_installed "$bundle/installed.txt" "$source_commit" "$source_remote" '-' \
  'cross-build-android' 'cross-android' 'cross-built-android'

rl_manifest "$bundle" "$bundle/installed.sha256"

ndk_source_url=${WA_ANDROID_NDK_SOURCE_URL:-unknown}
ndk_source_sha1=${WA_ANDROID_NDK_SOURCE_SHA1:-unknown}
{
  printf 'bundle_format=1\n'
  printf 'bundle_kind=cross-built-android\n'
  printf 'target_triple=%s\n' "$target_triple"
  printf 'elf_machine=%s\n' "$built_abi"
  printf 'android_api=%s\n' "$android_api"
  printf 'build_profile=cross-android\n'
  printf 'source_provenance=cross-built-android\n'
  printf 'source_commit=%s\n' "$source_commit"
  printf 'source_tree_sha256=%s\n' "$source_tree"
  printf 'source_remote=%s\n' "$source_remote"
  printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'built_by=cross-build-android.sh\n'
  printf 'host_triple=%s\n' "$host_triple"
  printf 'rustc_version=%s\n' "$rustc_version"
  printf 'rustc_commit=%s\n' "$rustc_commit"
  printf 'cargo_version=%s\n' "$("$cargo_bin" -V 2>/dev/null | head -n 1)"
  printf 'ndk_version=%s\n' "$ndk_version"
  printf 'ndk_source_url=%s\n' "$ndk_source_url"
  printf 'ndk_source_sha1=%s\n' "$ndk_source_sha1"
  printf 'release_manifest=installed.sha256\n'
  printf 'release_manifest_sha256=%s\n' "$(rl_sha256 "$bundle/installed.sha256")"
  printf 'member_count=%s\n' "$(wc -l < "$bundle/installed.sha256" | tr -d ' ')"
  # One line per artefact, in the same order and with the same hashes as the release
  # manifest. They are what a human reads; the installer checks them against the bytes.
  sed 's/^\([0-9a-f]\{64\}\)  \(.*\)$/artefact \1 \2/' "$bundle/installed.sha256"
} > "$bundle/bundle.manifest"

manifest_sha256=$(rl_sha256 "$bundle/bundle.manifest")

# Verify the bundle exactly as the phone will, before the operator is told a hash to paste.
rl_bundle_verify "$bundle" ||
  fail 'bundle_refused: the bundle this script just wrote does not verify (see above); nothing was packed'

printf '%s\n' "$manifest_sha256" > "$out/bundle.manifest.sha256"

# ---- the runner archive: what gets pushed to the phone ---------------------

# The phone-side step must need no compiler and no network, so the installer travels with
# the bundle. This is a copy of the reviewed scripts from the same commit, not a second
# implementation: it is the tree's own install-termux.sh running against ./bundle.
if [ "$archive" = 1 ]; then
  stage=$out/stage/wa-android-bundle
  rm -rf -- "$out/stage"
  mkdir -p -- "$stage/scripts/termux"
  install -m 755 "$root/scripts/install-termux.sh" "$stage/scripts/install-termux.sh" ||
    fail 'assemble_failed: scripts/install-termux.sh'
  for _s in install-bundle.sh release-lib.sh wa wa-update.sh adopt-existing.sh bootstrap.sh; do
    install -m 755 "$root/scripts/termux/$_s" "$stage/scripts/termux/$_s" ||
      fail "assemble_failed: scripts/termux/$_s"
  done
  cp -R -- "$bundle" "$stage/bundle" || fail 'assemble_failed: bundle copy'
  {
    printf 'wasm-agent for Android arm64, prebuilt (no compiler, no network on the phone)\n\n'
    printf 'built from commit %s\ntarget %s, NDK %s\nbundle manifest sha256: %s\n\n' \
      "$source_commit" "$target_triple" "$ndk_version" "$manifest_sha256"
    printf 'In Termux, two lines:\n\n'
    printf 'cd ~ && rm -rf wa-android-bundle && tar -xzf /sdcard/Download/wa-android-bundle.tar.gz\n'
    printf 'bash ~/wa-android-bundle/scripts/install-termux.sh --bundle ~/wa-android-bundle/bundle --manifest-sha256 %s\n\n' \
      "$manifest_sha256"
    printf 'The installer verifies that hash, then every member hash, then the ELF machine\n'
    printf 'before it switches anything; it backs the current installation up first. It never\n'
    printf 'touches ~/.wasm-agent and never runs wa setup. Roll back with: wa update --rollback\n'
  } > "$stage/INSTALL.txt"
  ( cd "$out/stage" && tar -czf "$out/wa-android-bundle.tar.gz" wa-android-bundle ) ||
    fail "archive_failed: $out/wa-android-bundle.tar.gz"
  rl_sha256 "$out/wa-android-bundle.tar.gz" > "$out/wa-android-bundle.tar.gz.sha256"
fi

note 'bundle built (a cross-built Android binary is verified here by hash and ELF machine; that it RUNS is proven only on the phone, by the installer)'
note "  bundle:            $bundle"
note "  bundle manifest:   $manifest_sha256"
note "  source:            $source_commit ($target_triple, NDK $ndk_version, rustc $rustc_version)"
if [ "$archive" = 1 ]; then
  note "  archive to push:   $out/wa-android-bundle.tar.gz"
  note "  archive sha256:    $(cat "$out/wa-android-bundle.tar.gz.sha256")"
fi
note '  install on the phone:'
note "    cd ~ && rm -rf wa-android-bundle && tar -xzf /sdcard/Download/wa-android-bundle.tar.gz"
note "    bash ~/wa-android-bundle/scripts/install-termux.sh --bundle ~/wa-android-bundle/bundle --manifest-sha256 $manifest_sha256"
