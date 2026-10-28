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

for required in dirname date mkdir sed tr wc uname; do
  command -v "$required" >/dev/null 2>&1 || { printf 'upgrade: shell_environment_missing:%s; no installation attempted\n' "$required" >&2; exit 127; }
done

say() { printf '  %s\n' "$*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A node cannot replace itself; a CLI turn may, through the sentinel (scripts/lib/turn-guard.sh).
. "$ROOT/scripts/lib/turn-guard.sh" 2>/dev/null || . "$(dirname "$0")/lib/turn-guard.sh"
TURN_OWNER="$(turn_owner)"
case "$TURN_OWNER" in
  node|unknown)
    echo "upgrade: refused inside a turn running on the node it would replace; request the external sentinel instead" >&2
    exit 2 ;;
esac
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

else
  INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/bin}"
  EXE="wa"

fi
# Runtime HOME is the parent of .wasm-agent, including under the sentinel.
SERVICE_LIB="$ROOT/scripts/lib/service-target.sh"
[ -f "$SERVICE_LIB" ] || { say "missing service-target.sh: cannot resolve runtime config safely"; exit 2; }
. "$SERVICE_LIB"
HOME_DIR="$(wa_config_dir)"
INSTALLED="$INSTALL_DIR/$EXE"
UI_DIR="${WA_UI_DIR:-$INSTALL_DIR/ui}"
RUNTIME_ROOT="${WA_RUNTIME_WORKTREE:-$ROOT}"
if [ -z "${WA_RUNTIME_WORKTREE:-}" ] && [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then
  RUNTIME_ROOT="$(tr -d '\r\n' < "$INSTALL_DIR/runtime-worktree.txt")"
fi
[ -d "$RUNTIME_ROOT" ] || { say "runtime worktree does not exist: $RUNTIME_ROOT"; exit 2; }
RUNTIME_ROOT="$(cd "$RUNTIME_ROOT" && pwd)"
SOURCE_UI="${WA_SOURCE_UI_DIR:-$ROOT/ui}"
UI_FILES="index.html app.js components.js style.css render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png"

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
# The record as THIS script found it, captured once. `record_install` runs twice in one upgrade (after the
# swap, and again as the last write), and the second call used to re-read the file it had just written - so
# its `sha256=` named the bytes being placed and the identity branch below borrowed `commit=` from the
# PREVIOUS record, stamping the OLD commit onto the NEW bytes. Measured on the live install: five deploys
# on 2026-10-20 left `commit=255b0790` beside `source_commit_hint=5767a31b` and a 5767a31b binary, which
# `verify-deployed.sh` refused. A record this run wrote is not an independent witness; only the one it
# found is, so the comparison below reads this snapshot instead of the live file.
PREVIOUS_HASH="$(sed -n 's/^sha256=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)"
PREVIOUS_BRANCH="$(sed -n 's/^branch=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)"
# WHO called this upgrade is this script's business, not the node's. The node started below inherits this
# environment and passes it to every child it ever spawns, so a deploy's caller identity outlives the deploy:
# MEASURED 2026-10-20, the live node's environment carried `WA_UPGRADE_VIA=deploy.sh` and a 16:58 deploy's
# reason hours later, and a hand-run upgrade under it would record itself as that deploy's interim write -
# the very confusion `record_role` exists to prevent. It also made `scripts/test-deploy-record.sh` fail a
# correct tree. So read the identity once, then take it out of the environment the node will inherit.
UPGRADE_VIA_WANTED="${WA_UPGRADE_VIA:-}"
UPGRADE_REASON_WANTED="${WA_UPGRADE_REASON:-}"
unset WA_UPGRADE_VIA WA_UPGRADE_REASON
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
  local hash sentinel_hash upgrade_hash commit branch source_hint reason via role provenance stamp record
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
  # The record's OWN identity is reused when the bytes it names are the bytes this script is placing: its
  # `sha256=` field is that claim and it is checkable here. `-ef` covers the hard-link case (the installed
  # file IS the built file); the wider check covers a deploy's build, which is a DIFFERENT file with
  # identical bytes - the case that used to leave `record_role=final` beside `commit=unknown`, which no
  # verifier can reconcile.
  if [ -n "$PREVIOUS_HASH" ] && [ "$PREVIOUS_HASH" = "$hash" ]; then
    commit="${PREVIOUS_COMMIT:-unknown}"
    branch="${PREVIOUS_BRANCH:-unknown}"
  fi
  reason="$(printf '%s' "${UPGRADE_REASON_WANTED:-upgrade requested}" | tr '\r\n' '  ')"
  via="$(printf '%s' "${UPGRADE_VIA_WANTED:-upgrade.sh}" | tr '\r\n' '  ')"
  # WHOSE record is this? This script installs bytes and can only certify the bytes: a binary built
  # somewhere else is `source_provenance=unverified-binary`, and a sentinel upgrade may not even know
  # which commit it came from (`commit=unknown`). That is honest when this *is* the final record - a
  # hand-run upgrade - and it is INTERIM when a deploy called this script, because the deploy owns the
  # install's record: it is the party that knows the commit, and it writes the exact-commit record
  # (`record_role=final`, `source_provenance=clean-built-by-deploy`) together with the sentinel it
  # installs - which also corrects the `sentinel_sha256` here, taken before that replacement.
  #
  # `record_role` is what makes that legible instead of silent. WHY it exists: on 2026-10-02 19:30 a deploy
  # died between installing the node and its own record step (the exact cause is at the self-ship below),
  # so this interim record became the last word - installed.txt said `commit=unknown / via=upgrade.sh`
  # while the node served 2f02b4c's build - and `verify-install.sh` could only report that the installed
  # commit was unknown. With the role on disk, a verifier reads "a deploy was in flight and did not
  # finish" instead of "nobody knows".
  if [ "$via" = "deploy.sh" ]; then role=interim; else role=final; fi
  # A final record must name a commit. An upgrade that cannot name the source (or the
  # previous bytes) stays interim; the deploy is the party that writes the proved final record.
  if [ "$commit" = "unknown" ] || [ "$source_hint" = "unknown" ]; then role=interim; fi
  provenance=unverified-binary
  # MONOTONE, and this is finding F4 of the review of change/deploy-unbound: an interim write may not
  # DOWNGRADE a record that is still true. A deploy whose build is byte-identical to what is installed
  # calls this script only for the restart ("the new binary is byte-identical to ... - nothing to swap,
  # restarting it", measured on the live node on 2026-10-02), and the record it finds already says
  # `record_role=final` with `source_provenance=clean-built-by-deploy` FOR THESE EXACT BYTES. Overwriting
  # that with "a deploy was in flight" asserts a death that has not happened, and `verify-install.sh`
  # fails it by name. Nothing about what is installed changed, so the role and the provenance are kept -
  # the record is refreshed around them (at/via/reason/hashes), which is what lets a LATER death be seen.
  # A new binary still gets interim, because that is the fact then.
  if [ "$via" = "deploy.sh" ] \
     && [ "$(sed -n 's/^record_role=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)" = "final" ] \
     && [ "$(sed -n 's/^source_provenance=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)" = "clean-built-by-deploy" ] \
     && [ "$(sed -n 's/^sha256=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)" = "$hash" ]; then
    role=final
    provenance=clean-built-by-deploy
  fi
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$INSTALL_DIR/.installed.txt.$$"
  printf 'commit=%s\nbranch=%s\ndirty=unknown\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\nsource_commit_hint=%s\nsource_provenance=%s\nrecord_role=%s\nvia=%s\nat=%s\nreason=%s\n' \
    "$commit" "$branch" "$hash" "$sentinel_hash" "$upgrade_hash" "$source_hint" "$provenance" "$role" "$via" "$stamp" "$reason" > "$record" \
    && mv -f "$record" "$INSTALL_DIR/installed.txt"
}

