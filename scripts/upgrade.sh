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
if [ "${WASM_AGENT_IN_TURN:-}" = "1" ]; then
  echo "upgrade: refused inside a running turn; request the external sentinel instead" >&2
  exit 2
fi
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
RUNTIME_ROOT="${WA_RUNTIME_WORKTREE:-$ROOT}"
if [ -z "${WA_RUNTIME_WORKTREE:-}" ] && [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then
  RUNTIME_ROOT="$(tr -d '\r\n' < "$INSTALL_DIR/runtime-worktree.txt")"
fi
[ -d "$RUNTIME_ROOT" ] || { say "runtime worktree does not exist: $RUNTIME_ROOT"; exit 2; }
RUNTIME_ROOT="$(cd "$RUNTIME_ROOT" && pwd)"
SOURCE_UI="${WA_SOURCE_UI_DIR:-$ROOT/ui}"
UI_FILES="index.html app.js components.js style.css render.wasm"

NEW="${1:-}"
if [ -z "$NEW" ]; then
  for candidate in "$ROOT/rust/target/release/$EXE" "$ROOT/rust/target/release/wa"; do
    [ -x "$candidate" ] && NEW="$candidate" && break
  done
fi
[ -n "$NEW" ] && [ -x "$NEW" ] || { say "no new binary to install (build one, or pass a path)"; exit 2; }
[ -x "$INSTALLED" ] || { say "nothing installed at $INSTALLED - this upgrades a running node, it does not create one"; exit 2; }

# The sentinel runs the copy beside the installed binary, so ROOT is the install
# directory in that path. The candidate binary still points back to its source
# checkout: use that checkout for UI assets and for a downgrade guard.
SOURCE_ROOT="$(git -C "$(dirname "$NEW")" rev-parse --show-toplevel 2>/dev/null || true)"
SOURCE_COMMIT=""
if [ -n "$SOURCE_ROOT" ]; then
  SOURCE_COMMIT="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "${WA_SOURCE_UI_DIR:-}" ] && [ -d "$SOURCE_ROOT/ui" ]; then SOURCE_UI="$SOURCE_ROOT/ui"; fi
fi
PREVIOUS_COMMIT="$(sed -n 's/^commit=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)"
if [ -n "$PREVIOUS_COMMIT" ] && [ "$PREVIOUS_COMMIT" != unknown ] \
    && [ -z "$SOURCE_COMMIT" ] && [ "${WA_ALLOW_UNVERIFIED_UPGRADE:-}" != 1 ]; then
  say "candidate has no source checkout to compare with installed commit $PREVIOUS_COMMIT; set WA_ALLOW_UNVERIFIED_UPGRADE=1 only for an intentional operator override"
  exit 2
fi
if [ -n "$SOURCE_COMMIT" ] && [ -n "$PREVIOUS_COMMIT" ] && [ "$PREVIOUS_COMMIT" != unknown ] \
    && git -C "$SOURCE_ROOT" cat-file -e "$PREVIOUS_COMMIT^{commit}" 2>/dev/null \
    && ! git -C "$SOURCE_ROOT" merge-base --is-ancestor "$PREVIOUS_COMMIT" "$SOURCE_COMMIT"; then
  say "refusing a candidate from $SOURCE_COMMIT: it does not contain installed commit $PREVIOUS_COMMIT"
  exit 2
fi

file_hash() { [ -f "$1" ] && sha256sum < "$1" 2>/dev/null | awk '{print $1}' || true; }
record_install() {
  local hash sentinel_hash upgrade_hash commit branch source_hint reason via stamp record
  hash="$(file_hash "$INSTALLED")"
  sentinel_hash="$(file_hash "$INSTALL_DIR/wa-sentinel.exe")"
  [ -n "$sentinel_hash" ] || sentinel_hash="$(file_hash "$INSTALL_DIR/wa-sentinel")"
  [ -n "$sentinel_hash" ] || sentinel_hash=missing
  upgrade_hash="$(file_hash "$INSTALL_DIR/scripts/upgrade.sh")"
  [ -n "$upgrade_hash" ] || upgrade_hash=missing
  [ -n "$hash" ] || return 1
  commit=unknown; branch=unknown
  # A sentinel upgrade knows the exact installed bytes, but cannot prove that a
  # separately built binary corresponds to the checkout's current HEAD.
  source_hint="${SOURCE_COMMIT:-unknown}"
  if [ "$NEW" -ef "$INSTALLED" ] && [ "$(sed -n 's/^sha256=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)" = "$hash" ]; then
    commit="${PREVIOUS_COMMIT:-unknown}"
    branch="$(sed -n 's/^branch=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)"
    branch="${branch:-unknown}"
  fi
  reason="$(printf '%s' "${WA_UPGRADE_REASON:-upgrade requested}" | tr '\r\n' '  ')"
  via="$(printf '%s' "${WA_UPGRADE_VIA:-upgrade.sh}" | tr '\r\n' '  ')"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$INSTALL_DIR/.installed.txt.$$"
  printf 'commit=%s\nbranch=%s\ndirty=unknown\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\nsource_commit_hint=%s\nsource_provenance=unverified-binary\nvia=%s\nat=%s\nreason=%s\n' \
    "$commit" "$branch" "$hash" "$sentinel_hash" "$upgrade_hash" "$source_hint" "$via" "$stamp" "$reason" > "$record" \
    && mv -f "$record" "$INSTALL_DIR/installed.txt"
}

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
  NEW_HASH="$(sha256sum < "$NEW" 2>/dev/null | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  NEW_HASH="$(shasum -a 256 < "$NEW" 2>/dev/null | awk '{print $1}')"
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
FINE_TICKS=0
while :; do
  state="$(health)"
  case "$state" in
    *'"current":null'*)
      # Older nodes report current=null while secondary workers are busy.
      # Inspect every worker too, before trusting that it is safe to stop.
      if ! printf '%s' "$state" | grep -q '"label":"POST /chat' && printf '%s' "$state" | grep -q '"queue":0'; then break; fi ;;
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
  #
  # The counter is whole seconds and the sleep is derived from it, so the number in the log is the
  # number that elapsed. It used to sleep 0.5s and increment by 1, which advanced twice as fast as the
  # clock: `IDLE_TIMEOUT=900` gave up after ~450 real seconds while saying 900, so the message named a
  # deadline that had not passed. Two ticks, one second, counted once - no compensating arithmetic.
  if [ "$waited" -ge 10 ]; then
    sleep 0.5
    FINE_TICKS=$((FINE_TICKS + 1))
    if [ $((FINE_TICKS % 2)) -eq 0 ]; then waited=$((waited + 1)); fi
  else
    sleep 5
    waited=$((waited + 5))
  fi
