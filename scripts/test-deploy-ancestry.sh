#!/usr/bin/env bash
# Does a deploy refuse to replace a newer commit that is RUNNING, and list what it would lose?
#
# WHAT THIS EXISTS FOR. On 18/11 a sentinel deploy of main replaced a node running a build of 8 commits that
# were on no landed branch, and removed features that had been working. The guard that existed compared this
# tree against installed.txt - a record written by the party that meant to install - and that record said
# commit=14963b6f, which WAS an ancestor of main. So the guard passed and the work went away.
#
# The rule now: ask the RUNNING binary (`wa --build-info`), compare against this tree, refuse by name and list
# the commits that would be lost, and allow the override only with --force --reason <text>, which is recorded.
#
# HOW THE FIXTURE IS BUILT. A shared clone of this checkout (cheap: the objects are linked, nothing is written
# into the source), with origin/main pointed at the commit under test so the tree is "on its main". The running
# binary is a stub that answers --build-info with a commit made on top of it - the exact 18/11 shape: a running
# commit that this tree does not contain. The stub is also what makes the test independent of a built node
# binary and of what happens to be installed on the machine running the test.
#
# Nothing here builds: every case stops at or before the gate, and --force --reason is stopped at the first step
# after it (WA_DEPLOY_PREBUILT_ONLY with nothing published), so the run touches no landing queue and no network
# path that can succeed.
#
# Usage:  bash scripts/test-deploy-ancestry.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in: $(printf '%s' "$2" | tail -4 | tr '\n' '|')" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }

# THE FIXTURE NEEDS A DETACHER AND GIT. `setsid --fork` keeps the deploy off this turn's process tree (deploy.sh
# refuses to replace the node its own turn runs on), and the whole case is built out of local clones. A host
# without them says so instead of failing inside a half-started deploy.
if ! command -v setsid >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP test-deploy-ancestry: no setsid/git on this host (the fixture runs deploy.sh detached from this turn)"
  exit 0
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"; INSTALL="$WORK/install"; SHIM="$WORK/bin"
# The node's own config directory: deploy.sh reads its pin store (scripts/lib/node-pins.sh) from here, so a case
# can put a pin in front of a deploy without touching this machine's ~/.wasm-agent.
AGENT_HOME="$WORK/agent-home"
mkdir -p "$INSTALL" "$SHIM" "$AGENT_HOME/.wasm-agent"
# A machine with no service: the fixture is a directory, not this machine's install, and deploy.sh asks systemd
# and the port who owns the node. systemctl answering nothing is the honest fixture for "no service here".
printf '#!/bin/sh\nexit 1\n' > "$SHIM/systemctl"; chmod +x "$SHIM/systemctl"

git clone -q --shared "$ROOT" "$TREE" || { echo "test-deploy-ancestry: cannot clone $ROOT" >&2; exit 1; }
git -C "$TREE" config user.email test@example.com
git -C "$TREE" config user.name test
HEAD="$(git -C "$TREE" rev-parse HEAD)"
# The fixture's main IS the commit under test: this checkout is on its main, which is what deploy.sh's rule 2
# asks, and it keeps the test about the ancestry rule rather than about the branch this work happens to be on.
# deploy.sh fetches origin before it reads origin/main (step 0b). The clone's origin is THIS checkout, whose
# main is not the commit under test on any branch but main itself, so that fetch moved origin/main back to
# main and every case waited out the "quiet canonical tree" bound (21/11 survey: 4 minutes a case, then wrong
# output). The fixture is its own origin: a fetch then finds main == HEAD, which is the shape stated here.
git -C "$TREE" remote set-url origin "$TREE"
git -C "$TREE" update-ref refs/remotes/origin/main "$HEAD"
# ...and on branch main, because main's runtime-binding preflight (deploy.sh step 0c) refuses a deploy from a tree
# no checkout has on branch main, BEFORE the build and therefore before the ancestry gate this test is about.
# The fixture states the shape the rule asks for (this checkout is the one main checkout) instead of bypassing the
# preflight, so the preflight itself still runs here. Round 4: the rebase onto main brought the preflight, and 46
# assertions of this file stopped reaching the gate they were written for.
git -C "$TREE" checkout -q -B main "$HEAD"
TREE_SHA="$(git -C "$TREE" rev-parse 'HEAD^{tree}')"
# The commit the node is RUNNING and this tree does not contain, made with commit-tree: no worktree, no branch,
# no push, and it is exactly the shape of the incident (newer than the tree, absent from it).
LOST="$(git -C "$TREE" commit-tree "$TREE_SHA" -p "$HEAD" -m 'feature: the commit that would be lost')"
{ echo '#!/bin/sh'; echo 'case "$1" in';
  echo "  --build-info) printf 'version=9.9.9\\ncommit=$LOST\\ntree=$TREE_SHA\\ndirty=false\\nsource=git\\nbuilt_epoch=1\\nancestors=3\\nancestors_complete=true\\n' ;;";
  echo "  --contains) [ \"\$2\" = \"$LOST\" ] && exit 0; exit 1 ;;";
  echo "  --version) echo 'wasm-agent 9.9.9' ;;";
  echo '  *) exit 0 ;;'; echo 'esac'; } > "$INSTALL/wa"
