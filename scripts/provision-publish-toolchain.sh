#!/usr/bin/env bash
# Make THIS machine able to build the node binaries a landing publishes: `zig` and `cargo-zigbuild` at the
# pinned versions, and the rust-std of every release target, installed into user directories.
#
# WHY. `scripts/publish-node-binaries.sh` builds both Linux targets with `cargo zigbuild` (a cross build:
# zig is the C compiler the crates with C inside need and it is the linker), and its header's only advice
# for the toolchain is "pip install ziglang; cargo install cargo-zigbuild" - unpinned, into whatever
# environment the shell happened to have. Measured 2026-11-11: the only machine that could publish both
# targets was wasm_the_first (Windows), so a Linux node whose landing touched a compiled input had no way
# to produce the release a deploy installs, and `work`'s deploy of main hit
# `codemode_build:cargo_failed: spawnSync cargo ETIMEDOUT` while every node waited for a binary nobody
# could build. This script is that missing step: one command, pinned versions, verified checksums, user
# directories only (no root, no distro package), idempotent, and `--check` answers without the network.
#
#   bash scripts/provision-publish-toolchain.sh                 # install what is missing
#   bash scripts/provision-publish-toolchain.sh --check         # one row per requirement; nothing installed
#   bash scripts/provision-publish-toolchain.sh --targets "x86_64-unknown-linux-gnu"
#   bash scripts/provision-publish-toolchain.sh --zig-only      # the C compiler/linker half
#
# What it installs, and where (all overridable, nothing touches a system directory):
#   zig <ZIG_VERSION>          $HOME/.local/zig/zig-<host>-<version>, symlinked to $HOME/.local/bin/zig
#                              (`WA_ZIG_DIR` moves the tree, `WA_ZIG` is honoured for an existing binary)
#   cargo-zigbuild <version>   `cargo install --version <version> --locked`, i.e. $CARGO_HOME/bin
#   rust-std per target        `rustup target add <triple>` (a cross build needs that target's std)
#
# The zig archive is verified against the sha256 ziglang.org publishes in its own download index
# (https://ziglang.org/download/index.json), pinned here as a constant: the pin is what makes two
# publishers' binaries comparable, and a download that does not match it is refused, never installed.
# cargo-zigbuild comes from crates.io through cargo, which verifies every crate's published checksum, at
# a pinned version and with `--locked` (the dependency set the publisher's measurements were taken with).
#
# THE VERSIONS ARE THE PUBLISHER'S OWN. docs/COMPONENTS.md's distribution measurements (zig 0.17.1,
# cargo-zigbuild 0.24.1) were taken with these, and `glibc 2.31` - the floor the manifest pins and reads
# back out of the bytes - is a property of the toolchain, so a different zig is a different artifact. A
# zig or cargo-zigbuild already installed with another version is REPORTED (`warn`) and left alone: this
# script never replaces a toolchain behind a user's back, it says what it found.
#
# Exit codes: 0 ok (installed or already present); 1 `--check` found a requirement missing; 2 a missing
# tool or bad argument; 8 a download, checksum or install failed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
say() { printf 'provision-publish-toolchain: %s\n' "$*"; }
fail() { printf 'provision-publish-toolchain: %s\n' "$*" >&2; exit "${2:-2}"; }

# ---- the pins ----------------------------------------------------------------------------------------
ZIG_VERSION="0.17.1"
# ziglang.org/download/index.json, "<version>" -> "<host>" -> shasum, for the two Linux hosts a publisher
# runs on. A tarball that does not hash to its pin is not unpacked.
zig_pinned_sha256() {
  case "$1" in
    x86_64-linux)  printf '%s' '3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a' ;;
    aarch64-linux) printf '%s' 'a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795' ;;
    *) return 1 ;;
  esac
}
CARGO_ZIGBUILD_VERSION="0.24.1"
DEFAULT_TARGETS="aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu"

CHECK=0
ZIG_ONLY=0
TARGETS="$DEFAULT_TARGETS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --zig-only) ZIG_ONLY=1; shift ;;
    --targets) [ "$#" -ge 2 ] || fail 'targets_value_required'; TARGETS="$2"; shift 2 ;;
    -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown_option: $1" ;;
  esac
done
case "$(uname -s)" in
  Linux) ;;
  *) fail "platform_unsupported: $(uname -s); a published Linux binary is built on Linux (a cross build needs zig, and this script installs the Linux host archives)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH=x86_64-linux ;;
  aarch64|arm64) HOST_ARCH=aarch64-linux ;;
  *) fail "arch_unsupported: $(uname -m)" ;;