done

# --- 3. swap, restart, verify, roll back if the new one does not come up -------------------------
OLD_PID="$(pid_on_port)"
[ -n "$OLD_PID" ] && say "stopping the node (pid $OLD_PID, by pid - never by image name)"
BACKUP="$INSTALLED.pre-upgrade"
cp -f "$INSTALLED" "$BACKUP" 2>/dev/null && cmp -s "$INSTALLED" "$BACKUP" || { say "cannot verify recovery binary; not stopping the node"; exit 1; }
if [ -d "$SOURCE_UI" ] && [ "$SOURCE_UI" != "$UI_DIR" ]; then
  for asset in $UI_FILES; do
    [ -f "$SOURCE_UI/$asset" ] || { say "missing release UI asset: $asset"; exit 1; }
    [ ! -f "$UI_DIR/$asset" ] || cp -f "$UI_DIR/$asset" "$UI_DIR/$asset.pre-upgrade" || exit 1
  done
fi
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
  if port_busy "$PORT"; then say "port $PORT is still occupied; refusing to overwrite or kill another listener"; exit 1; fi
fi

start_node() {
  local binary="$1"
  if [ "$WINDOWS" = "1" ]; then
    # PowerShell cannot use a POSIX path: passing one to -WorkingDirectory fails the whole start, and
    # the node then stays down while the script reports that the binary "did not come up" - which is
    # true and misleading in equal measure. Convert, or fail loudly here.
    local work win_binary
    work="$(cygpath -w "$RUNTIME_ROOT" 2>/dev/null || echo "$RUNTIME_ROOT")"
    win_binary="$(cygpath -w "$binary" 2>/dev/null || echo "$binary")"
    # A POSIX path handed to a native Windows process is silently unusable: the node starts, cannot read
    # index.html, falls through to the API routes, and answers 404 for / - so the window shows "not found",
    # runs no JavaScript, and looks like a dead shell. That cost an afternoon and three wrong diagnoses.
    # Converted here, at the boundary, because this is where a shell path becomes a Windows argument.
    ui_argument="$UI_DIR"
    if command -v cygpath >/dev/null 2>&1; then ui_argument="$(cygpath -w "$UI_DIR")"; fi
    local win_pid
    win_pid="$(cygpath -w "$INSTALL_DIR/serve.pid")"
    powershell.exe -NoProfile -Command "\$deployChild = Start-Process -FilePath '$win_binary' -ArgumentList @('serve','--port','$PORT','--client-port','$CLIENT_PORT','--ui','$ui_argument') -WorkingDirectory '$work' -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText('$win_pid', [string]\$deployChild.Id)" 2>/dev/null
  else
    (cd "$RUNTIME_ROOT" && { nohup "$binary" serve --port "$PORT" --client-port "$CLIENT_PORT" --ui "$UI_DIR" >>"$HOME_DIR/node.log" 2>&1 & echo $! > "$INSTALL_DIR/serve.pid"; })
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
SWAP_OK=1
if [ "$NEW" -ef "$INSTALLED" ]; then
  say "the new binary is already the installed one ($INSTALLED) - nothing to swap, restarting it"
else
  cp -f "$NEW" "$INSTALLED" || SWAP_OK=0
  say "installed $(basename "$NEW") over $INSTALLED"
fi
UI_OK=$SWAP_OK
if [ -d "$SOURCE_UI" ] && [ "$SOURCE_UI" != "$UI_DIR" ]; then
  mkdir -p "$UI_DIR"
  for asset in $UI_FILES; do cp -f "$SOURCE_UI/$asset" "$UI_DIR/$asset" || UI_OK=0; done
fi
start_node "$INSTALLED"
if [ "$UI_OK" = "1" ] && wait_health; then
  LISTENER="$(pid_on_port)"
  RECORDED="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
  if [ -n "$LISTENER" ] && [ "$LISTENER" = "$RECORDED" ]; then
    # Record the new binary before shipping companion files. If a companion
    # copy fails, installed.txt must still name the binary actually serving.
    record_install || { say "node upgraded, but installed.txt could not be recorded"; exit 3; }
    mkdir -p "$INSTALL_DIR/scripts"
    if ! cmp -s "$0" "$INSTALL_DIR/scripts/upgrade.sh"; then
      cp -f "$0" "$INSTALL_DIR/scripts/upgrade.sh" || { say "node upgraded, but could not ship upgrade.sh"; exit 3; }
    fi
    if [ -n "$SOURCE_ROOT" ] && [ -f "$SOURCE_ROOT/skills/self-update/SKILL.md" ]; then
      mkdir -p "$HOME_DIR/skills/self-update"
      cp -f "$SOURCE_ROOT/skills/self-update/SKILL.md" "$HOME_DIR/skills/self-update/SKILL.md" \
        || { say "node upgraded, but could not ship self-update skill"; exit 3; }
    fi
    record_install || { say "node upgraded, but final installed.txt could not be recorded"; exit 3; }
    say "upgraded and recorded: $(health)"
    # Keep this one binary/UI backup for recovery after the deployment verdict.
    exit 0
  fi
  say "health answered, but listener pid $LISTENER differs from recorded pid $RECORDED"
fi

say "the new binary did not come up - putting the previous one back"
FAILED_PID="$(pid_on_port)"
EXPECTED_PID="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
if [ -n "$FAILED_PID" ] && [ "$FAILED_PID" = "$EXPECTED_PID" ]; then
  if [ "$WINDOWS" = "1" ]; then powershell.exe -NoProfile -Command "Stop-Process -Id $FAILED_PID -Force" 2>/dev/null
  else kill "$FAILED_PID" 2>/dev/null; fi
fi
for _ in $(seq 1 100); do
  port_busy "$PORT" || break
  sleep 0.05
done
if port_busy "$PORT"; then say "port $PORT is still occupied; recovery requires checking the listener"; exit 1; fi
if [ -f "$BACKUP" ]; then
  cp -f "$BACKUP" "$INSTALLED"
  for asset in $UI_FILES; do
    [ ! -f "$UI_DIR/$asset.pre-upgrade" ] || cp -f "$UI_DIR/$asset.pre-upgrade" "$UI_DIR/$asset"
  done
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
