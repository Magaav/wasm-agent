#!/usr/bin/env bash
# WHAT A REQUEST RECORDS, AND WHAT THE TEXTS SAY, WHEN A NAMED MAIN IS BEHIND ORIGIN (24/11, G blocker).
#
#   WA_BIN=<built wa> bash scripts/test-deploy-target.sh
#
# MEASURED on `work`: `git config wa.deployRemote host` names a git bundle as a source of main, and that bundle's
# main was 74d48431 - seven days behind origin/main. `target_commit_at` recorded the FIRST named main that
# resolved, so EVERY request on that node recorded 74d48431, while `deploy.sh` built HEAD (deploy.sh:484-503)
# and installed 345e51be. The installs were right and every text that spoke by the record was wrong: the pause
# line's "(target commit ...)", the line for an install that did not happen, and the retry hint.
#
# This row runs the two REAL processes against one scratch home and one fixture repository:
#   * the sentinel writes the request (`wa-sentinel request deploy`), exactly as an operator's would;
#   * the node's own Lua reads the box and prints the sentences a paused and a released session read.
#
# Asserted, in a repository where the bundle's main is BEHIND origin/main (the measured shape):
#   1. the request's `target_commit` is origin/main - what a deploy would install - and never the bundle's main;
#   2. the pause line, the "did not happen" line and the release line all name that commit, and none names the
#      bundle's;
#   3. `wa-sentinel status` says the same commit for the waiting request - one more reader of the record.
#
# Hermetic: its own WASM_AGENT_HOME, install directory, repository, ledger and git config; no node, no port, no
# model, no network, no rendezvous, no fleet. SKIP (never a pass) when a binary it needs is not built.
set -uo pipefail
# This row never reads its caller's stdin: a child that inherited it would eat a row list (see
# scripts/test-deploy-wait.sh, 22/11).
exec </dev/null

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 76

checks=0
fail() { echo "test-deploy-target: $*" >&2; exit 1; }
skip() { printf 'SKIP test-deploy-target: %s\n' "$*"; exit 0; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }
same() { if [ "${1:-}" = "${2:-}" ]; then ok "$3"; else fail "$3: expected $2, got ${1:-<empty>}"; fi; }
neq() { if [ "${1:-}" != "${2:-}" ]; then ok "$3"; else fail "$3: both are $2"; fi; }
says() { case "${1:-}" in *"${2}"*) ok "$3" ;; *) fail "$3: expected $2 in: ${1:-<empty>}" ;; esac; }
never() { case "${1:-}" in *"${2}"*) fail "$3: named $2 in: ${1:-<empty>}" ;; *) ok "$3" ;; esac; }

find_bin() {
  local want="$1" candidate
  shift
  for candidate in "$@"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
WA="$(find_bin wa "${WA_BIN:-}" "$TARGET_DIR/release/wa" "$TARGET_DIR/debug/wa" \
  "$ROOT/rust/target/release/wa" "$ROOT/rust/target/debug/wa" "$(command -v wa 2>/dev/null || true)")" \
  || skip "no wa binary: set WA_BIN, or build rust/wa-host"
SENTINEL="$(find_bin wa-sentinel "${WA_SENTINEL:-}" "$TARGET_DIR/release/wa-sentinel" "$TARGET_DIR/debug/wa-sentinel" \
  "$ROOT/rust/target/release/wa-sentinel" "$ROOT/rust/target/debug/wa-sentinel" \
  "$ROOT/rust/wa-sentinel/target/release/wa-sentinel" "$ROOT/rust/wa-sentinel/target/debug/wa-sentinel" \
  "$(command -v wa-sentinel 2>/dev/null || true)")" \
  || skip "no wa-sentinel binary: build rust/wa-sentinel"
command -v git >/dev/null 2>&1 || skip "no git on this host"

# A scratch directory the node's own guard accepts (scripts/lib/scratch-home.lua refuses a home inside the
# operator store, and on a node whose TMPDIR IS the operator store's tmp this row would otherwise be refused -
# measured on avell, 24/11). /tmp first; a base that cannot be made hermetic is a SKIP, never a pass.
SCRATCH_BASE=/tmp
[ -d "$SCRATCH_BASE" ] && [ -w "$SCRATCH_BASE" ] || skip "no writable /tmp for a scratch home outside the operator store"
case "$SCRATCH_BASE" in "${HOME:-/nonexistent}/.wasm-agent"*) skip "the scratch base is the operator store" ;; esac
WORK="$(mktemp -d "$SCRATCH_BASE/wa-deploy-target-XXXXXX")" || skip "no scratch directory under $SCRATCH_BASE"
trap 'rm -rf "$WORK"' EXIT
NODE_HOME="$WORK/home"
INSTALL="$WORK/install"
TREE="$WORK/tree"
DB="$WORK/wa.db"
mkdir -p "$NODE_HOME" "$INSTALL" || fail "cannot create the scratch directories"

# A node store of this row's own, and a refusal to run against the machine's: the real box is
# $HOME/.wasm-agent/sentinel, and this row writes a request.
REAL_STORE="${HOME:-/nonexistent}/.wasm-agent/sentinel"
[ "$NODE_HOME/.wasm-agent/sentinel" != "$REAL_STORE" ] || fail "the scratch store is the node's own: $REAL_STORE"

