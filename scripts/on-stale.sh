#!/usr/bin/env bash
# onStale - the node's "nothing is working here" transition, and the one place it may act on it.
#
# WHAT. This is a deterministic observer, run by the sentinel on a schedule. It answers one question:
#   has this node gone from WORKING to IDLE, stayed idle, and is its install behind its own source?
# and, only when all of that is true, it prepares a candidate and writes ONE upgrade request.
#
# WHY IT LOOKS LIKE THIS.
#   * The idle test is the node's own `node_state` - one value derived from one snapshot of runs, queue,
#     threads and subagents. It is NOT re-derived here from four fields: the upgrade gate did that on
#     2026-10-22 and read "idle" with a turn in flight, stopping the node under it.
#   * It is EDGE-triggered via a state file. A level test would fire on every tick and fight every new run.
#   * It never stops, starts, or installs anything. Only the sentinel may, and it does that from the request
#     this writes - so a failure here is a failed *request*, which is visible, not a half-done install.
#   * Failure is loud: an install record it cannot trust (`commit=unknown`) is a refusal with a reason, not
#     a quiet exit.
#
# ENV
#   WA_INSTALL_DIR    install directory (default: the platform's wasm-agent install)
#   WA_STALE_QUIET_S  required quiet seconds before the node counts as stale (default 10)
#   WA_STALE_DRY_RUN  1 = compute and report, write no request
#   WA_COORDINATOR_SESSION  session to wake on a deploy outcome (optional)
set -uo pipefail

STATE_DIR="${WA_INSTALL_DIR:-}"
if [ -z "$STATE_DIR" ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) STATE_DIR="${LOCALAPPDATA:-$HOME/AppData/Local}/wasm-agent" ;;
    *) STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/wasm-agent" ;;
  esac
fi
STATE="$STATE_DIR/on-stale-state.json"
LOG="$STATE_DIR/on-stale.log"
PORT="${WA_PORT:-8799}"
QUIET="${WA_STALE_QUIET_S:-10}"
DRY="${WA_STALE_DRY_RUN:-0}"
now="$(date +%s)"

say() { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; printf '%s\n' "$*"; }
field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
state_field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p" | head -1; }
read_state() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" "$STATE" 2>/dev/null | tr -d '"' | head -1; }
write_state() { # busy_at acted_key head
  printf '{"last_busy_at":%s,"acted_key":"%s","head":"%s","at":%s}\n' \
    "${1:-0}" "${2:-}" "${3:-}" "$now" > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null
}

# WA_HEALTH_FILE is a test seam: the decision below is what needs testing, and a fixed JSON is the only
# way to test "idle from one snapshot" without racing a real node's changing state.
if [ -n "${WA_HEALTH_FILE:-}" ]; then health="$(cat "$WA_HEALTH_FILE" 2>/dev/null)";
else health="$(curl -s -m 4 "http://127.0.0.1:$PORT/health" 2>/dev/null)"; fi
if [ -z "$health" ]; then
  # No node answering is not "idle": there is nothing to upgrade and nothing to prove. Leave the state
  # alone so a restart does not look like a fresh idle edge.
  say "onStale: node is not answering on :$PORT - nothing to do"
  exit 0
fi

node_state="$(printf '%s' "$health" | field state)"
case "$node_state" in
  idle) ;;
  upgrading|restarting)
    say "onStale: install already in progress (node_state=$node_state) - not stacking a second one"
    exit 0 ;;
  busy|unknown|'')
    write_state "$now" "$(read_state acted_key)" "$(read_state head)"
    say "onStale: node is $node_state - not stale"
    exit 0 ;;
  *)
    write_state "$now" "$(read_state acted_key)" "$(read_state head)"
    say "onStale: unrecognised node_state=$node_state - treating as busy"
    exit 0 ;;
esac

busy_at="$(read_state last_busy_at)"
[ -n "$busy_at" ] || busy_at=0
quiet_for=$((now - busy_at))
if [ "$quiet_for" -lt "$QUIET" ]; then
  say "onStale: idle for ${quiet_for}s < ${QUIET}s - waiting for a stable edge"
  exit 0
