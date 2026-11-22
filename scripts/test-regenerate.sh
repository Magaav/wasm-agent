#!/usr/bin/env bash
# The merge-time regeneration (scripts/regenerate.sh + scripts/generators.txt): a derived file cannot go
# stale - and cannot stop a landing with a conflict - when two branches that are each correct alone meet.
#
# WHY A ROW FOR THIS. 21/11: land243 added lua/core/agent_control.lua and its refusal codes, land244 was
# green (its narrowed gate never ran the refusal row), and main was red from bfad4f8f on
# `lua5.4 scripts/gen-refusal-codes.lua --check` for the next landings - every innocent mission whose rows
# included scripts/test-refusal-contract.lua paid for it (land245 went red twice, 855 s, then sat stopped
# for 40+ minutes). No worker could have prevented it: the stale file only exists in the MERGE of two
# correct branches. So this row replays exactly that merge, with the REAL generator over a copy of this
# tree's lua/ and rust/wa-capabilities/src. No node, no cargo, no build, no network, a few seconds.
#
# The replay also found the second half of the incident, which the 21/11 report did not have: two branches
# that BOTH regenerate the same derived file conflict in it, so the merge stops on a file no person wrote.
# The registry therefore declares each generator's OUTPUT (the landing resolves a conflict only in paths
# declared there, lua/core/land.lua M.merge), and this row proves the sequence the landing runs.
#
#   bash scripts/test-regenerate.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v lua5.4 >/dev/null 2>&1 || { echo "SKIP test-regenerate: lua5.4 is not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP test-regenerate: git is not on PATH"; exit 0; }
# A tree without the runner or the registry has nothing to judge: named as a skip, not as a pass and not as a
# failure (scripts/test-discriminates.sh reads it that way).
[ -f "$root/scripts/regenerate.sh" ] && [ -f "$root/scripts/generators.txt" ] \
  || { echo "SKIP test-regenerate: this tree has no scripts/regenerate.sh or scripts/generators.txt (nothing to judge)"; exit 0; }

