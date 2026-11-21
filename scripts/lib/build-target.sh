#!/usr/bin/env bash
# One build root for every build on this node (`docs/ONEROOT.md`).
#
#   . scripts/lib/build-target.sh
#   wa_build_run      "$ROOT" cargo build --release --offline     # sweep + cap + lock, then the command
#   wa_build_target   "$ROOT"   # where this tree's cargo output goes; invented nowhere else
#   wa_build_prepare  "$ROOT"   # sweep + cap for a script that sets CARGO_TARGET_DIR itself
#   wa_build_forget   "$ROOT"   # a tree went away: its build output goes with it
#
# THE PROBLEM THIS REPLACES (operator, 13/11). On wa-desktop the distro grew to 246 GB and filled the
# Windows C: drive until WSL crashed. Cleanup removed 73 separate Rust build folders, ~196 GB: one
# `rust/target` inside every worktree (up to 16 GB each), extra `rust/target-<name>` directories in the
# canonical checkout (target-ops 11 GB, target-onetool 8.3 GB, target-eval 7.2 GB), one-root build
# islands under `~/.wasm-agent/build/<name>-<hash>` (graphdb-baseline 9.8 GB, wt-oneroot-<hash>
# 6.9 GB, sign-target 6.2 GB) and the deploy cache under `<root>/build-cache` - each script invented
# its own directory and nothing owned the question "how much build space is this node using".
#
# THE ANSWER IS THREE RULES, and this file is the only place they are written down.
#
#   1. ONE BUILD ROOT, `<root>/build/target`. Every build kind the repo does resolves its target dir
#      here through this file - an agent's worktree, `scripts/fast.sh`, a landing, a test, a deploy, a
#      publish cross build (which cargo nests in `target/<triple>/`, as it already does). No script
#      invents another one, and any other target dir an older layout left behind is deleted before a
#      build uses new space (`wa_build_sweep`, which prints what it reclaimed).
#
#   2. INSIDE IT, ONE CHILD PER TREE: `<root>/build/target/<basename>-<12 hex of sha256 of the tree's
#      canonical path>`. That is the nesting cargo itself uses for target triples, and it is NOT a
#      detail: ONE FLAT `CARGO_TARGET_DIR` shared by two trees was reproduced on this node on 13/11
#      and it hands one tree another tree's artifacts (`scripts/test-onebuild.mjs` keeps that as a
#      check). Two checkouts of `rust/Cargo.toml` are two workspaces whose members have the same name,
#      version and relative path, so cargo gives the same member the SAME metadata hash in both trees
#      and the second tree's `libbase`/`libwa_host_support` overwrites the first tree's. Measured on a
#      two-member fixture (the `scripts/test-onebuild.mjs` row, seconds): one `libbase` rlib served both
#      trees, and after tree B's library was edited and built, tree A's rebuild printed `base=2` - it ran
#      B's library. A verdict about a tree that was never loaded is exactly what the binary doctrine of
#      this repo exists to prevent.
#      What IS shared is the root: one directory, one `wa clean`, one `wa status` line, one cap, one
#      owner - and no artifact crosses a tree. Reuse inside a tree is unchanged (cargo's incremental
#      build in that tree's child), and an island whose tree is gone or has landed is deleted by
#      `wa_build_sweep` / `wa clean`, so the node keeps at most one island per LIVE tree.
#
#   3. A HARD CAP ON THAT SPACE, `WASM_AGENT_BUILD_CAP_GB` (default 30 GB), enforced before every
#      heavy build: over it, the OLDEST build output goes first, and the build says so. Source, git
#      objects, the `~/.cargo` registry and operator data are never candidates - only directories this
#      file recognises as cargo output.
#
# The names here and in `rust/wa-capabilities/src/disk.rs` (`build_island_in`, `build_env_for_in`) and
# `scripts/codemode-build.mjs` (`targetDir`) are the same name: `scripts/test-onebuild.mjs` compares
# all three, so the binary `scripts/fast.sh` builds is the one the node's own builds use.

# ---- where -----------------------------------------------------------------------------------------

# `<home>/.wasm-agent/build`, resolved the way the node resolves its own root (`$WASM_AGENT_HOME` when
# set, else `$HOME`). One root, never a second concept.
wa_build_root() {
  printf '%s' "$(printf '%s' "${WASM_AGENT_HOME:-$HOME}/.wasm-agent/build" | sed 's|//*|/|g')"
}

# The one build root's cargo directory. Its children are per-tree target dirs and nothing else.
wa_build_target_root() {
  printf '%s' "$(wa_build_root)/target"
}

