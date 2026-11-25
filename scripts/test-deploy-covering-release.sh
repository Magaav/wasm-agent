#!/usr/bin/env bash
# A NODE ON AN OLD BINARY UPDATES TO A SCRIPTS-ONLY COMMIT, FROM THAT COMMIT'S COVERING RELEASE (24/11, work).
#
# WHAT WAS MEASURED (work, Victor's `wa update`, 22:17:09Z; Fable read it): deploy.sh from 4bceddd5 took the
# covering release node-39e862d60bad ("this commit changes no compiled input"), installed the 4bceddd5 Lua tree,
# fetched components-df6f97708c72, proved, swapped and restarted the node on build 39e862d6 - and THEN refused:
#
#   refused(build_commit_mismatch): the binary installed ... reports commit 39e862d60bad but this deploy meant to
#   install 4bceddd58ab7 ... Nothing was recorded            (exit 1, 94.4 s)
#
# installed.txt stayed the INTERIM record (commit=39e862d6, no lua_tree=, no binary_commit=) and the scripts were
# never shipped. The node ran new bytes nobody had recorded. Every fleet node hits this on any landing whose
# binary must change to a covering build; the laptop cannot (LUA_FAST keeps its binary on a scripts-only landing).
#
# WHAT RUNS HERE - the REAL scripts/deploy.sh, end to end, on a scratch node:
#   * the tree: a clean worktree at this branch's HEAD (C2). Its compiled inputs are unchanged since the newest
#     published release (C1), so the deploy's own resolver takes C1's COVERING release - the row asserts the
#     `binary_release:` line says so, and SKIPS by name if this commit ever has a release of its own;
#   * the install: a scratch install directory on C1's BINARY with work's INTERIM record (commit=C1,
#     record_role=interim, no lua_tree=, no binary_commit=, no scripts of its own) - so item 4's repair ("the
#     NEXT update completes the record and ships the scripts, with no manual step") is the same measurement;
#   * and it must come out the other side: exit 0; installed.txt commit=C2, lua_tree=C2, binary_commit=C1,
#     record_role=final; the scripts shipped; `wa --version` naming v<C1> and tree <C2>; verify-install green.
#
# RED ON MAIN TODAY: with the code before this branch the deploy refuses AFTER the swap and leaves the interim
# record (measured in a worktree of main, see the report).
#
# Scratch only: its own root, its own HOME, its own install directory, its own port, a service-unit path that
# does not exist (WA_SERVICE_UNIT_FILE), no vault and no branch state touched. The node it starts is stopped by
# the pid the install records - never by name. The old binary comes from the published release and is verified
# by scripts/lib/node-binaries.sh, so nothing is built and nothing is published.
#
#   bash scripts/test-deploy-covering-release.sh
#
# Exit: 0 green; 1 a check failed; 3 SKIP (a named reason: no published covering release, or this test is inside
# a node turn, where the deploy's own turn guard refuses before it starts).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/service-target.sh"
. "$ROOT/scripts/lib/node-binaries.sh"