chmod +x "$INSTALL/wa"; cp "$INSTALL/wa" "$INSTALL/wa-sentinel"
# The record's claim is the tree's own commit - an ancestor of the target, which is what let 18/11 through.
# If deploy.sh still trusted it, case 1 would pass the gate instead of refusing.
printf 'commit=%s\nvia=deploy.sh\nrecord_role=final\n' "$HEAD" > "$INSTALL/installed.txt"
RECORD_BEFORE="$(cat "$INSTALL/installed.txt")"
echo "test-deploy-ancestry: running $(printf '%s' "$LOST" | cut -c1-12) (not in this tree $(printf '%s' "$HEAD" | cut -c1-12)), record claims $(printf '%s' "$HEAD" | cut -c1-12)"

# setsid --fork detaches, so the exit status has to be carried out in a file: the deploy is run off the process
# tree of whatever turn this test runs in (deploy.sh refuses to replace the node it is running on), and a
# detached parent cannot report its child's status.
deploy() { # <install-dir> <args...> -> sets DEPLOY_OUT, DEPLOY_RC
  local dir="$1"; shift
  rm -f "$WORK/out" "$WORK/rc"
  setsid --fork env -u WASM_AGENT_IN_TURN -u WA_SESSION_ID PATH="$SHIM:$PATH" \
    WA_PORT=18799 WA_CLIENT_PORT=18800 WA_INSTALL_DIR="$dir" WA_DEPLOY_PREBUILT_ONLY=1 \
    WASM_AGENT_HOME="$AGENT_HOME" \
    bash -c 'timeout 300 bash "$1" "${@:2}" >"'$WORK'/out" 2>&1; echo $? > "'$WORK'/rc"' runner \
      "$TREE/scripts/deploy.sh" "$@" >/dev/null 2>&1
  # wait for the detached run to settle (bounded), then read what it left
  local waited=0
  while [ ! -f "$WORK/rc" ] && [ "$waited" -lt 300 ]; do sleep 1; waited=$((waited + 1)); done
  DEPLOY_OUT="$(cat "$WORK/out" 2>/dev/null)"
  DEPLOY_RC="$(cat "$WORK/rc" 2>/dev/null || echo timeout)"
}

echo "test-deploy-ancestry: a deploy over a newer, unlanded binary"
deploy "$INSTALL" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "it did not refuse"
shows "the refusal names the rule" "$DEPLOY_OUT" "downgrade refused(node_not_contained)"
shows "it names the RUNNING commit" "$DEPLOY_OUT" "$(printf '%s' "$LOST" | cut -c1-12)"
shows "it lists the commit that would be lost, by subject" "$DEPLOY_OUT" "feature: the commit that would be lost"
shows "it says the running binary was asked" "$DEPLOY_OUT" "asked of the binary, not read from installed.txt"
shows "it names the way back" "$DEPLOY_OUT" "--rollback"
same "the install record was not touched" "$(cat "$INSTALL/installed.txt")" "$RECORD_BEFORE"

