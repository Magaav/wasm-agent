#!/usr/bin/env bash
# The one rule every test that gives a node a home must obey: the home it hands over is a SCRATCH home,
# never the operator's.
#
# MEASURED 19/11 (item 4 of the node-ops round). WASM_AGENT_HOME is the USER home, not the node's state
# directory: rust/wa-host-support/src/paths.rs:12 makes it override HOME, and the node's state hangs off
# it as <home>/.wasm-agent. Two mistakes followed from reading it the other way:
#
#   * the guards compared the scratch home against $HOME/.wasm-agent - the WRONG side. A scratch home of
#     $HOME (or $HOME/.wasm-agent itself) therefore PASSED the guard while the node wrote straight into
#     the operator's real ~/.wasm-agent. Measured in this session: WASM_AGENT_HOME=<d>/home/.wasm-agent
#     made the node use <d>/home/.wasm-agent/.wasm-agent - the doubled path is what a store root looks
#     like when it is written one level too deep.
#   * scripts/test-fast-watchdog.sh set WASM_AGENT_HOME to a store path while checking only that it was
#     under its WORK directory: consistent with the wrong reading, and it never noticed.
#
# The rule, four refusals plus one acceptance:
#   refuse  an empty path;
#   refuse  the real $HOME (the node's store would BE ~/.wasm-agent);
#   refuse  the real $HOME/.wasm-agent, and anything inside it (the operator's own store);
#   refuse  anything that CONTAINS the real $HOME/.wasm-agent (a home above the store is the same store);
#   accept  everything else, and say so by printing nothing.
#
#   . "$ROOT/scripts/lib/scratch-home.sh"
#   wa_scratch_home_guard "$SCRATCH/home" || exit 2
#
# It never creates, deletes or writes anything: it answers one question about a path.

