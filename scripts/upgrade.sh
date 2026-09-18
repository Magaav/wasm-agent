#!/usr/bin/env bash
# Upgrade a running node without killing a turn.
#
# The old way was: stop the node, copy the binary, start it again. Every step of that can lose work -
# the stop kills whatever turn is running, and a build that does not start leaves the node down with
# nothing to say about it. This is the same operation with those two mistakes removed:
#
#   1. prove the new binary answers before touching the running node
#   2. wait for the node to be idle, so no turn is interrupted
#   3. swap, restart, verify - and if the new one does not come up, put the old one back
#
# The gap is a fraction of a second: the window's version poll runs every second and reconnects on its
# own, so the reader sees the transcript come back rather than a dead page. Nothing here is clever
# about the port - a process cannot hand its listening socket to another on Windows, so the only way
# to be seamless is to be quick and to recover by itself.
#
# Usage:
#   scripts/upgrade.sh [path-to-new-binary]
#   WA_PORT=8799 WA_INSTALL_DIR=/usr/local/bin scripts/upgrade.sh ./rust/target/release/wa
set -uo pipefail

say() { printf '  %s\n' "$*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${WA_PORT:-8799}"
CLIENT_PORT="${WA_CLIENT_PORT:-8800}"
IDLE_TIMEOUT="${WA_IDLE_TIMEOUT:-900}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;;
  *) WINDOWS=0 ;;
esac
if [ "$WINDOWS" = "1" ]; then
  INSTALL_DIR="${WA_INSTALL_DIR:-$LOCALAPPDATA/wasm-agent}"
  EXE="wa.exe"
  HOME_DIR="${WASM_AGENT_HOME:-$USERPROFILE/.wasm-agent}"
else
  INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/bin}"
  EXE="wa"
  HOME_DIR="${WASM_AGENT_HOME:-$HOME/.wasm-agent}"
fi
INSTALLED="$INSTALL_DIR/$EXE"
UI_DIR="${WA_UI_DIR:-$INSTALL_DIR/ui}"

NEW="${1:-}"
if [ -z "$NEW" ]; then
  for candidate in "$ROOT/rust/target/release/$EXE" "$ROOT/rust/target/release/wa"; do
    [ -x "$candidate" ] && NEW="$candidate" && break
  done
fi
[ -n "$NEW" ] && [ -x "$NEW" ] || { say "no new binary to install (build one, or pass a path)"; exit 2; }
[ -x "$INSTALLED" ] || { say "nothing installed at $INSTALLED - this upgrades a running node, it does not create one"; exit 2; }

health() { curl -s -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null || true; }

pid_on_port() {
  if [ "$WINDOWS" = "1" ]; then
    powershell.exe -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort $PORT -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { \$_.OwningProcess }" 2>/dev/null | tr -d '\r'
  else
    (command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $NF}' | sed 's/.*pid=\([0-9]*\).*/\1/' | head -1) || true
  fi
}

# The scratch port must be one nothing else is using. 8800 is the client bridge of the node already
# running, so a check on it answers whether or not the new binary works at all - which is exactly what
# happened: a text file "answered", was installed, and only the rollback saved the node.
free_port() {
  local candidate=$((PORT + 3))
  for _ in $(seq 1 20); do
    if [ "$WINDOWS" = "1" ]; then
      if ! powershell.exe -NoProfile -Command "Get-NetTCPConnection -State Listen -LocalPort $candidate -ErrorAction SilentlyContinue" 2>/dev/null | grep -q .; then
        echo "$candidate"; return 0
      fi
    else
      if ! (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$candidate "); then
        echo "$candidate"; return 0
      fi
    fi
    candidate=$((candidate + 1))
  done
  echo "$((PORT + 3))"
}
SCRATCH_PORT="$(free_port)"
SCRATCH_CLIENT=$((SCRATCH_PORT + 1))

say "checking $NEW answers on scratch port $SCRATCH_PORT before it goes near the running node"
SCRATCH_HOME="$(mktemp -d)"
SCRATCH_DB="$SCRATCH_HOME/scratch.db"
WASM_AGENT_HOME="$SCRATCH_HOME" "$NEW" serve --port "$SCRATCH_PORT" --client-port "$SCRATCH_CLIENT" --db "$SCRATCH_DB" >"$SCRATCH_HOME/out.log" 2>&1 &
SCRATCH_PID=$!
ok=0
for _ in $(seq 1 40); do
  # Both: the process must still be alive, and its port must answer. The port alone can be answered by
  # something else - a text file cannot stay alive as a process.
  if ! kill -0 "$SCRATCH_PID" 2>/dev/null; then break; fi
  if curl -s -m 2 "http://127.0.0.1:$SCRATCH_PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.5
done
kill "$SCRATCH_PID" 2>/dev/null
wait "$SCRATCH_PID" 2>/dev/null
if [ "$ok" != "1" ]; then
  say "the new binary did not answer /health on a scratch port - not installing it"
  tail -6 "$SCRATCH_HOME/out.log" 2>/dev/null | sed 's/^/    /'
  rm -rf "$SCRATCH_HOME"
  exit 1
fi
rm -rf "$SCRATCH_HOME"
say "it answers"

# --- 2. wait for the node to be idle, so no turn is interrupted ----------------------------------
say "waiting for the running node to finish what it is doing"
waited=0
while :; do
  state="$(health)"
  case "$state" in
    *'"current":null'*) break ;;
    "") say "the node is not answering - nothing to wait for"; break ;;
  esac
  if [ "$waited" -ge "$IDLE_TIMEOUT" ]; then
    say "still busy after ${IDLE_TIMEOUT}s; not upgrading under a running turn"
    exit 1
  fi
  [ $((waited % 30)) -eq 0 ] && say "  busy: $state"
  sleep 5
  waited=$((waited + 5))