echo "test-deploy-ancestry: --force without a reason"
deploy "$INSTALL" --force
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "it did not refuse"
shows "the refusal demands a reason" "$DEPLOY_OUT" "override_reason_required"
same "the install record was not touched" "$(cat "$INSTALL/installed.txt")" "$RECORD_BEFORE"

echo "test-deploy-ancestry: --force --reason passes, and records the override"
deploy "$INSTALL" --force --reason "retiring the feature on purpose"
hides "it got past the ancestry gate" "$DEPLOY_OUT" "downgrade refused"
shows "it said the override out loud" "$DEPLOY_OUT" "OVERRIDE, recorded"
LOG="$INSTALL/deploy.log"
shows "the override is in deploy.log with its reason" "$(cat "$LOG" 2>/dev/null)" "ancestry_override=retiring the feature on purpose"
shows "...with the commit it replaced" "$(cat "$LOG" 2>/dev/null)" "ancestry_replaced=$LOST"
shows "...and who did it" "$(cat "$LOG" 2>/dev/null)" "ancestry_by="

echo "test-deploy-ancestry: the record is a fallback, not the witness"
# With the binary unable to answer, the guard falls back to installed.txt and SAYS SO - and the fallback is
# allowed only when the record is provably about THESE bytes, which means a sha256= that is the binary's
# (round-3 item 1 made the missing-sha256 case a refusal; the case below has one, and is still a fallback).
DEADINSTALL="$WORK/dead-install"; mkdir -p "$DEADINSTALL"
printf '#!/bin/sh\nexit 1\n' > "$DEADINSTALL/wa"; chmod +x "$DEADINSTALL/wa"; cp "$DEADINSTALL/wa" "$DEADINSTALL/wa-sentinel"
printf 'commit=%s\nsha256=%s\nvia=deploy.sh\n' "$LOST" "$(sha256sum < "$DEADINSTALL/wa" | cut -d' ' -f1)" > "$DEADINSTALL/installed.txt"
deploy "$DEADINSTALL"
shows "with no answer from the binary the record is used, and named" "$DEPLOY_OUT" "could not be asked"
shows "...and it still refuses, because the record is newer than this tree" "$DEPLOY_OUT" "downgrade refused(node_not_contained)"
# ...and the same record with the sha256= filed off is not a fallback at all.
NOSHADEAD="$WORK/nosha-dead"; mkdir -p "$NOSHADEAD"
printf '#!/bin/sh\nexit 1\n' > "$NOSHADEAD/wa"; chmod +x "$NOSHADEAD/wa"; cp "$NOSHADEAD/wa" "$NOSHADEAD/wa-sentinel"
printf 'commit=%s\nvia=deploy.sh\n' "$LOST" > "$NOSHADEAD/installed.txt"
deploy "$NOSHADEAD" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "a record with no sha256= is refused (exit $DEPLOY_RC)" || bad "a record with no sha256= was used as if it described the bytes"
shows "the refusal is by name" "$DEPLOY_OUT" "refused(running_commit_unprovable)"
hides "...and the record is NOT named as a witness" "$DEPLOY_OUT" "for THESE bytes"

