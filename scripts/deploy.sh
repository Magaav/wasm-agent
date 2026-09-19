#!/usr/bin/env bash
# Deploy a node: the one gate through which a build becomes the installed one.
#
#   bash scripts/deploy.sh [--reason "why"]
#
# Why this exists. Two parties install this node - the operator and the agent working in it - and for a day
# they installed over each other: the agent rebuilt from its worktree while a fix was being deployed from
# another, so "what is running" and "what is in main" disagreed, and a bug was diagnosed twice from a binary
# that did not contain the instrumentation meant to find it. That is not a code bug, it is a missing gate.
#
# So installing goes through here, and here refuses to install something that cannot be explained:
#
#   1. the tree must be clean - an install from a half-edited tree is a build nobody can reproduce;
#   2. the tree must not be behind origin/main - a node that cannot see main cannot see its own fixes, and
#      installing from a stale branch is how a node served a diff route that answered unknown_action:patch;
#   3. the build must answer /health on a scratch port before it goes near the running node;
#   4. the restart is upgrade.sh's job, because it already waits for idle, stops by pid, verifies and rolls
#      back - and because the first version of this script reimplemented it, stopped one of two listeners on
#      the port, failed to bind, and then reported success because the *other* node answered /health. The
#      verification was reading someone else's outcome, which is the trap this project keeps writing down;
#   5. what was installed is recorded, and the pid answering must be the pid the install recorded.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
[ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
PORT="${WA_PORT:-8799}"
CLIENT_PORT="${WA_CLIENT_PORT:-8800}"

# A refusal is evidence: the gate saying no, with a reason, at a moment. Printing to stderr is not enough -
# after the fact, "did it refuse anything?" has to be answerable. Every refusal is appended to
# <install>/deploy.log with the time, what it was about, and why.
fail() {
  echo "deploy: $*" >&2
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT:-unknown}" "${BRANCH:-unknown}" "$*" \
    >> "$INSTALL_DIR/deploy.log" 2>/dev/null
  exit 1
}

if [ "${WASM_AGENT_IN_TURN:-}" = "1" ]; then
  fail "cannot deploy from a running turn: it cannot become idle while this command waits. Build, then request an upgrade through wa-sentinel; see skills/self-update/SKILL.md"
fi

# 1. Clean. A build from a half-edited tree is not reproducible, and the file being edited is often the one
#    that matters.
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
[ "$DIRTY" = "0" ] || fail "the tree has $DIRTY uncommitted change(s); commit or stash them first"

# 2. Current. Behind main is the failure this project has paid for repeatedly.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch -q origin 2>/dev/null || true
if git rev-parse --verify -q origin/main >/dev/null; then
  BEHIND="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  [ "$BEHIND" = "0" ] || fail "this tree is $BEHIND commit(s) behind origin/main; merge main first (a node that cannot see main cannot see its own fixes)"
fi
COMMIT="$(git rev-parse --short HEAD)"

echo "deploy: $BRANCH@$COMMIT -> $INSTALL_DIR (port $PORT)"

# 3. Build.
echo "deploy: building"
( cd rust && cargo build --release --offline -p wa-host ) || fail "the build failed"
# The sentinel is its own crate, outside the `rust/` workspace (which lists only `wa-host`), so it is
# built with its own manifest. Asking the workspace for `-p wa-sentinel` fails - "package ID
# specification did not match any packages" - and that is how it came to be installed by hand at all.
( cd rust && cargo build --release --offline --manifest-path wa-sentinel/Cargo.toml ) || fail "the sentinel build failed"
NEW="rust/target/release/wa.exe"
[ -f "$NEW" ] || NEW="rust/target/release/wa"
[ -x "$NEW" ] || fail "no built binary at $NEW"

