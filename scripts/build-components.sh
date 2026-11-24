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
# The build root and the compiler are part of the artifact, and three files have to agree on them: this
# one builds, scripts/publish-components.sh publishes and scripts/test-component-lock-rebuild.sh judges.
# One library holds the literal defaults, the refusal by name, and the ownership/permission checks.
. "$PWD/scripts/lib/component-build-root.sh"

# --- THE COMPILER IS AN INPUT, and it is pinned -----------------------------------------------
# A component's bytes are the bytes of the compiler that built it. Measured on avell 23/11, one
# source (`agent-core` at main 0d8657e5): rustc 1.100.0 gives 393,860 bytes / `68c5d849...`, rustc
# 1.99.1 gives the pinned 392,561 bytes / `b24672b2...`. Eight of the eleven pins in components.lock
# carry `58cf8f9c35b3...` - rustc 1.99.1's commit hash, the same way 1.100.0's `0ef1bc38...` shows up in
# a build of today - so those pins were made with 1.99.1, and a node whose default toolchain has moved
# on can no longer rebuild them. This build asks rustup for that toolchain by name instead of taking
# the node's default; components.lock records the pin. Installing it is provisioning, like wasi-sdk:
# rustup fetches it once per node.
# WA_COMPONENT_TOOLCHAIN=node builds with the node's default compiler. That is a diagnosis aid - it
# shows what the compiler contributes - and never where a pinned artifact comes from.
COMPONENT_TOOLCHAIN="${WA_COMPONENT_TOOLCHAIN:-$(wa_component_lock_toolchain "$PWD")}"
if [ "$COMPONENT_TOOLCHAIN" != node ]; then
  command -v rustup >/dev/null 2>&1 || {
    echo "error: component builds are pinned to rustc $COMPONENT_TOOLCHAIN (components.lock) and rustup is not on PATH; install rustup, or WA_COMPONENT_TOOLCHAIN=node for a build whose bytes are not the pinned ones" >&2
    exit 2
  }
  if ! rustup toolchain list 2>/dev/null | grep -q "^$COMPONENT_TOOLCHAIN"; then
    printf 'component toolchain %s is not installed; fetching exactly: rustup toolchain install %s --profile minimal --target wasm32-wasip2 --target wasm32-wasip1\n'       "$COMPONENT_TOOLCHAIN" "$COMPONENT_TOOLCHAIN" >&2
    rustup toolchain install "$COMPONENT_TOOLCHAIN" --profile minimal --target wasm32-wasip2 --target wasm32-wasip1 >&2 || {
      echo "error: cannot install rustc $COMPONENT_TOOLCHAIN (offline?); the pinned component bytes need it" >&2
      exit 2
    }
    # What was actually installed, by version and commit - a channel name is a request, not an answer.
    printf 'component toolchain fetched: %s [%s]\n'       "$(rustup run "$COMPONENT_TOOLCHAIN" rustc -V 2>/dev/null)" "$(rustup run "$COMPONENT_TOOLCHAIN" rustc -Vv 2>/dev/null | awk '/^commit-hash/{print $2}')" >&2
  fi
  export RUSTUP_TOOLCHAIN="$COMPONENT_TOOLCHAIN"
fi

# THE ONE BUILD ROOT (docs/ONEROOT.md): every build kind on this node resolves its cargo target dir
# through `scripts/lib/build-target.sh`. A caller that names CARGO_TARGET_DIR keeps it; otherwise this
# tree's child of the one root is used, exported so the `cargo build` below and the lookup after it
# cannot disagree about where the artifact went.
if [ -z "${CARGO_TARGET_DIR:-}" ]; then
  . "$PWD/scripts/lib/build-target.sh"
  one_build_target=$(wa_build_prepare "$PWD" 2>/dev/null) || one_build_target=''
  if [ -n "$one_build_target" ]; then export CARGO_TARGET_DIR="$one_build_target"; fi
fi
# The node's one heavy build at a time (scripts/lib/build-target.sh, rule 2 (heat)): a component build is a
# cargo invocation like any other and queues with every other build on this node. Sourced separately
# because a caller that named CARGO_TARGET_DIR skips the block above and still has to queue.
if ! command -v wa_build_host_lock >/dev/null 2>&1 && [ -f "$PWD/scripts/lib/build-target.sh" ]; then
  . "$PWD/scripts/lib/build-target.sh"