echo "test-deploy-ancestry: a record about these bytes that names no commit is UNKNOWN (round-4 item 1)"
# The fail-open this closes: the binary cannot answer, the record IS about these bytes, and its commit= is
# unknown (or blank). wa_running_identity answered source=none with no commit, deploy.sh read that as a FIRST
# INSTALL, installed over the node, and printed "the override above was recorded as ancestry_unverified=yes" -
# a record nobody made, in the sentence an operator would later quote as their own decision.
NOCOMMIT="$WORK/nocommit-install"; mkdir -p "$NOCOMMIT"
printf '#!/bin/sh
exit 1
' > "$NOCOMMIT/wa"; chmod +x "$NOCOMMIT/wa"; cp "$NOCOMMIT/wa" "$NOCOMMIT/wa-sentinel"
printf 'commit=unknown
sha256=%s
via=deploy.sh
' "$(sha256sum < "$NOCOMMIT/wa" | cut -d' ' -f1)" > "$NOCOMMIT/installed.txt"
NOCOMMIT_BEFORE="$(cat "$NOCOMMIT/installed.txt")"
deploy "$NOCOMMIT" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "a record about these bytes with no commit was replaced with no ancestry question"
shows "the refusal is by name" "$DEPLOY_OUT" "refused(running_commit_unprovable)"
shows "it says the record names no commit=" "$DEPLOY_OUT" "names no commit="
hides "it does not call it a first install" "$DEPLOY_OUT" "this is a first install"
hides "it does not claim an override nobody gave" "$DEPLOY_OUT" "the override above was recorded"
same "the install record was not touched" "$(cat "$NOCOMMIT/installed.txt")" "$NOCOMMIT_BEFORE"
deploy "$NOCOMMIT" --force --reason "a dev box we are moving anyway"
hides "with --force --reason the gate opens" "$DEPLOY_OUT" "refused(running_commit_unprovable)"
shows "...and only THEN is the override named" "$DEPLOY_OUT" "the override above was recorded as ancestry_unverified=yes"
shows "...and it is recorded against the rule it overrode" "$(cat "$NOCOMMIT/deploy.log" 2>/dev/null)" "overrode=running_commit_unprovable"

echo "test-deploy-ancestry: a record that is not about these bytes is not evidence"
# The shape measured on this machine and on work on 18/11: the record says commit=14963b6f and sha256=4248d61b,
# the bytes are fc6a9d80, and 14963b6f is an ancestor of main - so a record-based guard let a deploy of main
# replace a build of 8 unlanded commits. A record naming another sha256 is provably not this binary's.
STALE="$WORK/stale-install"; mkdir -p "$STALE"
printf '#!/bin/sh\nexit 1\n' > "$STALE/wa"; chmod +x "$STALE/wa"; cp "$STALE/wa" "$STALE/wa-sentinel"
printf 'commit=%s\nsha256=%s\nvia=deploy.sh\n' "$HEAD" "$(printf 'deadbeef%.0s' 1 2 3 4 5 6 7 8)" > "$STALE/installed.txt"
deploy "$STALE" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "it deployed over a record that describes other bytes"
shows "the refusal is by name" "$DEPLOY_OUT" "downgrade_unprovable(record_not_this_binary)"
shows "it names the sha256 the record carries" "$DEPLOY_OUT" "deadbeefdead"
shows "and the bytes it is now" "$DEPLOY_OUT" "the binary at"
deploy "$STALE" --force --reason "I know what is on that node"
hides "with --force --reason it goes on" "$DEPLOY_OUT" "downgrade_unprovable"
shows "...and the unverified ancestry is recorded" "$(cat "$STALE/deploy.log" 2>/dev/null)" "ancestry_unverified=yes"


echo "test-deploy-ancestry: the exact 18/11 case - the running commit is not in this history at all"
# MEASURED 18/11: the node ran a build of 8 commits that were on no landed branch, its installed.txt said
# commit=14963b6f (an ANCESTOR of main, so the old record-based guard saw a safe deploy), and the deployer's
# checkout had never seen the running commit at all. That answered "cannot tell" for every cause at once, and
# deploy.sh only noted it and installed. It must refuse, and name the commit that is running.
OTHER="$WORK/other-repo"; mkdir -p "$OTHER"
git -C "$OTHER" init -q; git -C "$OTHER" config user.email test@example.com; git -C "$OTHER" config user.name test
printf 'x\n' > "$OTHER/x"; git -C "$OTHER" add x; git -C "$OTHER" commit -qm 'the running build, on no branch here'
FOREIGN="$(git -C "$OTHER" rev-parse HEAD)"
MISSING="$WORK/missing-install"; mkdir -p "$MISSING"
{ echo '#!/bin/sh'; echo 'case "$1" in';
  echo "  --build-info) printf 'version=9.9.9\\ncommit=$FOREIGN\\ntree=$TREE_SHA\\ndirty=false\\nsource=git\\nbuilt_epoch=1\\nancestors=8\\nancestors_complete=true\\n' ;;";
  echo '  --contains) exit 1 ;;';
  echo "  --version) echo 'wasm-agent 9.9.9' ;;";
  echo '  *) exit 0 ;;'; echo 'esac'; } > "$MISSING/wa"
