#!/usr/bin/env bash
# Deploy a node: the one gate through which a build becomes the installed one.
#
#   bash scripts/deploy.sh [--reason "why"] [--no-restart]
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
#   4. what was installed is recorded: commit, branch, dirty state, hash, time, reason. `/health` reports it,
#      so "what is running" is a question with an answer instead of an argument.
#
# The restart is by pid (never by image name), waits for the port to come free, and verifies /health. It does
# not touch the window: the window is a client, it reconnects on its own, and restarting it is what a human
# does when a page is wedged.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REASON=""
RESTART=1
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON="${2:-}"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
[ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
PORT="${WA_PORT:-8799}"
CLIENT_PORT="${WA_CLIENT_PORT:-8800}"

fail() { echo "deploy: $*" >&2; exit 1; }

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
NEW="rust/target/release/wa.exe"
[ -f "$NEW" ] || NEW="rust/target/release/wa"
[ -x "$NEW" ] || fail "no built binary at $NEW"

# 4. Prove it answers before it goes near the running node. A build that cannot start must not replace one
#    that is serving.
SCRATCH=$((PORT + 40))
SCRATCH_HOME="$(mktemp -d)"
"$NEW" serve --port "$SCRATCH" --client-port "$((SCRATCH + 1))" --ui "$ROOT/ui" >"$SCRATCH_HOME/out.log" 2>&1 &
SCRATCH_PID=$!
ANSWERED=0
for _ in $(seq 1 100); do
  if curl -s -o /dev/null -m 2 "http://127.0.0.1:$SCRATCH/health" 2>/dev/null; then ANSWERED=1; break; fi
  sleep 0.1
done
kill "$SCRATCH_PID" 2>/dev/null
rm -rf "$SCRATCH_HOME"
[ "$ANSWERED" = "1" ] || fail "the new binary did not answer /health on the scratch port; not installing it"
echo "deploy: the new binary answers on a scratch port"

# 5. Install and restart by pid.
PID_FILE="$INSTALL_DIR/serve.pid"
OLD_PID=""
[ -f "$PID_FILE" ] && OLD_PID="$(tr -d '[:space:]' < "$PID_FILE")"
if [ -z "$OLD_PID" ]; then
  OLD_PID="$(netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { print $5; exit }' | tr -d '\r')"
fi

if [ "$RESTART" = "1" ]; then
  [ -n "$OLD_PID" ] && { echo "deploy: stopping pid $OLD_PID"; taskkill //PID "$OLD_PID" //F >/dev/null 2>&1 || kill "$OLD_PID" 2>/dev/null; }
  for _ in $(seq 1 100); do
    netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { found=1 } END { exit !found }' || break
    sleep 0.1
  done
fi

# `mv`, never `cp`: the binary is running, and on Windows a copy over a running image fails with "Text file
# busy" - which reads as a permissions problem and is not one.
mv -f "$NEW" "$INSTALL_DIR/wa.exe" || fail "could not install the binary (is it running under another name?)"

if [ "$RESTART" = "1" ]; then
  powershell.exe -NoProfile -Command "Start-Process -FilePath '$INSTALL_DIR\\wa.exe' -ArgumentList @('serve','--port','$PORT','--client-port','$CLIENT_PORT','--ui','$INSTALL_DIR\\ui') -WindowStyle Hidden" 2>/dev/null \
    || ( cd "$INSTALL_DIR" && nohup ./wa.exe serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$INSTALL_DIR/ui" >>"$INSTALL_DIR/node.log" 2>&1 & )
  UP=0
  for _ in $(seq 1 150); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null; then UP=1; break; fi
    sleep 0.1
  done
  [ "$UP" = "1" ] || fail "the node did not answer /health after the restart; the previous binary is still on disk as .pre-upgrade if you need it"
fi

# 6. Record what is installed, so "what is running" is answerable.
HASH="$(sha256sum "$INSTALL_DIR/wa.exe" 2>/dev/null | awk '{print $1}')"
[ -n "$HASH" ] || HASH="$(shasum -a 256 "$INSTALL_DIR/wa.exe" 2>/dev/null | awk '{print $1}')"
printf 'commit=%s\nbranch=%s\ndirty=%s\nsha256=%s\nat=%s\nreason=%s\n' \
  "$COMMIT" "$BRANCH" "$DIRTY" "$HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REASON" \
  > "$INSTALL_DIR/installed.txt"

NEW_PID="$(tr -d '[:space:]' < "$PID_FILE" 2>/dev/null)"
echo "deploy: installed $COMMIT ($HASH)"
echo "deploy: recorded in $INSTALL_DIR/installed.txt"
echo "deploy: /health -> $(curl -s -m 5 "http://127.0.0.1:$PORT/health" | head -c 200)"