# The supervisor is part of what this installs, and leaving it out is how the node and the thing that
# restarts it drifted apart: `deploy.sh` replaced `wa.exe` while `wa-sentinel.exe` stayed at whatever
# version was last placed by hand, so a fixed stop/start path sat in the repo uninstalled and the
# e2e test refused to run - "the installed sentinel is the one just built" is a check the test makes
# and the gate did not. The sentinel is the only process that can replace the node; shipping the node
# without shipping it is shipping half a node.
NEW_SENTINEL="rust/wa-sentinel/target/release/wa-sentinel.exe"
[ -f "$NEW_SENTINEL" ] || NEW_SENTINEL="rust/wa-sentinel/target/release/wa-sentinel"
[ -x "$NEW_SENTINEL" ] || fail "no built sentinel at $NEW_SENTINEL"
NEW_SENTINEL_LOWER="$(echo "$NEW_SENTINEL" | tr '[:upper:]' '[:lower:]')"
case "$NEW_SENTINEL_LOWER" in
  *.exe) SENTINEL_NAME="wa-sentinel.exe" ;;
  *)     SENTINEL_NAME="wa-sentinel" ;;
esac

# 4. Prove it answers before it goes near the running node. A build that cannot start must not replace one
#    that is serving.
SCRATCH=$((PORT + 40))
SCRATCH_HOME="$(mktemp -d)"
WASM_AGENT_HOME="$SCRATCH_HOME" "$NEW" serve --port "$SCRATCH" --client-port "$((SCRATCH + 1))" --ui "$ROOT/ui" >"$SCRATCH_HOME/out.log" 2>&1 &
SCRATCH_PID=$!
ANSWERED=0
for _ in $(seq 1 100); do
  if ! kill -0 "$SCRATCH_PID" 2>/dev/null; then break; fi
  if curl -fsS -o /dev/null -m 2 "http://127.0.0.1:$SCRATCH/health" 2>/dev/null && curl -fsS -o /dev/null -m 2 "http://127.0.0.1:$SCRATCH/" 2>/dev/null; then ANSWERED=1; break; fi
  sleep 0.1
done
kill "$SCRATCH_PID" 2>/dev/null
wait "$SCRATCH_PID" 2>/dev/null
rm -rf "$SCRATCH_HOME"
[ "$ANSWERED" = "1" ] || fail "the new binary did not answer /health on the scratch port; not installing it"
echo "deploy: the new binary answers on a scratch port"