fi

tree="$(cat "$STATE_DIR/runtime-worktree.txt" 2>/dev/null | tr -d '\r\n')"
if [ -z "$tree" ]; then
  say "onStale: no runtime worktree recorded in $STATE_DIR/runtime-worktree.txt - refusing to guess"
  exit 2
fi
if [ ! -d "$tree/.git" ] && [ ! -f "$tree/.git" ]; then
  say "onStale: recorded runtime worktree $tree is not a git work tree - refusing to guess"
  exit 2
fi

installed="$(sed -n 's/^commit=//p' "$STATE_DIR/installed.txt" 2>/dev/null | head -1 | tr -d '\r')"
case "$installed" in
  ''|unknown)
    # This is the state that silently disabled the previous staleness check: the install happened and its
    # record says unknown. A check that cannot name what is installed cannot say whether it is behind.
    say "onStale: REFUSED - installed.txt says commit=${installed:-<empty>}; no update decision can be made from that"
    exit 2 ;;
esac

if [ -n "$(git -C "$tree" status --porcelain 2>/dev/null | head -1)" ]; then
  say "onStale: $tree is dirty - refusing to build an install from a tree nobody can reproduce"
  exit 0
fi

git -C "$tree" fetch --quiet origin 2>/dev/null
head_commit="$(git -C "$tree" rev-parse --short=8 origin/main 2>/dev/null)"
[ -n "$head_commit" ] || { say "onStale: cannot read origin/main in $tree - refusing to guess"; exit 2; }

if [ "${installed:0:8}" = "$head_commit" ]; then
  write_state "$busy_at" "" "$head_commit"
  say "onStale: installed ${installed:0:8} == origin/main $head_commit - nothing to do"
  exit 0
fi

acted="$(read_state acted_key)"
key="$installed->$head_commit"
if [ "$acted" = "$key" ]; then
  say "onStale: already acted for $key; waiting for a new commit or an install"
  exit 0
fi

say "onStale: STALE - installed ${installed:0:8}, origin/main $head_commit"
if [ "$DRY" = "1" ]; then
  say "onStale: dry run - would build and request the upgrade"
  exit 0
fi

# The candidate must come from a source checkout: upgrade.sh refuses one it cannot compare with the
# installed commit, which is exactly the refusal that made the first real deploy fail in 12 seconds.
cargo build --release --manifest-path "$tree/rust/Cargo.toml" >/dev/null 2>&1 || {
  say "onStale: build failed; not requesting an install from a binary that does not exist"
  exit 2
}
candidate="$tree/rust/target/release/wa.exe"
[ -x "$candidate" ] || candidate="$tree/rust/target/release/wa"
[ -f "$candidate" ] || { say "onStale: no candidate binary after a successful build"; exit 2; }

sentinel="${WA_SENTINEL_BIN:-$STATE_DIR/wa-sentinel.exe}"
[ -f "$sentinel" ] || sentinel="$(command -v wa-sentinel 2>/dev/null || true)"
[ -n "$sentinel" ] && [ -e "$sentinel" ] || { say "onStale: no sentinel binary to request an upgrade"; exit 2; }

args=(request upgrade --binary "$candidate" --reason "onStale: installed ${installed:0:8} is behind origin/main $head_commit; the node went idle, so this is the moment to install it")
if [ -n "${WA_COORDINATOR_SESSION:-}" ]; then
  args+=(--session "$WA_COORDINATOR_SESSION" --prompt "onStale requested an install (installed ${installed:0:8} -> $head_commit). Verify from installed.txt and the served ui/app.js, not from the request: if the request failed, read failed/*.json and upgrade.log, FIX the root cause, then re-request. Do not report a launch receipt as a result.")
fi

if "$sentinel" "${args[@]}" >>"$LOG" 2>&1; then
  write_state "$busy_at" "$key" "$head_commit"
  say "onStale: upgrade requested for $key"
else
  say "onStale: the request itself was refused (see $LOG); no install was attempted"
  exit 2
fi
