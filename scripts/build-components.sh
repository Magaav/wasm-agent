#!/usr/bin/env bash
# Build every WASI component (rust/components/*, wasm32-wasip2) and install it into the component
# directory with its pin and manifest. Separate from the core build on purpose: a component changes
# without rebuilding `wa`, and `wa` builds without compiling any component. See docs/COMPONENTS.md.
#
#   bash scripts/build-components.sh            # all components
#   bash scripts/build-components.sh mcp-whatsapp
#
# Reproducible bytes: the same source builds to the same sha256 from any checkout path (see the
# "Reproducible builds" section of docs/COMPONENTS.md, and `scripts/test-repro-components.sh`).
# WA_COMPONENTS_REPRO=0 turns the path remapping off (a diagnosis aid: it shows what the paths would
# otherwise contribute).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

# The two spellings a path can have for the toolchain on this machine: `C:/a/b` (mixed, what
# cygpath -m gives and what Cargo/rustc print in most places on Windows) and `C:\a\b` (what a
# native tool hands to the C compiler). Off Windows both are the same POSIX path. A
# --remap-path-prefix that matches nothing is a no-op, so both are always supplied.
tree_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
win_path() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" | sed 's|/|\\|g' ;;
    *) printf '%s' "$1" ;;
  esac
}

OUT="${WA_COMPONENTS_DIR:-$HOME/.wasm-agent/components}"
mkdir -p "$OUT"
# Request components (MCP) are wasm32-wasip2; long-lived services are wasm32-wasip1 (what Go's
# GOOS=wasip1 produces). A manifest may name its target; the default is wasm32-wasip2.
ensure_target() {
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$1"; then
    rustup target add "$1" >/dev/null
  fi
}

# A component with C inside (the graph: tree-sitter + SQLite) needs a wasm C toolchain: wasi-sdk
# (WASI_SDK=<dir>, else ~/wasi-sdk*, else /opt/wasi-sdk*). Exported when found; pure-Rust
# components build without it, and a C one fails with a clear message instead of a cc error.
SDK="${WASI_SDK:-}"
if [ -z "$SDK" ]; then
  for candidate in "$HOME"/wasi-sdk* /opt/wasi-sdk*; do [ -d "$candidate/share/wasi-sysroot" ] && SDK="$candidate"; done
fi
if [ -n "$SDK" ] && [ -d "$SDK/share/wasi-sysroot" ]; then
  ext=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".exe";; esac
  for t in wasm32_wasip1 wasm32_wasip2; do
    export "CC_$t=$SDK/bin/clang$ext" "AR_$t=$SDK/bin/llvm-ar$ext"
  done
  export WASI_SYSROOT="$SDK/share/wasi-sysroot" WASI_SDK_PATH="$SDK"
fi

# --- Reproducible bytes: the checkout path is not an input ------------------------------------
# Rust embeds source paths where the guest can see them: panic locations (`file!()` on a path
# dependency is absolute), `module_path!()`-style strings, and the debuginfo of every crate. C
# toolchains do the same for the C in a component (tree-sitter, SQLite, libc). The paths are
# absolute - Cargo hands rustc the checkout and the registry cache as absolute paths - so one tree
# checked out at /a/tree and at /b/tree produced different bytes with identical inputs
# (docs/COMPONENTS.md measured 8,185,719 vs 8,185,720 bytes). Remapping the three roots to fixed
# names takes the path out of the compilation:
#   * the checkout (Rust sources of this tree, and wa-graph's, which is a path dependency);
#   * CARGO_HOME (the registry cache; also where a path dependency outside this tree would live);
#   * wasi-sdk (the sysroot's C headers and libc sources, which is what -ffile-prefix-map covers).
# The Rust half travels in `scripts/wa-remap-rustc` (compiled as `rust/wa-remap-rustc` for a native
# Windows Cargo), reached through RUSTC_WRAPPER - NOT through RUSTFLAGS. RUSTFLAGS is hashed by Cargo
# into `-C metadata`, so a `--remap-path-prefix` naming this checkout would give the two checkouts two
# different flag strings: measured, that alone kept 1 byte of difference in the graph's 8 MB
# (8,216,117 vs 8,216,118 bytes) after every embedded path had already been remapped. The wrapper is
# found through PATH by its bare name, which is the same string in every checkout, and it computes the
# paths per invocation.
#
# It is installed outside the checkout (below) so that the resolved wrapper path, like the
# `RUSTC_WRAPPER` value, is one string for every checkout. That is not what makes a component with a
# path dependency differ still - that is Cargo's `-C metadata` (docs/COMPONENTS.md, "Reproducible
# builds", measured) - but a build input that can be one constant should not be a per-checkout path.
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'; else shasum -a 256 < "$1" | awk '{print $1}'; fi; }
sha_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

