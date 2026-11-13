#!/usr/bin/env bash
# Which `wa` the fast path runs, and how it knows (11/11).
#
# The measured failure this replaces: on a lane worktree, `scripts/fast.sh` looked for a binary in this
# order - `command -v wa`, `$HOME/.local/bin/wa`, `$ROOT/rust/target/release/wa` - and on this node
# `~/.local/bin/wa` is a symlink into the CANONICAL checkout's target dir. Three sessions lost work to
# it (whatsapp.log, cli.log, codemode.log): the rows ran another commit's node, one of them green,
# against a tree whose edits were never loaded. Nothing said which binary ran.
#
# The rule now: the tree's own binary, or a named refusal.
#   * The first line of every fast run names the binary, its build commit, this tree's commit, and the
#     verdict - `fresh`, `stale`, or `unknown` - so a skew can never be silent again.
#   * `$ROOT/rust/target/release/wa` wins over anything on PATH. When it is missing or stale it is
#     BUILT (stamped with the tree's commit, with the prepared code-mode assets when they exist), so
#     the rows test this tree; when it cannot be built the run fails fast by name instead of grading
#     another commit.
#   * An explicit `WA_BIN` is still authoritative - a caller who names a binary has chosen it - and the
#     banner says so.
#   * Rows that need more than a working node (the code-mode ones need the embedded QuickJS assets) are
#     named when the chosen binary does not have them.
#
# `fast.sh --binary` prints the resolution and exits; it is what `scripts/test-fast-binary.mjs` drives.

# A probe that answers with the binary's own identity. `host.runtime_info()` is already a JSON object
# (rust/wa-capabilities/src/host.rs) and `host.quickjs` is present only when the code-mode assets were
# embedded, so this needs no module beyond the binary itself.
fast_binary_probe_script() {
  cat <<'LUA'
print(host.runtime_info())
print('quickjs=' .. (host.quickjs and '1' or '0'))
LUA
}

# fast_binary_probe <path> -> sets FAST_BIN_COMMIT FAST_BIN_TREE FAST_BIN_SHA FAST_BIN_PATH
#                             FAST_BIN_CODEMODE; returns 1 when the binary cannot answer.
fast_binary_probe() {
  local bin=$1 dir out
  FAST_BIN_COMMIT=''; FAST_BIN_TREE=''; FAST_BIN_SHA=''; FAST_BIN_PATH=''; FAST_BIN_CODEMODE='unknown'
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wa-binprobe-XXXXXX" 2>/dev/null) || return 1
  fast_binary_probe_script > "$dir/identity.lua"
  # `timeout` is coreutils: present on Linux and in MSYS, absent on a bare busybox. A probe that hangs
  # would hang the fast path, so run it unbounded only where the guard does not exist.
  local guard=''
  command -v timeout >/dev/null 2>&1 && guard=timeout
  out=$(env -u WASM_AGENT_LUA_ROOT -u WASM_AGENT_VAULT_URL -u WASM_AGENT_VAULT_DIR \
      -u WASM_AGENT_VAULT_KEYSTORE -u WASM_AGENT_VAULT_PASSPHRASE \
      WASM_AGENT_HOME="$dir/home" WASM_AGENT_DB="$dir/probe.db" \
      WA_SCRIPT="$dir/identity.lua" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
      ${guard:+"$guard" 60} "$bin" --db "$dir/probe.db" 2>/dev/null)
  local status=$?
  rm -rf "$dir"
  [ "$status" = 0 ] || return 1
  FAST_BIN_COMMIT=$(printf '%s' "$out" | sed -n 's/.*"build_source_commit":"\([^"]*\)".*/\1/p' | head -1)
  FAST_BIN_TREE=$(printf '%s' "$out" | sed -n 's/.*"build_source_tree":"\([^"]*\)".*/\1/p' | head -1)
  FAST_BIN_SHA=$(printf '%s' "$out" | sed -n 's/.*"binary_sha256":"\([^"]*\)".*/\1/p' | head -1)
  FAST_BIN_PATH=$(printf '%s' "$out" | sed -n 's/.*"binary_path":"\([^"]*\)".*/\1/p' | head -1)
  case "$(printf '%s' "$out" | sed -n 's/^quickjs=\(.*\)$/\1/p' | head -1)" in
    1) FAST_BIN_CODEMODE=yes ;;
    0) FAST_BIN_CODEMODE=no ;;
    *) FAST_BIN_CODEMODE=unknown ;;
  esac
  [ -n "$FAST_BIN_PATH" ] || FAST_BIN_PATH=$bin
  return 0
}