# 5. Install and restart, through the script that owns that job.
UPGRADE="$ROOT/scripts/upgrade.sh"
[ -f "$UPGRADE" ] || fail "no scripts/upgrade.sh to perform the install"
echo "deploy: installing through upgrade.sh"
# Persist only the explicitly selected runtime location; never move its git branch.
if [ -n "${WA_RUNTIME_WORKTREE:-}" ]; then
  [ -d "$WA_RUNTIME_WORKTREE" ] || fail "runtime worktree does not exist"
  RUNTIME_PATH="$(cd "$WA_RUNTIME_WORKTREE" && pwd)"
  command -v cygpath >/dev/null 2>&1 && RUNTIME_PATH="$(cygpath -w "$RUNTIME_PATH")"
  if [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then
    cp -f "$INSTALL_DIR/runtime-worktree.txt" "$INSTALL_DIR/runtime-worktree.txt.pre-upgrade" || fail "cannot back up runtime location"
  fi
  printf '%s\n' "$RUNTIME_PATH" > "$INSTALL_DIR/runtime-worktree.txt" || fail "cannot record runtime location"
fi
WA_INSTALL_DIR="$INSTALL_DIR" WA_PORT="$PORT" WA_CLIENT_PORT="$CLIENT_PORT" \
  WA_UPGRADE_REASON="$REASON" WA_UPGRADE_VIA=deploy.sh \
  bash "$UPGRADE" "$(cd "$(dirname "$NEW")" && pwd)/$(basename "$NEW")" 2>&1 | sed "s/^/  upgrade: /"
UPGRADE_STATUS=${PIPESTATUS[0]}
if [ "$UPGRADE_STATUS" = "3" ]; then
  fail "the node upgraded, but its script or install record failed (exit 3); inspect the live pid and installed.txt"
fi
[ "$UPGRADE_STATUS" = "0" ] || fail "upgrade.sh failed (exit $UPGRADE_STATUS); inspect its rollback output before assuming which binary is live"

# 6. Verify that the node answering is *this* install: the listener's pid must be the pid the install
#    recorded. Without this, a second node on the port answers /health and the deploy reports success for
#    work it did not do.
LISTENER="$(netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { print $5; exit }' | tr -d '\r')"
RECORDED="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
if [ -z "$RECORDED" ] || [ -z "$LISTENER" ] || [ "$RECORDED" != "$LISTENER" ]; then
  fail "the node answering on $PORT is pid $LISTENER, not the pid $RECORDED the install recorded - two nodes, one port"
fi
# An accumulated node.log can contain a bind error from a previous deployment.
# The recorded child owning this listener is the current startup verdict; a
# historical string is not evidence about that process. Also verify its artifact.
INSTALLED_NODE="$INSTALL_DIR/$(basename "$NEW")"
cmp -s "$NEW" "$INSTALLED_NODE" || fail "installed binary differs from the proved build"

# 7. Record what is installed, so "what is running" is answerable.
HASH="$(sha256sum < "$INSTALLED_NODE" 2>/dev/null | awk '{print $1}')"
[ -n "$HASH" ] || HASH="$(shasum -a 256 < "$INSTALLED_NODE" 2>/dev/null | awk '{print $1}')"

# The supervisor, installed *after* the node is confirmed answering - so a failed upgrade leaves a
# sentinel that still matches the node it supervises, rather than one rebuilt ahead of a node that
# rolled back. A running sentinel holds its own image open on Windows, so the copy is attempted and
# its failure is reported rather than fatal: the swap is completed by the one-shot restart below.
SENTINEL_HASH="(none)"
if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
  cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
  if cmp -s "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME"; then
    echo "deploy: sentinel $SENTINEL_NAME updated"
  else
    # The file is locked by the running supervisor. Stop it, replace it, start it again - the verb
    # that exists for exactly this, and the reason it is not done by hand.
    OLD_SENTINEL_PID="$(netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { print $5; exit }' | tr -d '\r')"
    if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
      "$INSTALL_DIR/$SENTINEL_NAME" stop >/dev/null 2>&1 || true
      sleep 2
      cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
      "$INSTALL_DIR/$SENTINEL_NAME" start >/dev/null 2>&1 || true
    fi
    if cmp -s "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME"; then
      echo "deploy: sentinel $SENTINEL_NAME updated (restarted past the file lock)"
    else
      fail "could not install $SENTINEL_NAME - it is still the old build; the node and its supervisor would disagree"
    fi
  fi
  SENTINEL_HASH="$(sha256sum < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
  [ -n "$SENTINEL_HASH" ] || SENTINEL_HASH="$(shasum -a 256 < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
else
  cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || fail "could not place $SENTINEL_NAME"
  echo "deploy: sentinel $SENTINEL_NAME installed"
  SENTINEL_HASH="$(sha256sum < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
fi

cmp -s "$UPGRADE" "$INSTALL_DIR/scripts/upgrade.sh" || fail "the node is installed but the sentinel's upgrade.sh differs from this release"
UPGRADE_HASH="$(sha256sum < "$INSTALL_DIR/scripts/upgrade.sh" 2>/dev/null | awk '{print $1}')"
[ -n "$UPGRADE_HASH" ] || fail "the node is installed but upgrade.sh could not be hashed"

RECORD_TMP="$INSTALL_DIR/.installed.txt.deploy.$$"
REASON_LINE="$(printf '%s' "$REASON" | tr '\r\n' '  ')"
printf 'commit=%s\nbranch=%s\ndirty=%s\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\nsource_provenance=clean-built-by-deploy\nvia=deploy.sh\nat=%s\nreason=%s\n' \
  "$COMMIT" "$BRANCH" "$DIRTY" "$HASH" "$SENTINEL_HASH" "$UPGRADE_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REASON_LINE" \
  > "$RECORD_TMP" && mv -f "$RECORD_TMP" "$INSTALL_DIR/installed.txt" \
  || fail "node installed, but installed.txt could not be committed atomically"

echo "deploy: installed $COMMIT ($HASH)"
echo "deploy: recorded in $INSTALL_DIR/installed.txt"
echo "deploy: /health -> $(curl -s -m 5 "http://127.0.0.1:$PORT/health" | head -c 260)"