# ---- the fixture repository: HEAD = origin/main; a named remote's main seven days BEHIND it ----------------
git init -q --initial-branch=main "$TREE" || fail "cannot init the fixture repository"
git -C "$TREE" config user.name "deploy-target fixture"
git -C "$TREE" config user.email "deploy-target@example.invalid"
printf 'the bundle tip\n' > "$TREE/README"
git -C "$TREE" add -A >/dev/null 2>&1 || fail "cannot stage the fixture"
git -C "$TREE" commit -qm "the bundle tip" || fail "cannot commit the fixture"
STALE="$(git -C "$TREE" rev-parse HEAD)" || fail "cannot read the fixture's tip"
printf 'seven days of main\n' >> "$TREE/README"
git -C "$TREE" commit -qam "the seven days after it" || fail "cannot commit the fixture's second commit"
MAIN="$(git -C "$TREE" rev-parse HEAD)" || fail "cannot read the fixture's main"
git -C "$TREE" update-ref refs/remotes/origin/main "$MAIN" || fail "cannot pin origin/main"
git -C "$TREE" update-ref refs/remotes/host/main "$STALE" || fail "cannot pin the bundle's main"
git -C "$TREE" config wa.deployRemote host || fail "cannot name the remote"
neq "$STALE" "$MAIN" "the fixture made two commits"
same "$(git -C "$TREE" rev-list --count HEAD..host/main)" "0" "the fixture: HEAD is not behind the bundle"
same "$(git -C "$TREE" rev-list --count host/main..HEAD)" "1" "the fixture: the bundle IS behind HEAD, which is the defect"

# ---- a real sentinel writes the request ----------------------------------------------------------------
# The node's Lua is read from THIS checkout (`wa` otherwise loads the modules embedded in the binary it
# was built with, which would test a different tree).
export WASM_AGENT_LUA_ROOT="$ROOT"
export WASM_AGENT_HOME="$NODE_HOME"
export WA_DEPLOY_ROOT="$TREE"
export WA_INSTALL_DIR="$INSTALL"
# Nothing on this machine's service is read: no unit file, no service pid, no port.
export WA_SERVICE_UNIT_FILE="$WORK/no-such-service.unit" WA_SERVICE_PID=0
unset WA_SENTINEL_SUPERVISOR 2>/dev/null || true
export WASM_AGENT_PROVENANCE=operator

out="$("$SENTINEL" request deploy --reason "the stale bundle" 2>&1)" \
  || fail "the sentinel refused to write the request: $out"
BOX="$NODE_HOME/.wasm-agent/sentinel/requests"
shopt -s nullglob
requests=("$BOX"/*.json)
shopt -u nullglob
[ "${#requests[@]}" -eq 1 ] || fail "expected one request in the box, found ${#requests[@]}: ${requests[*]:-none}"
RECORDED="$(sed -n 's/.*"target_commit":"\([0-9a-f]\{40\}\)".*/\1/p' "${requests[0]}" | head -1)"
same "$RECORDED" "$MAIN" "the request records the commit a deploy would install (origin/main)"
neq "$RECORDED" "$STALE" "and never the named remote's main that is behind it"

# The install record the release line reads, in the installer's own format (`commit=`). Its only writer
# (scripts/lib/install-record.sh) records a real binary's build info, which needs a real swap; what is asserted
# here is the SENTENCE and the commit it names, read by the product's reader (lua/core/update.lua).
printf 'commit=%s\nbranch=main\n' "$MAIN" > "$INSTALL/installed.txt" || fail "cannot write the install record"

# ---- the node's own readers say the same commit --------------------------------------------------------
lines="$(WA_SCRIPT=scripts/lib/deploy-target-e2e.lua DW_WAS="1111111111111111111111111111111111111111" \
  "$WA" --db "$DB" 2>&1)" || fail "the reader refused the request the sentinel wrote: $lines"
lines="$(printf '%s\n' "$lines" | grep -v 'served natively' || true)"
TO="$(printf '%s\n' "$lines" | sed -n 's/^to //p' | head -1)"
PAUSE="$(printf '%s\n' "$lines" | sed -n 's/^pause //p' | head -1)"
NOPE="$(printf '%s\n' "$lines" | sed -n 's/^not-happened //p' | head -1)"
RESUME="$(printf '%s\n' "$lines" | sed -n 's/^resume //p' | head -1)"

same "$TO" "$MAIN" "the waiting request names the commit that is coming"
says "$PAUSE" "${MAIN:0:12}" "the pause line's (target commit ...) names it"
never "$PAUSE" "${STALE:0:12}" "and not the bundle's main"
says "$NOPE" "${MAIN:0:12}" "the 'did not happen' line names it"
never "$NOPE" "${STALE:0:12}" "and not the bundle's main"
# THE LINE NOW NAMES THE PROGRAM AND THE TREE (factory-small-items item 1, 25/11): the record written above is a
# FULL build's, so its `commit=` is the bytes as well as the tree, the program is printed with the `wa --version`
# `v`, and the record named no separate `lua_tree=` before the swap - which the line says as `not recorded`.
# Both assertions got NARROWER (they name more), not looser: the same commit, plus the tree, plus the OLD side.
says "$RESUME" "now runs program v${MAIN:0:12}, tree ${MAIN:0:12}" "the release line says the node now runs the commit installed.txt holds, program and tree"
says "$RESUME" "(was program not recorded, tree 111111111111)" "and names the build it replaced as the OLD one"

# ---- and the sentinel's own status, which reads the record -------------------------------------------
status="$("$SENTINEL" status 2>&1 || true)"
says "$status" "$MAIN" "wa-sentinel status names the commit the request recorded"
never "$status" "$STALE" "and not the bundle's main"

echo "deploy target ok ($checks checks)"