esac
ZIG_SHA="$(zig_pinned_sha256 "$HOST_ARCH")" || fail "zig_unpinned_host: no sha256 pin for $HOST_ARCH"
ZIG_DIR="${WA_ZIG_DIR:-$HOME/.local/zig}"
ZIG_HOME="$ZIG_DIR/zig-$HOST_ARCH-$ZIG_VERSION"
ZIG_LINK_DIR="$HOME/.local/bin"
CARGO_HOME_REAL="${CARGO_HOME:-$HOME/.cargo}"
for target in $TARGETS; do
  case "$target" in
    aarch64-unknown-linux-gnu|x86_64-unknown-linux-gnu|aarch64-unknown-linux-musl|x86_64-unknown-linux-musl) ;;
    *) fail "target_unsupported: $target (aarch64|x86_64-unknown-linux-gnu|musl)" ;;
  esac
done

# The same search the publisher does (scripts/publish-node-binaries.sh, find_zig): a zig the publisher
# would not find is not a zig this script may call installed.
find_zig() {
  local candidate python_zig
  if candidate="$(command -v zig 2>/dev/null)" && [ -n "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  python_zig="$(python3 -c 'import ziglang,os;print(os.path.join(os.path.dirname(ziglang.__file__),"zig"))' 2>/dev/null)" || python_zig=""
  for candidate in \
    "${WA_ZIG:-}" \
    "$ZIG_LINK_DIR/zig" \
    "$CARGO_HOME_REAL/bin/zig" \
    "$ZIG_HOME/zig" \
    "/usr/local/bin/zig" \
    "/opt/homebrew/bin/zig" \
    "$ROOT/build/zig/zig" \
    "$python_zig" ; do
    if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}
zig_version_of() { "$1" version 2>/dev/null | head -1; }
zigbuild_version() { # cargo-zigbuild's own version, "" when absent
  local bin
  bin="$(command -v cargo-zigbuild 2>/dev/null)" || return 0
  [ -n "$bin" ] || return 0
  "$bin" --version 2>/dev/null | sed -n 's/^cargo-zigbuild //p' | head -1
}
rust_targets() { # installed rust-std triples, one per line
  command -v rustup >/dev/null 2>&1 || return 0
  rustup target list --installed 2>/dev/null
}
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 7; fi
}

# ---- --check: stats and two `--version` calls, never a download ---------------------------------------
if [ "$CHECK" = 1 ]; then
  missing=0
  row() { # status id detail
    case "$1" in
      ok) printf 'ok      %-12s %s\n' "$2" "$3" ;;
      warn) printf 'warn    %-12s %s\n' "$2" "$3" ;;
      *) printf 'missing %-12s %s\n' "$2" "$3"; missing=1 ;;
    esac
  }
  if bin="$(find_zig)"; then
    have="$(zig_version_of "$bin")"
    if [ "$have" = "$ZIG_VERSION" ]; then row ok zig "$bin ($have)"
    else row warn zig "$bin ($have; the publisher was measured with $ZIG_VERSION, so this is a different artifact)"; fi
  else
    row missing zig "no zig on PATH, in the pip ziglang package, in $ZIG_LINK_DIR or in build/zig (this script installs $ZIG_VERSION into $ZIG_HOME)"
  fi
  have="$(zigbuild_version)"
  if [ -z "$have" ]; then
    row missing cargo-zigbuild "not on PATH (the publisher refuses with cargo_zigbuild_missing; this script installs $CARGO_ZIGBUILD_VERSION into $CARGO_HOME_REAL/bin)"
  elif [ "$have" = "$CARGO_ZIGBUILD_VERSION" ]; then row ok cargo-zigbuild "$(command -v cargo-zigbuild) ($have)"
  else row warn cargo-zigbuild "$(command -v cargo-zigbuild) ($have; the publisher was measured with $CARGO_ZIGBUILD_VERSION)"; fi
  installed="$(rust_targets)"
  if ! command -v rustup >/dev/null 2>&1; then
    row warn rust-target "rustup is not on PATH; cannot name the installed targets (the publisher needs each target's rust-std)"
  else
    for target in $TARGETS; do
      if printf '%s\n' "$installed" | grep -qx "$target"; then row ok "rust-target" "$target"
      else row missing "rust-target" "$target (rustup target add $target)"; fi
    done
  fi
  if [ "$missing" = 0 ]; then
    say "everything the publisher needs is here; build both targets with:"
    printf '\n  bash scripts/publish-node-binaries.sh\n\n'
    exit 0
  fi
  say "missing above; run this script without --check to install it, then:"
  printf '\n  bash scripts/publish-node-binaries.sh\n\n'
  exit 1
fi

