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
# Exit: 0 green; 1 a check failed; 3 SKIP (a named reason: the covering release could not be built here, or this test is inside
# a node turn, where the deploy's own turn guard refuses before it starts).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/scratch-installer.sh"
. "$ROOT/scripts/lib/service-target.sh"
. "$ROOT/scripts/lib/node-binaries.sh"

root="$(wa_scratch_root wa-deploy-covering)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
NODE_PID=""
# TREE IS DECLARED EMPTY HERE because cleanup runs from a SKIP too, and a skip before the fixture exists (no published
# release covers this base, measured rows/20261125T034256Z) printed "line 50: TREE: unbound variable" under the skip.
TREE=""
cleanup() {
  [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null
  [ -n "$TREE" ] && git -C "$ROOT" worktree remove --force "$TREE" >/dev/null 2>&1 || true
  chmod -R u+w "$W" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
REAL_HOME="${HOME:-}"
# GH AUTHENTICATION TRAVELS WITH THE ROW (24/11). This test replaces HOME with a scratch one, and gh reads its
# token from $HOME/.config/gh - so every release request would be ANONYMOUS, at 60 an hour, and the deploy's
# release walk spends those in a few runs (measured: HTTP 401/403 mid-row, the resolver found nothing, and the
# deploy fell back to a build it could not do - a RED that had nothing to do with the code). The machine's own
# gh config is named explicitly instead; it is read, never written.
if [ -z "${GH_CONFIG_DIR:-}" ]; then
  for candidate in "${XDG_CONFIG_HOME:-$REAL_HOME/.config}/gh" "$REAL_HOME/.config/gh"; do
    [ -d "$candidate" ] && { GH_CONFIG_DIR="$candidate"; export GH_CONFIG_DIR; break; }
  done
fi
export HOME="$W/home"
mkdir -p "$HOME"
HOME="$REAL_HOME" wa_scratch_home_guard "$W/home" || exit 2
export WASM_AGENT_HOME="$HOME"
unset WASM_AGENT_RENDEZVOUS WASM_AGENT_RELAY WA_GRAPH_ROOT WA_GRAPH_DB WA_COMPONENTS_DIR WA_COMPONENT_RELEASE_URL

checks=0; failed=0; skipped=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
skip_all() { printf 'SKIP test-deploy-covering-release: %s\n' "$1"; exit 3; }

for tool in git cargo python3; do
  command -v "$tool" >/dev/null 2>&1 || skip_all "$tool is not on PATH (this row BUILDS the covering release here)"
done

# THE COVERING RELEASE IS BUILT HERE, NOT DOWNLOADED (25/11, Fable's D2). No GitHub call, no credential, no share
# of the machine's 60/hour: C1 is origin/main - the source commit whose compiled inputs this branch's scripts, lua
# and docs do not change - and its bytes are built by the product's own publisher into a directory under this row's
# scratch root. The deploy reads that directory through WA_NODE_BINARIES_URL, the stub seam
# scripts/lib/node-binaries.sh documents (a dir holding node-<sha12>/ subdirectories, plus releases.txt).
TRIPLE="$(wa_node_target_triple 2>/dev/null)" || skip_all "this host has no node-binary target triple"
KEYS="$ROOT/tests/fixtures/release-sign/keys.txt"
[ -f "$KEYS" ] || skip_all "no committed TEST signing key at $KEYS (a stub channel is signed with it)"
BASE="$(git -C "$ROOT" rev-parse origin/main)"
C1="$BASE"; SHORT="${C1:0:12}"
CHANNEL="$W/channel"; RELEASE="$CHANNEL/node-$SHORT"
BUILD_TREE="$W/c1-tree"
mkdir -p "$CHANNEL" "$BUILD_TREE" || skip_all "cannot make the stub channel under $W"
git -C "$ROOT" worktree add -q --detach "$BUILD_TREE" "$C1" 2>/dev/null   || skip_all "cannot check out $C1 to build the covering release"
# THE BYTES, WITHOUT ZIG AND WITHOUT THE VAULT. Measured while writing this (c1probe, 25/11): plain cargo builds the
# host triple once the code-mode assets are where build.rs looks for them; the publisher then verifies the artifact
# set against a manifest but signs through wa-vault, which a row must not have a token for. So the row does what the
# other stub-channel rows do: it builds, writes the manifest the product reads (with its OWN compiled-inputs digest),
# and signs the sums with the committed TEST key (scripts/lib/release-fixture-sign.py), which is the signature the
# verifier accepts. Nothing here is published and nothing asks for a secret.
BUILT="$W/built"; mkdir -p "$BUILT" "$RELEASE"
ASSET_SRC="$ROOT/.git/codemode-assets"
if [ -d "$ASSET_SRC" ]; then
  mkdir -p "$BUILD_TREE/.git"; cp -a "$ASSET_SRC" "$BUILD_TREE/.git/" 2>/dev/null || true
fi
CODEMODE_ENV=""
for cand in "$BUILD_TREE"/.git/codemode-assets/*; do [ -d "$cand" ] && CODEMODE_ENV="$cand" && break; done
( cd "$BUILD_TREE/rust" && WA_CODEMODE_BUILD_ASSETS="$CODEMODE_ENV" CARGO_TARGET_DIR="$W/target" \
    cargo build --release --offline -q -p wa-host ) > "$W/build-wa.log" 2>&1 \
  || skip_all "cannot build the node binary from $SHORT: $(tail -3 "$W/build-wa.log" | tr '\n' ' ')"
( cd "$BUILD_TREE/rust/wa-sentinel" && WA_CODEMODE_BUILD_ASSETS="$CODEMODE_ENV" CARGO_TARGET_DIR="$W/target" \
    cargo build --release --offline -q ) > "$W/build-sentinel.log" 2>&1 \
  || skip_all "cannot build wa-sentinel from $SHORT: $(tail -3 "$W/build-sentinel.log" | tr '\n' ' ')"
cp -f "$W/target/release/wa" "$RELEASE/wa-$TRIPLE-$SHORT" || skip_all "cannot stage the built wa"
cp -f "$W/target/release/wa-sentinel" "$RELEASE/wa-sentinel-$TRIPLE-$SHORT" || skip_all "cannot stage the built wa-sentinel"
chmod +x "$RELEASE/wa-$TRIPLE-$SHORT" "$RELEASE/wa-sentinel-$TRIPLE-$SHORT"
DIGEST="$(. "$ROOT/scripts/lib/node-binaries.sh"; wa_compiled_inputs_digest "$ROOT" "$C1")"
[ -n "$DIGEST" ] || skip_all "cannot compute the compiled-inputs digest of $SHORT"
FLOOR=""
[ -r "$ROOT/scripts/lib/glibc-floor.sh" ] && FLOOR="$(. "$ROOT/scripts/lib/glibc-floor.sh"; wa_glibc_max_symbol "$RELEASE/wa-$TRIPLE-$SHORT" 2>/dev/null)"
[ -n "$FLOOR" ] || FLOOR=2.31
{
  printf 'schema=wasm-agent-node-binaries/1\n'
  printf 'source_commit=%s\n' "$C1"
  printf 'source_tree=%s\n' "$(git -C "$ROOT" rev-parse "$C1^{tree}")"
  printf 'rustc_version=%s\n' "$(rustc --version 2>/dev/null | awk '{print $2}')"
  printf 'zig_version=none-built-with-cargo\n'
  printf 'glibc_floor=%s\n' "$FLOOR"
  printf 'codemode=%s\n' "${CODEMODE_ENV:+embedded}"
  [ -n "$CODEMODE_ENV" ] || printf 'codemode=empty\n'
  printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'compiled_inputs=%s\n' "$DIGEST"
  printf '# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes\n'
  printf '%s %s %s %s %s\n' "$TRIPLE" \
    "$(sha256sum "$RELEASE/wa-$TRIPLE-$SHORT" | cut -d' ' -f1)" "$(wc -c < "$RELEASE/wa-$TRIPLE-$SHORT" | tr -d ' ')" \
    "$(sha256sum "$RELEASE/wa-sentinel-$TRIPLE-$SHORT" | cut -d' ' -f1)" "$(wc -c < "$RELEASE/wa-sentinel-$TRIPLE-$SHORT" | tr -d ' ')"
} > "$RELEASE/node-$SHORT.manifest"
python3 "$ROOT/scripts/lib/release-fixture-sign.py" "$RELEASE" --key A > /dev/null 2>&1 \
  || skip_all "the local covering release could not be signed with the TEST key"
cd "$ROOT" || skip_all "cannot return to the checkout"
printf '%s\n' "node-$SHORT" > "$RELEASE/releases.txt"
export WA_NODE_BINARIES_URL="file://$RELEASE"
export WA_RELEASE_KEYS="$KEYS"
echo "stub channel: $RELEASE (node-$SHORT built here from $SHORT and signed with the TEST key; no GitHub call, no credential)"

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
# THE FIXTURE REMOTE INHERITS `main` FROM THE SOURCE CHECKOUT (`clone --bare --shared` copies its refs), and this
# row's C2 sits on a BASE that can be OLDER than that main - so a plain push is a non-fast-forward and the row
# SKIPPED with "cannot push the fixture C2 into the fixture remote" (measured in the orchestrator's runner, 25/11
# 03:21Z, rows/20261125T032147Z). The remote is this row's own scratch clone, so the inherited ref is dropped first;
# nothing outside the row is touched, and the push below is the ordinary one.
git -C "$REMOTE" update-ref -d refs/heads/main 2>/dev/null || true
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

# THE OLD BINARY, out of the release this row just built and signed (the deploy's own fetch proves it again: the
# manifest names C1, every byte is checked against the row, and the signature is the committed TEST key).
BIN_DIR="$(WA_NODE_BINARIES_URL="file://$CHANNEL" wa_node_binary_download "$ROOT" "$C1" "$TRIPLE" "$W/node-binaries" 2>"$W/binary.err")"   || skip_all "the stub release for $SHORT is not usable by the product's own downloader: $(tail -2 "$W/binary.err" | tr '\n' ' ')"
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

# ---- the two facts the code must carry, BEFORE any network (these are the rows that fail on main) ------
# THE END-TO-END HALF BELOW IS THE PROOF; these two are its CUT CONDITION, and they are the part that can be
# measured without a release channel. On the code before this branch (main 2d7ac300/ebf6d2ec):
#   * the prebuilt path set BINARY_COMMIT=HEAD and record_expected followed it, so a covering release was
#     refused AFTER the swap (work, 22:17Z);
#   * the only build-info check lived in record_installed, i.e. on the far side of upgrade.sh.
# Both are greps on the deployed script, and both must hold in the tree this row runs.
DEPLOY_SRC="$TREE/scripts/deploy.sh"
ok "$(grep -q 'record_expected="${BINARY_SOURCE_COMMIT:-${BINARY_COMMIT:-$COMMIT}}"' "$DEPLOY_SRC" && echo 1)" \
  "the record expects the RELEASE's source commit for a prebuilt install, not HEAD" \
  "deploy.sh does not compute record_expected from BINARY_SOURCE_COMMIT (main expected HEAD and refused a covering install)"
ok "$(grep -q 'BINARY_EXPECT_COMMIT="${BINARY_SOURCE_COMMIT:-${BINARY_COMMIT:-$COMMIT}}"' "$DEPLOY_SRC" && echo 1)" \
  "and the staged binary is proved against that commit BEFORE the swap" \
  "deploy.sh has no pre-swap build-info proof of the staged binary (main checked only after upgrade.sh)"
ok "$(grep -q 'SWAPPED=1' "$DEPLOY_SRC" && grep -q 'post_swap_problem' "$DEPLOY_SRC" && echo 1)" \
  "and a post-swap failure is recorded (post_swap_problem=), not a refusal" \
  "deploy.sh has no post-swap problem record: every fail() on the far side of the swap still exits"

# ---- run the real deploy --------------------------------------------------------------------------
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
[ -n "$PORT" ] || skip_all "no free port for the scratch node"
OUT="$W/deploy.out"
# TWO MODES, and the clean one is the one that matters now (25/11, Fable's E):
#   clean   a covering install whose watcher ANSWERS - the deploy exits 0 and records NO post_swap_problem;
#   inject  the same install with one thing that cannot work AFTER the swap - it exits 3, the verdict and the
#           record name the problem, and nothing is reported as "failed" about a node that was installed.
MODE="${1:-clean}"
case "$MODE" in clean|inject) ;; *) echo "usage: $0 [clean|inject]" >&2; exit 2 ;; esac
# A WATCHER THAT ANSWERS. The runner gives rows a systemctl stub that refuses; a clean covering install needs
# one that says a watcher is up (`is-active` -> active), and every call is still recorded under this row's root.
mkdir -p "$W/bin"
cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/../systemctl-calls.log"
case "$1" in
  is-active|status) echo active ;;
  show) echo "LoadState=loaded" ;;
esac
exit 0
STUB
chmod +x "$W/bin/systemctl"
if [ "$MODE" = inject ]; then
  # ONE THING THAT CANNOT WORK AFTER THE SWAP: the deploy ships scripts/lib/download-asset.sh into the install,
  # and a DIRECTORY sitting where that file goes makes the ship fail every time - after the node is installed
  # and serving, which is exactly the state the review asks about.
  mkdir -p "$INSTALL/scripts/lib/download-asset.sh" || skip_all "cannot stage the injected post-swap problem"
fi
# THE ENVIRONMENT IS REBUILT, NOT FILTERED (25/11). This block used to be
#     ( cd "$TREE" && env -u WASM_AGENT_IN_TURN -u WA_INSTALL_DIR -u WA_PORT HOME="$HOME" ... bash scripts/deploy.sh )
# and that is what reached the operator's machine: the row replaced HOME and nothing else, so the deploy's unit path
# (${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user, scripts/lib/sentinel-unit.sh:41) was the LIVE one, its
# `systemctl --user` talked to the LIVE manager through the inherited XDG_RUNTIME_DIR, and the sentinel it
# restarted ran on the LIVE ledger through the inherited WASM_AGENT_DB - while `env -u WASM_AGENT_IN_TURN` removed
# the one guard that would have refused inside a turn. scripts/lib/scratch-installer.sh now builds the child's
# environment from an allow-list: HOME, WASM_AGENT_HOME, WA_INSTALL_DIR, the unit dir, a systemctl STUB, the ledger,
# XDG config+runtime and the port are all under $W, the marker travels unchanged, and the live ports are refused.
# That library is what scripts/test-installer-data-isolation.sh measures, so this row is safe to run anywhere.
# WA_DEPLOY_FULL=1 IS THE TREE'S OWN WAY TO SAY "install the tree fully", and it is what puts this row on the
# COVERING path instead of the Lua fast path. Both are correct, and they are different questions: the fast
# path keeps the installed binary (nothing compiled changed, so there is nothing to download) and never asks
# the release channel anything; the covering path is a deploy that INSTALLS a binary and therefore must take
# the newest published build of this tree's compiled inputs - which is the branch work's 22:17Z update ran,
# and the branch whose record was wrong. The row names the knob rather than pretending the two are one path.
# WA_DEPLOY_FULL=1 IS THE TREE'S OWN WAY TO SAY "install the tree fully", and it is what puts this row on the
# COVERING path instead of the Lua fast path. Both are correct, and they are different questions: the fast path keeps
# the installed binary (nothing compiled changed, so there is nothing to download) and never asks the release channel
# anything; the covering path is a deploy that INSTALLS a binary and therefore must take the newest published build
# of this tree's compiled inputs - which is the update work's 22:17Z run was, and the branch whose record was wrong.
# WA_SENTINEL_SUPERVISOR=none: nothing outside owns the watcher in a scratch home (deploy.sh's own seam).
wa_installer_run --root "$W" --cd "$TREE" --port "$PORT" --install-dir "$INSTALL" \
  --set WA_DEPLOY_FULL=1 --set WA_DEPLOY_TREE_WAIT=60 \
  --set WA_DEPLOY_ROOT="$TREE" \
  --set WA_SERVICE_UNIT_FILE="$W/no-such.unit" --set WA_SENTINEL_SUPERVISOR=none \
  --set WA_NODE_BINARIES_URL="file://$CHANNEL" --set WA_RELEASE_KEYS="$KEYS" \
  --set WA_SENTINEL_UNIT_SYSTEMCTL="$W/bin/systemctl" \
  -- bash scripts/deploy.sh --reason "test-deploy-covering-release: a covering release must record both facts" \
  > "$OUT" 2>&1
rc=$?

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
# A SCRATCH HOME HAS NO SYSTEMD USER SESSION, so the sentinel cannot start there and the deploy RECORDS that instead
# of exiting half installed - which is the behaviour this row exists to prove. It records it as SEVERAL problems
# (measured in the runner, rows/20261125T032635Z: the sentinel not starting, and not watching, from the one cause), so
# the question is not "is there exactly one" but "is every one of them the watcher": anything else is a real failure
# of the covering install and must stay a red.
watcher_only() { # <the recorded problems, '; '-separated> -> 0 when every one of them is the watcher
  local rest="${1-}" item
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    case "$rest" in
      *'; '*) item="${rest%%; *}"; rest="${rest#*; }" ;;
      *) item="$rest"; rest="" ;;
    esac
    case "$item" in
      *sentinel*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}
if [ "$rc" = 0 ]; then
  ok 1 "the deploy exits 0 on a covering release"
elif [ "$rc" = 3 ] && [ "$MODE" = inject ] && [ -n "$PROBLEMS" ]; then
  ok 1 "the deploy exits 3 and the record names the problem it hit after the swap: $PROBLEMS"
elif [ "$rc" = 3 ] && watcher_only "$PROBLEMS"; then
  ok 1 "the deploy exits 3, and every recorded problem is the watcher a scratch home cannot start: $PROBLEMS"
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
if [ "$MODE" = inject ]; then
  ok "$([ -n "$PROBLEMS" ] && printf '%s' "$PROBLEMS" | grep -qi 'download-asset' && echo 1)" \
    "the injected post-swap problem is IN THE RECORD, named by what could not be shipped" "post_swap_problem=${PROBLEMS:-none}"
else
  ok "$([ -z "$PROBLEMS" ] && echo 1)" "a covering install whose watcher answers records NO post-swap problem" "post_swap_problem=${PROBLEMS:-none}"
fi

# THE SCRIPTS SHIPPED (work's install had none): two that only exist in the tree this deploy came from.
for rel in scripts/lib/download-asset.sh scripts/lib/health-wakes.sh; do
  ok "$([ -f "$INSTALL/$rel" ] && echo 1)" "the install carries $rel" "missing $INSTALL/$rel"
done

# THE NODE THE INSTALL RUNS: the old bytes, the new tree, and it says so itself.
# WA_INSTALL_DIR is how a binary finds the record it names beside itself (rust/wa-host/src/main.rs:413):
# with it unset the label reads ~/.local/bin, where a scratch home has no installed.txt, and the tree
# half is silently absent (measured while writing this row).
VERSION="$(WA_INSTALL_DIR="$INSTALL" "$INSTALL/wa" --version 2>/dev/null | head -1)"
# The label names the RELEASE TAG the record carries (binary_release=, which the record now writes for a
# covering install) and then the tree: `wasm-agent v0.1.2 node-<sha12> tree <tree>` - the bytes first,
# because they are what is executing, and the tree because it is not them (rust/wa-host/src/build_info.rs).
ok "$(printf '%s' "$VERSION" | grep -q "node-${C1:0:12}" && echo 1)" "wa --version names the OLD binary's release (node-${C1:0:12})" "$VERSION"
ok "$(printf '%s' "$VERSION" | grep -q "tree ${lua_tree}" && echo 1)" "and the NEW tree (tree ${lua_tree})" "$VERSION"

# IT IS RUNNING, and the record says which pid.
NODE_PID="$(tr -d '[:space:]' < "$INSTALL/serve.pid" 2>/dev/null)"
ok "$([ -n "$NODE_PID" ] && kill -0 "$NODE_PID" 2>/dev/null && echo 1)" "the node the deploy started is running (pid ${NODE_PID:-none})"

# VERIFY-INSTALL GREEN: the checks an operator runs after a deploy, against the install this row produced.
VERIFY="$W/verify.out"
WA_INSTALL_DIR="$INSTALL" WA_PORT="$PORT" WASM_AGENT_HOME="$HOME" bash "$INSTALL/scripts/verify-install.sh" > "$VERIFY" 2>&1; vrc=$?
# VERIFY-INSTALL'S VERDICT ON THIS INSTALL: every FAIL line is one this row EXPECTS and none other. The two that a
# scratch home forces are named - the deploy's own verdict (ok=false, because the watcher problem above was recorded)
# and the sentinel not watching - and any THIRD one fails the row, so this is an allow-list, not a relaxation.
if [ "$MODE" = clean ]; then
  ok "$([ "$vrc" = 0 ] && ! grep -qE '^  FAIL ' "$VERIFY" && echo 1)" \
    "verify-install is GREEN on a covering install whose watcher answers - no FAIL line at all" "rc=$vrc $(grep -E '^  FAIL ' "$VERIFY" | head -2 | tr '\n' '|')"
fi
EXPECTED_FAILS=("the deploy's verdict matches the record" "the sentinel is watching")
unexpected=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  known=0
  for want in "${EXPECTED_FAILS[@]}"; do
    case "$line" in *"$want"*) known=1 ;; esac
  done
  [ "$known" = 1 ] || unexpected="${unexpected}${unexpected:+| }$line"
done <<VERIFY_FAILS
$(grep -E '^  FAIL ' "$VERIFY" 2>/dev/null)
VERIFY_FAILS
ok "$([ -z "$unexpected" ] && echo 1)" "verify-install's only FAIL lines are the two a scratch home forces (its verdict, and the sentinel)" "$unexpected"
ok "$(grep -qE '^  FAIL the sentinel is watching' "$VERIFY" 2>/dev/null && echo 1)" "and it does say the sentinel is not watching (the one thing this scratch install cannot have)" "$(grep -c FAIL "$VERIFY") FAIL line(s)"

printf 'deploy covering release ok (%d checks, %d failed)\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
