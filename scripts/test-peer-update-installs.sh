#!/usr/bin/env bash
# A PEER CAN INSTALL WHILE THE FACTORY LANDS, AND A FAILED COMPONENT PROOF SAYS WHAT FAILED (P0, work 27/11).
#
# Attempt 2 refused `canonical_busy` after 600 s: the deploy demanded HEAD == origin/main, and the factory lands every
# ~10 minutes, so a tree whose deploy fetches can never satisfy it. The rule the deploy needs is ancestry.
# Attempt 1 refused `component_proof_failed` with one sentence for two different failures and named no component.
#
# Both are predicates, and both are asserted here against the real code, not against a copy:
#   1. the gate condition (git merge-base --is-ancestor) on a tree that is ON main but BEHIND its tip;
#   2. the proof announces its section before the first thing that can fail, and the failure names the reason.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# NO OWNER PATH IN A ROW (landing queue, 27/11: the private-data gate refused this branch because the default below
# named the owner's home - a row that carries somebody's filesystem is not a row another machine can run). WA_BIN when
# the caller has one, else the tree's own build, else a named skip.
BIN=${WA_BIN:-$ROOT/rust/target/release/wa}
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"
W=$(mktemp -d "$TMPBASE/wa-peer.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
cleanup() { if [ "$failed" -gt 0 ]; then printf 'peer row: scratch kept at %s\n' "$W"; else rm -rf "$W"; fi }
trap cleanup EXIT

# ---- 1. a tree ON main that is not its tip ------------------------------------------------------
git init -q --bare "$W/o.git"; git -C "$W/o.git" symbolic-ref HEAD refs/heads/main
git init -q "$W/t"; cd "$W/t"
git config user.email row; git config user.name row
echo a > f; git add f; git commit -qm A; git branch -M main; git remote add origin "$W/o.git"; git push -q origin main
A=$(git rev-parse HEAD)
git init -q "$W/o2"; cd "$W/o2"; git config user.email row; git config user.name row
git remote add origin "$W/o.git"; git fetch -q origin; git checkout -q -B main origin/main
echo b >> f; git commit -qam B; git push -q origin main
cd "$W/t"; git fetch -q origin
M=$(git rev-parse origin/main)
[ "$A" != "$M" ] || bad 'the fixture did not move origin/main'
[ "$A" = "$M" ] && bad 'fixture: the tree is already the tip, so equality would also pass' \
  || ok 'fixture: the tree is one commit behind origin/main (equality would refuse it)'
if git merge-base --is-ancestor "$A" "$M"; then ok "the gate's condition accepts a tree on main but behind its tip (${A:0:8} < ${M:0:8})"; else bad 'ancestry refused a main commit'; fi
# and a commit that is NOT on main is still refused - the rule has a direction
cd "$W/t"; git checkout -q -B side "$A"; echo c > g; git add g; git commit -qm side-only; SIDE=$(git rev-parse HEAD)
if git merge-base --is-ancestor "$SIDE" "$M"; then bad 'a commit that is not on main passed the ancestry test'; else ok 'a commit that is not on main is still refused'; fi

# ---- 2. the component proof names what failed ------------------------------------------------------
[ -x "$BIN" ] || { echo 'peer row: SKIP the proof half (no wa binary: set WA_BIN)'; printf 'peer update installs: %s checks, %s failed\n' "$checks" "$failed"; exit $([ "$failed" -eq 0 ] && echo 0 || echo 1); }
mkdir -p "$W/stage" "$W/home"
WA_COMPONENTS_DIR="$W/stage" WASM_AGENT_HOME="$W/home" WASM_AGENT_MANAGED=0 WA_SCRIPT="$ROOT/scripts/check-component-proof.lua" \
  env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY -u WA_GRAPH_ROOT -u WA_GRAPH_DB \
  "$BIN" --db "$W/home/proof.db" > "$W/proof.log" 2>&1
rc=$?
[ "$rc" != 0 ] && ok 'with no staged component the proof fails (the shape work hit)' || bad 'the proof passed with no staged component'
STEPS="$(grep -c 'component proof step:' "$W/proof.log" 2>/dev/null || echo 0)"
[ "$STEPS" -ge 1 ] && ok "the proof announces the section before it fails (${STEPS} step line)" || bad 'the proof printed no step, so the refusal cannot name the component'
grep -q 'component proof step: the default-on memory component' "$W/proof.log" \
  && ok 'and the step names the COMPONENT (memory) and the call' || bad 'the step does not name memory'
grep -q 'memory is not routed to a component' "$W/proof.log" \
  && ok 'the proof own reason is in the log the refusal quotes' || bad 'the reason is missing from the proof log'

printf 'peer update installs: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'peer update installs ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