# The name a tree's build output carries: `basename` + '-' + 12 hex of sha256(realpath).
# `rust/wa-capabilities/src/disk.rs::build_island_in` computes the same string with `ring`, and
# `scripts/codemode-build.mjs::treeName` with `node:crypto`; `scripts/test-onebuild.mjs` checks that
# the three agree.
wa_build_tree_name() {
  local tree=$1 hash name
  # The canonical path when it can be resolved. A tree that has just been removed cannot be `cd`-ed
  # into, and its build output still has to be findable in the same breath (`wa_build_forget`), so an
  # ABSOLUTE path is used as given: `disk.rs::build_island_in` does the same fallback with the same
  # input, which is what keeps the two names equal. A relative path that does not resolve is refused.
  if ! tree=$(cd "$tree" 2>/dev/null && pwd -P); then
    case "$1" in
      /*) tree=${1%/} ;;
      *) return 1 ;;
    esac
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$tree" | sha256sum | cut -c1-12)
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$tree" | shasum -a 256 | cut -c1-12)
  else
    return 1
  fi
  # `basename` in a pipe carries a newline and `tr -c` would turn it into a trailing '-'; the Rust
  # side has no newline there, so strip it first or the two name different directories.
  name=$(basename "$tree" | tr -d '\n')
  name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '-')
  printf '%s-%s' "$name" "$hash"
}

# `CARGO_TARGET_DIR` for a tree: `<root>/build/target/<name>-<hash>`.
wa_build_target() {
  local name
  name=$(wa_build_tree_name "$1") || return 1
  printf '%s/%s' "$(wa_build_target_root)" "$name"
}

# ---- measuring -------------------------------------------------------------------------------------

# Human bytes, in the same shape `wa clean` prints them (`lua/core/clean.lua`).
wa_build_human() {
  awk -v n="${1:-0}" 'BEGIN{ if (n>=1024^3) printf "%.1fG", n/1024^3; else if (n>=1024^2) printf "%.1fM", n/1024^2; else if (n>=1024) printf "%.1fk", n/1024; else printf "%d", n }'
}

# Bytes in a directory, `du -sb` where it exists (GNU), `du -sk` elsewhere (macOS/MSYS).
wa_build_bytes() {
  local dir=$1 out
  [ -e "$dir" ] || { printf '0'; return; }
  if out=$(du -sb "$dir" 2>/dev/null | cut -f1) && [ -n "$out" ]; then printf '%s' "$out"; return; fi
  if out=$(du -sk "$dir" 2>/dev/null | cut -f1) && [ -n "$out" ]; then printf '%s' "$((out * 1024))"; return; fi
  printf '0'
}

# The cap, in bytes. `WASM_AGENT_BUILD_CAP_BYTES` wins over `WASM_AGENT_BUILD_CAP_GB` (decimal GB,
# default 30). `rust/wa-capabilities/src/disk.rs::build_cap_bytes` reads the same variable.
wa_build_cap_bytes() {
  if [ -n "${WASM_AGENT_BUILD_CAP_BYTES:-}" ]; then printf '%s' "$WASM_AGENT_BUILD_CAP_BYTES"; return; fi
  awk -v gb="${WASM_AGENT_BUILD_CAP_GB:-30}" 'BEGIN{ printf "%d", (gb+0)*1000000000 }'
}

# ---- the guard on deletions ------------------------------------------------------------------------

# Only cargo output is ever a candidate, and only where this file expects it:
#   * a child of `<root>/build` that is not `target` (an island an older layout wrote);
#   * `<root>/build-cache` (the deploy cache from before the one build root);
#   * `<tree>/rust/target` or `<tree>/rust/target-<name>`, for a tree that IS this repo's checkout;
#   * a child of `<root>/build/target` (a per-tree target dir), which the cap may evict.
# A symlink is refused, not followed, and a path only counts when its canonical parent is the directory
# the rule names. This is the same refusal `disk.rs` applies (`guard_inside`).
wa_build_deletable() { # <path> <kind: island|buildcache|tree-target|child>
  local path=$1 kind=$2 parent base root
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -L "$path" ] && { printf 'symlink_not_followed: %s\n' "$path" >&2; return 1; }
  base=$(basename "$path")
  root=$(wa_build_root)
  case "$kind" in
    island)
      parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
      [ "$parent" = "$(cd "$root" 2>/dev/null && pwd -P)" ] || return 1
      [ "$base" = target ] && return 1
      ;;
    buildcache)
      [ "$base" = build-cache ] || return 1
      parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
      [ "$parent" = "$(cd "$(dirname "$root")" 2>/dev/null && pwd -P)" ] || return 1
      ;;
    tree-target)
      case "$base" in target|target-*) : ;; *) return 1 ;; esac
      [ "$(basename "$(dirname "$path")")" = rust ] || return 1
      ;;
    fast-components)
      # The per-worktree component cache the fast path kept inside each worktree's git dir: one target
      # dir per worktree, 635M each and 59 of them (37 GB) measured on this node on 13/11. Components are
      # built into the one build root now, so these are pure garbage - and they are still cargo output,
      # which is what makes them a candidate at all.
      [ "$base" = target ] || return 1
      [ "$(basename "$(dirname "$path")")" = wa-fast-components ] || return 1
      ;;
    child)
      parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
      [ "$parent" = "$(cd "$(wa_build_target_root)" 2>/dev/null && pwd -P)" ] || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# Delete one candidate and print nothing; the caller counts and reports. Prints the bytes freed.
#
# A LEGACY directory (an older layout's target dir) that something wrote to moments ago is somebody's
# build in flight - another session on this node may be compiling in it right now, and deleting it would
# fail that build for a reason its owner cannot see. So a legacy candidate gets a grace period
# (`WASM_AGENT_BUILD_GRACE`, default 600 s): it is left, said so, and swept on a later run, once its
# owner's build has stopped writing there (after this change nothing new is ever written to one). The one
# build root's own children are NOT delayed this way - the cap judges those, and a child with a held
# build lock is skipped there.
wa_build_delete() { # <path> <kind>
  local path=$1 kind=$2 bytes age
  wa_build_deletable "$path" "$kind" || return 1
  case "$kind" in
    island|buildcache|tree-target|fast-components)
      age=$(( $(date +%s) - $(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo 0) ))
      if [ "$age" -lt "${WASM_AGENT_BUILD_GRACE:-600}" ]; then
        printf 'onebuild: leaving %s alone: written to %ss ago, so a build may be using it (swept after %ss, WASM_AGENT_BUILD_GRACE)\n' \
          "$path" "$age" "${WASM_AGENT_BUILD_GRACE:-600}" >&2
        return 1
      fi
      ;;
  esac
  bytes=$(wa_build_bytes "$path")
  rm -rf -- "$path" 2>/dev/null || { printf 'onebuild: could not delete %s\n' "$path" >&2; return 1; }
  printf '%s' "$bytes"
  return 0
}

# ---- the trees this node builds --------------------------------------------------------------------

# Every place a checkout of THIS repository can be: the tree this call is about, the worktrees under
# the one root, the session worktrees, and the `~/wt-*` trees an older habit left beside the home. A
# directory only counts when it is a checkout of this repo - `rust/wa-host-support` is a crate only
# this repository has - so a foreign project's `target` is never touched.
wa_build_known_trees() {
  local home candidate marker
  home=${WASM_AGENT_HOME:-$HOME}
  [ -n "${WA_BUILD_THIS_TREE:-}" ] && printf '%s\n' "$WA_BUILD_THIS_TREE"
  for candidate in "$home/.wasm-agent"/worktrees/* "$home/.wasm-agent"/wa-worktree-* "$home"/*/; do
    candidate=${candidate%/}
    [ -d "$candidate" ] || continue
    [ -e "$candidate/.git" ] || continue
    [ -f "$candidate/rust/wa-host-support/Cargo.toml" ] || continue
    printf '%s\n' "$candidate"
  done
  # ... plus every tree that ever built into the one root, read back from its marker. An agent may put a
  # worktree at any depth, and a sweep that only looked one level under the home would leave that tree's
  # `rust/target` (16 GB, on 13/11) exactly where the operator's rule says it must not be.
  for marker in "$(wa_build_target_root)"/*/tree; do
    [ -f "$marker" ] || continue
    candidate=$(cat "$marker" 2>/dev/null)
    [ -n "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    [ -f "$candidate/rust/wa-host-support/Cargo.toml" ] || continue
    printf '%s\n' "$candidate"
  done
}

# ---- rule 1: keep only one - sweep what other layouts left behind -----------------------------------

# Deletes every target dir that is not the one build root's children, and prints the reclaim to stderr.
# Cheap when there is nothing to do (one `[ -e ]` per candidate tree). Never deletes source, never a
# git object, never the cargo registry: the candidates are `target`/`target-*` directories under a
# checkout of this repo, children of `<root>/build` that are not `target`, and `<root>/build-cache`.
# Prints the bytes reclaimed on stdout.
wa_build_sweep() { # [--quiet]
  local quiet=${1:-} tree legacy total=0 count=0 bytes root home common
  root=$(wa_build_root)
  # 1. islands an older layout wrote: children of <root>/build other than `target`.
  for legacy in "$root"/*; do
    [ -e "$legacy" ] || [ -L "$legacy" ] || continue
    # The node's build lock lives here (rule 2 (heat)) and is NOT build output: it is the one file that
    # must outlive every sweep, or a queued build loses the lock it is waiting on.
    case "$(basename "$legacy")" in target|build.lock) continue ;; esac
    bytes=$(wa_build_delete "$legacy" island) || continue
    total=$((total + bytes)); count=$((count + 1))
  done
  # 2. the deploy cache from before the one build root: <root>/build-cache.
  home=${WASM_AGENT_HOME:-$HOME}
  for legacy in "$home/.wasm-agent/build-cache"; do
    [ -e "$legacy" ] || continue
    bytes=$(wa_build_delete "$legacy" buildcache) || continue
    total=$((total + bytes)); count=$((count + 1))
  done
  # 3. `rust/target` and `rust/target-*` inside every live checkout of this repo.
  while IFS= read -r tree; do
    [ -n "$tree" ] || continue
    for legacy in "$tree/rust/target" "$tree"/rust/target-*; do
      [ -e "$legacy" ] || [ -L "$legacy" ] || continue
      bytes=$(wa_build_delete "$legacy" tree-target) || continue
      total=$((total + bytes)); count=$((count + 1))
    done
  done <<EOF
$(wa_build_known_trees)
EOF
  # 4. a child of the one build root that no LIVE tree owns: it cannot be reused, and keeping it is how
  #    the 73 folders of 13/11 happened. A child is kept only when its name is the name one of this
  #    node's live checkouts hashes to (`wa_build_known_trees`), so "at most one island per live tree,
  #    and the newest one" holds without trusting a marker file this layout may not have written. A
  #    renamed or removed worktree therefore takes its island with it, and an unmarked child from an
  #    older layout goes too.
  local live=' ' tree
  while IFS= read -r tree; do
    [ -n "$tree" ] || continue
    live="$live$(wa_build_tree_name "$tree" 2>/dev/null) "
  done <<EOF
$(wa_build_known_trees)
EOF
  for legacy in "$(wa_build_target_root)"/*; do
    [ -e "$legacy" ] || [ -L "$legacy" ] || continue
    # `deploy-<commit>` is keyed by CONTENT (the commit), not by a tree path: it outlives the pin it was
    # built in on purpose, so that a retried deploy of the same commit reuses it. The cap evicts it by
    # age like any other build output.
    case "$(basename "$legacy")" in deploy-*) continue ;; esac
    # A live tree the enumeration above found, by name ...
    case "$live" in *" $(basename "$legacy") "*) continue ;; esac
    # ... or a tree the marker names and that is still a checkout, which covers a tree deeper than the
    # places the enumeration looks (`wa_build_known_trees` cannot see every depth an agent may choose).
    if [ -f "$legacy/tree" ]; then
      tree=$(cat "$legacy/tree" 2>/dev/null)
      [ -n "$tree" ] && [ -d "$tree" ] && continue
    fi
    bytes=$(wa_build_delete "$legacy" child) || continue
    total=$((total + bytes)); count=$((count + 1))
  done
  # 5. the per-worktree component cache inside each worktree's git dir (`<git dir>/wa-fast-components/
  #    target`, one per worktree, 635M each on this node on 13/11). Components build into the one build
  #    root now, so every one of them is space nothing will ever write to again.
  common=$(git -C "${WA_BUILD_THIS_TREE:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    for legacy in "$common"/wa-fast-components/target "$common"/worktrees/*/wa-fast-components/target; do
      [ -e "$legacy" ] || [ -L "$legacy" ] || continue
      bytes=$(wa_build_delete "$legacy" fast-components) || continue
      total=$((total + bytes)); count=$((count + 1))
    done
  fi
  if [ "$count" -gt 0 ] && [ "$quiet" != --quiet ]; then
    printf 'onebuild: reclaimed %s from %d build dir(s) no script owns any more - one build root owns build space from now on: %s\n' \
      "$(wa_build_human "$total")" "$count" "$(wa_build_target_root)" >&2
  fi
  printf '%s' "$total"
}