fi
: "${CARGO_TARGET_DIR:=$PWD/rust/target}"
# A relative CARGO_TARGET_DIR is resolved ONCE, here, against the checkout: the build moves to the
# constant build root below, and resolving it there would put the target directory inside the copy.
case "$CARGO_TARGET_DIR" in
  /*|[A-Za-z]:/*|[A-Za-z]:\*) ;;
  *) CARGO_TARGET_DIR="$PWD/$CARGO_TARGET_DIR"; export CARGO_TARGET_DIR ;;
esac
one_build_target="$CARGO_TARGET_DIR"

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

# What built these bytes, on the record: a build that does not match the pin is diagnosed by these two
# versions first, and a run that reports them cannot be mistaken for one that used another toolchain.
sdk_record='none'
if [ -n "${SDK:-}" ]; then sdk_record="$(head -1 "$SDK/VERSION" 2>/dev/null)"; sdk_record="${sdk_record:-$SDK}"; fi
printf 'component toolchain: %s (pinned: %s); wasi-sdk: %s\n' "$(rustc -V 2>/dev/null)" "${COMPONENT_TOOLCHAIN:-default}" "$sdk_record" >&2

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

# The byte helpers, before anything uses them (the build root below hashes a tree; the install hashes
# the module it wrote). The implementation is scripts/lib/component-build-root.sh, so the publisher and
# the check that judges the pins cannot drift from the build.
sha() { wa_component_sha "$1"; }
sha_stdin() { wa_component_sha_stdin; }

# --- The build root is a CONSTANT path, never this checkout's ----------------------------------
# Cargo's source identity for a `path =` package is its canonical absolute path; that hash travels into
# every dependent's `-C metadata`, and rustc combines `-C metadata` into symbol names. So the same
# source in two checkouts builds to two different files, with the same size and a different sha256.
# Measured on avell 23/11, one commit, two paths, same toolchain: `libwa_mesh_core-8ee54b00c7a6cacd.rlib`
# against `libwa_mesh_core-cf7108a003359ad6.rlib`, and `mesh` 211,918 bytes `4769e631...` against
# `871179cc...`. Five of the pinned components have such a dependency (`graph` -> wa-graph, `mesh` ->
# wa-mesh-core, `model-gateway` -> wa-model-gateway, `wa-email` -> outbox+index, `wa-whatsapp` ->
# outbox+index), and it is exactly those five that no rebuild could match (docs/COMPONENTS.md,
# "Reproducible builds"). No wrapper can take that input over: it is not a flag that is added, and
# rustc combines every `-C metadata` it is given, so Cargo's own part cannot be replaced from outside.
#
# What does close it: build from a copy at ONE path, the same for every checkout. A real directory, not
# a symlink - Cargo canonicalises a symlink back to the tree (measured: the metadata stayed the tree's).
# The copy is the whole tree except `.git`, `build/` and every `target/`, so every input the build has is
# inside it.
#
# Two shapes of the same answer:
#  * with flock: one path, `$WA_COMPONENT_BUILD_ROOT/src`, re-extracted for each run under an exclusive
#    lock held for the whole script (`flock -o` re-exec: the lock belongs to the flock process, so no
#    cargo child inherits the descriptor and holds it after the build). Re-extracting instead of
#    rebuilding the tree file by file keeps every mtime, so Cargo's cache stays warm between runs: an
#    unchanged tree is `Fresh`, a changed one recompiles only what changed.
#  * without flock (no POSIX lock on this host): `$WA_COMPONENT_BUILD_ROOT/src-<hash of the tree>`, which
#    needs no lock because it is never written twice - the price is a cold build per changed tree.
# WA_COMPONENT_STABLE_ROOT=0 turns both off and builds in the checkout, which is how the path's
# contribution is shown (like WA_COMPONENTS_REPRO=0 for the remapping).
# ONE LITERAL PATH (scripts/lib/component-build-root.sh): `/tmp/wa-component-build`, or
# `C:/wa-component-build` on Windows, and `WA_COMPONENT_BUILD_ROOT` as the only override. It was
# `${TMPDIR:-/tmp}/...` in the first cut, which is one path only where TMPDIR is unset - macOS always sets
# it, so does many a container - and a build there is a different path, and different bytes, silently.
# A fixed directory under a shared /tmp is also a place another local user can prepare, so creating it and
# reusing it are both checked by name (0700, a real directory, ours, not group- or world-writable).
BUILD_ROOT="$(wa_component_build_root)"
copy_tree() { # <destination>: this checkout's whole build input, as it is now
  local dst="$1"
  rm -rf "$dst" && mkdir -p "$dst" || return 1
  tar -C "$PWD" --exclude=.git --exclude=build --exclude=target -cf - . | tar -C "$dst" -xf - || return 1
}
if [ "${WA_COMPONENTS_REPRO:-1}" != 0 ] && [ "${WA_COMPONENT_STABLE_ROOT:-1}" != 0 ]; then
  case "$BUILD_ROOT" in
    "$PWD"|"$PWD"/*) echo "error: WA_COMPONENT_BUILD_ROOT ($BUILD_ROOT) is inside this checkout; the build root must live outside the tree it copies" >&2; exit 2 ;;
  esac
  wa_component_build_root_prepare "$BUILD_ROOT" || exit 2
  if [ -z "${WA_COMPONENT_SRC_ROOT:-}" ] && command -v flock >/dev/null 2>&1; then
    exec flock -o "$BUILD_ROOT/.src.lock" env WA_COMPONENT_SRC_ROOT="$BUILD_ROOT/src" "$0" "$@"
  fi
  if [ -n "${WA_COMPONENT_SRC_ROOT:-}" ]; then
    BUILD_SRC="$WA_COMPONENT_SRC_ROOT"
    # Checked like the root, and before anything is deleted inside it: a symlink here would point the
    # rm below, and copy_tree's, at whatever it names.
    wa_component_build_root_prepare "$BUILD_SRC" || exit 2
    # A SWITCHED TREE MUST NOT INHERIT ANOTHER TREE'S ARTIFACTS (measured 24/11 on avell, mission
    # deploy-hold-r8a4). Cargo decides what to recompile by MTIME, and the copy preserves the mtimes of the
    # checkout it came from: build this tree's `selfloop` (09:58), build another worktree's at 10:04, come
    # back, and cargo answers `warm, nothing to compile` for the FIRST tree while the artifacts in the target
    # directory are the SECOND tree's - identical size, another sha256, and the component that ships is the
    # one this tree does not have. Measured exactly that: `selfloop` installed with the other tree's
    # 880aef08 while `lib.rs` in the build root held this tree's source.
    #
    # So the tree is compared with the one this build root last held (the hash, kept beside it so it cannot
    # change the hash of what it describes): the same tree keeps every mtime and the cache stays warm, and a
    # DIFFERENT tree is installed and then touched, so every input is newer than any artifact built from the
    # tree before it. The price is a real rebuild whenever the tree changes, which is exactly the run that
    # needs one.
    stage="$(mktemp -d "$BUILD_ROOT/.stage-XXXXXX")" || { echo "error: cannot stage under $BUILD_ROOT" >&2; exit 2; }
    copy_tree "$stage" || { rm -rf "$stage"; echo "error: cannot copy this tree into $stage" >&2; exit 2; }
    tree_hash="$(wa_component_tree_hash "$stage")"
    hash_file="$BUILD_ROOT/.src-tree-hash"
    recorded=""
    [ -f "$hash_file" ] && recorded="$(cat "$hash_file" 2>/dev/null || true)"
    if [ "$recorded" = "$tree_hash" ]; then
      rm -rf "$stage"
    else
      rm -rf "$BUILD_SRC"
      mkdir -p "$BUILD_SRC" || { rm -rf "$stage"; echo "error: cannot install $BUILD_SRC" >&2; exit 2; }
      tar -C "$stage" -cf - . | tar -C "$BUILD_SRC" -xf - || { rm -rf "$stage"; echo "error: cannot install $BUILD_SRC" >&2; exit 2; }
      rm -rf "$stage"
      find "$BUILD_SRC" -type f -print0 2>/dev/null | xargs -0 -r touch 2>/dev/null || true
      printf '%s' "$tree_hash" > "$hash_file" 2>/dev/null || true
    fi
  else
    stage="$(mktemp -d "$BUILD_ROOT/.stage-XXXXXX")" || { echo "error: cannot stage under $BUILD_ROOT" >&2; exit 2; }
    copy_tree "$stage" || { rm -rf "$stage"; echo "error: cannot copy this tree into $stage" >&2; exit 2; }
    tree_hash="$(wa_component_tree_hash "$stage")"
    BUILD_SRC="$BUILD_ROOT/src-$tree_hash"
    if [ -d "$BUILD_SRC" ]; then
      # A NAME IS NOT A PROOF: the hash in the directory's own name is recomputed from the tree inside it,
      # and the directory is reused only when the two agree. A directory that says one thing and holds
      # another is replaced (after the same ownership/permission check as the root), never built in.
      if wa_component_build_root_prepare "$BUILD_SRC" && [ "$(wa_component_tree_hash "$BUILD_SRC")" = "$tree_hash" ]; then
        rm -rf "$stage"
      else
        rm -rf "$stage" "$BUILD_SRC"
        mv "$stage" "$BUILD_SRC" || { echo "error: cannot install $BUILD_SRC" >&2; exit 2; }
      fi
    else
      mv "$stage" "$BUILD_SRC" || { echo "error: cannot install $BUILD_SRC" >&2; exit 2; }
    fi
  fi
  cd "$BUILD_SRC" || { echo "error: cannot enter the build root $BUILD_SRC" >&2; exit 2; }
  printf 'component build root: %s\n' "$BUILD_SRC" >&2
fi

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
  # THE BUILD, timed. A component is a module because a change to it compiles and ships on
  # its own (ARCHITECTURE.md, "Modules over the monolith"), and the fast path prints what each of
  # these cost. The compiler output is kept so the failure path can show it and so the units it
  # built can be counted: 0 units is a warm cache hit, not a fast build.
  build_log=$(mktemp "${TMPDIR:-/tmp}/wa-component-build-XXXXXX")
  build_started=$(date +%s%N)
  # Queued on the node's single build lock and under the node's job cap (scripts/lib/build-target.sh,
  # rule 2 (heat)): the same treatment every other heavy build on this node gets.
  if ! CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(wa_build_jobs)}" wa_build_host_lock cargo build --manifest-path "$crate/Cargo.toml" --target "$TARGET" --release ${WA_COMPONENTS_OFFLINE:+--offline} >"$build_log" 2>&1; then
    cat "$build_log" >&2; rm -f "$build_log"
    echo "error: component $name did not compile" >&2
    exit 1
  fi
  build_ms=$(( ($(date +%s%N)-build_started)/1000000 ))
  build_units=$(grep -c "^ *Compiling " "$build_log" 2>/dev/null) || build_units=0
  rm -f "$build_log"
  # One line per component for a caller that wants the numbers (scripts/fast.sh summary):
  # name, milliseconds, units compiled. /dev/null when nobody asked, so this changes nothing else.
  printf "%s\t%s\t%s\n" "$name" "$build_ms" "$build_units" >> "${WA_COMPONENT_BUILD_TIMINGS:-/dev/null}" 2>/dev/null || true
  # Cargo's artifact directory: `CARGO_TARGET_DIR` when the caller set one (the fast path, the job
  # harness), else THIS tree's child of the node's one build root (`scripts/lib/build-target.sh`,
  # docs/ONEROOT.md) - never a `target/` beside each component crate, which is one more folder per
  # crate that nothing owned (73 of them were 196 GB on wa-desktop on 13/11). A relative
  # CARGO_TARGET_DIR is resolved against the directory cargo runs in, which is this script's cwd (the
  # repository root).
  target_dir="${CARGO_TARGET_DIR:-$one_build_target}"
  case "$target_dir" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;; *) target_dir="$PWD/$target_dir" ;; esac
  wasm="$target_dir/$TARGET/release/$name.wasm"
  # A library component (cdylib) is named with underscores.
  [ -f "$wasm" ] || wasm="$target_dir/$TARGET/release/${name//-/_}.wasm"
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