chmod +x "$MISSING/wa"; cp "$MISSING/wa" "$MISSING/wa-sentinel"
# the record claims an ancestor of this tree, which is exactly what made the belief look safe
printf 'commit=%s\nvia=deploy.sh\nrecord_role=final\n' "$HEAD" > "$MISSING/installed.txt"
MISSING_BEFORE="$(cat "$MISSING/installed.txt")"
deploy "$MISSING" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "it deployed over a running build this history has never seen"
shows "the refusal names the rule" "$DEPLOY_OUT" "downgrade refused(node_not_contained)"
shows "it names the running commit" "$DEPLOY_OUT" "$(printf '%s' "$FOREIGN" | cut -c1-12)"
shows "it says the commit is not in this history" "$DEPLOY_OUT" "not in this history"
hides "it did not go on to install" "$DEPLOY_OUT" "OVERRIDE, recorded"
same "the install record was not touched" "$(cat "$MISSING/installed.txt")" "$MISSING_BEFORE"
deploy "$MISSING" --force --reason "I know that node runs a build this clone has never seen"
hides "with --force --reason it goes on" "$DEPLOY_OUT" "downgrade refused"

echo "test-deploy-ancestry: an unknown refuses too (a shallow checkout cannot tell)"
# The other half of the same hole: a checkout that is SHALLOW has real ignorance about what a deploy would
# lose, and a verdict of 2 was a note, not a stop. It is a stop now, unless the operator says --force --reason.
SHALLOWTREE="$WORK/shallow-tree"
if git clone -q --depth 1 "file://$ROOT" "$SHALLOWTREE" 2>/dev/null; then
  same "the fixture checkout is shallow" "$(git -C "$SHALLOWTREE" rev-parse --is-shallow-repository)" "true"
  SHEAD="$(git -C "$SHALLOWTREE" rev-parse HEAD)"
  git -C "$SHALLOWTREE" remote set-url origin "$SHALLOWTREE"   # its own origin, as the full fixture above
  git -C "$SHALLOWTREE" update-ref refs/remotes/origin/main "$SHEAD"
  # the same statement as the full fixture above: the shallow clone IS the main checkout for this run
  git -C "$SHALLOWTREE" checkout -q -B main "$SHEAD"
  UNKNOWN="$WORK/unknown-install"; mkdir -p "$UNKNOWN"
  { echo '#!/bin/sh'; echo 'case "$1" in';
    echo "  --build-info) printf 'version=9.9.9\\ncommit=$FOREIGN\\ntree=$TREE_SHA\\ndirty=false\\nsource=git\\nbuilt_epoch=1\\nancestors=8\\nancestors_complete=false\\n' ;;";
    echo '  --contains) exit 2 ;;   # an incomplete ancestry: "I cannot tell", not "no"';
    echo "  --version) echo 'wasm-agent 9.9.9' ;;";
    echo '  *) exit 0 ;;'; echo 'esac'; } > "$UNKNOWN/wa"
  chmod +x "$UNKNOWN/wa"; cp "$UNKNOWN/wa" "$UNKNOWN/wa-sentinel"
  printf 'commit=%s\nvia=deploy.sh\n' "$FOREIGN" > "$UNKNOWN/installed.txt"
  UNKNOWN_BEFORE="$(cat "$UNKNOWN/installed.txt")"
  # the tree under test is the shallow one, so the deploy is that checkout's own
  deploy_in() { # <tree> <install-dir> <args...>
    local tree="$1" dir="$2"; shift 2
    rm -f "$WORK/out" "$WORK/rc"
    setsid --fork env -u WASM_AGENT_IN_TURN -u WA_SESSION_ID PATH="$SHIM:$PATH" \
      WA_PORT=18799 WA_CLIENT_PORT=18800 WA_INSTALL_DIR="$dir" WA_DEPLOY_PREBUILT_ONLY=1 \
      WASM_AGENT_HOME="$AGENT_HOME" \
      bash -c 'timeout 300 bash "$1" "${@:2}" >"'$WORK'/out" 2>&1; echo $? > "'$WORK'/rc"' runner \
        "$tree/scripts/deploy.sh" "$@" >/dev/null 2>&1
    local waited=0
    while [ ! -f "$WORK/rc" ] && [ "$waited" -lt 300 ]; do sleep 1; waited=$((waited + 1)); done
    DEPLOY_OUT="$(cat "$WORK/out" 2>/dev/null)"
    DEPLOY_RC="$(cat "$WORK/rc" 2>/dev/null || echo timeout)"
  }
  deploy_in "$SHALLOWTREE" "$UNKNOWN" --reason "an ordinary deploy"
  [ "$DEPLOY_RC" != 0 ] && ok "an unknown verdict refused (exit $DEPLOY_RC)" || bad "a deploy went on where nothing could tell what would be lost"
  shows "the refusal is by name" "$DEPLOY_OUT" "refused(ancestry_unknown)"
  shows "it says the checkout is shallow" "$DEPLOY_OUT" "shallow"
  shows "it says what would make it answerable" "$DEPLOY_OUT" "fetch --unshallow"
  same "the install record was not touched" "$(cat "$UNKNOWN/installed.txt")" "$UNKNOWN_BEFORE"
  deploy_in "$SHALLOWTREE" "$UNKNOWN" --force --reason "the node's build is on no branch and I accept the loss"
  hides "with --force --reason it goes on" "$DEPLOY_OUT" "refused(ancestry_unknown)"
  shows "...and the override names what it overrode" "$(cat "$UNKNOWN/deploy.log" 2>/dev/null)" "overrode=ancestry_unknown"
