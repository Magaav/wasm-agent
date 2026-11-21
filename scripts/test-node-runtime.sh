#!/usr/bin/env bash
# ONE answer to "which node" for every deploy path, and a NAMED refusal when there is none.
#
# THE FAILURE THIS PINS (21/11, node-7ddbfa98036a rollout, hand fix 1 of 5). "wa update <node> --binary" runs
# scripts/deploy.sh from the node's own serve operation, and that operation's PATH is the SERVICE's: it does
# not carry the user's Node install (mail and nextcloud keep theirs at ~/.local/bin/node/bin/node). Step 0c -
# the runtime-install binding - therefore died with "line 436: node: command not found" and the remote update
# refused: a correct refusal with a cause nobody can act on. The operator's only fix was to install node by
# hand where the service happens to look.
#
# WHAT RUNS HERE, AND WHAT DOES NOT. The REAL scripts/deploy.sh, as a separate process, with a PATH that
# carries NO node at all and a private HOME. That is the only way to see this defect: a test that calls the
# resolver directly would pass while deploy.sh still said "node". The tree is a scratch Git repository that is
# its own origin (deploy.sh step 0b waits for HEAD == origin/main), it is never this checkout, and the port is
# one nobody listens on. The build cannot start: the workspace is a stub, so if anything ever got past the
# steps under test it would fail in seconds instead of spending a toolchain.
#
# The node the deploy should find is a WRAPPER around this machine's real node that first appends its argv to
# a marker file - so "which node ran" is an observation, not an inference from log wording.
#
# Usage: bash scripts/test-node-runtime.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
RESOLVER="$ROOT_DIR/scripts/lib/node-runtime.sh"
checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s %s\n' "$2" "${3:-}"; fi; }
fail_hard() { echo "test-node-runtime: $*" >&2; exit 1; }

[ -f "$DEPLOY" ] || fail_hard "no $DEPLOY to test"
# A MISSING RESOLVER IS A FAILED CHECK, NOT AN EXIT. On the code before this change the lib does not exist,
# and a test that stopped at its first line would say only that - while the cases below are what show the
# defect (a deploy that says "node: command not found", or a refusal no operator can act on). The lib is
# sourced only when it is there; the cases that need it are already guarded by their own assertions.
RESOLVER_PRESENT=0
if [ -f "$RESOLVER" ]; then RESOLVER_PRESENT=1; fi
ok "$RESOLVER_PRESENT" "every deploy path goes through one node resolver (scripts/lib/node-runtime.sh)" "no $RESOLVER"

# The scratch-home rule (scripts/lib/scratch-home.sh): this test hands a node a home, so it must prove the home
# is not the operator's before anything runs.
. "$ROOT_DIR/scripts/lib/scratch-home.sh" || fail_hard "no scripts/lib/scratch-home.sh to prove the scratch home"

