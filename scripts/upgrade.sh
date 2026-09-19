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
    # `netstat -ano` rather than `Get-NetTCPConnection`. Both answer the same question, but PowerShell
    # costs ~600ms to start while netstat costs ~40ms - and this is called in a poll loop, so the
    # difference is the difference between a fast upgrade and a slow one. The port is matched as the
    # *local* address only: a row whose remote port happens to match is a different connection.
    netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '
      $1 == "TCP" && $2 ~ p"$" && $4 == "LISTENING" { print $5; exit }' | tr -d '\r'
  else
    (command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $NF}' | sed 's/.*pid=\([0-9]*\).*/\1/' | head -1) || true
  fi
}

# Is anything listening on a port? The same question `pid_on_port` answers, but it must be cheap: this
# one is polled while waiting for a port to come free or answer, and a PowerShell spawn per poll made
# the wait longer than the thing being waited for.
port_busy() {
  if [ "$WINDOWS" = "1" ]; then
    netstat -ano -p TCP 2>/dev/null | awk -v p=":$1" '$1 == "TCP" && $2 ~ p"$" && $4 == "LISTENING" { found = 1 } END { exit !found }'
  else
    (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$1 ") || return 1
  fi
}

# The scratch port must be one nothing else is using. 8800 is the client bridge of the node already
# running, so a check on it answers whether or not the new binary works at all - which is exactly what
# happened: a text file "answered", was installed, and only the rollback saved the node.
free_port() {
  local candidate=$((PORT + 3))
  for _ in $(seq 1 20); do
    # `port_busy` rather than its own PowerShell probe: 20 candidate ports each costing a PowerShell
    # start was ~12s of pure process overhead in the worst case, for a question netstat answers in 40ms.
    if ! port_busy "$candidate"; then
      echo "$candidate"; return 0
    fi
    candidate=$((candidate + 1))
  done
  echo "$((PORT + 3))"
}
SCRATCH_PORT="$(free_port)"
SCRATCH_CLIENT=$((SCRATCH_PORT + 1))

SCRATCH_HOME="$(mktemp -d)"
SCRATCH_DB="$SCRATCH_HOME/scratch.db"
# A build that has already answered on a scratch port is not proved again. The proof exists to catch
# a binary that cannot start, and a binary cannot un-start: the same bytes answer the same way. So the
# verdict is cached against the file's hash, which takes the ~20s worst-case spawn-and-poll off every
# upgrade after the first. Only a *positive* verdict is cached - a build that failed to answer is
# retried, because the failure may have been a busy machine rather than the binary.
PROOF_CACHE="$INSTALL_DIR/.upgrade-proof"
NEW_HASH=""
if command -v sha256sum >/dev/null 2>&1; then
  NEW_HASH="$(sha256sum "$NEW" 2>/dev/null | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  NEW_HASH="$(shasum -a 256 "$NEW" 2>/dev/null | awk '{print $1}')"
fi
PROVED_ALREADY=0
if [ -n "$NEW_HASH" ] && [ -f "$PROOF_CACHE" ]; then
  # One hash per line. Compared with grep -F so a hash is matched as data, never as a pattern.
  if grep -qF "$NEW_HASH" "$PROOF_CACHE" 2>/dev/null; then PROVED_ALREADY=1; fi
fi

if [ "$PROVED_ALREADY" = "1" ]; then
  say "this build already answered on a scratch port (hash ${NEW_HASH%${NEW_HASH#??????}}...) - skipping the proof"
else
say "checking $NEW answers on scratch port $SCRATCH_PORT before it goes near the running node"
WASM_AGENT_HOME="$SCRATCH_HOME" "$NEW" serve --port "$SCRATCH_PORT" --client-port "$SCRATCH_CLIENT" --db "$SCRATCH_DB" >"$SCRATCH_HOME/out.log" 2>&1 &
SCRATCH_PID=$!
ok=0
# Polled in tenths rather than halves: the measured cold start is ~55ms, so a 500ms tick spent most of
# its life asleep after a node that was already up. The deadline is the same wall-clock, just measured
# finely, so a slow machine is still given its full 20 seconds.
for _ in $(seq 1 200); do
  # Both: the process must still be alive, and its port must answer. The port alone can be answered by
  # something else - a text file cannot stay alive as a process.
  if ! kill -0 "$SCRATCH_PID" 2>/dev/null; then break; fi
  if curl -s -m 2 "http://127.0.0.1:$SCRATCH_PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.1
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
# Recorded only after the verdict is final, so an interrupted run cannot leave a hash it never proved.
# The file is trimmed to the last 20 hashes: it records recent builds, it is not a ledger.
if [ -n "$NEW_HASH" ]; then
  { tail -19 "$PROOF_CACHE" 2>/dev/null; echo "$NEW_HASH"; } > "$PROOF_CACHE.tmp" 2>/dev/null \
    && mv -f "$PROOF_CACHE.tmp" "$PROOF_CACHE" 2>/dev/null
fi
say "it answers"
fi

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
  # Two cadences, because the two situations are different. A long turn should not be polled 50 times a
  # minute - that is noise in the log and in the node's queue. But the *last* moment, when the turn has
  # just ended, is exactly when a fixed 5s tick costs 5s of outage for nothing: the swap cannot start
  # until the poll notices. So once the node has been seen busy for a while, poll finely.
  if [ "$waited" -ge 10 ]; then
    sleep 0.5
    waited=$((waited + 1))
  else
    sleep 5
    waited=$((waited + 5))
  fi
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
  # Wait for the port to be free rather than sleeping a fixed two seconds. Measured: the process is
  # gone in ~150ms, so the fixed sleep was ~1.8s of outage per upgrade that nothing needed. This waits
  # for the actual condition - and, unlike a sleep, it cannot be too short on a loaded machine.
  for _ in $(seq 1 100); do
    port_busy "$PORT" || break
    sleep 0.05
  done
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
  # Tenths, not halves: the measured cold start is ~55ms, so this loop's own tick was the longest part
  # of bringing the node back. The deadline is unchanged in wall-clock terms (40 * 0.5s == 200 * 0.1s).
  for _ in $(seq 1 200); do
    case "$(health)" in *'"ok":true'*) return 0 ;; esac
    sleep 0.1
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