# Is this binary's build older than the tree it would be used to test? An unstamped binary (a plain
# `cargo build --release`, which fast.sh no longer produces but a developer may) is fresh only when it
# is newer than every source that is embedded in it.
fast_binary_newer_than_tree() {
  local bin=$1 newer
  newer=$(find "$ROOT/lua/core" "$ROOT/lua/vendor" "$ROOT/rust" \
    -path "$ROOT/rust/target" -prune -o -type f \
    \( -name '*.lua' -o -name '*.rs' -o -name '*.toml' \) -newer "$bin" -print 2>/dev/null | head -1)
  [ -z "$newer" ]
}

# The prepared code-mode assets, if this checkout has them: the shipping build embeds them, so a build
# this script makes must too, or the node it installs cannot run code mode at all.
fast_binary_assets() {
  local common
  if [ -n "${WA_CODEMODE_BUILD_ASSETS:-}" ] && [ -d "$WA_CODEMODE_BUILD_ASSETS" ]; then
    FAST_CODEMODE_ASSETS=$WA_CODEMODE_BUILD_ASSETS
  else
    # MEASURED 13/11 in a worktree: `$ROOT/.git` is a FILE there (`gitdir: ...`), so the assets that the
    # canonical checkout prepared were never found, the build failed with `code-mode assets required` and
    # the run stopped as `stale_binary` - 193 rows unrun, and the reason three layers from the cause. The
    # assets belong to the CLONE, so the common git directory is where to look for them.
    common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
    case "$common" in
      '') common="$ROOT/.git" ;;
      /*) ;;
      *) common="$ROOT/$common" ;;
    esac
    if [ -d "$common/codemode-assets" ]; then
      FAST_CODEMODE_ASSETS=$(find "$common/codemode-assets" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
    else
      FAST_CODEMODE_ASSETS=''
    fi
  fi
}

# Where this tree's build actually lands. The node's one root owns all build output
# (`docs/ONEROOT.md`), as ONE ISLAND PER TREE: `<root>/build/<tree>-<hash>/target`. A single shared
# `CARGO_TARGET_DIR` for every tree was measured here on 12/11 and is not merely slower, it is wrong -
# cargo reused the other tree's `libwa_host_support` because its mtime was newer than this tree's
# source, and the build failed against a library that was never built from this tree.
#
# The island name is `basename(realpath) + '-' + first 12 hex of sha256(realpath)`, which
# `rust/wa-capabilities/src/disk.rs::build_island` computes with `ring`; `scripts/test-oneroot.lua`
# checks that the two agree, so the binary this script builds is the one the node's own builds use.
# A caller that names CARGO_TARGET_DIR keeps it, and the rule this file exists for is unchanged: the
# tree's OWN binary wins, identified by the commit it was stamped with, not by the directory.
fast_binary_target_dir() {
  local dir=${CARGO_TARGET_DIR:-}
  if [ -n "$dir" ]; then
    # Cargo resolves a relative CARGO_TARGET_DIR against the directory it runs in, which is $ROOT here.
    case "$dir" in
      /*|[A-Za-z]:[\\/]*) printf '%s' "$dir" ;;
      *) printf '%s/%s' "$ROOT" "$dir" ;;
    esac
    return
  fi
  if [ "${WASM_AGENT_SHARED_BUILD_DIR:-1}" = 0 ]; then printf '%s' "$ROOT/rust/target"; return; fi
  local tree hash name home
  tree=$(cd "$ROOT" 2>/dev/null && pwd -P) || { printf '%s' "$ROOT/rust/target"; return; }
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$tree" | sha256sum | cut -c1-12)
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$tree" | shasum -a 256 | cut -c1-12)
  else
    printf '%s' "$ROOT/rust/target"; return
  fi
  # `basename` in a pipe carries a newline, and `tr -c` would turn it into a trailing '-' - the Rust
  # side has no newline there, so the two would name different islands. Strip it first.
  name=$(basename "$tree" | tr -d '\n')
  name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '-')
  home=${WASM_AGENT_HOME:-$HOME}/.wasm-agent
  printf '%s' "$home/build/$name-$hash/target"
}

# fast_binary_plan -> decides, and sets:
#   FAST_BIN            the binary to use (may be the one about to be built)
#   FAST_BIN_SOURCE     explicit | tree | installed | none
#   FAST_BIN_VERDICT    fresh | stale | unknown | missing
#   FAST_BIN_ACTION     use | build | refuse | docker
#   FAST_BIN_WHY        one clause for the banner
fast_binary_plan() {
  local head tree_commit installed candidate source
  fast_binary_assets
  head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo '')
  FAST_HEAD=${head:0:12}
  FAST_BIN=${WA_BIN:-}
  FAST_BIN_SOURCE='none'; FAST_BIN_VERDICT='missing'; FAST_BIN_ACTION='refuse'; FAST_BIN_WHY=''
  FAST_BIN_COMMIT=''; FAST_BIN_TREE=''; FAST_BIN_SHA=''; FAST_BIN_PATH=''; FAST_BIN_CODEMODE='unknown'

  if [ -n "${WA_BIN:-}" ]; then
    candidate=$WA_BIN; source=explicit
  elif [ -x "$(fast_binary_target_dir)/release/wa" ]; then
    candidate=$(fast_binary_target_dir)/release/wa; source=tree
  elif [ -x "$(fast_binary_target_dir)/release/wa.exe" ]; then
    candidate=$(fast_binary_target_dir)/release/wa.exe; source=tree
  elif [ -x "$ROOT/rust/target/release/wa" ]; then
    # A tree built before the node's one root owned build output (or with
    # WASM_AGENT_SHARED_BUILD_DIR=0). It is still judged by its stamp, never by its path.
    candidate=$ROOT/rust/target/release/wa; source=tree
  elif [ -x "$ROOT/rust/target/release/wa.exe" ]; then
    candidate=$ROOT/rust/target/release/wa.exe; source=tree
  else
    candidate=''; source=installed
    installed=$(command -v wa 2>/dev/null || true)
    [ -n "$installed" ] || installed="$HOME/.local/bin/wa"
    [ -x "$installed" ] && candidate=$installed
  fi

  if [ -z "$candidate" ]; then
    FAST_BIN_ACTION='docker'; FAST_BIN_VERDICT='missing'
    FAST_BIN_WHY="no wa binary in this tree, on PATH or in ~/.local/bin"
    return 0
  fi
  FAST_BIN=$candidate; FAST_BIN_SOURCE=$source

  if fast_binary_probe "$candidate"; then
    case "$source" in
      explicit) FAST_BIN_VERDICT='explicit'
                FAST_BIN_WHY="named by WA_BIN (build ${FAST_BIN_COMMIT:0:12})" ;;
      *) if [ -n "$FAST_BIN_COMMIT" ] && [ -n "$head" ] && [ "$FAST_BIN_COMMIT" = "$head" ]; then
           FAST_BIN_VERDICT='fresh'
           FAST_BIN_WHY="built from this tree"
         elif [ -z "$FAST_BIN_COMMIT" ] && [ "$source" = tree ] && fast_binary_newer_than_tree "$candidate"; then
           FAST_BIN_VERDICT='fresh'
           FAST_BIN_WHY="unstamped build, newer than every lua/ and rust/ source"
         else
           FAST_BIN_VERDICT='stale'
           if [ -n "$FAST_BIN_COMMIT" ]; then
             FAST_BIN_WHY="build ${FAST_BIN_COMMIT:0:12} is not this tree (${FAST_HEAD:-unknown})"
           else
             FAST_BIN_WHY="unstamped build, older than the tree's lua/ or rust/ sources"
           fi
         fi ;;
    esac
  else
    FAST_BIN_VERDICT='unknown'
    FAST_BIN_WHY="the binary cannot report its identity (probe failed)"
  fi

  if [ "$source" = explicit ]; then FAST_BIN_ACTION='use'; return 0; fi
  if [ "$FAST_BIN_VERDICT" = fresh ]; then FAST_BIN_ACTION='use'; return 0; fi
  if [ "${WA_FAST_ALLOW_STALE_BINARY:-}" = 1 ]; then
    # The documented way out for a machine that cannot build: chosen by a human, printed as stale.
    FAST_BIN_ACTION='use'; FAST_BIN_WHY="$FAST_BIN_WHY; used anyway because WA_FAST_ALLOW_STALE_BINARY=1"
    return 0
  fi
  if [ "${WA_FAST_SKIP_BUILD:-}" = 1 ]; then
    FAST_BIN_ACTION='refuse'
    FAST_BIN_WHY="$FAST_BIN_WHY; WA_FAST_SKIP_BUILD=1 forbids building one"
    return 0
  fi
  FAST_BIN_ACTION='build'
}

# The first line of the run. `<binary> <verdict> <why>` in one line, because that line has to be
# readable on its own in a log that starts with it.
fast_binary_banner() {
  local bin=${FAST_BIN:-none} build tree extra=''
  build=${FAST_BIN_COMMIT:-none}; build=${build:0:12}
  tree=${FAST_HEAD:-unknown}; tree=${tree:0:12}
  [ -n "${FAST_BIN_SHA:-}" ] && extra=" sha256=${FAST_BIN_SHA:0:12}"
  [ "${FAST_BIN_CODEMODE:-unknown}" = no ] && extra="$extra code-mode=absent"
  printf 'fast: binary %s (build %s, tree %s, %s: %s)%s\n' \
    "$bin" "$build" "$tree" "${FAST_BIN_VERDICT}" "${FAST_BIN_WHY}" "$extra"
}

# Build the tree's own binary, stamped so the next run can prove freshness by commit instead of by a
# timestamp. The assets half matters: a build without them replaces a code-mode-capable node with an
# empty one (72 598 376 B vs 73 904 880 B, measured) and the code-mode rows then fail for a reason that
# has nothing to do with the branch.
fast_binary_build() {
  local assets=${FAST_CODEMODE_ASSETS:-} log
  command -v cargo >/dev/null 2>&1 || { FAST_BIN_WHY="$FAST_BIN_WHY; cargo is not on PATH"; return 1; }
  log=$(mktemp "${TMPDIR:-/tmp}/wa-fast-build-XXXXXX" 2>/dev/null) || log=/dev/null
  echo "fast: building this tree's binary (cargo build --release --offline)${assets:+ with code-mode assets}"
  (
    cd "$ROOT" || exit 1
    if [ -n "$assets" ]; then
      WA_BUILD_SOURCE_COMMIT=$(git rev-parse HEAD) \
      WA_BUILD_SOURCE_TREE=$(git rev-parse 'HEAD^{tree}') \
      WA_CODEMODE_BUILD_ASSETS="$assets" \
        cargo build --release --offline --manifest-path rust/Cargo.toml
    else
      WA_BUILD_SOURCE_COMMIT=$(git rev-parse HEAD) \
      WA_BUILD_SOURCE_TREE=$(git rev-parse 'HEAD^{tree}') \
      WA_CODEMODE_ALLOW_EMPTY=1 \
        cargo build --release --offline --manifest-path rust/Cargo.toml
    fi
  ) > "$log" 2>&1
  local status=$?
  if [ "$status" != 0 ]; then
    FAST_BIN_WHY="$FAST_BIN_WHY; cargo build failed: $(tail -1 "$log" 2>/dev/null | cut -c1-160)"
    [ "$log" != /dev/null ] && echo "fast: build log $log"
    return 1
  fi
  [ "$log" != /dev/null ] && rm -f "$log"
  # Mark the island with the tree it was built from, the same way
  # `rust/wa-capabilities/src/disk.rs::build_env_for` does: that marker is what `wa clean` judges an
  # island by, so a build this script made is retired when the tree it belongs to lands or goes.
  local island
  island=$(dirname "$(fast_binary_target_dir)")
  if [ -d "$island" ]; then printf '%s' "$(cd "$ROOT" && pwd -P)" > "$island/tree" 2>/dev/null || true; fi
  FAST_BIN="$(fast_binary_target_dir)/release/wa"; FAST_BIN_SOURCE='tree'
  if ! fast_binary_probe "$FAST_BIN"; then
    FAST_BIN_VERDICT='unknown'
    FAST_BIN_WHY="the binary it just built cannot report its identity"
    return 1
  fi
  if [ -n "$FAST_BIN_COMMIT" ] && [ "$FAST_BIN_COMMIT" = "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" ]; then
    FAST_BIN_VERDICT='fresh'; FAST_BIN_WHY="built from this tree"
  else
    # A build that does not carry this commit is not this tree's binary, whatever the path says.
    FAST_BIN_VERDICT='stale'
    FAST_BIN_WHY="the freshly built binary reports build ${FAST_BIN_COMMIT:0:12}, not this tree (${FAST_HEAD:-unknown})"
    return 1
  fi
  return 0
}

# The rows that need more than a working node: the code-mode ones read `host.quickjs` (or pin the mode),
# so a binary built without the embedded assets fails them for a reason the banner has to name.
fast_binary_rows_needing_assets() {
  local row
  for row in "$ROOT"/scripts/test-*.lua; do
    [ -f "$row" ] || continue
    if grep -qE "host\.quickjs|WASM_AGENT_CODEMODE['\"]?\)?[^=]*native" "$row" 2>/dev/null; then
      printf '%s ' "${row#$ROOT/}"
    fi
  done
}

# The refusal. A named error, with the two ways out, because the alternative is what this replaces.
fast_binary_refuse() {
  printf 'fast: stale_binary: %s\n' "$FAST_BIN_WHY" >&2
  printf 'fast: the rows must run THIS tree, so the run stops here instead of grading another commit.\n' >&2
  printf 'fast: build it with: WA_BUILD_SOURCE_COMMIT=$(git -C %s rev-parse HEAD) WA_CODEMODE_BUILD_ASSETS=<prepared assets> cargo build --release --offline --manifest-path rust/Cargo.toml\n' "$ROOT" >&2
  printf 'fast: or name a binary you mean with WA_BIN=<path>, or run WA_FAST_ALLOW_STALE_BINARY=1 to use the stale one (said out loud, every row).\n' >&2
  return 2
}
