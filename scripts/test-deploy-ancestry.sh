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
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"; INSTALL="$WORK/install"; SHIM="$WORK/bin"
mkdir -p "$INSTALL" "$SHIM"
# A machine with no service: the fixture is a directory, not this machine's install, and deploy.sh asks systemd
# and the port who owns the node. systemctl answering nothing is the honest fixture for "no service here".
printf '#!/bin/sh\nexit 1\n' > "$SHIM/systemctl"; chmod +x "$SHIM/systemctl"

git clone -q --shared "$ROOT" "$TREE" || { echo "test-deploy-ancestry: cannot clone $ROOT" >&2; exit 1; }
git -C "$TREE" config user.email test@example.com
git -C "$TREE" config user.name test
HEAD="$(git -C "$TREE" rev-parse HEAD)"
# The fixture's main IS the commit under test: this checkout is on its main, which is what deploy.sh's rule 2
# asks, and it keeps the test about the ancestry rule rather than about the branch this work happens to be on.
git -C "$TREE" update-ref refs/remotes/origin/main "$HEAD"
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
# With the binary unable to answer, the guard falls back to installed.txt and SAYS SO - it does not refuse on
# its own ignorance, and it does not pretend the record is the binary's answer.
DEADINSTALL="$WORK/dead-install"; mkdir -p "$DEADINSTALL"
printf '#!/bin/sh\nexit 1\n' > "$DEADINSTALL/wa"; chmod +x "$DEADINSTALL/wa"; cp "$DEADINSTALL/wa" "$DEADINSTALL/wa-sentinel"
printf 'commit=%s\nvia=deploy.sh\n' "$LOST" > "$DEADINSTALL/installed.txt"
deploy "$DEADINSTALL"
shows "with no answer from the binary the record is used, and named" "$DEPLOY_OUT" "could not be asked"
shows "...and it still refuses, because the record is newer than this tree" "$DEPLOY_OUT" "downgrade refused(node_not_contained)"

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

echo "test-deploy-ancestry: the source of the rule is one file, shipped beside the running copy"
grep -q 'install-record.sh' "$ROOT/scripts/deploy.sh" && ok "deploy.sh ships and sources the one ancestry verdict" || bad "deploy.sh does not use scripts/lib/install-record.sh"
grep -q 'wa_ancestry_verdict' "$ROOT/scripts/upgrade.sh" && ok "upgrade.sh asks the same verdict" || bad "upgrade.sh has its own idea of a downgrade"

printf 'test-deploy-ancestry: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
