#!/usr/bin/env bash
# Run ONE fast row at a base commit and at this tree, and say what changed (item 5 of the node-ops round, #46).
#
#   bash scripts/row-at-sha.sh <sha> <row>          (the script: scripts/row-at-sha.sh)
#   . scripts/lib/row-at-sha.sh; wa_row_at_sha_classify <base-code> <change-code>
#
# WHY THIS EXISTS. "Fails before, passes after" is the shape every item of this round claims, and until now
# the only way to establish it was to edit the tree, run, un-edit, run again - which is how a session loses
# an afternoon and how a stash leaked into another worktree (19/11). The comparison is one command:
# a DETACHED worktree of the base commit beside the repo (never inside it), the row run there with its own
# scratch home, then the same row run against this tree with its own scratch home, and one verdict.
#
# WHAT IT DOES NOT PROVE, said here rather than implied: the binary that runs both rows is THIS node's `wa`,
# not a build of the base commit. The row's LUA comes from the commit under test (WASM_AGENT_LUA_ROOT), so a
# row that exercises Lua is covered; a row that needs a binary built at the base commit is not, and the
# answer says `binary_not_rebuilt` for that case instead of claiming the base was tested.
set -uo pipefail

# 0/0 still_passing, fail/fail pre_existing, 0/fail new_failure, fail/0 fixed.
# A nonzero code is a failure; 77 is the row's own SKIP (the harness convention), and a skip is never a pass.
wa_row_at_sha_classify() { # <base-code> <change-code> -> the class, one word
  local base=${1-} change=${2-}
  case "$base:$change" in
    0:0) printf 'still_passing' ;;
    0:77|77:77|77:0) printf 'skipped' ;;
    0:*) printf 'new_failure' ;;
    # 77 IS A SKIP, AND A SKIP IS NOT A PASS (item 8 of the node-ops round). The base never ran this row,
    # so it demonstrated nothing here; calling the result 'pre_existing' would claim 'the row failed at the
    # base', which is false. Measured before this fix: wa_row_at_sha_classify 77 1 answered pre_existing.
    77:*) printf 'new_failure' ;;
    *:0) printf 'fixed' ;;
    *:77) printf 'skipped' ;;
    *) printf 'pre_existing' ;;
  esac
}

# What a class means for a mission's claim, one sentence, so the reader is not left to infer it.
wa_row_at_sha_meaning() { # <class>
  case "${1-}" in
    still_passing) printf 'the row passed at the base and passes here: it says nothing about this change' ;;
    new_failure) printf 'the row did not pass at the base (it passed, or it SKIPPED) and FAILS here: the change is not exonerated - a base that never ran the row proves nothing about it' ;;
    fixed) printf 'the row FAILED at the base and passes here: the change repaired it' ;;
    pre_existing) printf 'the row fails at the base and fails here: a pre-existing failure, not this change' ;;
    skipped) printf 'the row skipped at one end or both: a skip is never a pass, and this is not evidence either way' ;;
    *) printf 'unknown: the row did not produce a code this can classify' ;;
  esac
}

# The scratch root: beside the repo (never inside it, so the worktree this creates is not in the tree under
# test), and never /tmp when /tmp is a small tmpfs - measured 19/11: SQLite answered "disk I/O error" at 80%
# full and it looked like a defect in the code under test.
wa_row_at_sha_root() { # <repo-root>
  printf '%s/.wa-row-at-sha-%s' "$(dirname "$1")" "$$"
}