# ITS OWN HOME, AND IT REFUSES THE OPERATOR'S (rule 2): this row writes repositories and runs generators,
# and it must never do either inside the operator's node store. The scratch directory is made where a
# scratch directory belongs (TMPDIR=/tmp): on this machine the inherited TMPDIR points inside
# ~/.wasm-agent, and a fixture under it would be exactly the write this guard exists to prevent.
work=$(TMPDIR=/tmp mktemp -d) || { echo "SKIP test-regenerate: mktemp failed"; exit 0; }
trap 'rm -rf "$work"' EXIT
export HOME=$work/user WASM_AGENT_HOME=$work/node TMPDIR=$work/tmp
mkdir -p "$HOME" "$WASM_AGENT_HOME" "$TMPDIR"
operator_home=${OPERATOR_NODE_HOME:-/home/$(id -un)/.wasm-agent}
case "$work" in
  "$operator_home"|"$operator_home"/*) echo "test-regenerate: refused(real_node_home): $work is the operator's node home" >&2; exit 2 ;;
esac

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "test-regenerate FAILED: $*" >&2; exit 1; }
git_c() { git -c user.email=test@example.invalid -c user.name=Test -c commit.gpgsign=false "$@"; }

repo="$work/replay"
mkdir -p "$repo"
# THE REAL TREE under test: the Lua modules the inventory scans, the generator, the runner and the registry.
cp -a "$root/lua" "$repo/lua" || fail "cannot copy lua/ into the replay"
mkdir -p "$repo/scripts" "$repo/rust/wa-capabilities"
cp "$root/scripts/gen-refusal-codes.lua" "$root/scripts/regenerate.sh" "$root/scripts/generators.txt" "$repo/scripts/" \
  || fail "cannot copy the generator and the runner into the replay"
cp -a "$root/rust/wa-capabilities/src" "$repo/rust/wa-capabilities/src" || fail "cannot copy rust/wa-capabilities/src"
cd "$repo" || fail "cannot cd into the replay"
git_c init -q -b main . || fail "git init"
git_c add -A >/dev/null && git_c commit -q -m base || fail "the base commit"

check_rc() { lua5.4 scripts/gen-refusal-codes.lua --check >/dev/null 2>&1; echo $?; }

[ "$(check_rc)" = 0 ] || fail "the copied base tree is already stale: the copy is not what this row proves"
ok
# The registry declares the output, and the runner answers with it: the landing has no other way to know
# which conflicted paths are safe to resolve by regenerating.
out=$(bash scripts/regenerate.sh --outputs)
grep -qx 'lua/core/refusal_codes.lua' <<< "$out" || fail "the registry does not declare the inventory as an output: $out"
ok
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "--outputs printed more than the one declared output: $out"
ok

# ---- the replay: two branches, one refusal code each, in DIFFERENT modules, each green alone -----------
# A code is the literal right-hand side of an `error` field (scripts/gen-refusal-codes.lua, codes_of), so
# one inert table line in a reachable module is exactly what a worker adds - and, like a worker, the
# branch regenerates in its own tree, so each branch is green alone.
add_code() {  # <module> <code> <branch>
  local module=$1 code=$2 branch=$3
  git_c checkout -q -b "$branch" main || fail "cannot branch $branch"
  printf "\n-- replay (%s): a refusal code this branch adds\nlocal replay_%s = { error = '%s' }\n" \
    "$branch" "$code" "$code" >> "$module" || fail "cannot append to $module"
  lua5.4 scripts/gen-refusal-codes.lua --write >/dev/null 2>&1 || fail "$branch: the generator failed"
  [ "$(check_rc)" = 0 ] || fail "$branch is not green alone, so the replay proves nothing"
  git_c add -A >/dev/null && git_c commit -q -m "$branch: one refusal code" || fail "$branch: commit"
  git_c checkout -q main || fail "cannot return to main"
}
module_a=lua/core/done_gate.lua
module_b=lua/core/history_search.lua
[ -f "$module_a" ] && [ -f "$module_b" ] || fail "the replay modules are gone from this tree: pick two reachable ones"
grep -q "done_gate.lua" lua/core/refusal_codes.lua || fail "lua/core/done_gate.lua is not in the reachable closure any more"
grep -q "history_search.lua" lua/core/refusal_codes.lua || fail "lua/core/history_search.lua is not in the reachable closure any more"
add_code "$module_a" replay_alpha replay/alpha
add_code "$module_b" replay_beta replay/beta
ok

# ---- the merge of both: the derived file goes STALE, and the runner is what repairs it ------------------
git_c merge -q --no-ff --no-edit replay/alpha >/dev/null || fail "merge alpha"
[ "$(check_rc)" = 0 ] || fail "one branch alone made the merged tree stale: the replay is not the incident"
ok
git_c merge -q --no-ff --no-edit -m "merge beta" replay/beta >/dev/null 2>&1
unmerged=$(git ls-files -u | awk '{print $4}' | sort -u)
# THE SECOND HALF OF THE INCIDENT: two branches that both regenerated the same file conflict in it. The
# landing resolves that one file ONLY because the registry declares it as a generated output - and this
# row proves the sequence it runs there (checkout ours, stage, commit, regenerate, amend).
if [ -n "$unmerged" ]; then
  [ "$unmerged" = lua/core/refusal_codes.lua ] || fail "the conflict is not only the declared output: $unmerged"
  ok
  git_c checkout --ours -- lua/core/refusal_codes.lua || fail "cannot take ours for the generated file"
  git_c add lua/core/refusal_codes.lua && git_c commit -q --no-edit || fail "cannot finish the merge commit"
else
  # No conflict: the two hunks were far enough apart. Then the file is simply stale, which is the case the
  # 21/11 report measured, and the same regeneration repairs it.
  ok
fi
[ "$(check_rc)" = 1 ] || fail "after merging both clean branches the inventory is NOT stale, so this row proves nothing"
ok

out=$(bash scripts/regenerate.sh 2>&1); rc=$?
[ "$rc" = 0 ] || fail "regenerate.sh exited $rc on a tree it must repair: $out"
ok
grep -q '^regenerate: changed lua/core/refusal_codes.lua$' <<< "$out" || fail "the runner did not name the file it wrote: $out"
ok
grep -q '^regenerate: changed_count 1$' <<< "$out" || fail "the runner did not count what it wrote: $out"
ok
grep -q "replay_alpha" lua/core/refusal_codes.lua || fail "the written inventory does not carry alpha"
grep -q "replay_beta" lua/core/refusal_codes.lua || fail "the written inventory does not carry beta"
ok
[ "$(check_rc)" = 0 ] || fail "the inventory is STILL stale after the runner wrote it"
ok
# The merge commit carries the fresh file - the landing amends its own merge commit, so the tip main sees
# is green without a second commit nobody asked for.
git_c add -A >/dev/null && git_c commit -q --amend --no-edit -a || fail "cannot amend the merge commit"
git_c show HEAD:lua/core/refusal_codes.lua | grep -q "replay_beta" || fail "the amended commit does not carry the fresh inventory"
ok
[ -z "$(git status --porcelain)" ] || fail "the amended tree is dirty: $(git status --porcelain | head -3)"
ok
# IDEMPOTENT: a second run writes nothing, which is what tells the merge not to amend at all.
out=$(bash scripts/regenerate.sh 2>&1); rc=$?
[ "$rc" = 0 ] || fail "the second run exited $rc: $out"
grep -q '^regenerate: changed_count 0$' <<< "$out" || fail "the second run wrote files again (not idempotent): $out"
ok

# ---- a failing generator, and a line that lies about its output, are FAILURES by name ------------------
mkdir -p "$work/failing" && cd "$work/failing" || fail "cannot enter the failing case"
mkdir -p scripts && git_c init -q -b main . && printf 'x\n' > a.txt && git_c add -A >/dev/null && git_c commit -q -m base \
  || fail "the failing case needs a repository"
cp "$root/scripts/regenerate.sh" scripts/regenerate.sh || fail "cannot copy the runner"
printf 'a.txt = bash -c "exit 7"\na.txt = true\nmissing.txt = true\n' > scripts/generators.txt
out=$(bash scripts/regenerate.sh 2>&1); rc=$?
[ "$rc" = 1 ] || fail "a failing generator did not fail the run (exit $rc): $out"
ok
grep -q 'regenerate: FAILED bash -c "exit 7" (exit 7)' <<< "$out" || fail "the failure does not name the generator: $out"
ok
grep -q "declared output 'missing.txt' does not exist" <<< "$out" || fail "a line that lies about its output passes: $out"
ok
grep -q 'regenerate: 2 generator line(s) FAILED' <<< "$out" || fail "the failure count is not reported: $out"
ok

# ---- unknown is not yes: outside a worktree there is no way to tell what was written -------------------
mkdir -p "$work/plain" && cp "$root/scripts/regenerate.sh" "$work/plain/" || fail "cannot set up the plain case"
out=$(cd "$work/plain" && bash regenerate.sh 2>&1); rc=$?
[ "$rc" = 2 ] || fail "a tree that is not a worktree was not refused (exit $rc): $out"
ok
grep -q 'refused(not_a_worktree)' <<< "$out" || fail "the refusal is not named: $out"
ok

# ---- a tree that declares no derived file says so, instead of looking clean ----------------------------
mkdir -p "$work/noreg/scripts" && cd "$work/noreg" || fail "cannot enter the no-registry case"
git_c init -q -b main . && printf 'x\n' > a.txt && git_c add -A >/dev/null && git_c commit -q -m base || fail "the no-registry case needs a repository"
cp "$root/scripts/regenerate.sh" scripts/regenerate.sh
out=$(bash scripts/regenerate.sh 2>&1); rc=$?
[ "$rc" = 0 ] || fail "a missing registry was made an error (exit $rc): $out"
ok
grep -q 'no registry at scripts/generators.txt' <<< "$out" || fail "a missing registry is silent: $out"
ok
grep -q '^regenerate: changed_count 0$' <<< "$out" || fail "a missing registry does not answer the count: $out"
ok

# ---- THE REGISTRY ITSELF: exactly the generators that are pure functions of the tree -------------------
cd "$root" || fail "cannot return to the tree"
lines=$(sed -n '/^[[:space:]]*[^#[:space:]]/p' scripts/generators.txt | grep -c .)
[ "$lines" -ge 1 ] || fail "scripts/generators.txt lists no generator: the merge would regenerate nothing"
ok
grep -qx 'lua/core/refusal_codes.lua = lua5.4 scripts/gen-refusal-codes.lua --write' scripts/generators.txt \
  || fail "the refusal inventory is not a registered generator: the 21/11 staleness is back"
ok
# A golden is an approval, and a generator that reads an installed binary is not a function of the tree.
# Only the COMMANDS count: the registry's own comments name both, with the reason they are out.
commands=$(sed -n '/^[[:space:]]*[^#[:space:]]/p' scripts/generators.txt)
grep -q 'gen-balloon' <<< "$commands" && fail "a balloon golden is registered as a generator (a golden is an approval)"
ok
grep -q 'sync-prompt-docs.sh --write' <<< "$commands" \
  && fail "sync-prompt-docs is registered: it writes whatever the installed wa produces, not what this tree does"
ok

echo "test-regenerate ok ($checks checks)"
