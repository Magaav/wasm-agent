#!/usr/bin/env bash
# The Lua tree a node LOADS: which files it is, and the digest that names that exact set.
#
# WHY THIS IS A LIB AND NOT A LINE IN deploy.sh. `scripts/deploy.sh` stages `lua-core/` from a list it
# used to spell inline (`find lua/core lua/vendor -type f \( -name '*.lua' -o -name '*.sql' \)` plus the
# two embedded AGENTS documents), and the release record a Lua-only round publishes has to describe the
# SAME set - a record over a slightly different list would certify a tree the node does not run, which
# is worse than no record. One definition, two callers (scripts/deploy.sh, scripts/publish-lua-tree.sh),
# and `scripts/test-land-signing.sh` refuses a deploy.sh that no longer uses it.
#
# The digest is over paths and content, schema-tagged like `wa_compiled_inputs_digest` and for the same
# reason: reclassifying the set must invalidate old records instead of silently re-matching.
#
# Sourced by scripts/deploy.sh and scripts/publish-lua-tree.sh after scripts/lib/node-binaries.sh (it
# uses that file's `wa_node_sha256`, the one sha256-tool detection in this tree). Sourcing it twice is
# harmless, so the guard is "is the function already here", not a variable a caller must remember to set.
if ! command -v wa_node_sha256 >/dev/null 2>&1; then
  . "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/node-binaries.sh"
fi

WA_LUA_TREE_SCHEMA='wasm-agent-lua-tree/1'

# <repo> -> the shipped tree's paths, one per line, LC_ALL=C sorted. A path that does not exist is
# printed anyway (the caller's copy/sha step then fails by name) - this function answers "which paths",
# never "are they all here".
wa_lua_tree_files() {
  local root="${1:-}"
  ( cd "$root" 2>/dev/null || exit 1
    { find lua/core lua/vendor -type f \( -name '*.lua' -o -name '*.sql' \) 2>/dev/null
      printf '%s\n' AGENTS.orchestrator.md AGENTS.subagents.md
    } | LC_ALL=C sort )
}

# <repo> [commit] -> sha256 over `<schema>` + one `<path> <sha256 of its content>` line per shipped path,
# on stdout. With a commit, the paths and their blobs come from THAT commit's tree (git ls-tree), so a
# record can be made for a landed commit from any checkout; without one, from the working tree through
# `git cat-file` on HEAD's index... no: without a commit it reads the files on disk, which is what a
# deploy stages. 2 when the commit is unknown, 7 when no sha tool exists.
wa_lua_tree_digest() {
  local root="${1:-}" commit="${2:-}" path blob
  [ -n "$root" ] || return 2
  if [ -n "$commit" ]; then
    git -C "$root" rev-parse --verify -q "${commit}^{commit}" >/dev/null 2>&1 || return 2
    {
      printf '%s\n' "$WA_LUA_TREE_SCHEMA"
      wa_lua_tree_files "$root" | while IFS= read -r path; do
        [ -n "$path" ] || continue
        blob="$(git -C "$root" ls-tree -r --full-tree "$commit" -- "$path" 2>/dev/null | awk '{print $3}' | head -1)"
        [ -n "$blob" ] || continue
        printf '%s %s\n' "$path" "$blob"
      done
    } | wa_node_sha256_stdin
    return
  fi
  {
    printf '%s\n' "$WA_LUA_TREE_SCHEMA"
    wa_lua_tree_files "$root" | while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ -f "$root/$path" ] || continue
      printf '%s %s\n' "$path" "$(wa_node_sha256 "$root/$path")"
    done
  } | wa_node_sha256_stdin
}

# <manifest> -> the `lua_inputs=` row of a Lua-tree release record, or nothing. A record written before
# the row existed answers nothing, which the caller reads as "cannot be verified", never as "unchanged".
wa_lua_tree_manifest_value() { # <manifest> <field>
  [ -f "${1:-}" ] || return 1
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1 | tr -d '[:space:]'
}