wa_scratch_home_guard() { # <user-home-the-node-will-be-given>
  local candidate="${1-}"
  if [ -z "$candidate" ]; then
    printf 'refused(real_node_home): no scratch home was named, so this test cannot prove it is not the operator home\n' >&2
    return 1
  fi
  local real_home
  real_home="$(CDPATH= cd -- "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || real_home=
  if [ -z "$real_home" ]; then
    printf 'refused(real_node_home): the operator home could not be resolved, so the scratch home %s cannot be proven distinct from it\n' "$candidate" >&2
    return 1
  fi
  local real_store="$real_home/.wasm-agent"
  local resolved
  resolved="$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd -P)" || resolved=
  if [ -z "$resolved" ]; then
    # A path that does not exist yet is compared as written; a relative path is refused, because where it
    # points would depend on whatever cwd the node happened to have.
    case "$candidate" in
      /*) resolved="$candidate" ;;
      *) printf 'refused(real_node_home): the scratch home %s is not an absolute path, so where it points depends on the caller cwd\n' "$candidate" >&2; return 1 ;;
    esac
  fi
  resolved="${resolved%/}"
  # The home ITSELF is refused (its store is the operator store); a directory UNDER the home is not -
  # a scratch tree beside the repository is exactly that, and its own .wasm-agent is its own.
  case "$resolved" in
    "$real_home"|"$real_store"|"$real_store"/*)
      printf 'refused(real_node_home): %s is the operator home or inside the operator store %s; this test would act on the real node\n' "$resolved" "$real_store" >&2
      return 1 ;;
  esac
  case "$real_store/" in
    "$resolved"/*)
      printf 'refused(real_node_home): %s contains the operator store %s; a home above the store is the same store\n' "$resolved" "$real_store" >&2
      return 1 ;;
  esac
  return 0
}

# A scratch root that is NOT inside the operator's store. This node sets
# TMPDIR=/home/<user>/.wasm-agent/tmp (measured 19/11), so a plain `mktemp -d` makes its scratch home
# INSIDE the real node: the tests were writing their fixtures into the operator's own state and the
# guard below refused the result, which is how it was found. The candidates are tried in order and the
# first one OUTSIDE the real store wins; when none is outside it, the answer is a named refusal and a
# test says SKIP rather than writing there.
#
#   root="$(wa_scratch_root wa-fast-watchdog-test)" || exit 2
#   WORK="$(mktemp -d "$root/wa-fast-watchdog-test-XXXXXX")"
wa_scratch_root() { # <prefix> -> prints a directory a test may create its own under
  local prefix="${1:-wa-test}"
  local real_home real_store
  real_home="$(CDPATH= cd -- "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || real_home=
  real_store="$real_home/.wasm-agent"
  local candidate resolved
  local repo_root
  # The repository is found from the CALLER's directory when it is inside one, and from this file's own
  # scripts/.. otherwise: a lib sourced from a test's cwd must still exclude the tree under test, and
  # $(dirname $(dirname BASH_SOURCE)) is .../wt/scripts when the file is scripts/lib/scratch-home.sh.
  repo_root="$(CDPATH= cd -- "${PWD:-/nonexistent}" 2>/dev/null && git -C "${PWD:-.}" rev-parse --show-toplevel 2>/dev/null)" || repo_root=''
  if [ -z "$repo_root" ]; then
    repo_root="$(CDPATH= cd -- "$(dirname -- "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)")/.." 2>/dev/null && pwd -P)" || repo_root=/nonexistent
  fi
  # A ROOT MUST ALSO HAVE ROOM (item 0, measured): /tmp on this node is a 16 G tmpfs that was 79% full,
  # so moving every row home there made rows die with a Rust panic (exit 101) from a failed write.
  local min_mb="${WA_SCRATCH_MIN_FREE_MB:-4096}" free_mb
  # A LAND TREE OR A LANE IS INSIDE THE STORE (review r2, A4). When this runs from
  # ~/.wasm-agent/land/<id>/tree or ~/.wasm-agent/worktrees/<n>, the repository's own parent IS the
  # operator store, so the two repo-relative candidates are inside it and TMPDIR is inside it too. The
  # home-relative candidate is the one that still exists there: it is beside the store, not in it.
  for candidate in "${WA_TEST_ROOT:-}" "$(dirname -- "$repo_root")/.wa-scratch" "$(dirname -- "$(dirname -- "$repo_root")")/.wa-scratch" "${HOME:-/nonexistent}/.wa-scratch" "${TMPDIR:-}" /tmp; do
    [ -n "$candidate" ] || continue
    case "$candidate" in /*) ;; *) continue ;; esac
    # A ROOT GIVEN BY THE CALLER IS HELD TO THE SAME RULE AS A HOME (review r2 SHOULD): / and any
    # ancestor of the home are refused here too. wa_test_workdir refused them; wa_scratch_root did not,
    # so WA_TEST_ROOT=/ would have been returned as a root and the first test to use it would have made
    # /<name>.XXXXXX at the filesystem root.
    case "$candidate" in /|/) continue ;; esac
    # CHECK BEFORE MAKING ANYTHING (review r2, A4). This loop used to mkdir -p every candidate and then
    # refuse it, so a run from a land tree CREATED ~/.wasm-agent/land/<id>/.wa-scratch inside the
    # operator store and then refused every root it had just polluted. The path is resolved first - from
    # the candidate when it exists, from its nearest existing parent when it does not - and the store,
    # home, repository and space rules are asked BEFORE a directory is made.
    if [ -d "$candidate" ]; then
      resolved="$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd -P)" || continue
    else
      local parent base
      parent="$(dirname -- "$candidate")"
      base="$(basename -- "$candidate")"
      while [ ! -d "$parent" ] && [ "$parent" != "/" ] && [ "$parent" != "." ]; do
        base="$(basename -- "$parent")/$base"
        parent="$(dirname -- "$parent")"
      done
      local parent_resolved
      parent_resolved="$(CDPATH= cd -- "$parent" 2>/dev/null && pwd -P)" || continue
      resolved="$parent_resolved/$base"
    fi
    case "$resolved/" in "$real_store"/*) continue ;; esac
    # NOT the home itself (its store IS the operator store), but a directory BESIDE it is fine:
    # the rule is about the store, not about the whole home - and on this node the only filesystem
    # with room is /home, so refusing every path under it refuses every usable root (measured).
    [ "$resolved" = "$real_home" ] && continue
    case "$resolved/" in "$repo_root"/*) continue ;; esac
    [ "$resolved" = "$repo_root" ] && continue
    # Nothing is made until the path has passed every refusal above.
    [ -d "$candidate" ] || mkdir -p "$candidate" 2>/dev/null || continue
    resolved="$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd -P)" || continue
    [ -w "$resolved" ] || continue
    # df -Pm is POSIX; a machine without it keeps the old behaviour rather than refusing every root.
    free_mb=$(df -Pm "$resolved" 2>/dev/null | awk 'NR==2{print $4}')
    case "$free_mb" in ''|*[!0-9]*) : ;; *) [ "$free_mb" -lt "$min_mb" ] && continue ;; esac
    # AND IT MUST BE OUTSIDE THIS REPOSITORY: rows test their own tree, and a scratch home INSIDE it
    # makes the path-guard rows see a protected path (measured: the root resolved to wt/scripts and six
    # rows failed with secret_path_denied on a home they had just been given).
    case "$resolved/" in "$repo_root"/*) continue ;; esac
    printf '%s\n' "$resolved"
    return 0
  done
  printf 'refused(real_node_home): no writable scratch root exists outside the operator store %s (tried WA_TEST_ROOT, TMPDIR, /tmp and the directory above this repository)\n' "$real_store" >&2
  return 1
}


# A DIRECTORY THIS TEST OWNS, under a root the CALLER MAY HAVE SUPPLIED (review item 2).
#
# MEASURED 11/11 shape, and the review found it again in four scripts of this round:
#   SCRATCH="${WA_TEST_ROOT:-...}"; rm -rf "$SCRATCH"
# deletes the ROOT ITSELF when the operator set it - and WA_TEST_ROOT is exactly what somebody sets to
# ~ or ~/Work/missions when their /tmp is small. So this never touches the root: it makes a
# mktemp -d "$root/<name>.XXXXXX" under it and prints THAT, and it refuses by name a root that is a home
# or that carries a .git or a .wasm-agent. A root with a repository or a live store in it is not scratch.
#
#   root="$(wa_scratch_root wa-test)" || exit 2
#   WORK="$(wa_test_workdir "$root" nodes-probe-instances)" || exit 2
#   trap 'rm -rf "$WORK"' EXIT
wa_test_workdir() { # <root> <name> -> prints a fresh directory this test owns
  local root=${1-} name=${2-}
  if [ -z "$root" ] || [ -z "$name" ]; then
    printf 'refused(test_workdir_no_root): a test workdir needs a root and a name\n' >&2
    return 1
  fi
  if [ ! -d "$root" ]; then
    printf 'refused(test_workdir_missing): %s is not a directory\n' "$root" >&2
    return 1
  fi
  local resolved real_home
  resolved="$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P)" || {
    printf 'refused(test_workdir_unresolved): %s cannot be resolved\n' "$root" >&2
    return 1
  }
  real_home="$(CDPATH= cd -- "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || real_home=
  if [ -n "$real_home" ] && [ "$resolved" = "$real_home" ]; then
    printf 'refused(test_workdir_is_home): %s is a home; a test never makes or deletes directories in one\n' "$resolved" >&2
    return 1
  fi
  # NOT / AND NOT AN ANCESTOR OF THE HOME (review SHOULD). A root of / would put a scratch directory at
  # the filesystem root; /home would put one beside the operator's home, and a sloppy rm -rf of a name
  # like that is one keystroke from the home itself. The rule is the same shape as the home refusal: a
  # scratch root is BELOW the home's parent, never at or above it.
  if [ "$resolved" = "/" ]; then
    printf 'refused(test_workdir_is_root): / is never a scratch root\n' >&2
    return 1
  fi
  if [ -n "$real_home" ]; then
    case "$real_home/" in
      "$resolved"/*)
        printf 'refused(test_workdir_above_home): %s is an ancestor of the home %s; a scratch root is never at or above a home\n' "$resolved" "$real_home" >&2
        return 1 ;;
    esac
  fi
  if [ -e "$resolved/.git" ] || [ -e "$resolved/.wasm-agent" ]; then
    printf 'refused(test_workdir_is_state): %s holds a .git or a .wasm-agent; a scratch root is never that\n' "$resolved" >&2
    return 1
  fi
  local dir
  dir="$(mktemp -d "$resolved/$name.XXXXXX" 2>/dev/null)" || {
    printf 'refused(test_workdir_mkdir): cannot make a directory under %s\n' "$resolved" >&2
    return 1
  }
  printf '%s\n' "$dir"
}