# Run one row against one tree root, in its own scratch home, and answer its exit code.
#
# The row runs through THIS node binary with WASM_AGENT_LUA_ROOT pointed at the tree under test: the Lua
# the row exercises comes from that commit, which is the question being asked. The binary is named in the
# answer, and a row that needs the binary ITSELF built at that commit is not covered - the caller is told.
#
# TWO RULES TRAVEL WITH IT FROM scripts/fast.sh (item 8 of the node-ops round):
#   * the WASM_AGENT_*/WA_MESH* ALLOW-LIST is cleared here too, exactly as fast.sh clears it, so a row run
#     through the comparison cannot reach the operator vault or ledger while the same row under fast.sh
#     cannot either. The names removed are printed in the row log, so the answer says what was taken away.
#   * the row runs under the WATCHDOG (scripts/lib/fast-watchdog.sh): its own process group, a deadline, and
#     a hung row named instead of a bare 124 that reads like a failed assertion.
wa_row_at_sha_run() { # <bin> <tree-root> <row> <scratch> [seconds] -> prints the row exit code
  local bin=$1 root=$2 row=$3 scratch=$4 seconds=${5:-${WA_FAST_ROW_SECONDS:-120}} home log code name
  name=$(printf '%s' "$row" | tr '/.' '__')
  home="$scratch/home-$name"
  mkdir -p "$home/.wasm-agent" || { printf '2'; return 0; }
  log="$scratch/$name.log"
  local -a cleared=()
  local one
  while IFS= read -r one; do cleared+=(-u "$one"); done < <(
    env | sed -n 's/^\(WASM_AGENT_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(WA_MESH[A-Za-z0-9_]*\)=.*/\1/p' |
      grep -vx -e WASM_AGENT_LUA_ROOT -e WASM_AGENT_HOME)
  local cleared_names=""
  for one in ${cleared[@]+"${cleared[@]}"}; do [ "$one" = -u ] || cleared_names="$cleared_names,$one"; done
  printf 'row_at_sha: %s runs with WASM_AGENT_HOME=%s, LUA_ROOT=%s, watchdog %ss, cleared:%s\n' \
    "$row" "$home" "$root" "$seconds" "${cleared_names:- nothing}" >> "$log"
  if [ -f "$root/scripts/lib/fast-watchdog.sh" ]; then
    ( cd "$root" && . "$root/scripts/lib/fast-watchdog.sh" && \
        wa_fast_watchdog "$seconds" "row-at-sha $row" -- env ${cleared[@]+"${cleared[@]}"} \
          WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$root" WA_SCRIPT="$row" WASM_AGENT_MANAGED=0 \
          WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= "$bin" --db "$home/.wasm-agent/ledger.db" ) >> "$log" 2>&1
  else
    # NO WATCHDOG IN THAT TREE: the row still runs, and the log SAYS so - a silent difference between the
    # two sides of the comparison would be the answer lying about what it measured.
    printf 'row_at_sha: no scripts/lib/fast-watchdog.sh at %s, so this side ran WITHOUT the watchdog\n' "$root" >> "$log"
    ( cd "$root" && env ${cleared[@]+"${cleared[@]}"} WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$root" \
        WA_SCRIPT="$row" WASM_AGENT_MANAGED=0 WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= \
        "$bin" --db "$home/.wasm-agent/ledger.db" ) >> "$log" 2>&1
  fi
  code=$?
  printf '%s' "$code"
}

# The whole comparison: a detached worktree of the base commit, the row there, the row here, one verdict.
#
# Prints one field per line so a shell can read it (class=, base_code=, change_code=, binary=) and one human
# line at the end. Nothing is written inside the tree under test: the base worktree and both scratch homes
# live beside the repo, and they are removed on every exit path.
wa_row_at_sha() { # <sha> <row> [repo-root]
  local sha=${1-} row=${2-} repo=${3:-$(pwd)}
  local scratch base_tree bin base_code change_code class meaning name
  case "$sha" in ''|*[!0-9a-fA-F]*) printf 'refused(row_at_sha_bad_commit): %q is not a commit sha\n' "$sha" >&2; return 2 ;; esac
  [ -n "$row" ] || { printf 'refused(row_at_sha_row_required): name the row to run\n' >&2; return 2; }
  [ -f "$repo/$row" ] || { printf 'refused(row_at_sha_row_missing): %s is not a file in %s\n' "$row" "$repo" >&2; return 2; }
  bin="${WA_BIN:-}"
  if [ -z "$bin" ]; then
    bin="$repo/rust/target/release/wa"
    [ -x "$bin" ] || bin="$(command -v wa || true)"
  fi
  [ -n "$bin" ] && [ -x "$bin" ] || { printf 'refused(row_at_sha_binary_missing): no wa binary to run the row with (WA_BIN, or a wa on PATH)\n' >&2; return 2; }
  scratch="$(wa_row_at_sha_root "$repo")"
  rm -rf "$scratch"; mkdir -p "$scratch" || { printf 'refused(row_at_sha_scratch_failed): cannot create %s\n' "$scratch" >&2; return 2; }
  base_tree="$scratch/base"
  # The cleanup is one function and it runs on every exit path, including a refusal below: a base worktree
  # left behind is the leak this round already fixed once (item 6).
  # The trap body runs after this function returned, so it cannot read its locals: it reads the two
  # names it needs from the caller environment it was handed, never from a variable that went out of
  # scope (measured: `repo: unbound variable` on the way out).
  WA_ROW_AT_SHA_REPO="$repo" WA_ROW_AT_SHA_SCRATCH="$scratch"
  cleanup_row_at_sha() {
    git -C "$WA_ROW_AT_SHA_REPO" worktree remove --force "$WA_ROW_AT_SHA_SCRATCH/base" >/dev/null 2>&1
    rm -rf "$WA_ROW_AT_SHA_SCRATCH"
  }
  # THE CALLER'S EXIT TRAP IS PUT BACK, NOT REPLACED (item 8): this is a LIBRARY, and a test that sources
  # it to use the classifier already has a cleanup trap of its own. Measured: installing this one silently
  # dropped the caller's, so a sourced test left its scratch directory behind. `trap -p EXIT` is saved here
  # and restored by every return path (and the script form restores an empty one, which is no trap).
  local caller_trap
  caller_trap="$(trap -p EXIT)"
  # CLEANING UP AND RESTORING THE CALLER ARE ONE STEP, NOT TWO (item 8 of the node-ops round). Measured:
  # restoring the caller's trap on its own REMOVED this function's cleanup trap and never ran it, so every
  # completed comparison left its base worktree and scratch directory behind - the leak item 6 fixed,
  # reintroduced by the fix that was meant to keep a sourced caller's trap. finish_row_at_sha runs the
  # cleanup FIRST, then puts the caller's trap back, then answers the exit code.
  finish_row_at_sha() { # <exit-code> -> returns it
    local code=$1
    cleanup_row_at_sha
    if [ -n "$caller_trap" ]; then eval "$caller_trap"; else trap - EXIT; fi
    return "$code"
  }
  trap cleanup_row_at_sha EXIT
  if ! git -C "$repo" worktree add --detach "$base_tree" "$sha" > "$scratch/worktree.log" 2>&1; then
    printf 'refused(row_at_sha_worktree_failed): could not check out %s beside %s: %s\n' "$sha" "$repo" "$(tail -1 "$scratch/worktree.log")" >&2
    finish_row_at_sha 2; return 2
  fi
  [ -f "$base_tree/$row" ] || { printf 'refused(row_at_sha_row_absent_at_base): %s does not exist at %s, so there is nothing to run there\n' "$row" "$sha" >&2; finish_row_at_sha 2; return 2; }
  printf 'row_at_sha: base %s and change %s, row %s\n' "$(printf '%s' "$sha" | cut -c1-12)" "$repo" "$row"
  base_code="$(wa_row_at_sha_run "$bin" "$base_tree" "$row" "$scratch/home")"
  change_code="$(wa_row_at_sha_run "$bin" "$repo" "$row" "$scratch/home")"
  class="$(wa_row_at_sha_classify "$base_code" "$change_code")"
  meaning="$(wa_row_at_sha_meaning "$class")"
  printf 'class=%s\nbase_code=%s\nchange_code=%s\nbinary=%s\n' "$class" "$base_code" "$change_code" "$bin"
  printf 'row_at_sha: %s: base exit %s, change exit %s - %s\n' "$class" "$base_code" "$change_code" "$meaning"
  # The exit code answers ONE question: did the comparison complete, and did the change break the row?
  # It does not encode the mission verdict, because that is what `class=` is for and a caller reading an
  # exit code for it would confuse "the tool ran" with "the change repaired something".
  #   0  a verdict was produced (any class, including still_passing and fixed)
  #   1  the row passes at the base and FAILS here: the change broke it
  #   2  refused, nothing was compared
  if [ "$class" = new_failure ]; then finish_row_at_sha 1; return 1; fi
  finish_row_at_sha 0; return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  wa_row_at_sha "$@"
fi