# ---- install -----------------------------------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then FETCH=curl
elif command -v wget >/dev/null 2>&1; then FETCH=wget
else fail 'fetch_tool_missing: neither curl nor wget is on PATH'
fi
fetch() { # url file
  case "$FETCH" in
    curl) curl -fsSL --retry 3 --connect-timeout 20 "$1" -o "$2" ;;
    wget) wget -q -O "$2" "$1" ;;
  esac
}

# 1. zig, verified against the pin before it is unpacked.
if bin="$(find_zig)" && [ "$(zig_version_of "$bin")" = "$ZIG_VERSION" ]; then
  say "zig $ZIG_VERSION already present: $bin"
else
  tmp="$(mktemp -d)" || fail 'scratch_unwritable'
  trap 'rm -rf "$tmp"' EXIT
  archive="zig-$HOST_ARCH-$ZIG_VERSION.tar.xz"
  url="https://ziglang.org/download/$ZIG_VERSION/$archive"
  say "fetching $url"
  fetch "$url" "$tmp/$archive" || { say "download failed: $url"; exit 8; }
  actual="$(sha256_of "$tmp/$archive")" || fail 'sha256_tool_missing: no sha256sum or shasum' 7
  if [ "$actual" != "$ZIG_SHA" ]; then
    fail "zig_checksum_mismatch: $archive is $actual, the pin is $ZIG_SHA (not installed)" 8
  fi
  say "checksum ok: $actual"
  mkdir -p "$ZIG_DIR" "$ZIG_LINK_DIR" || fail "unwritable: $ZIG_DIR" 8
  rm -rf "$ZIG_HOME.new" && mkdir -p "$ZIG_HOME.new" \
    && tar -xf "$tmp/$archive" -C "$ZIG_HOME.new" --strip-components=1 \
    || fail "zig_unpack_failed: $tmp/$archive" 8
  rm -rf "$ZIG_HOME" && mv "$ZIG_HOME.new" "$ZIG_HOME" || fail "zig_install_failed: $ZIG_HOME" 8
  ln -sfn "$ZIG_HOME/zig" "$ZIG_LINK_DIR/zig" || fail "zig_link_failed: $ZIG_LINK_DIR/zig" 8
  have="$(zig_version_of "$ZIG_LINK_DIR/zig")"
  [ "$have" = "$ZIG_VERSION" ] || fail "zig_install_unverified: $ZIG_LINK_DIR/zig reports '$have'" 8
  say "installed zig $have: $ZIG_LINK_DIR/zig -> $ZIG_HOME/zig"
fi

if [ "$ZIG_ONLY" = 1 ]; then
  say "zig only (--zig-only); the publisher also needs cargo-zigbuild and each target's rust-std"
  exit 0
fi

# 2. cargo-zigbuild, from crates.io at the pinned version.
have="$(zigbuild_version)"
if [ "$have" = "$CARGO_ZIGBUILD_VERSION" ]; then
  say "cargo-zigbuild $have already present: $(command -v cargo-zigbuild)"
else
  command -v cargo >/dev/null 2>&1 || fail 'cargo_missing: install a Rust toolchain (https://rustup.rs), then re-run'
  say "installing cargo-zigbuild $CARGO_ZIGBUILD_VERSION (cargo install --locked; crates.io checksums verified by cargo)"
  cargo install cargo-zigbuild --version "$CARGO_ZIGBUILD_VERSION" --locked 2>&1 | sed 's/^/  /' \
    || fail "cargo_zigbuild_install_failed: cargo install cargo-zigbuild --version $CARGO_ZIGBUILD_VERSION --locked" 8
  have="$(zigbuild_version)"
  [ "$have" = "$CARGO_ZIGBUILD_VERSION" ] || fail "cargo_zigbuild_install_unverified: reports '$have'" 8
  say "installed cargo-zigbuild $have: $(command -v cargo-zigbuild)"
fi

# 3. the rust-std of every release target: a cross build links a std for the target, and cargo refuses
#    without it ("can't find crate for `std`").
if command -v rustup >/dev/null 2>&1; then
  installed="$(rust_targets)"
  for target in $TARGETS; do
    if printf '%s\n' "$installed" | grep -qx "$target"; then
      say "rust-std $target already installed"
    else
      say "adding rust-std for $target"
      rustup target add "$target" >/dev/null 2>&1 || fail "rust_target_failed: rustup target add $target" 8
      rust_targets | grep -qx "$target" || fail "rust_target_unverified: $target is not in rustup target list --installed" 8
      say "installed rust-std $target"
    fi
  done
else
  say 'rustup is not on PATH: the publisher needs each target'"'"'s rust-std installed some other way'
fi

say "ready. Build and verify both Linux targets with:"
printf '\n  bash scripts/publish-node-binaries.sh\n\n'
say "it prints the exact gh release command and never runs it (--publish is the coordinator's call)"
