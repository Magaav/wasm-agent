#!/usr/bin/env bash
# onStale - the node's "nothing is working here" transition, and the one place it may act on it.
#
# WHAT. This is a deterministic observer, run by the sentinel on a schedule. It answers one question:
#   has this node gone from WORKING to IDLE, stayed idle, and is its install behind its own source?
# and, only when all of that is true, it writes ONE deploy request carrying the exact full origin/main
# SHA and the parent session/owner the node itself proves.
#
# WHY IT LOOKS LIKE THIS.
#   * The idle test is the node's own `node_state` - one value derived from one snapshot of runs, queue,
#     threads and subagents. It is NOT re-derived here from four fields: the upgrade gate did that on
#     2026-10-22 and read "idle" with a turn in flight, stopping the node under it.
#   * It is EDGE-triggered via a state file. A level test would fire on every tick and fight every new run.
#   * It never stops, starts, builds or installs anything. Deploy is the only installer path, and the
#     sentinel performs the request when the node is idle. A failure here is a failed *request*, which is
#     visible, not a half-done install.
#   * Failure is loud: an install record it cannot trust (`commit=unknown`) is a refusal with a reason, not
#     a quiet exit. A required deploy value it cannot prove is a durable HELD state with that exact reason -
#     never a guessed source, owner or session, and never an install.
#
# ENV
#   WA_INSTALL_DIR          install directory (default: the platform's wasm-agent install)
#   WA_STALE_QUIET_S        required quiet seconds before the node counts as stale (default 10)
#   WA_STALE_DRY_RUN        1 = compute and report, write no request
#   WA_COORDINATOR_SESSION  parent session for the deploy protocol (required to request a deploy)
set -uo pipefail

STATE_DIR="${WA_INSTALL_DIR:-}"
if [ -z "$STATE_DIR" ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) STATE_DIR="${LOCALAPPDATA:-$HOME/AppData/Local}/wasm-agent" ;;
    *) STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/wasm-agent" ;;
  esac
fi
STATE="$STATE_DIR/on-stale-state.json"
HELD="$STATE_DIR/on-stale-held.json"
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
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n' '  '; }
hold() { # code detail
  # A required value could not be proved. Record it where an operator and the status surface can read it,
  # with the exact reason, and stop without writing a request. The stale key is deliberately not marked as
  # acted: once the operator supplies the missing fact the next tick may request the deploy.
  local code="$1" detail="$2"
  printf '{"phase":"held","code":"%s","reason":"%s","installed":"%s","head":"%s","at":%s}\n' \
    "$(json_escape "$code")" "$(json_escape "$detail")" "$(json_escape "${installed:-}")" \
    "$(json_escape "${head_sha:-}")" "$now" > "$HELD.tmp" 2>/dev/null && mv -f "$HELD.tmp" "$HELD" 2>/dev/null
  say "onStale: HELD ($code) - $detail; no deploy was requested and nothing was installed"
  exit 2
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

node_state="$(printf '%s' "$health" | sed -n 's/.*"node_state":{[^}]*"state":"\([a-z]*\)".*/\1/p' | head -1)"
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

# Idle summarization: the in-run compactor keeps its measured 90-95% trigger because early
# rewrites invalidate the provider prefix cache. On an idle, quiet node the operator asked for
# one additional maintenance path at 40%: summarize the latest main session now, while no turn
# is using it. The route rechecks the 40% threshold; it never summarizes a subagent.
if [ "${WA_STALE_COMPACT:-1}" != "0" ]; then
  compact="$(curl -s -m 180 -X POST -H 'Content-Type: application/json' -d '{"min_percent":40}' "http://127.0.0.1:$PORT/compact" 2>/dev/null)"
  if [ -n "$compact" ]; then
    say "onStale: idle compaction $compact"
  else
    say "onStale: idle compaction returned no response (the request may still be running; not retried here)"
  fi
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
head_sha="$(git -C "$tree" rev-parse origin/main 2>/dev/null)"
case "$head_sha" in
  ''|*[!0-9a-fA-F]*) hold deploy_source_sha_unproved "origin/main in $tree is not a full source SHA (got '${head_sha:-<empty>}')" ;;
esac
[ "${#head_sha}" -eq 40 ] || hold deploy_source_sha_unproved "origin/main in $tree is not a 40-character source SHA (got '${head_sha:-<empty>}')"
head_commit="${head_sha:0:8}"

if [ "${installed:0:8}" = "$head_commit" ]; then
  rm -f "$HELD"
  write_state "$busy_at" "" "$head_commit"
  say "onStale: installed ${installed:0:8} == origin/main $head_commit - nothing to do"
  exit 0
fi

acted="$(read_state acted_key)"
key="$installed->$head_commit"
if [ "$acted" = "$key" ]; then
  rm -f "$HELD"
  say "onStale: already acted for $key; waiting for a new commit or an install"
  exit 0
fi

say "onStale: STALE - installed ${installed:0:8}, origin/main $head_commit"
if [ "$DRY" = "1" ]; then
  if [ -n "${WA_COORDINATOR_SESSION:-}" ]; then
    say "onStale: dry run - would prove the owner for $WA_COORDINATOR_SESSION and request deploy for $head_sha (onStale never builds or installs)"
  else
    say "onStale: dry run - would be HELD (deploy_parent_session_unproved: WA_COORDINATOR_SESSION is unset); no request would be written"
  fi
  exit 0
fi

# The deploy protocol requires an exact source SHA, a parent session and the owner the node proves for
# that session. None of them is guessed: if a value is missing or does not match what the node says, this
# is a visible hold, not a request and not an install.
SESSION="${WA_COORDINATOR_SESSION:-}"
if [ -z "$SESSION" ]; then
  hold deploy_parent_session_unproved "WA_COORDINATOR_SESSION is unset; the deploy protocol requires the parent session"
fi

owner_json="$(curl -s -m 4 -G --data-urlencode "id=$SESSION" "http://127.0.0.1:$PORT/session/owner" 2>/dev/null)"
OWNER="$(printf '%s' "$owner_json" | field user_id)"
owner_id="$(printf '%s' "$owner_json" | field id)"
if [ -z "$OWNER" ] || [ "$owner_id" != "$SESSION" ]; then
  hold deploy_owner_unproved "GET /session/owner?id=$SESSION did not prove session id and user_id (response: ${owner_json:0:300})"
fi

sentinel="${WA_SENTINEL_BIN:-$STATE_DIR/wa-sentinel.exe}"
[ -f "$sentinel" ] || sentinel="$(command -v wa-sentinel 2>/dev/null || true)"
[ -n "$sentinel" ] && [ -e "$sentinel" ] || hold deploy_sentinel_unavailable "no sentinel binary to request a deploy"

reason="onStale: installed ${installed:0:8} is behind origin/main $head_sha; the node went idle, so this is the moment to deploy it"
args=(request deploy --expected-sha "$head_sha" --owner "$OWNER" --session "$SESSION" --reason "$reason")

if request_out="$("$sentinel" "${args[@]}" 2>&1)"; then
  printf '%s\n' "$request_out" >> "$LOG"
  rm -f "$HELD"
  write_state "$busy_at" "$key" "$head_commit"
  say "onStale: deploy requested for $key (source $head_sha)"
else
  rc=$?
  printf '%s\n' "$request_out" >> "$LOG"
  hold deploy_request_refused "the sentinel refused the deploy request (exit $rc): $(printf '%s' "$request_out" | tail -n 1)"
fi