else
  bad "could not make a shallow clone of this checkout (file:// transport refused)"
fi

echo "test-deploy-ancestry: a running binary built from a dirty tree is not replaceable for free"
# dirty=true means those bytes are a commit PLUS uncommitted edits, and the commit-level ancestry question
# cannot see them at all: the target contains the commit, and the edits go anyway.
DIRTY="$WORK/dirty-install"; mkdir -p "$DIRTY"
{ echo '#!/bin/sh'; echo 'case "$1" in';
  echo "  --build-info) printf 'version=9.9.9\\ncommit=$HEAD\\ntree=$TREE_SHA\\ndirty=true\\nsource=git\\nbuilt_epoch=1\\nancestors=3\\nancestors_complete=true\\n' ;;";
  echo '  --contains) exit 0 ;;';
  echo "  --version) echo 'wasm-agent 9.9.9' ;;";
  echo '  *) exit 0 ;;'; echo 'esac'; } > "$DIRTY/wa"
chmod +x "$DIRTY/wa"; cp "$DIRTY/wa" "$DIRTY/wa-sentinel"
printf 'commit=%s\nvia=deploy.sh\n' "$HEAD" > "$DIRTY/installed.txt"
DIRTY_BEFORE="$(cat "$DIRTY/installed.txt")"
deploy "$DIRTY" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "it replaced bytes that carry uncommitted work"
shows "the refusal is by name" "$DEPLOY_OUT" "downgrade refused(dirty_running_binary)"
same "the install record was not touched" "$(cat "$DIRTY/installed.txt")" "$DIRTY_BEFORE"
deploy "$DIRTY" --force --reason "the uncommitted edits on that node are mine to lose"
hides "with --force --reason it goes on" "$DEPLOY_OUT" "downgrade refused(dirty_running_binary)"
shows "...and the override is a record" "$(cat "$DIRTY/deploy.log" 2>/dev/null)" "running_dirty=true"

