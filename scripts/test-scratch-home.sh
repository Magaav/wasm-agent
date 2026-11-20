#!/usr/bin/env bash
# The real-home guard, judged: the rule every test that hands a node a home rests on.
#
# Item 4 of the node-ops round (19/11). WASM_AGENT_HOME is the USER home
# (rust/wa-host-support/src/paths.rs:12), and the node's store hangs off it as <home>/.wasm-agent. The
# guards used to compare a scratch home against $HOME/.wasm-agent - the wrong side - so a scratch home of
# $HOME passed while the node wrote the operator's real store. This test says which side is right, in
# both directions, and it is the check the other tests' guards are read against.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
fail() { printf 'test-scratch-home: %s\n' "$*" >&2; exit 1; }
checks=0
ok() { checks=$((checks + 1)); }

. scripts/lib/scratch-home.sh
command -v wa_scratch_home_guard >/dev/null 2>&1 || fail 'scripts/lib/scratch-home.sh defines no wa_scratch_home_guard'

# A fake operator home, so the assertions below are about the RULE and not about whoever runs this.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-scratch-home-test-XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/operator/.wasm-agent" "$WORK/scratch/home" || fail 'cannot make the fixture directories'

refused() { # <path> <what>
  if HOME="$WORK/operator" wa_scratch_home_guard "$1" 2>/dev/null; then
    fail "$2: the guard ACCEPTED $1, which is the operator home or inside or above its store"
  fi
  ok
}
accepted() { # <path> <what>
  if ! HOME="$WORK/operator" wa_scratch_home_guard "$1" 2>/dev/null; then
    local why; why="$(HOME="$WORK/operator" wa_scratch_home_guard "$1" 2>&1)"
    fail "$2: the guard refused $1 ($why) - a scratch home that is none of the operator's must pass"
  fi
  ok
}

# The four refusals, each a different way of being the operator's.
refused "" 'no home named'
refused "$WORK/operator" 'the operator home itself: the node store would BE ~/.wasm-agent'
refused "$WORK/operator/.wasm-agent" 'the operator store itself'
refused "$WORK/operator/.wasm-agent/tmp" 'inside the operator store: this node TMPDIR is exactly that'
refused "$WORK" 'above the operator store: a home that contains it is the same store'
refused "relative/home" 'a relative path: where it points depends on the caller cwd'
# The acceptance: a scratch tree, wherever it is, that is none of the above.
accepted "$WORK/scratch/home" 'a scratch home beside the fixture'
accepted "$WORK/operator-work/home" 'a directory whose NAME starts like the operator home is not the operator home'

# The refusal names its reason, so a failing test says which rule refused it.
msg="$(HOME="$WORK/operator" wa_scratch_home_guard "$WORK/operator" 2>&1)"
case "$msg" in *real_node_home*) ;; *) fail "a refusal did not name real_node_home: $msg" ;; esac
ok

# wa_scratch_root never hands back the operator store - on this node TMPDIR IS inside it (measured 19/11),
# so a plain mktemp -d would put every fixture in the real node.
root="$(HOME="$WORK/operator" TMPDIR="$WORK/operator/.wasm-agent/tmp" wa_scratch_root x 2>/dev/null)" || fail 'wa_scratch_root found no root outside the operator store'
case "$root/" in "$WORK/operator/.wasm-agent"/*) fail "wa_scratch_root returned a directory inside the operator store: $root" ;; esac
ok

# THE SIDE THAT WAS WRONG, asserted directly: with the old comparison the operator's own store PASSED.
# This is the regression the item is about, so it is stated as a case and not left to a comment.
if HOME="$WORK/operator" wa_scratch_home_guard "$WORK/operator/.wasm-agent" 2>/dev/null; then
  fail 'a store path passed the guard: this is the defect of item 4 - the guard compared the wrong side'
fi
ok

printf 'test-scratch-home: ok (%d checks: the operator home, its store, anything inside or above it and a relative path are refused; a scratch home is accepted, and a scratch root is never inside the store)\n' "$checks"