# WHERE THE SCRATCH TREE LIVES. A node gives every child TMPDIR inside its own root (docs/ONEROOT.md), so on a
# node this test's TMPDIR is inside the operator's store - and the scratch-home guard below is right to refuse
# that. The guard is not loosened for the test's convenience: the test moves its own scratch root out of the
# store instead.
SCRATCH_ROOT="${TMPDIR:-/tmp}"
case "$SCRATCH_ROOT" in
  "${HOME:-/nonexistent}"|"${HOME:-/nonexistent}"/*) SCRATCH_ROOT=/tmp ;;
esac
W="$(mktemp -d "$SCRATCH_ROOT/wa-node-runtime-XXXXXX")" || fail_hard "no scratch directory outside the node store"
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT
HOME_DIR="$W/home"
INSTALL="$W/install"
TREE="$W/tree"
FARM="$W/bin"
mkdir -p "$HOME_DIR" "$INSTALL" "$TREE/rust" "$TREE/scripts" "$FARM" "$W/calls"
wa_scratch_home_guard "$HOME_DIR" || fail_hard "this test would act on the operator's own node home"

# ---- the node-less PATH ---------------------------------------------------------------------------------
# Every executable this machine has, EXCEPT any node. A farm of symlinks, not a filtered PATH: /usr/bin holds
# this host's own node, so dropping the directory that carries node would also drop git, sed and uname.
for f in /usr/bin/* /usr/local/bin/* /bin/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in node|nodejs|node-gyp|npx|npm|corepack) continue ;; esac
  ln -sf "$f" "$FARM/$base" 2>/dev/null || true
done
[ -z "$(PATH="$FARM" command -v node 2>/dev/null || true)" ] || fail_hard "the fixture PATH still carries a node, so this test cannot prove anything"
[ -n "$(PATH="$FARM" command -v git 2>/dev/null || true)" ] || fail_hard "the fixture PATH has no git, so deploy.sh would fail for an unrelated reason"

REAL_NODE="$(command -v node 2>/dev/null || true)"
[ -n "$REAL_NODE" ] || fail_hard "this machine has no node to wrap, so the fixture cannot prove a node was found"

# ---- the scratch tree: a real repository that is its own origin ------------------------------------------
printf '[workspace]\n' > "$TREE/rust/Cargo.toml"
cp "$ROOT_DIR/scripts/runtime-install-binding.mjs" "$TREE/scripts/"
printf 'the node this deploy would replace\n' > "$INSTALL/wa"
# A HAND-WRITTEN STUB, and why: scripts/lib/turn-guard.sh refuses a deploy started from a CLI turn unless a
# sentinel is supervising the install ("deploying from a CLI turn needs a sentinel supervising the node"). That
# gate is not what this test is about - it is about WHICH node the deploy runs - so the fixture satisfies it the
# way a real install does: a wa-sentinel beside the binary whose "status" reports the one line the guard reads
# (turn-guard.sh, sentinel_supervises). scripts/lib/contract-host.lua is the shared fake for host CAPABILITIES,
# not for the sentinel binary, so it does not cover this; the answer is the documented status line and nothing
# else. The stub is never trusted with anything: it prints, it does not supervise.
{
  printf '#!/bin/sh\n'
  printf 'case "$1" in status) echo "sentinel: up (fixture)"; exit 0 ;; esac\n'
  printf 'exit 2\n'
} > "$INSTALL/wa-sentinel"
chmod +x "$INSTALL/wa-sentinel"
git -C "$TREE" init -q --initial-branch=main || fail_hard "cannot init the scratch tree"
git -C "$TREE" add -A || fail_hard "cannot stage the scratch tree"
git -C "$TREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture tree" || fail_hard "cannot commit the scratch tree"
git -C "$TREE" remote add origin "$TREE" && git -C "$TREE" fetch -q origin || fail_hard "cannot make the scratch tree its own origin"

PORT=""
for candidate in $(seq 24000 $((24000 + 60))); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then PORT="$candidate"; break; fi
done
[ -n "$PORT" ] || PORT=25999

# A node that reports itself before it runs: the marker is how "which node" is OBSERVED.
install_wrapper_node() {
  mkdir -p "$1" || return 1
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "$W/calls/node"
    printf 'exec %s "$@"\n' "$REAL_NODE"
  } > "$1/node" || return 1
  chmod +x "$1/node"
}

run_deploy() {
  local home="${RUN_HOME:-$HOME_DIR}"
  last_out="$(cd "$TREE" && env -i \
      HOME="$home" USERPROFILE="$home" PATH="$FARM" \
      WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$INSTALL" WA_PORT="$PORT" WA_CLIENT_PORT="$((PORT + 1))" \
      WA_SERVICE_UNIT_FILE="$W/no-such-service.unit" WA_SERVICE_PID=0 \
      WA_NODE_SYSTEM_DIRS="$W/no-system-dirs" \
      WA_DEPLOY_BUILD_ONLY=1 \
      timeout 120 bash "$DEPLOY" --reason "node runtime fixture" 2>&1)"
  last_exit=$?
}

# ---- (a) the node where the user's own install lives is FOUND, and it is that node that runs --------------
install_wrapper_node "$HOME_DIR/.local/bin/node/bin" || fail_hard "cannot stage the wrapper node"
: > "$W/calls/node"
run_deploy
ok "$([ -s "$W/calls/node" ] && echo 1 || echo 0)" \
  "a deploy whose PATH has no node still runs one, from ~/.local/bin/node/bin" "exit $last_exit: $(printf '%s' "$last_out" | head -2 | tr '\n' '|')"
ok "$(grep -q 'runtime-install-binding.mjs' "$W/calls/node" 2>/dev/null && echo 1 || echo 0)" \
  "and the step that needed it - the runtime-install binding (0c) - is what ran it" "$(head -1 "$W/calls/node" 2>/dev/null)"
ok "$(case "$last_out" in *"command not found"*) echo 0 ;; *) echo 1 ;; esac)" \
  "the deploy never says 'node: command not found'" "$(printf '%s' "$last_out" | grep -m1 'command not found' || true)"
ok "$(case "$last_out" in *node_runtime_missing*) echo 0 ;; *) echo 1 ;; esac)" \
  "and it does not refuse with node_runtime_missing while a node is there"

# ---- (b) with no node anywhere the refusal is NAMED, and it says where it looked --------------------------
# A FRESH home, not the one case (a) used: the wrapped node is this machine's mise node, and mise writes its
# own state (and its shims directory, which carries a node) into whatever HOME it runs under. Case (a) therefore
# left a node in a place the resolver is right to search - measured while writing this test, and the reason
# this case gets a home of its own instead of a cleaned-up one.
RUN_HOME="$W/home-missing"
mkdir -p "$RUN_HOME"
: > "$W/calls/node"
run_deploy
RUN_HOME=""
ok "$([ "$last_exit" != "0" ] && echo 1 || echo 0)" "a deploy with no node at all refuses" "exit $last_exit"
ok "$(case "$last_out" in *"refused(node_runtime_missing)"*) echo 1 ;; *) echo 0 ;; esac)" \
  "the refusal is named node_runtime_missing" "$(printf '%s' "$last_out" | head -3 | tr '\n' '|')"
ok "$(case "$last_out" in *".local/bin/node/bin"*) echo 1 ;; *) echo 0 ;; esac)" \
  "the refusal names the places that were looked in" "$(printf '%s' "$last_out" | grep -m1 node_runtime_missing || true)"
ok "$(case "$last_out" in *"command not found"*) echo 0 ;; *) echo 1 ;; esac)" \
  "and it is not a shell's 'command not found' from a line number"

# ---- (c) WA_NODE_BIN is obeyed, and a broken one is a refusal, never a silent second choice --------------
# Without the lib there is nothing to call: the checks above already reported the defect these would repeat.
install_wrapper_node "$W/named"
NAMED_OUT=""
BROKEN="rc=3 (no resolver)"
if [ "$RESOLVER_PRESENT" = "1" ]; then
NAMED_OUT="$(env -i HOME="$HOME_DIR" PATH="$FARM" WA_NODE_BIN="$W/named/node" WA_NODE_SYSTEM_DIRS="$W/no-system-dirs" \
  bash -c '. "$1"; wa_node_bin' _ "$RESOLVER")"
BROKEN="$(env -i HOME="$HOME_DIR" PATH="$FARM" WA_NODE_BIN="$W/named/gone" bash -c '. "$1"; wa_node_require; echo "rc=$?"' _ "$RESOLVER")"
fi
ok "$([ "$NAMED_OUT" = "$W/named/node" ] && echo 1 || echo 0)" "WA_NODE_BIN is used when it is executable" "$NAMED_OUT"
ok "$(case "$BROKEN" in *"rc=3"*) echo 1 ;; *) echo 0 ;; esac)" \
  "a WA_NODE_BIN that is not there is a refusal, not a search that quietly picks another node" "$BROKEN"

# ---- (d) one resolver, not a second list: no deploy path still spells a bare 'node' ----------------------
strays="$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*node[[:space:]]+["$]' "$DEPLOY" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
ok "$([ -z "$strays" ] && echo 1 || echo 0)" "deploy.sh calls node only through the resolver's answer" "$(printf '%s' "$strays" | head -3 | tr '\n' '|')"
nodeless="$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*node[[:space:]]+["$]' "$ROOT_DIR/scripts/upgrade.sh" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
ok "$([ -z "$nodeless" ] && echo 1 || echo 0)" "upgrade.sh calls no bare node either" "$(printf '%s' "$nodeless" | head -3 | tr '\n' '|')"
ok "$(grep -q 'node-runtime.sh' "$DEPLOY" && echo 1 || echo 0)" "deploy.sh sources the one resolver"
ok "$(grep -q 'refused(node_runtime_lib_missing)' "$DEPLOY" && echo 1 || echo 0)" \
  "and refuses by name when the resolver is not beside it (an installed copy without the lib is not a silent fallback)"

# ---- (e) the wrapper a peer runs carries the same PATH ----------------------------------------------------
WRAPPER_ROWS="$(grep -c 'node-runtime.sh' "$ROOT_DIR/lua/core/remote_update.lua" 2>/dev/null || echo 0)"
ok "$([ "$WRAPPER_ROWS" -ge 1 ] && echo 1 || echo 0)" \
  "the remote-update wrapper sources the same resolver for the deploy it execs" "$WRAPPER_ROWS row(s)"

echo "test-node-runtime: $checks checks, $failed failed"
[ "$failed" = "0" ]