echo "test-deploy-ancestry: every force is recorded, and a force without a reason is refused before any work"
shows "the reason is in deploy.log as its own line" "$(cat "$INSTALL/deploy.log" 2>/dev/null)" "force_requested reason=retiring the feature on purpose"
shows "...with who asked" "$(cat "$INSTALL/deploy.log" 2>/dev/null)" "by="
shows "...and when" "$(cat "$INSTALL/deploy.log" 2>/dev/null)" "at=20"
deploy "$INSTALL" --force
shows "the parse-time refusal names the rule" "$DEPLOY_OUT" "override_reason_required"
shows "...and says nothing was resolved or built" "$DEPLOY_OUT" "Nothing was resolved, built or installed"
case "$DEPLOY_OUT" in
  *"running binary:"*|*"installed.txt"*) bad "the refusal happened after the deploy had started reading the install" ;;
  *) ok "it refused before touching the install (no ancestry work was done)" ;;
esac


echo "test-deploy-ancestry: a commit no branch on the remote has (item 7, on the deploy path)"
# MEASURED 18/11: the artifact came from a helper that had fetched a ref into a detached HEAD, and nothing on the
# publishing side asked whether the commit was one anybody else could see. The same question is asked here, before
# the build, so that a refusal leaves the node untouched instead of stopping halfway through an install.
EMPTYREMOTE="$WORK/empty.git"; git init -q --bare "$EMPTYREMOTE"
SHAREDTREE="$WORK/shared-tree"
if git clone -q --shared "$ROOT" "$SHAREDTREE" 2>/dev/null; then
  git -C "$SHAREDTREE" config user.email test@example.com; git -C "$SHAREDTREE" config user.name test
  git -C "$SHAREDTREE" remote set-url origin "$EMPTYREMOTE"
  git -C "$SHAREDTREE" update-ref refs/remotes/origin/main "$(git -C "$SHAREDTREE" rev-parse HEAD)"
  # the same statement as the fixtures above: this clone IS the main checkout, so the runtime-binding preflight
  # (deploy.sh step 0c) lets the run reach the rule under test. Round 4: the rebase brought that preflight, and
  # without this line every case of this file stopped at "found 0 on branch refs/heads/main" instead.
  git -C "$SHAREDTREE" checkout -q -B main HEAD
  FRESH="$WORK/fresh-install"; mkdir -p "$FRESH"
  deploy_in "$SHAREDTREE" "$FRESH" --reason "an ordinary deploy"
  [ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "a deploy installed a commit no branch on the remote has"
  shows "the refusal is by name" "$DEPLOY_OUT" "refused(commit_not_on_pushed_branch)"
  shows "it says the remote was asked and answered no" "$DEPLOY_OUT" "no branch contains it"
  shows "it says nothing was built or installed" "$DEPLOY_OUT" "Nothing was built and nothing was installed"
  same "nothing was installed" "$([ -x "$FRESH/wa" ] && echo yes || echo no)" "no"
  deploy_in "$SHAREDTREE" "$FRESH" --force --reason "a test node, this branch is mine"
  hides "with --force --reason it goes on" "$DEPLOY_OUT" "refused(commit_not_on_pushed_branch)"
  shows "...and the override is recorded" "$(cat "$FRESH/deploy.log" 2>/dev/null)" "commit_not_on_pushed_branch accepted with --force --reason"
else
  bad "could not clone this checkout for the unshared-commit case"
fi

echo "test-deploy-ancestry: a binary that cannot name its commit is UNKNOWN, not a first install (item 1)"
# Round 3 of the review: an install whose binary predates --build-info, beside no record (or beside a record with
# commit= and no sha256=), left RUNNING_COMMIT empty - and this script printed "this is a first install, not a
# downgrade" and replaced it with no ancestry question at all. A binary is the test: nothing installed means the
# directory is empty, not that the binary has nothing to say.
NOPROOF="$WORK/noproof-install"; mkdir -p "$NOPROOF"
printf '#!/bin/sh\nexit 1\n' > "$NOPROOF/wa"; chmod +x "$NOPROOF/wa"; cp "$NOPROOF/wa" "$NOPROOF/wa-sentinel"
deploy "$NOPROOF" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "an install nothing can identify was replaced as if empty"
shows "the refusal is by name" "$DEPLOY_OUT" "refused(running_commit_unprovable)"
shows "it says nothing can show whether the tree contains it" "$DEPLOY_OUT" "so nothing can show whether this tree"
hides "...and it does not call it a first install" "$DEPLOY_OUT" "this is a first install"
deploy "$NOPROOF" --force --reason "the node's rebuild is not here yet"
hides "with --force --reason it goes on" "$DEPLOY_OUT" "refused(running_commit_unprovable)"
shows "...and the override names what it overrode" "$(cat "$NOPROOF/deploy.log" 2>/dev/null)" "overrode=running_commit_unprovable"
shows "...and is a record with the reason" "$(cat "$NOPROOF/deploy.log" 2>/dev/null)" "nothing here can prove which commit is installed"

echo "test-deploy-ancestry: a record with commit= and no sha256= is a belief, not evidence (item 1)"
NOSHA="$WORK/nosha-install"; mkdir -p "$NOSHA"
printf '#!/bin/sh\nexit 1\n' > "$NOSHA/wa"; chmod +x "$NOSHA/wa"; cp "$NOSHA/wa" "$NOSHA/wa-sentinel"
printf 'commit=1111111111111111111111111111111111111111\nvia=deploy.sh\n' > "$NOSHA/installed.txt"
NOSHA_BEFORE="$(cat "$NOSHA/installed.txt")"
deploy "$NOSHA" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "it refused (exit $DEPLOY_RC)" || bad "a record with no sha256= was trusted as the running commit"
shows "the refusal is by name" "$DEPLOY_OUT" "refused(running_commit_unprovable)"
shows "it names the missing sha256" "$DEPLOY_OUT" "no sha256="
same "the record was not touched" "$(cat "$NOSHA/installed.txt")" "$NOSHA_BEFORE"

echo "test-deploy-ancestry: the node's pin is read BEFORE the build (item 6)"
# A pin is a record that this node was put somewhere on purpose (a rollback writes it). Reading it after the
# build spends an hour of compilation to learn what a two-millisecond file read would have said.
printf 'fixture-node\n' > "$AGENT_HOME/.wasm-agent/node.name"
cat > "$AGENT_HOME/.wasm-agent/pins.txt" <<'PINS'
schema=wasm-agent-pins/1
id=pin00001
node=fixture-node
kind=rollback
state=active
commit=2222222222222222222222222222222222222222
rolled_back_from=3333333333333333333333333333333333333333
reason=held on the build the operator wants
by=operator
at=2026-11-18T10:00:00Z
PINS
PINFRESH="$WORK/pinned-install"; mkdir -p "$PINFRESH"
deploy "$PINFRESH" --reason "an ordinary deploy"
[ "$DEPLOY_RC" != 0 ] && ok "the deploy is refused (exit $DEPLOY_RC)" || bad "a deploy walked over the node's own pin"
shows "the refusal is by name" "$DEPLOY_OUT" "node_pinned"
shows "it quotes the pin" "$DEPLOY_OUT" "held on the build the operator wants"
hides "nothing was built" "$DEPLOY_OUT" "deploy: building"
shows "and it says so" "$DEPLOY_OUT" "Nothing was built and nothing was installed"
shows "the way out names --unpin" "$DEPLOY_OUT" "--unpin --reason"
deploy "$PINFRESH" --force --reason "the operator released this pin on purpose"
hides "with --force --reason the gate opens" "$DEPLOY_OUT" "node_pinned: fixture-node"
shows "...and the force is recorded with its rule" "$(cat "$PINFRESH/deploy.log" 2>/dev/null)" "force_requested rule=node_pinned"
rm -f "$AGENT_HOME/.wasm-agent/pins.txt"

echo "test-deploy-ancestry: the source of the rule is one file, shipped beside the running copy"
grep -q 'install-record.sh' "$ROOT/scripts/deploy.sh" && ok "deploy.sh ships and sources the one ancestry verdict" || bad "deploy.sh does not use scripts/lib/install-record.sh"
grep -q 'wa_ancestry_verdict' "$ROOT/scripts/upgrade.sh" && ok "upgrade.sh asks the same verdict" || bad "upgrade.sh has its own idea of a downgrade"

printf 'test-deploy-ancestry: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