# ---- rule 3: the cap -------------------------------------------------------------------------------

# Deletes the OLDEST build output under the one build root until the total fits the cap. The tree about
# to build is never a candidate (it is the work), and nothing outside `<root>/build/target` is
# considered at all. Prints the bytes freed on stdout; what it deleted, it says on stderr.
wa_build_cap_enforce() { # <keep path|->
  local keep=${1:-} cap total oldest bytes freed=0 removed=0 name skipped=$'\n' link
  cap=$(wa_build_cap_bytes)
  # A symlink in the build root is not build output: it is unlinked - the link, never what it names. One
  # left by an agent on 13/11 (`waarchive-<hash> -> /tmp/waarchive-target`, its target gone) read as the
  # oldest entry forever, the guard refused it, and the loop below stopped at that first refusal - so the
  # 30 GB cap evicted nothing for a day and the distro grew to 261 GB (14/11).
  for link in "$(wa_build_target_root)"/*; do
    [ -L "$link" ] || continue
    unlink "$link" 2>/dev/null && printf 'onebuild: unlinked %s (a link in the build root, not build output)\n' "$(basename "$link")" >&2
  done
  total=$(wa_build_bytes "$(wa_build_target_root)")
  [ "$total" -gt "$cap" ] || { printf '0'; return 0; }
  # Oldest first: "the directory written to longest ago" is the build output a node is least likely to
  # need again, and it is what the operator's rule names ("delete old").
  while [ "$total" -gt "$cap" ]; do
    oldest=$(
      for candidate in "$(wa_build_target_root)"/*; do
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
        [ "$candidate" = "$keep" ] && continue
        case "$skipped" in *$'\n'"$candidate"$'\n'*) continue ;; esac
        # A build output another process is writing to RIGHT NOW is not old, whatever its mtime says: a
        # successful `flock -n` means nobody holds this dir's build lock, and only then is it a candidate.
        # The check is non-mutating on purpose - creating the lock file here would write into the very
        # directory whose mtime and size decide the eviction (measured: it made two fresh fixtures look
        # like the newest build in the root, and the cap then evicted the wrong one).
        if command -v flock >/dev/null 2>&1 && [ -f "$candidate/.wa-build.lock" ]; then
          flock -n "$candidate/.wa-build.lock" true 2>/dev/null || continue
        fi
        printf '%s\t%s\n' "$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null || echo 0)" "$candidate"
      done | sort -n | head -1 | cut -f2-
    )
    [ -n "$oldest" ] || break
    name=$(basename "$oldest")
    # One candidate that cannot go (in use, refused by the guard) is named and passed over - the cap goes
    # on to the next oldest instead of giving up on all of them.
    if ! bytes=$(wa_build_delete "$oldest" child); then
      printf 'onebuild: kept %s (it could not be deleted); trying the next oldest\n' "$name" >&2
      skipped="$skipped$oldest"$'\n'
      continue
    fi
    total=$((total - bytes)); freed=$((freed + bytes)); removed=$((removed + 1))
    printf 'onebuild: over the %s build cap: deleted %s (%s, oldest build output)\n' \
      "$(wa_build_human "$cap")" "$name" "$(wa_build_human "$bytes")" >&2
  done
  if [ "$removed" -gt 0 ]; then
    printf 'onebuild: %d build output(s) went, %s freed; build space is now %s of a %s cap\n' \
      "$removed" "$(wa_build_human "$freed")" "$(wa_build_human "$(wa_build_bytes "$(wa_build_target_root)")")" \
      "$(wa_build_human "$cap")" >&2
  fi
  if [ "$total" -gt "$cap" ]; then
    printf 'onebuild: still %s over the %s cap with nothing left to delete but the build this call is about to run; going ahead (raise WASM_AGENT_BUILD_CAP_GB to keep more than one)\n' \
      "$(wa_build_human "$total")" "$(wa_build_human "$cap")" >&2
  fi
  printf '%s' "$freed"
}

# ---- prepare: sweep, place the tree's target, enforce the cap --------------------------------------

# `wa_build_prepare <tree>` -> prints the target dir on stdout, everything else on stderr.
# Called by `wa_build_run`, and directly by a script that sets CARGO_TARGET_DIR itself but still wants
# the sweep and the cap to hold.
wa_build_prepare() { # <tree> [--quiet]
  local tree=$1 quiet=${2:-} target toolchain identity
  WA_BUILD_THIS_TREE=$(cd "$tree" 2>/dev/null && pwd -P) || WA_BUILD_THIS_TREE=$tree
  export WA_BUILD_THIS_TREE
  target=$(wa_build_target "$tree") || { printf 'onebuild: cannot name a build dir for %s (no sha256 tool)\n' "$tree" >&2; return 1; }
  # A dir that does not exist yet is seeded BEFORE it is created, from the newest sibling built by this
  # same toolchain (rule 1 (seeding) below). This is the only place a new child comes into being, so it is
  # the only place that has to know about it.
  if [ ! -e "$target" ]; then
    wa_build_seed "$target" "$quiet"
  fi
  mkdir -p "$target" 2>/dev/null || { printf 'onebuild: cannot create %s\n' "$target" >&2; return 1; }
  # The marker wa clean judges a build dir by: "tree" names the checkout it was built from, the same file
  # disk.rs::build_env_for_in writes.
  printf '%s' "$WA_BUILD_THIS_TREE" > "$target/tree" 2>/dev/null || true
  # Which toolchain builds here. Written on every prepare, because the value that matters is the compiler
  # the NEXT build will use, and a later new tree reads it to decide whether this child is reusable.
  toolchain=$(wa_build_toolchain) && printf '%s' "$toolchain" > "$target/toolchain" 2>/dev/null || true
  # Which SOURCE this child is for: the only thing that makes it a seed for a later tree (wa_build_seed).
  identity=$(wa_build_source_identity "$WA_BUILD_THIS_TREE")
  printf '%s' "$identity" > "$target/identity" 2>/dev/null || true
  wa_build_sweep "$quiet" >/dev/null
  wa_build_cap_enforce "$target" >/dev/null
  printf '%s' "$target"
  return 0
}

# ---- rule 1 (seeding): a NEW target dir starts from the newest sibling for the same toolchain -------

# WHY. Every tree gets its own child of the one root (rule 2 above), which is what keeps one tree from
# seeing another tree's artifacts - and it is also why every NEW worktree, every landing tree and every
# land gate used to compile from cold: no child existed, so cargo had nothing to reuse. Measured on this
# node (16 cores, btrfs, 21/11): a cold release build of wa-host took 144 s; the same build into a child
# seeded from a sibling took 61 s (a tree at another commit) and 64 s (same commit, one changed crate),
# and the binary each produced reported ITS OWN commit, not the seed's. The seed is a copy made with
# cp -a --reflink=always, so the two children share their blocks on btrfs until one of them writes:
# 1.4 GB copied in 105 ms, against minutes of compiling.
#
# WHAT IT IS NOT. It is not a shared target dir - rule 2 refuses that and scripts/test-onebuild.mjs keeps
# the refusal. The seed is a POINT-IN-TIME COPY that is the new tree's private child from the moment it
# exists. Cargo's own fingerprints then decide what is still valid, so a seed only saves the work that
# did not change, and a tree whose crate differs rebuilds that crate: scripts/test-build-seed.mjs fails
# if a seeded build ever reports another tree's code.
#
# THREE CONDITIONS, because a wrong seed is worse than a cold build:
#   * SAME TOOLCHAIN. An artifact another rustc produced is not reusable, so every child records the
#     toolchain that built it (child/toolchain) and only a sibling with the same value is a candidate.
#     Unknown is not yes: a child with no record is never a seed.
#   * NOT IN USE. A child another process is compiling into right now is not a seed; its build lock is
#     probed non-destructively, exactly as the cap does it.
#   * REFLINK OR NOTHING. --reflink=always either shares the blocks or fails, and it never falls back to
#     a full copy: a second 1.4 GB per tree is what the cap exists to stop. When it fails the build says
#     so and starts cold.

# The toolchain a build output belongs to, as one short string. rustc -vV carries the compiler's own
# commit hash, so two compilers of one version that are not the same binary do not match.
wa_build_toolchain() {
  local v
  v=$(rustc -vV 2>/dev/null) || return 1
  [ -n "$v" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$v" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$v" | shasum -a 256 | cut -c1-16
  else
    return 1
  fi
}

# When a child was last built, in seconds, for "most recently used". The binary a build produces is the
# best answer; a child with only a debug output, or none yet, falls back to its own entries.
wa_build_used_at() { # <child> -> seconds
  local child=$1 newest=0 stamp candidate
  for candidate in "$child/release/wa" "$child/release/wa.exe" "$child/debug/wa" "$child/debug/wa.exe" "$child/release" "$child/debug" "$child"; do
    [ -e "$candidate" ] || continue
    stamp=$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null || echo 0)
    case "$stamp" in ''|*[!0-9]*) continue ;; esac
    if [ "$stamp" -gt "$newest" ]; then newest=$stamp; fi
  done
  printf '%s' "$newest"
}

# The child to seed from: the most recently built sibling of the same toolchain that is not being built
# into right now. Prints nothing when there is none, which means a cold build.
wa_build_seed_candidate() { # <target>  (reads WA_BUILD_SEED_IDENTITY)
  local target=$1 mine candidate used best='' best_used=0 ident
  mine=$(wa_build_toolchain) || return 0
  ident=${WA_BUILD_SEED_IDENTITY:-}
  [ -n "$ident" ] || return 0
  for candidate in "$(wa_build_target_root)"/*; do
    [ -d "$candidate" ] || continue
    [ -L "$candidate" ] && continue
    [ "$candidate" = "$target" ] && continue
    [ -f "$candidate/toolchain" ] || continue
    [ "$(cat "$candidate/toolchain" 2>/dev/null)" = "$mine" ] || continue
    # The artifacts must have been produced from THIS tree's source, or they are another tree's code.
    [ -f "$candidate/identity" ] || continue
    [ "$(cat "$candidate/identity" 2>/dev/null)" = "$ident" ] || continue
    if [ ! -d "$candidate/release" ] && [ ! -d "$candidate/debug" ]; then continue; fi
    if command -v flock >/dev/null 2>&1 && [ -f "$candidate/.wa-build.lock" ]; then
      flock -n "$candidate/.wa-build.lock" true 2>/dev/null || continue
    fi
    used=$(wa_build_used_at "$candidate")
    if [ "$used" -gt "$best_used" ]; then best=$candidate; best_used=$used; fi
  done
  printf '%s' "$best"
}

# The newest source mtime of a tree, in seconds: the time against which cargo judges whether a build
# artifact is out of date. 0 when it cannot be told.
wa_build_tree_newest_source() { # <tree> -> seconds
  local tree=$1 newest
  newest=$(find "$tree" -name .git -prune -o -type f -printf '%T@\n' 2>/dev/null | cut -d. -f1 | sort -n | tail -1)
  case "$newest" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$newest" ;; esac
}

# The identity of the SOURCE a build output belongs to: the commit, plus the state of the tracked rust
# and lua trees (so an uncommitted edit is a different identity, not the same one).
#
# WHY THIS AND NOT AN MTIME. Cargo decides whether an artifact is current by comparing its mtime with its
# sources', so seeding an OLDER tree from a NEWER sibling handed over artifacts cargo kept - and the tree
# ran the SIBLING's code (measured: base=1 where its own library answered base=2). Comparing single files
# is the wrong question: cargo writes its own files into the child (.rustc_info.json), so a sibling is
# always 'newer' than something. What a seed has to answer is whether the artifacts were produced from
# THE SAME SOURCE as the tree being built: identical identity means a rebuild would produce exactly these
# bytes, so cargo may keep them; a different identity is a cold build, by name.
wa_build_source_identity() { # <tree>
  local tree=$1 head dirty
  head=$(git -C "$tree" rev-parse HEAD 2>/dev/null) || { printf 'unknown'; return 0; }
  # The WHOLE tracked state, not just the compiled subtrees: a seed is only reused when this tree is the
  # same source as the sibling, and guessing which edits matter is how a tree ends up running code it does
  # not have. Untracked files are included by --porcelain too, so a new file also means a cold build.
  dirty=$(git -C "$tree" status --porcelain 2>/dev/null | sha256sum 2>/dev/null | cut -c1-16)
  [ -n "$dirty" ] || dirty=unknown
  printf '%s-%s' "$head" "$dirty"
}

# Seed a target dir that does not exist yet. Staged beside it and renamed into place, so a copy that
# fails halfway leaves NO half-seeded child behind: a partial seed is a silent wrong answer, a missing
# one is only a slow build.
wa_build_seed() { # <target> [--quiet]
  local target=$1 quiet=${2:-} candidate stage bytes tree identity
  if [ "${WA_BUILD_SEED:-1}" = 0 ]; then return 0; fi
  if ! wa_build_toolchain >/dev/null 2>&1; then
    printf 'onebuild: cannot name this build toolchain (rustc -vV failed), so %s starts cold\n' "$(basename "$target")" >&2
    return 0
  fi
  tree=${WA_BUILD_THIS_TREE:-}
  if [ -z "$tree" ] || [ ! -d "$tree" ]; then
    printf 'onebuild: %s starts cold: the tree this build is for is unknown, so no sibling can be shown to hold its source\n' "$(basename "$target")" >&2
    return 0
  fi
  identity=$(wa_build_source_identity "$tree")
  case "$identity" in
    unknown*)
      printf 'onebuild: %s starts cold: the source identity of %s cannot be read (git), so no sibling can be shown to hold its source\n' "$(basename "$target")" "$tree" >&2
      return 0
      ;;
  esac
  candidate=$(WA_BUILD_SEED_IDENTITY="$identity" wa_build_seed_candidate "$target")
  [ -n "$candidate" ] || return 0
  stage="$target.seed-$$"
  rm -rf -- "$stage" 2>/dev/null || true
  if ! cp -a --reflink=always "$candidate" "$stage" 2>/dev/null; then
    rm -rf -- "$stage" 2>/dev/null || true
    if [ "$quiet" != --quiet ]; then
      printf 'onebuild: reflink is not supported on this filesystem, so %s starts cold instead of being seeded from %s (never a full copy)\n' \
        "$(basename "$target")" "$(basename "$candidate")" >&2
    fi
    return 0
  fi
  # The copy carries the origin's markers, and they are the origin's facts, not this child's.
  rm -f -- "$stage/tree" "$stage/toolchain" "$stage/identity" "$stage/.wa-build.lock" 2>/dev/null || true
  if [ -e "$target" ]; then rm -rf -- "$stage" 2>/dev/null || true; return 0; fi
  if ! mv -- "$stage" "$target" 2>/dev/null; then
    rm -rf -- "$stage" 2>/dev/null || true
    return 0
  fi
  bytes=$(wa_build_bytes "$target")
  if [ "$quiet" != --quiet ]; then
    printf 'onebuild: seeded %s from %s (%s, cp -a --reflink=always: the same source, so cargo rebuilds only what differs)\n' \
      "$(basename "$target")" "$(basename "$candidate")" "$(wa_build_human "$bytes")" >&2
  fi
  return 0
}

# ---- rule 2 (heat): ONE heavy build at a time on this node, and a bounded job count ----------------
#
# WHY. Builds from different trees ran at the same time: a land gate, a mission's fast.sh and a
# developer's build could each start a 16-job cargo, which is 48 compilers on 16 cores. Measured on this
# node on 20/11: load average 105, CPU at 95 C, and timing rows failing at random because the machine
# was thrashing. Serialising them costs nothing when they are already queueing: the work is the same, it
# just happens one build at a time, so the wall clock of a single build is unchanged while the peak
# temperature stops depending on how many sessions happen to build at once.
#
# WHAT IS LOCKED. The cargo invocation and nothing else. A test suite is NOT run under this lock: a row
# that builds takes it for that build only and releases it before its tests start, so two suites can
# still run in parallel and a test that waits on another process cannot deadlock the node's builds.
# A build started from inside a locked build (a build script that runs cargo) is not deadlocked either:
# the lock is announced in the environment of the locked command (WA_BUILD_HOST_LOCK_HELD) and a nested
# call sees it and does not queue behind itself.
#
# flock(1) IS USED, NEVER lock(1), AND ALWAYS WITH -o. Without -o a child that a build leaves behind
# inherits the lock's descriptor and holds the lock after the build has ended (measured 20/11: a fixture
# sleep 600 held the suite lock for ten minutes after its suite finished, twice). -o closes the
# descriptor in children, so the lock belongs to the wait and nothing else.

# The one lock every heavy build on this node takes. It lives beside the build root's target directory,
# not inside it: the cap's candidates are children of <root>/build/target, and a lock file the cap can
# delete is not a lock.
wa_build_lock_path() {
  printf '%s/build.lock' "$(wa_build_root)"
}

# The default job count, when the caller did not name one. Measured on this node (cold wa-host release,
# 16 cores, 21/11): 6 jobs 144 s, 10 jobs 136 s, 16 jobs 132 s, every run peaking at 97-98 C. Ten is the
# default because it is within 3% of sixteen (4 s of 136) and leaves half the cores free: a single build
# has the same wall clock, while an interactive session, a test row or a second build sharing this node
# no longer competes with sixteen compilers for sixteen cores. The peak temperature of ONE build is not
# what this cap moves - a build this long soaks the cooler at any job count, which is what the
# measurement above shows - what it moves is how bad the machine gets under CONCURRENT builds, which the
# host lock above serialises. Raise or lower it with WA_BUILD_JOBS_DEFAULT, or per call with
# CARGO_BUILD_JOBS (which always wins, because a caller that named a number meant it).
wa_build_jobs() {
  if [ -n "${CARGO_BUILD_JOBS:-}" ]; then printf '%s' "$CARGO_BUILD_JOBS"; return 0; fi
  printf '%s' "${WA_BUILD_JOBS_DEFAULT:-10}"
}

# Run one command under the node's single build lock. Prints the wait when it is worth mentioning.
#   wa_build_host_lock <command...>
# No flock(1) on this host means no queueing, not no build: the command runs and says so.
wa_build_host_lock() {
  local lock status
  if [ "${WA_BUILD_HOST_LOCK_HELD:-}" = 1 ]; then "$@"; return $?; fi
  if ! command -v flock >/dev/null 2>&1; then
    printf 'onebuild: flock is not available, so this build is not queued behind other builds\n' >&2
    "$@"; return $?
  fi
  lock=$(wa_build_lock_path)
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  (
    # -o: the lock is the wait's, never a child's. A build that leaves a compiler or a test behind must
    # not keep the node's build queue blocked after it exits.
    lock_started=$(wa_build_now_ms)
    if ! flock -o -w "${WA_BUILD_HOST_LOCK_WAIT:-3600}" 8; then
      printf 'onebuild: waited %ss for the node build lock and gave up; building anyway (WA_BUILD_HOST_LOCK_WAIT raises the wait)\n' \
        "${WA_BUILD_HOST_LOCK_WAIT:-3600}" >&2
    fi
    # The WAIT is measured here, between the start and the acquisition, never around the build: a build
    # that took 150 s once reported 'waited 149.8s', which credits compile time to the queue.
    lock_waited=$(( $(wa_build_now_ms) - lock_started ))
    if [ "$lock_waited" -gt 2000 ]; then
      printf 'onebuild: waited %ss for the node build lock (another build on this node was running; one heavy build at a time)\n' \
        "$(awk -v ms="$lock_waited" 'BEGIN{printf "%.1f", ms/1000}')" >&2
    fi
    WA_BUILD_HOST_LOCK_HELD=1 "$@"
  ) 8>>"$lock"
  status=$?
  return "$status"
}

# ---- rule 1 (concurrency): builds that share a target wait, and say how long ------------------------

wa_build_now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in ''|*[!0-9]*) printf '%s' "$(( $(date +%s) * 1000 ))" ;; *) printf '%s' "$((ns / 1000000))" ;; esac
}

# Is this command line a cargo invocation? True for cargo itself and for the env-prefixed form the
# callers use (wa_build_run <tree> env VAR=... cargo build ...). Anything else - a script, a test - is
# run as given and never queued on the build lock: the lock exists for compilers, and a test suite that
# waited on it could deadlock against a build of its own tree.
wa_build_is_cargo() {
  local word
  for word in "$@"; do
    case "$word" in
      env|[A-Za-z_]*=*) continue ;;
    esac
    case "$(basename "$word")" in
      cargo|cargo.exe) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# The one invocation every build goes through: the tree's target dir, the node's job cap when the caller
# named none, and the node's single build lock for a cargo build. Kept in one place so no caller can
# grow a second, unlocked way to compile.
wa_build_invoke() { # <target> <command...>
  local target=$1; shift
  if wa_build_is_cargo "$@"; then
    if [ -n "${CARGO_BUILD_JOBS:-}" ]; then
      CARGO_TARGET_DIR="$target" wa_build_host_lock "$@"
    else
      CARGO_TARGET_DIR="$target" CARGO_BUILD_JOBS="$(wa_build_jobs)" wa_build_host_lock "$@"
    fi
    return $?
  fi
  CARGO_TARGET_DIR="$target" "$@"
}

# `wa_build_run <tree> <command...>` - the one way a script builds.
#
# CARGO_TARGET_DIR is resolved here. A caller that sets it explicitly keeps it (a fixture or a
# reproducibility check that WANTS isolation says so), and the line says which one ran, so a build can
# never again be pointed somewhere nobody owns.
#
# Concurrency: two builds of the SAME tree share one target dir, so this runs the command under a
# `flock` on that directory and PRINTS the wait when it is worth mentioning (`--lock-wait-seconds`,
# default 1800). Cargo's own file lock would block the same way but silently; the wait is measured
# here so a slow build can be attributed to the queue and not to the compiler.
wa_build_run() {
  local tree=$1; shift
  local target explicit=${CARGO_TARGET_DIR:-} started waited=0 status
  target=$(wa_build_prepare "$tree") || return 1
  if [ -n "$explicit" ]; then
    case "$explicit" in
      /*|[A-Za-z]:[\\/]*) target=$explicit ;;
      *) target="$(cd "$tree" && pwd -P)/$explicit" ;;
    esac
    printf 'onebuild: CARGO_TARGET_DIR was named by the caller: %s (the one build root is %s)\n' "$target" "$(wa_build_target_root)" >&2
  else
    # NOT `export`: this function runs in the caller's shell, and a leaked CARGO_TARGET_DIR is inherited by
    # every later child of that shell - a row of `scripts/fast.sh` then believes the caller named a build
    # dir and resolves the fast path against this run's instead of its own fixture (measured on this
    # branch: the `fast-binary` check failed exactly there). The assignment is prefixed onto the command.
    printf 'onebuild: target %s (cap %s, WASM_AGENT_BUILD_CAP_GB)\n' "$target" "$(wa_build_human "$(wa_build_cap_bytes)")" >&2
  fi
  if command -v flock >/dev/null 2>&1 && [ -d "$target" ]; then
    (
      tree_lock_started=$(wa_build_now_ms)
      flock -w "${WA_BUILD_LOCK_WAIT:-1800}" 9 || printf 'onebuild: waited %ss for the build lock on %s and gave up (another build holds it; WA_BUILD_LOCK_WAIT raises the wait)\n' "$(awk -v s="${WA_BUILD_LOCK_WAIT:-1800}" 'BEGIN{printf "%d", s}')" "$(basename "$target")" >&2
      # The wait, not the build: measured between the start and the acquisition (see the host lock).
      tree_lock_waited=$(( $(wa_build_now_ms) - tree_lock_started ))
      if [ "$tree_lock_waited" -gt 2000 ]; then
        printf 'onebuild: waited %ss for the build lock on %s (another build of this tree was running)\n' \
          "$(awk -v ms="$tree_lock_waited" 'BEGIN{printf "%.1f", ms/1000}')" "$(basename "$target")" >&2
      fi
      cd "$tree" 2>/dev/null || exit 1
      wa_build_invoke "$target" "$@"
    ) 9>>"$target/.wa-build.lock"
    status=$?
    return "$status"
  fi
  ( cd "$tree" 2>/dev/null || exit 1; wa_build_invoke "$target" "$@" )
}

# `wa_build_forget <tree>` - delete this tree's build output (worktree removal).
# A finished worktree and its build outputs are one decision, not two. Prints the bytes freed.
wa_build_forget() { # <tree> [--quiet]
  local tree=$1 quiet=${2:-} target bytes=0 freed=0
  target=$(wa_build_target "$tree") || return 1
  if [ -e "$target" ]; then
    bytes=$(wa_build_delete "$target" child) || return 1
    freed=$((freed + bytes))
  fi
  if [ "$freed" -gt 0 ] && [ "$quiet" != --quiet ]; then
    printf 'onebuild: %s went with its tree, freeing %s\n' "$(basename "$target")" "$(wa_build_human "$freed")" >&2
  fi
  printf '%s' "$freed"
}

# `report`: the facts, no side effects (the reader's view of one build root).
wa_build_report() {
  local target_root cap total marker
  target_root=$(wa_build_target_root); cap=$(wa_build_cap_bytes); total=$(wa_build_bytes "$target_root")
  printf 'build root %s  %s of a %s cap%s\n' "$target_root" "$(wa_build_human "$total")" \
    "$(wa_build_human "$cap")" "$([ "$total" -gt "$cap" ] && echo ' (OVER)')"
  for marker in "$target_root"/*; do
    [ -d "$marker" ] || continue
    printf '  %-52s %8s  %s\n' "$(basename "$marker")" "$(wa_build_human "$(wa_build_bytes "$marker")")" \
      "$( [ -f "$marker/tree" ] && cat "$marker/tree" || echo '(no tree marker)')"
  done
}

# A script may run this file instead of sourcing it, which keeps every rule in one place and lets a
# test drive the exact code a build runs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    target) shift; wa_build_target "$1" ;;
    target-root) wa_build_target_root ;;
    root) wa_build_root ;;
    cap) wa_build_cap_bytes ;;
    prepare) shift; wa_build_prepare "$@" ;;
    sweep) shift; wa_build_sweep "$@" >/dev/null ;;
    forget) shift; wa_build_forget "$@" >/dev/null ;;
    report) wa_build_report ;;
    *) printf 'build-target: target <tree>|target-root|root|cap|prepare <tree>|sweep|forget <tree>|report\n' >&2; exit 2 ;;
  esac
fi