root="$(wa_scratch_root wa-deploy-covering)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
NODE_PID=""
cleanup() {
  [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
  git -C "$ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true
  chmod -R u+w "$W" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
REAL_HOME="${HOME:-}"
export HOME="$W/home"
mkdir -p "$HOME"
HOME="$REAL_HOME" wa_scratch_home_guard "$W/home" || exit 2
export WASM_AGENT_HOME="$HOME"
unset WASM_AGENT_RENDEZVOUS WASM_AGENT_RELAY WA_GRAPH_ROOT WA_GRAPH_DB WA_COMPONENTS_DIR WA_COMPONENT_RELEASE_URL

checks=0; failed=0; skipped=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip_all() { printf 'SKIP test-deploy-covering-release: %s\n' "$1"; exit 3; }

for tool in git curl gh python3; do
  command -v "$tool" >/dev/null 2>&1 || skip_all "$tool is not on PATH (this row asks the real release channel)"
done

# THE COMMITS. C2 is this branch's tree committed onto a base, in a fixture clone below; C1 is the newest
# published release whose compiled-inputs digest is C2's, chosen by the DEPLOY'S OWN resolver (never by this
# row). The BASE is origin/main when a release covers it, else the source commit of the newest published
# releases in turn: a release is published per landing, so main can be a few commits past the newest one, and
# a row that only tried main would skip every time a compiled input landed before its binary did.
SLUG="$(wa_node_release_repo "$ROOT")" || skip_all "no owner/repo for the node release"
TRIPLE="$(wa_node_target_triple 2>/dev/null)" || skip_all "this host has no published node-binary target"
CACHE="$W/node-binaries"
covers() { # <commit> -> 0 when a published release has this commit's compiled inputs
  WA_NODE_RELEASE_DIGEST_SECONDS=8 wa_node_release_digest_search "$ROOT" "$1" "$TRIPLE" "$CACHE" >/dev/null 2>&1
}
BASE="$(git -C "$ROOT" rev-parse origin/main)"
if ! covers "$BASE"; then
  for tag in $(wa_node_release_list "$ROOT" 8); do
    cand="$(git -C "$ROOT" rev-parse --verify --quiet "${tag#node-}^{commit}" 2>/dev/null)" || continue
    if covers "$cand"; then BASE="$cand"; echo "note: origin/main has no published release yet; this row uses $BASE, the source of ${tag}"; break; fi
  done
fi
[ -n "$BASE" ] || skip_all "no published release covers origin/main or any of its recent commits"
covers "$BASE" || skip_all "no published release covers $BASE (its compiled inputs), so there is no covering install to prove"

# THE TREE (C2): a scratch clone whose REMOTE'S main is this branch's commit. A deploy requires the tree it
# runs from to be exactly origin/main and clean (step 2), so the fixture makes that true rather than arguing
# with it - and because the branch's own changes ARE the subject of the row, they are committed here as the
# fixture's C2 instead of being left in the worktree. The fixture branch is MAIN on purpose: the canonical
# runtime binding (scripts/runtime-install-binding.mjs) requires exactly ONE checkout on refs/heads/main, so a
# fixture on any other branch is refused before anything is built. scripts/, lua/ and docs/ change no compiled input, so
# C2's compiled-inputs digest is its base's, which is a published release's - so the deploy's resolver takes it.
TREE="$W/src"
git clone -q --shared "$ROOT" "$TREE" 2>/dev/null || skip_all "cannot clone this checkout into the fixture"
git -C "$TREE" switch -q -c main "$BASE" 2>/dev/null || skip_all "cannot branch the fixture at $BASE"
git -C "$ROOT" diff "$BASE"..HEAD -- scripts lua docs 2>/dev/null | git -C "$TREE" apply - 2>/dev/null \
  || skip_all "cannot apply this branch's scripts/lua/docs onto $BASE in the fixture"
# `-A`, not `-a`: the branch adds files (this row is one), and a file an apply creates is UNTRACKED - the
# fixture would then be dirty, and a deploy rightly refuses a dirty tree (measured: 600 s of waiting and
# canonical_busy with `1 uncommitted change(s)`).
git -C "$TREE" add -A 2>/dev/null || skip_all "cannot stage the fixture diff"
git -C "$TREE" -c user.email=fixture@invalid -c user.name=fixture commit -q -m "fixture C2: this branch's scripts/lua/docs on $BASE" \
  || skip_all "cannot commit the fixture C2"
C2="$(git -C "$TREE" rev-parse HEAD)"
REMOTE="$W/remote.git"
git clone -q --bare --shared "$ROOT" "$REMOTE" 2>/dev/null || skip_all "cannot create the fixture remote"
# The fixture commit lives only in the clone (the shared objects are origin/main's), so it is PUSHED into the
# fixture remote: update-ref would name an object that remote cannot see.
git -C "$TREE" push -q "$REMOTE" "main:refs/heads/main" || skip_all "cannot push the fixture C2 into the fixture remote"
git -C "$TREE" remote set-url origin "$REMOTE"
git -C "$TREE" fetch -q origin 2>/dev/null
git -C "$TREE" update-ref refs/remotes/origin/main "$C2"
[ "$(git -C "$TREE" rev-parse HEAD)" = "$(git -C "$TREE" rev-parse origin/main)" ] \
  || skip_all "the fixture tree is not exactly its origin/main, so a deploy would (rightly) refuse it"

# THE COVERING RELEASE for C2, resolved by the same library call the deploy makes.
PLAN="$(wa_node_release_digest_search "$TREE" "$C2" "$TRIPLE" "$CACHE" 2>&1)" \
  || skip_all "no published release covers $C2 (its compiled inputs): $(printf '%s' "$PLAN" | tail -1)"
C1="$(printf '%s\n' "$PLAN" | sed -n 's/^release_commit=//p' | head -1)"
[ -n "$C1" ] || skip_all "the resolver named no covering release for $C2"
[ "$C1" != "$C2" ] || skip_all "$C2 has a published release of its own, so this row has no covering install to prove"
git -C "$ROOT" cat-file -e "$C1^{commit}" 2>/dev/null || skip_all "$C1 is not in this checkout"

# THE OLD BINARY, from its published release (verified against the manifest and the signature).
BIN_DIR="$(wa_node_binary_download "$SLUG" "$C1" "$TRIPLE" "$CACHE" 2>"$W/binary.err")" || {
  skip_all "no usable published release for $C1 (it is the covering build this row installs from)"
}
# THE INSTALL LIVES UNDER THE SCRATCH HOME: a path outside $HOME is a system-wide prefix to the sentinel
# unit logic, which then refuses to start a user watcher there (measured in this row, third run).
INSTALL="$HOME/install"
mkdir -p "$INSTALL/scripts"
cp -f "$BIN_DIR/wa-$TRIPLE-${C1:0:12}" "$INSTALL/wa" || skip_all "cannot seed the old binary"
chmod +x "$INSTALL/wa" 2>/dev/null || true
OLD_SHA="$(wa_node_sha256 "$INSTALL/wa")"
# WORK'S HALF STATE, on purpose: an INTERIM record naming the bytes, with no lua_tree=, no binary_commit= and no
# scripts beside it. This is the install a later update must be able to complete (item 4).
printf 'commit=%s\nbranch=main\ndirty=unknown\nsha256=%s\ninstall_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=interim\nvia=deploy.sh\nat=%s\nreason=interrupted by refused(build_commit_mismatch) after the swap\n' \
  "$C1" "$OLD_SHA" "$INSTALL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL/installed.txt"

# ---- run the real deploy --------------------------------------------------------------------------
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
[ -n "$PORT" ] || skip_all "no free port for the scratch node"
WA_SERVICE_UNIT_FILE="$W/no-such.unit"; export WA_SERVICE_UNIT_FILE
OUT="$W/deploy.out"
# WA_DEPLOY_FULL=1 IS THE TREE'S OWN WAY TO SAY "install the tree fully", and it is what puts this row on the
# COVERING path instead of the Lua fast path. Both are correct, and they are different questions: the fast
# path keeps the installed binary (nothing compiled changed, so there is nothing to download) and never asks
# the release channel anything; the covering path is a deploy that INSTALLS a binary and therefore must take
# the newest published build of this tree's compiled inputs - which is the branch work's 22:17Z update ran,
# and the branch whose record was wrong. The row names the knob rather than pretending the two are one path.
( cd "$TREE" && env -u WASM_AGENT_IN_TURN -u WA_INSTALL_DIR -u WA_PORT \
    WA_DEPLOY_FULL=1 WA_DEPLOY_TREE_WAIT=60 \
    WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$INSTALL" WA_PORT="$PORT" \
    WA_SERVICE_UNIT_FILE="$W/no-such.unit" WA_SENTINEL_SUPERVISOR=none \
    # ^ and NO systemd user session for this scratch home: with one, the sentinel step finds the MACHINE's
    #   unit and tries to restart that (measured: "systemctl --user restart wa-sentinel.service"), so the
    #   watcher of THIS install never starts. A scratch XDG_RUNTIME_DIR makes `systemctl --user` unable to
    #   answer, and the sentinel then starts as a plain child of this row.
    XDG_RUNTIME_DIR="$W/xdg" DBUS_SESSION_BUS_ADDRESS="unix:path=$W/no-bus" \
    HOME="$HOME" WASM_AGENT_HOME="$HOME" \
    bash scripts/deploy.sh --reason "test-deploy-covering-release: a covering release must record both facts" \
    > "$OUT" 2>&1 ); rc=$?

if grep -q 'refused(canonical_busy)' "$OUT" 2>/dev/null; then
  skip_all "the fixture tree is not clean enough for a deploy to run from: $(git -C "$TREE" status --porcelain | head -3 | tr '\n' ';') "
fi
if grep -q 'cannot deploy from a turn running on the node\|needs a sentinel supervising the node' "$OUT" 2>/dev/null; then
  skip_all "the deploy's turn guard refused first (this test is running in a node turn): $(grep -m1 -oE 'cannot deploy from a turn[^.]*\.|needs a sentinel supervising the node[^)]*' "$OUT")"
fi

# The covering release is the FACT this row is about: if the resolver took this commit's OWN release, the row's
# premise is gone and it says so by name instead of passing on a different path.
if ! grep -qE "^deploy: binary_release: node-[0-9a-f]{12} ${C1}" "$OUT"; then
  if grep -q "binary_release: node-${C2:0:12}" "$OUT"; then
    skip_all "$C2 has a published release of its own, so this deploy does not take the covering one (publish nothing: this row needs a scripts-only commit after $C1)"
  fi
fi

# EXIT 0, or 3 with the WATCHER as the only recorded problem: a scratch HOME has no systemd user session, so
# a sentinel cannot start there - the deploy's fail_installed path, which now RECORDS instead of exiting with
# the install half done. Everything else must be clean, and the row says which of the two happened.
PROBLEMS="$(sed -n 's/^post_swap_problem=//p' "$INSTALL/installed.txt" 2>/dev/null | head -1)"
if [ "$rc" = 0 ]; then
  ok 1 "the deploy exits 0 on a covering release"
elif [ "$rc" = 3 ] && printf '%s' "$PROBLEMS" | grep -q sentinel && ! printf '%s' "$PROBLEMS" | grep -q '; '; then
  ok 1 "the deploy exits 3 with ONE recorded problem, the watcher a scratch home cannot start: $PROBLEMS"
else
  ok 0 "the deploy exits 0 on a covering release" "rc=$rc problems=${PROBLEMS:-none} $(tail -3 "$OUT" | tr '\n' ' ')"
fi
# The deploy prints the covering fact on its `binary_source:` line (`... verified against node-<sha12>, the
# build of <commit>; this commit changes no compiled input`); the raw `binary_release:` line is consumed to
# fill the variables and is not echoed.
ok "$(grep -qE "verified against node-${C1:0:12}([,;]|$)" "$OUT" && echo 1)" "and it took C1's covering release, as the resolver chose it" "$(grep -m1 'binary_source' "$OUT")"

REC="$INSTALL/installed.txt"
field() { sed -n "s/^$1=//p" "$REC" 2>/dev/null | head -1; }
ok "$([ "$(field record_role)" = final ] && echo 1)" "the install record is FINAL, not the interim one it started from" "record_role=$(field record_role)"
ok "$([ "$(field commit)" = "$C2" ] && echo 1)" "commit= is the tree this deploy installed (C2)" "commit=$(field commit) wanted $C2"
# lua_tree= is written from the deploy's display id (12 hex) on every path - the same commit, in the
# spelling the rest of the record already uses.
# lua_tree= is the deploy's display id - git's short form, whose length is git's business (8 here). The
# row asks that it NAME C2, which is the fact, not that it spells it the way this row does.
lua_tree="$(field lua_tree)"
ok "$([ -n "$lua_tree" ] && [ "${C2#$lua_tree}" != "$C2" ] && echo 1)" "lua_tree= names C2 (${lua_tree:-none})" "lua_tree=$lua_tree C2=$C2"
ok "$([ "$(field binary_commit)" = "$C1" ] && echo 1)" "binary_commit= is the bytes' own build (C1), not the tree" "binary_commit=$(field binary_commit) wanted $C1"
ok "$(printf '%s' "$(field binary_release)" | grep -qE '^node-[0-9a-f]{12}$' && echo 1)" "and binary_release= names the release" "binary_release=$(field binary_release)"
ok "$([ "$(field record_expected)" = "$C1" ] && echo 1)" "record_expected= keeps the commit the staged binary was proved against" "record_expected=$(field record_expected)"
# NO POST-SWAP PROBLEM but the watcher one (see the exit code above).
ok "$({ [ -z "$PROBLEMS" ] || { printf '%s' "$PROBLEMS" | grep -q sentinel && ! printf '%s' "$PROBLEMS" | grep -q '; '; }; } && echo 1)" "the only recorded post-swap problem, if any, is the watcher" "post_swap_problem=${PROBLEMS:-none}"

# THE SCRIPTS SHIPPED (work's install had none): two that only exist in the tree this deploy came from.
for rel in scripts/lib/download-asset.sh scripts/lib/health-wakes.sh; do
  ok "$([ -f "$INSTALL/$rel" ] && echo 1)" "the install carries $rel" "missing $INSTALL/$rel"
done

# THE NODE THE INSTALL RUNS: the old bytes, the new tree, and it says so itself.
VERSION="$("$INSTALL/wa" --version 2>/dev/null | head -1)"
ok "$(printf '%s' "$VERSION" | grep -q "v${C1:0:7}" && echo 1)" "wa --version names the OLD binary's build (${C1:0:7})" "$VERSION"
ok "$(printf '%s' "$VERSION" | grep -q "tree ${C2:0:12}" && echo 1)" "and the NEW tree (tree ${C2:0:12})" "$VERSION"

# IT IS RUNNING, and the record says which pid.
NODE_PID="$(tr -d '[:space:]' < "$INSTALL/serve.pid" 2>/dev/null)"
ok "$([ -n "$NODE_PID" ] && kill -0 "$NODE_PID" 2>/dev/null && echo 1)" "the node the deploy started is running (pid ${NODE_PID:-none})"

# VERIFY-INSTALL GREEN: the checks an operator runs after a deploy, against the install this row produced.
VERIFY="$W/verify.out"
WA_INSTALL_DIR="$INSTALL" WA_PORT="$PORT" WASM_AGENT_HOME="$HOME" bash "$INSTALL/scripts/verify-install.sh" > "$VERIFY" 2>&1; vrc=$?
ok "$([ "$vrc" = 0 ] && echo 1)" "verify-install is green on the install the covering release produced" "rc=$vrc $(grep -c FAIL "$VERIFY") FAIL line(s): $(grep -m2 FAIL "$VERIFY")"
ok "$(grep -q 'FAIL' "$VERIFY" && echo 0 || echo 1)" "with no FAIL line at all" "$(grep -m3 FAIL "$VERIFY")"

printf 'deploy covering release ok (%d checks, %d failed)\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