done

# --- 3. swap, restart, verify, roll back if the new one does not come up -------------------------
OLD_PID="$(pid_on_port)"
[ -n "$OLD_PID" ] && say "stopping the node (pid $OLD_PID, by pid - never by image name)"
BACKUP="$INSTALLED.pre-upgrade"
cp -f "$INSTALLED" "$BACKUP" 2>/dev/null || true
if [ -n "$OLD_PID" ]; then
  if [ "$WINDOWS" = "1" ]; then
    powershell.exe -NoProfile -Command "Stop-Process -Id $OLD_PID -Force" 2>/dev/null
  else
    kill "$OLD_PID" 2>/dev/null
  fi
  sleep 2
fi

start_node() {
  local binary="$1"
  if [ "$WINDOWS" = "1" ]; then
    # PowerShell cannot use a POSIX path: passing one to -WorkingDirectory fails the whole start, and
    # the node then stays down while the script reports that the binary "did not come up" - which is
    # true and misleading in equal measure. Convert, or fail loudly here.
    local work win_binary
    work="$(cygpath -w "$ROOT" 2>/dev/null || echo "$ROOT")"
    win_binary="$(cygpath -w "$binary" 2>/dev/null || echo "$binary")"
    powershell.exe -NoProfile -Command "Start-Process -FilePath '$win_binary' -ArgumentList @('serve','--port','$PORT','--client-port','$CLIENT_PORT','--ui','$UI_DIR') -WorkingDirectory '$work' -WindowStyle Hidden" 2>/dev/null
  else
    (cd "$ROOT" && nohup "$binary" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$UI_DIR" >>"$HOME_DIR/node.log" 2>&1 &)
  fi
}

wait_health() {
  for _ in $(seq 1 40); do
    case "$(health)" in *'"ok":true'*) return 0 ;; esac
    sleep 0.5
  done
  return 1
}

# Copy rather than move: the caller's build tree keeps its binary, and a failed swap has something to
# roll back to. If they are already the same file - a hard link, which is how an installed binary and
# its build output often relate - there is nothing to copy and `cp` says so as an error.
if [ "$NEW" -ef "$INSTALLED" ]; then
  say "the new binary is already the installed one ($INSTALLED) - nothing to swap, restarting it"
else
  cp -f "$NEW" "$INSTALLED"
  say "installed $(basename "$NEW") over $INSTALLED"
fi
start_node "$INSTALLED"
if wait_health; then
  say "upgraded: $(health)"
  rm -f "$BACKUP" 2>/dev/null
  exit 0
fi

say "the new binary did not come up - putting the previous one back"
if [ -f "$BACKUP" ]; then
  cp -f "$BACKUP" "$INSTALLED"
  start_node "$INSTALLED"
  if wait_health; then
    say "rolled back: $(health)"
  else
    say "the previous binary did not come up either - start it by hand and read $HOME_DIR/node.log"
  fi
else
  say "no backup to roll back to"
fi
exit 1
