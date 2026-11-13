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
    island|buildcache|tree-target)
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
  local quiet=${1:-} tree legacy total=0 count=0 bytes root home
  root=$(wa_build_root)
  # 1. islands an older layout wrote: children of <root>/build other than `target`.
  for legacy in "$root"/*; do
    [ -e "$legacy" ] || [ -L "$legacy" ] || continue
    case "$(basename "$legacy")" in target) continue ;; esac
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
  local keep=${1:-} cap total oldest bytes freed=0 removed=0 name
  cap=$(wa_build_cap_bytes)
  total=$(wa_build_bytes "$(wa_build_target_root)")
  [ "$total" -gt "$cap" ] || { printf '0'; return 0; }
  # Oldest first: "the directory written to longest ago" is the build output a node is least likely to
  # need again, and it is what the operator's rule names ("delete old").
  while [ "$total" -gt "$cap" ]; do
    oldest=$(
      for candidate in "$(wa_build_target_root)"/*; do
        [ -d "$candidate" ] || continue
        [ "$candidate" = "$keep" ] && continue
        # A build output another process is writing to RIGHT NOW is not old, whatever its mtime says: a
        # successful `flock -n` means nobody holds this dir's build lock, and only then is it a candidate.
        if [ -f "$candidate/.wa-build.lock" ] && command -v flock >/dev/null 2>&1; then
          flock -n 9 2>/dev/null || continue
        fi 9>>"$candidate/.wa-build.lock"
        printf '%s\t%s\n' "$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null || echo 0)" "$candidate"
      done | sort -n | head -1 | cut -f2-
    )
    [ -n "$oldest" ] || break
    name=$(basename "$oldest")
    bytes=$(wa_build_delete "$oldest" child) || break
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
  local tree=$1 quiet=${2:-} target
  WA_BUILD_THIS_TREE=$(cd "$tree" 2>/dev/null && pwd -P) || WA_BUILD_THIS_TREE=$tree
  export WA_BUILD_THIS_TREE
  target=$(wa_build_target "$tree") || { printf 'onebuild: cannot name a build dir for %s (no sha256 tool)\n' "$tree" >&2; return 1; }
  mkdir -p "$target" 2>/dev/null || { printf 'onebuild: cannot create %s\n' "$target" >&2; return 1; }
  # The marker is what `wa clean` judges a build dir by: `tree` names the checkout it was built from,
  # the same file `disk.rs::build_env_for_in` writes.
  printf '%s' "$WA_BUILD_THIS_TREE" > "$target/tree" 2>/dev/null || true
  wa_build_sweep "$quiet" >/dev/null
  wa_build_cap_enforce "$target" >/dev/null
  printf '%s' "$target"
  return 0
}

# ---- rule 1 (concurrency): builds that share a target wait, and say how long ------------------------

wa_build_now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in ''|*[!0-9]*) printf '%s' "$(( $(date +%s) * 1000 ))" ;; *) printf '%s' "$((ns / 1000000))" ;; esac
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
    export CARGO_TARGET_DIR="$target"
    printf 'onebuild: target %s (cap %s, WASM_AGENT_BUILD_CAP_GB)\n' "$target" "$(wa_build_human "$(wa_build_cap_bytes)")" >&2
  fi
  if command -v flock >/dev/null 2>&1 && [ -d "$target" ]; then
    started=$(wa_build_now_ms)
    (
      flock -w "${WA_BUILD_LOCK_WAIT:-1800}" 9 || printf 'onebuild: waited %ss for the build lock on %s and gave up (another build holds it; WA_BUILD_LOCK_WAIT raises the wait)\n' "$(awk -v s="${WA_BUILD_LOCK_WAIT:-1800}" 'BEGIN{printf "%d", s}')" "$(basename "$target")" >&2
      cd "$tree" 2>/dev/null || exit 1
      "$@"
    ) 9>>"$target/.wa-build.lock"
    status=$?
    waited=$(( $(wa_build_now_ms) - started ))
    # Only a wait worth mentioning is mentioned: a build that started at once says nothing.
    if [ "$waited" -gt 2000 ]; then
      printf 'onebuild: waited %ss for the build lock on %s (another build of this tree was running)\n' \
        "$(awk -v ms="$waited" 'BEGIN{printf "%.1f", ms/1000}')" "$(basename "$target")" >&2
    fi
    return "$status"
  fi
  ( cd "$tree" 2>/dev/null || exit 1; "$@" )
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