health() { curl -s -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null || true; }

pid_on_port() {
  local pid="" root="${WA_PROC_ROOT:-/proc}" hex inodes inode fd target found
  if [ "$WINDOWS" = "1" ]; then
    # `netstat -ano` rather than `Get-NetTCPConnection`. Both answer the same question, but PowerShell
    # costs ~600ms to start while netstat costs ~40ms - and this is called in a poll loop, so the
    # difference is the difference between a fast upgrade and a slow one. The port is matched as the
    # *local* address only: a row whose remote port happens to match is a different connection.
    netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '
      $1 == "TCP" && $2 ~ p"$" && $4 == "LISTENING" { print $5; exit }' | tr -d '\r'
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $NF}' | sed 's/.*pid=\([0-9]*\).*/\1/' | head -1)"
    if [ -n "$pid" ]; then printf '%s' "$pid"; return 0; fi
  fi
  # The kernel's own answer, for an image that ships no `ss`: /proc/net/tcp{,6} names the listening
  # socket by inode, and the inode is matched against each process's descriptors. Without this, an
  # upgrade on such a machine found no listener, never stopped the old node, started a second one that
  # could not bind :$PORT, read health from the process it had failed to stop, and rolled back saying
  # the new binary "did not come up" (2026-10-28 on this node's own deploy).
  hex="$(printf '%04X' "$PORT" 2>/dev/null)"
  if [ -n "$hex" ] && [ -d "$root/net" ]; then
    inodes="$(awk -v want="$hex" 'FNR>1 { split($2, addr, ":"); if (addr[2]==want && $4=="0A") print $10 }' \
      "$root/net/tcp" "$root/net/tcp6" 2>/dev/null | sort -u)"
    for inode in $inodes; do
      [ -n "$inode" ] || continue
      for fd in "$root"/*/fd/*; do
        [ -L "$fd" ] || continue
        target="$(readlink "$fd" 2>/dev/null)" || continue
        [ "$target" = "socket:[$inode]" ] || continue
        found="${fd#"$root"/}"
        printf '%s' "${found%%/*}"
        return 0
      done
    done
  fi
  printf ''
}

# Is anything listening on a port? The same question `pid_on_port` answers, but it must be cheap: this
# one is polled while waiting for a port to come free or answer, and a PowerShell spawn per poll made
# the wait longer than the thing being waited for.
port_busy() {
  local root="${WA_PROC_ROOT:-/proc}" hex
  if [ "$WINDOWS" = "1" ]; then
    netstat -ano -p TCP 2>/dev/null | awk -v p=":$1" '$1 == "TCP" && $2 ~ p"$" && $4 == "LISTENING" { found = 1 } END { exit !found }'
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":$1 " && return 0
  fi
  # Same gap as `pid_on_port`: without `ss` this answered "free" about a port the old node held, which is
  # how an upgrade installed over a running process and then failed to bind behind it.
  hex="$(printf '%04X' "$1" 2>/dev/null)"
  [ -n "$hex" ] && [ -d "$root/net" ] || return 1
  awk -v want="$hex" 'FNR>1 { split($2, addr, ":"); if (addr[2]==want && $4=="0A") { found = 1 } } END { exit !found }' \
    "$root/net/tcp" "$root/net/tcp6" 2>/dev/null
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

# --- 1b. prove the candidate can run native code mode before it replaces the node ------------------
# `/health` answering says the process starts; it says nothing about the embedded sandbox. The binary this
# refused to check on 2026-10-22 answered health perfectly and then failed every run with
# `codemode_not_ready`, because it had been built without assets. The proof is the same one deploy.sh runs:
# the candidate executes the pinned guest and returns 42, or it is not installed.
CODEMODE_CHECK="$SOURCE_ROOT/scripts/check-embedded-runtime.lua"
if [ -z "$SOURCE_ROOT" ] || [ ! -f "$CODEMODE_CHECK" ]; then
  say "warning: no check-embedded-runtime.lua beside the candidate's source checkout; its embedded code mode is not proven"
else
  CHECK_HOME="$(mktemp -d)"
  CHECK_ROOT="$SOURCE_ROOT"; CHECK_SCRIPT="$CODEMODE_CHECK"; CHECK_HOME_ARG="$CHECK_HOME"
  if command -v cygpath >/dev/null 2>&1; then
    CHECK_ROOT="$(cygpath -w "$CHECK_ROOT")"; CHECK_SCRIPT="$(cygpath -w "$CHECK_SCRIPT")"; CHECK_HOME_ARG="$(cygpath -w "$CHECK_HOME")"
  fi
  say "proving the candidate runs embedded native code mode"
  if WASM_AGENT_HOME="$CHECK_HOME_ARG" WASM_AGENT_LUA_ROOT='' \
    WA_EMBEDDED_SOURCE_ROOT="$CHECK_ROOT" WA_SCRIPT="$CHECK_SCRIPT" \
    "$NEW" --db "$CHECK_HOME_ARG/embedded.db" >"$CHECK_HOME/check.log" 2>&1; then
    say "native code-mode assets proven"
  else
    tail -6 "$CHECK_HOME/check.log" 2>/dev/null | sed 's/^/    /'
    rm -rf "$CHECK_HOME"
    say "the candidate cannot run embedded native code mode - not installing it"
    exit 1
  fi
  rm -rf "$CHECK_HOME"
fi

# --- 2. wait for the node to be idle, so no turn is interrupted ----------------------------------
# --- the upgrade's own state, readable while it happens -------------------------------------------
# /health publishes this file as `upgrading`, so the window can draw a progress bar and say "restarting"
# instead of "lost the local node" - and a reader can tell an install in progress from a dead node.
UPGRADE_PHASE=waiting
phase() {
  UPGRADE_PHASE="$1"
  printf '{"state":"%s","phase":"%s","at":"%s","from":"%s","to":"%s"}\n' \
    "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PREVIOUS_COMMIT:-unknown}" "${COMMIT:-unknown}" \
    > "$INSTALL_DIR/deploy-state.json.tmp" 2>/dev/null \
    && mv -f "$INSTALL_DIR/deploy-state.json.tmp" "$INSTALL_DIR/deploy-state.json" 2>/dev/null
}
finish() {
  _rc=$?
  if [ "$_rc" -eq 0 ]; then phase done complete; else phase failed "$UPGRADE_PHASE"; fi
}
trap finish EXIT
# The marker is `queued`, NOT `upgrading`, until the stop actually begins. Writing `upgrading` here was a
# self-deadlock, measured on 2026-10-22: the node derives node_state from this file, the idle gate reads
# node_state, so the installer announced an install the gate would then wait forever to see finish - and
# the window drew a "waiting" bar that never moved. `upgrading` starts at the stop, when it is true.
phase queued waiting
say "waiting for the running node to finish what it is doing"
waited=0
FINE_TICKS=0

# ONE predicate from ONE snapshot. /health publishes `node_state`, derived from a single read of runs,
# queue, subagents and workers. The four independent greps this replaces could each pass while a different
# field was busy, and on 2026-10-22 that stopped a node under a live turn (`lost the local node mid-run`).
node_is_idle() {
  # `serde_json` sorts object keys, so the field is an OBJECT whose "state" is not first:
  #   "node_state":{"busy_threads":0,"queue":0,"state":"idle",...}
  # Grepping for `"node_state":"idle"` can never match, and neither can an ordered
  # `"subagents":{"active":0,"queued":0,"running":0}`. Both were wrong, which made this gate blind to
  # idle on every deploy since node_state was added - measured 2026-10-22 in upgrade-wait.log: 266 polls,
  # idle_ticks=0, node_state empty. Match the KEY, never its position.
  if printf '%s' "$1" | grep -q '"node_state":{[^}]*"state":"idle"'; then return 0; fi
  if printf '%s' "$1" | grep -q '"node_state":'; then return 1; fi   # busy / upgrading / restarting
  # A node older than node_state: require every fact to hold in the SAME payload, order-independent.
  printf '%s' "$1" | grep -q '"runs":\[\]' || return 1
  printf '%s' "$1" | grep -q '"queue":0' || return 1
  printf '%s' "$1" | grep -q '"subagents":{[^}]*"active":0' || return 1
  printf '%s' "$1" | grep -q '"subagents":{[^}]*"running":0' || return 1
  printf '%s' "$1" | grep -q '"subagents":{[^}]*"queued":0' || return 1
  if printf '%s' "$1" | grep -q '"label":"POST /chat'; then return 1; fi
  return 0
}
idle_ticks=0
# When the node was last seen making progress. The deadline below is measured from here, not from the
# start, so a long turn that is still alive is waited on and only a worker that has stopped reporting
# fails. `WA_IDLE_MAX_SECONDS` (default 0 = no cap) is an operator's hard wall-clock bound.
progress_at=0
IDLE_MAX="${WA_IDLE_MAX_SECONDS:-0}"
polls=0
while :; do
  state="$(health)"
  # Every poll is recorded to a FILE, never to stdout. Measured twice on 2026-10-22: an installer logged
  # one line and then went silent for 40 minutes, and a wait and a wedge were indistinguishable because
  # the only channel was the parent's pipe. This trail names the poll the run died on.
  polls=$((polls + 1))
  printf '%s poll=%s waited=%ss idle_ticks=%s node_state=%s bytes=%s\n' "$(date +%H:%M:%S%z)" "$polls" "$waited" "$idle_ticks" \
    "$(printf '%s' "$state" | sed -n 's/.*"node_state":{[^}]*"state":"\([a-z]*\)".*/\1/p' | head -1)" "${#state}" \
    >> "${WAIT_LOG:-$INSTALL_DIR/upgrade-wait.log}" 2>/dev/null
  if [ "$polls" -gt "${WA_IDLE_MAX_POLLS:-1440}" ]; then
    say "gave up after $polls polls (WA_IDLE_MAX_POLLS); not upgrading. Trail: ${WAIT_LOG:-$INSTALL_DIR/upgrade-wait.log}"
    exit 1
  fi
  if [ -z "$state" ]; then say "the node is not answering - nothing to wait for"; break; fi
  if node_is_idle "$state"; then
    # A debounce, not a delay for its own sake: a turn that starts a moment after the previous one ended
    # must not be killed in the gap. Three consecutive idle polls is a stable quiet, not one lucky read.
    idle_ticks=$((idle_ticks + 1))
    [ "$idle_ticks" -ge 3 ] && break
  else
    idle_ticks=0
  fi
  # A long turn is not a wedged one. Waiting is bounded by *lack of progress*, not by wall time: a run
  # whose worker is still reporting is doing work, and interrupting it because fifteen minutes passed
  # is how a legitimate 40-minute turn made every queued upgrade wait 900s, fail, and be retried while
  # the node stayed busy. Only a worker that has stopped reporting counts toward the deadline.
  case "$state" in
    *'"worker":"alive"'*) progress_at=$waited ;;
  esac
  if [ "$((waited - progress_at))" -ge "$IDLE_TIMEOUT" ]; then
    say "the worker has not reported progress for ${IDLE_TIMEOUT}s; not upgrading under a stalled turn"
    exit 1
  fi
  if [ "$IDLE_MAX" -gt 0 ] && [ "$waited" -ge "$IDLE_MAX" ]; then
    say "still busy after ${IDLE_MAX}s (WA_IDLE_MAX_SECONDS); not upgrading"
    exit 1
  fi
  [ $((waited % 30)) -eq 0 ] && say "  busy after ${waited}s; waiting for the turn to finish"
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
# One supervisor. When a sentinel watches this node it is the one that stops and starts it: it holds the
# node's lifecycle record (sentinel/node.json), restarts a node that is down, and hands the binding
# transport over from an open CLI. This script starting its own node beside it raced the sentinel's
# autostart and verified the wrong pid (serve.pid vs node.json) - every self-deploy rolled back
# (2026-10-28, three times). Supervised, this script swaps the files and asks for the restart.
SUPERVISED=0
if [ "$WINDOWS" != "1" ] && sentinel_supervises "$INSTALL_DIR"; then SUPERVISED=1; fi
[ "$TURN_OWNER" = "cli" ] && [ "$SUPERVISED" = "0" ] && { say "refused: an upgrade from a CLI turn needs a sentinel supervising the node (wa-sentinel start)"; exit 2; }
SENTINEL_DIR=""
# Ask the sentinel to restart the node and wait for its record. 0 = it is back.
sentinel_restart() {
  local out id rec=""
  out="$("$INSTALL_DIR/wa-sentinel" request restart --reason "$1" 2>&1)" || { say "the sentinel refused the restart: $out"; return 1; }
  id="$(printf '%s\n' "$out" | sed -n 's#.*/requests/\([^/ ]*\)\.json.*#\1#p' | head -1)"
  SENTINEL_DIR="$(printf '%s\n' "$out" | sed -n 's#.*[: ]\(/[^ ]*\)/requests/[^/ ]*\.json.*#\1#p' | head -1)"
  [ -n "$id" ] && [ -n "$SENTINEL_DIR" ] || { say "could not read the restart request: $out"; return 1; }
  say "the sentinel restarts the node (request $id)"
  for _ in $(seq 1 1200); do
    for folder in done failed; do
      [ -f "$SENTINEL_DIR/$folder/$id.json" ] && { rec="$SENTINEL_DIR/$folder/$id.json"; break 2; }
    done
    sleep 0.25
  done
  [ -n "$rec" ] || { say "the sentinel did not settle the restart within 300s"; return 1; }
  grep -q '"ok":true' "$rec" || { say "the sentinel's restart failed: $(sed -n 's/.*"detail":"\([^"]*\)".*/\1/p' "$rec")"; return 1; }
  return 0
}
sentinel_node_pid() { sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$SENTINEL_DIR/node.json" 2>/dev/null | head -1; }
OLD_PID="$(pid_on_port)"
phase upgrading stopping
[ -n "$OLD_PID" ] && say "stopping the node (pid $OLD_PID, by pid - never by image name)"
BACKUP="$INSTALLED.pre-upgrade"
cp -f "$INSTALLED" "$BACKUP" 2>/dev/null && cmp -s "$INSTALLED" "$BACKUP" || { say "cannot verify recovery binary; not stopping the node"; exit 1; }
if [ -d "$SOURCE_UI" ] && [ "$SOURCE_UI" != "$UI_DIR" ]; then
  for asset in $UI_FILES; do
    [ -f "$SOURCE_UI/$asset" ] || { say "missing release UI asset: $asset"; exit 1; }
    [ ! -f "$UI_DIR/$asset" ] || cp -f "$UI_DIR/$asset" "$UI_DIR/$asset.pre-upgrade" || exit 1
  done
fi
if [ -n "$OLD_PID" ] && [ "$SUPERVISED" = "0" ]; then
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
  # The same process holds a *second* listener, and a node that starts while it is still taken spends two
  # seconds per retry waiting for it. Measured on this node's own deploy (2026-10-28): twelve retries on
  # /proc/net/tcp's 127.0.0.1:8800, printed as "[client] bind ... Address already in use", and the health
  # deadline below ran out while the node was in fact about to answer. Waiting for the port frees the
  # start; the deadline change below covers the ownership handover that follows it.
  for _ in $(seq 1 400); do
    port_busy "$CLIENT_PORT" || break
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
  # of bringing the node back. The deadline is 90s (900 * 0.1s), not the old 20s (200 * 0.1s), because
  # 20s declared failure exactly when the node was about to answer. A start behind a dying predecessor
  # waits on two things that are the node's own, not this script's: its client-port bind retries (2s each,
  # twelve of them observed) and `binding_transport_already_owned: the owner did not yield within 20s`,
  # its documented ownership handover. Both together outlast 20s, so the upgrade rolled a working binary
  # back and told the operator it 'did not come up' (2026-10-28). A node that is genuinely dead still
  # fails, only 70s later; a node that is coming up is no longer called dead.
  for _ in $(seq 1 900); do
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
elif cmp -s "$NEW" "$INSTALLED"; then
  # Same bytes, different file: copying would only move the mtime, which nothing should read as a change.
  say "the new binary is byte-identical to $INSTALLED - nothing to swap, restarting it"
else
  # Copied next to the target and renamed over it: a crash mid-copy used to leave a torn binary at the
  # installed path, while a rename is all-or-nothing.
  phase upgrading installing
  { cp -f "$NEW" "$INSTALLED.new" && mv -f "$INSTALLED.new" "$INSTALLED"; } || { rm -f "$INSTALLED.new"; SWAP_OK=0; }
  say "installed $(basename "$NEW") over $INSTALLED"
fi
UI_OK=$SWAP_OK
if [ -d "$SOURCE_UI" ] && [ "$SOURCE_UI" != "$UI_DIR" ]; then
  mkdir -p "$UI_DIR"
  # `cmp` first: an unconditional `cp -f` moves the mtime of an *unchanged* asset, and the UI's version is
  # read by every open page. A no-op install must be a no-op, not a reason for every window to reload.
  for asset in $UI_FILES; do
    cmp -s "$SOURCE_UI/$asset" "$UI_DIR/$asset" || cp -f "$SOURCE_UI/$asset" "$UI_DIR/$asset" || UI_OK=0
  done
fi
if [ "$SUPERVISED" = "1" ]; then
  STARTED=0
  [ "$UI_OK" = "1" ] && sentinel_restart "upgrade: $(basename "$NEW")" && STARTED=1
else
  start_node "$INSTALLED"; STARTED=1
fi
if [ "$STARTED" = "1" ] && [ "$UI_OK" = "1" ] && wait_health; then
  LISTENER="$(pid_on_port)"
  if [ "$SUPERVISED" = "1" ]; then RECORDED="$(sentinel_node_pid)"
  else RECORDED="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"; fi
  if [ -n "$LISTENER" ] && [ "$LISTENER" = "$RECORDED" ]; then
    # Record the new binary before shipping companion files. If a companion
    # copy fails, installed.txt must still name the binary actually serving.
    record_install || { say "node upgraded, but installed.txt could not be recorded"; exit 3; }
    mkdir -p "$INSTALL_DIR/scripts"
    # Ship beside the binary without ever rewriting a file THIS shell may be reading. When the sentinel runs
    # this script, `$0` IS `$INSTALL_DIR/scripts/upgrade.sh`; `cp -f` over it rewrites the file bash is
    # reading, and bash tracks its position by byte offset, so the next read lands inside a line. MEASURED on
    # deploy.sh's own self-ship, same shape, 2026-10-02 19:30: `/…/deploy.sh: line 534: syntax error near
    # unexpected token '('` after the sentinel swap, with every later step skipped and no line in deploy.log,
    # because a parse error reaches none of the script's own refusal paths (and the `cp` form can also just
    # stop with status 0). Stage beside it and rename: the running shell keeps the bytes it opened.
    if ! cmp -s "$0" "$INSTALL_DIR/scripts/upgrade.sh"; then
      cp -f "$0" "$INSTALL_DIR/scripts/upgrade.sh.new.$$" \
        && mv -f "$INSTALL_DIR/scripts/upgrade.sh.new.$$" "$INSTALL_DIR/scripts/upgrade.sh" \
        && cmp -s "$0" "$INSTALL_DIR/scripts/upgrade.sh" \
        || { rm -f "$INSTALL_DIR/scripts/upgrade.sh.new.$$"; say "node upgraded, but could not ship upgrade.sh"; exit 3; }
    fi
    for skill_source in "$SOURCE_ROOT"/skills/*; do
      skill="${skill_source##*/}"
      if [ -n "$SOURCE_ROOT" ] && [ -f "$skill_source/SKILL.md" ]; then
        mkdir -p "$HOME_DIR/skills/$skill"
        cp -R "$SOURCE_ROOT/skills/$skill/." "$HOME_DIR/skills/$skill/" \
          || { say "node upgraded, but could not ship $skill skill and its helpers"; exit 3; }
      fi
    done
    record_install || { say "node upgraded, but final installed.txt could not be recorded"; exit 3; }
    phase upgrading verifying
    say "upgraded and recorded: $(health)"
    # Keep this one binary/UI backup for recovery after the deployment verdict.
    exit 0
  fi
  say "health answered, but listener pid $LISTENER differs from recorded pid $RECORDED"
fi

say "the new binary did not come up - putting the previous one back"
if [ "$SUPERVISED" = "1" ]; then
  if [ -f "$BACKUP" ]; then
    cp -f "$BACKUP" "$INSTALLED.new" && mv -f "$INSTALLED.new" "$INSTALLED"
    for asset in $UI_FILES; do
      [ ! -f "$UI_DIR/$asset.pre-upgrade" ] || cp -f "$UI_DIR/$asset.pre-upgrade" "$UI_DIR/$asset"
    done
    if sentinel_restart "upgrade rollback" && wait_health; then say "rolled back: $(health)"
    else say "the previous binary did not come up either - see wa-sentinel status and $HOME_DIR/serve.log"; fi
  else
    say "no backup to roll back to"
  fi
  exit 1
fi
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