# Install the wrapper where every checkout of the same wrapper source shares exactly one path, and
# print that directory. Content-addressed: a changed wrapper is a different path, an unchanged one is
# the same path in every checkout and after every reboot. `cp` to a temporary name then `mv` so a
# concurrent build never picks up half a file.
install_wrapper() {
  local ext hash dir native
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".exe" ;; *) ext="" ;; esac
  hash=$({ cat rust/wa-remap-rustc/Cargo.toml rust/wa-remap-rustc/src/main.rs scripts/wa-remap-rustc; } 2>/dev/null | sha_stdin | cut -c1-16)
  if [ -z "$hash" ]; then echo "error: cannot read the wrapper sources (rust/wa-remap-rustc)" >&2; return 1; fi
  dir="${WA_REMAP_DIR:-${TMPDIR:-/tmp}/wa-remap-rustc}/$hash"
  mkdir -p "$dir" || return 1
  if [ ! -f "$dir/wa-remap-rustc$ext" ]; then
    if [ -n "$ext" ]; then
      # The native twin is compiled, not a `.cmd`: cmd.exe re-parses every argument and refuses a
      # command line over 8191 characters, and `windows-sys` alone passes one `--check-cfg`
      # argument naming ~250 features - that is what broke the wa-whatsapp build
      # (rust/wa-remap-rustc/src/main.rs).
      cargo build --release --manifest-path rust/wa-remap-rustc/Cargo.toml >/dev/null || {
        echo "error: cannot build the component-build wrapper (rust/wa-remap-rustc)" >&2; return 1; }
      native="${CARGO_TARGET_DIR:-$PWD/rust/target}/release/wa-remap-rustc.exe"
      case "$native" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;; *) native="$PWD/$native" ;; esac
      [ -f "$native" ] || { echo "error: the wrapper build produced no $native" >&2; return 1; }
      cp "$native" "$dir/.wa-remap-rustc$ext.tmp.$$" && mv "$dir/.wa-remap-rustc$ext.tmp.$$" "$dir/wa-remap-rustc$ext"
    else
      # A POSIX host needs no compile: the wrapper is the `exec` in scripts/wa-remap-rustc.
      cp scripts/wa-remap-rustc "$dir/.wa-remap-rustc.tmp.$$" && chmod 755 "$dir/.wa-remap-rustc.tmp.$$" &&
        mv "$dir/.wa-remap-rustc.tmp.$$" "$dir/wa-remap-rustc"
    fi || { echo "error: cannot install the wrapper in $dir" >&2; return 1; }
  fi
  printf '%s\n' "$dir"
}

if [ "${WA_COMPONENTS_REPRO:-1}" != 0 ]; then
  CHECKOUT="$(tree_path "$(pwd)")"
  CARGO_HOME_DIR="$(tree_path "${CARGO_HOME:-$HOME/.cargo}")"
  remap_c=""
  add_c_remap() { # <source dir> <fixed name>
    [ -n "$1" ] || return 0
    [ "$1" = "$2" ] && return 0
    remap_c="$remap_c -ffile-prefix-map=$1=$2 -ffile-prefix-map=$(win_path "$1")=$2"
  }
  add_c_remap "$CHECKOUT" /wasm-build
  add_c_remap "$CARGO_HOME_DIR" /cargo-home
  if [ -n "${WASI_SYSROOT:-}" ]; then add_c_remap "$(tree_path "$SDK")" /wasi-sdk; fi
  WRAPPER_DIR="$(install_wrapper)" || exit 2
  export PATH="$WRAPPER_DIR:$PATH"
  export RUSTC_WRAPPER=wa-remap-rustc
  # The wrapper reads its roots from here: it lives outside the checkout, so it cannot derive them.
  export WA_REMAP_CHECKOUT="$CHECKOUT" WA_REMAP_CARGO_HOME="$CARGO_HOME_DIR"
  for t in wasm32_wasip1 wasm32_wasip2; do
    eval "export CFLAGS_$t=\"\${CFLAGS_$t:-}$remap_c\""
    eval "export CXXFLAGS_$t=\"\${CXXFLAGS_$t:-}$remap_c\""
  done
  # `cc` reads CFLAGS_<target> for a cross build; these two cover a C toolchain that reads the
  # unprefixed names instead (`aws-lc`'s CMake build, a crate's own build.rs).
  export CFLAGS="${CFLAGS:-}$remap_c" CXXFLAGS="${CXXFLAGS:-}$remap_c"
  # `__DATE__`/`__TIME__` and any tool that stamps a build would otherwise make two identical
  # builds hours apart differ. Rust never embeds a build time; C does when a program uses those.
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
fi

built=0
for crate in rust/components/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi
  [ -f "$crate/manifest.json" ] || { echo "skip $name: no manifest.json" >&2; continue; }
  TARGET="$(sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([a-z0-9_-]*\)".*/\1/p' "$crate/manifest.json" | head -1)"
  TARGET="${TARGET:-wasm32-wasip2}"
  ensure_target "$TARGET"
  if grep -q '"needs_wasi_sdk"[[:space:]]*:[[:space:]]*true' "$crate/manifest.json" && [ -z "${WASI_SYSROOT:-}" ]; then
    echo "error: component $name needs wasi-sdk (C inside); set WASI_SDK=<dir>" >&2; exit 2
  fi
  cargo build --manifest-path "$crate/Cargo.toml" --target "$TARGET" --release ${WA_COMPONENTS_OFFLINE:+--offline} >/dev/null
  wasm="$crate/target/$TARGET/release/$name.wasm"
  # A library component (cdylib) is named with underscores.
  [ -f "$wasm" ] || wasm="$crate/target/$TARGET/release/${name//-/_}.wasm"
  [ -f "$wasm" ] || { echo "skip $name: no $wasm produced" >&2; continue; }
  # Install atomically: manifest and module first under temporary names, pin last, so a reader
  # never pairs a new module with an old pin (it would be refused, never run).
  cp "$crate/manifest.json" "$OUT/.$name.json.tmp" && mv "$OUT/.$name.json.tmp" "$OUT/$name.json"
  cp "$wasm" "$OUT/.$name.wasm.tmp" && mv "$OUT/.$name.wasm.tmp" "$OUT/$name.wasm"
  sha "$OUT/$name.wasm" > "$OUT/.$name.wasm.sha256.tmp" && mv "$OUT/.$name.wasm.sha256.tmp" "$OUT/$name.wasm.sha256"
  echo "installed $OUT/$name.wasm ($(wc -c < "$OUT/$name.wasm") bytes, sha256 $(cat "$OUT/$name.wasm.sha256"))"
  built=$((built + 1))
done
echo "built $built component(s)"
