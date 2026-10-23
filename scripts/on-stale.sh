#!/usr/bin/env bash
# onStale - the main run-finished observer, and the one place it may act on it.
#
# WHAT. This is a deterministic observer, run by the sentinel once per `node.run_finished` event.
# It asks whether a main run just finished, whether /compact can atomically reserve the idle node,
# and whether the install is behind its own source. On that event it checks the 40% idle compaction,
# then (if needed) writes ONE deploy request from the exact full origin/main SHA and the parent
# session/owner the node itself proves.
#
# WHY IT LOOKS LIKE THIS.
#   * The /compact route is the authority on whether a main run is still active. Aggregate health
#     state is not used here: it counts subagents, which are out of scope for main compaction.
#   * The trigger is the node's own run-finished event, so it does not poll or race a 30s tick.
#   * The event names the session that just finished, and that is the session this posts: with more
#     than one main thread, 'the newest main session on this node' is a different thread often
#     enough that the idle pass compacted the wrong one. The id is read from the retained event file
#     and validated against a strict character set before it is put in a JSON body - event text is
#     data, never shell, and never trusted to be well formed.
#   * A run with no event file (a manual/direct invocation) keeps the route's own latest-main
#     selection, and says so: that fallback is the route's, not this script's, and it is not
#     event-targeted. A run WITH an event file whose session is missing or malformed does not fall
#     back at all - it names the event it could not trust and skips the idle summary.
#   * It never stops, starts, builds or installs anything. Deploy is the only installer path, and the
#     sentinel performs the request when the node is idle. A failure here is a failed *request*, which is
#     visible, not a half-done install.
#   * Failure is loud: an install record it cannot trust (`commit=unknown`) is a refusal with a reason, not
#     a quiet exit. A required deploy value it cannot prove is a durable HELD state with that exact reason -
#     never a guessed source, owner or session, and never an install.
#
# ENV
#   WA_INSTALL_DIR          install directory (default: the platform's wasm-agent install)
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
# event_session - the top-level "session" string of a retained job event, or nothing.
# Reads JSON as data with awk's string scanner: one top-level object, quoted keys, escapes skipped.
# It never evaluates the event, and it stops when that object ends, so a nested "session" (a field
# of an unrelated object) is never mistaken for the event's own id.
event_session() { # file
  [ -f "$1" ] || return 0
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf); if (n == 0) exit 0
      depth = 0; i = 1; want = 0
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "{" || c == "[") { depth++; i++; continue }
        if (c == "}" || c == "]") { depth--; if (depth <= 0) exit 0; i++; continue }
        if (c != "\"") { i++; continue }
        j = i + 1; s = ""; closed = 0
        while (j <= n) {
          d = substr(buf, j, 1)
          if (d == "\\") { s = s substr(buf, j, 2); j += 2; continue }
          if (d == "\"") { closed = 1; j++; break }
          s = s d; j++
        }
        if (!closed) exit 0
        k = j
        while (k <= n) {
          e = substr(buf, k, 1)
          if (e != " " && e != "\t" && e != "\n" && e != "\r") break
          k++
        }
        if (depth == 1 && substr(buf, k, 1) == ":") { want = (s == "session") ? 1 : 0; i = k + 1; continue }
        if (depth == 1 && want == 1) { print s; exit 0 }
        i = j
      }
    }' "$1" 2>/dev/null | head -1
}
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

# The /compact route is the authority on whether a main run is still active. Do not gate on the
# aggregate node_state here: that field also counts subagents, which are deliberately out of scope
# for main-session compaction. The route ignores subagents and returns node_busy for a real run.
if printf '%s' "$health" | grep -q '"upgrading":{[^}]*"state":"upgrading"'; then
  say "onStale: install already in progress - not stacking a second one"
  exit 0
fi

# Idle summarization: the in-run compactor keeps its measured 90-95% trigger because early
# rewrites invalidate the provider prefix cache. After a main run has finished, with no other
# run queued, the operator asked for one maintenance check at 40% on the session that just
# finished. The route atomically reserves the idle node; subagents are ignored, and it never
# summarizes a subagent.
compact_body='{"min_percent":40}'
compact_skip=""
event_sid=""
if [ -n "${WA_JOB_EVENT_FILE:-}" ]; then
  event_sid="$(event_session "$WA_JOB_EVENT_FILE")"
  if [ -z "$event_sid" ]; then
    compact_skip="$WA_JOB_EVENT_FILE has no top-level \"session\" string; skipping the idle compaction rather than letting the route pick some other main session"
  else
    case "$event_sid" in
      *[!A-Za-z0-9._:-]*) compact_skip="$WA_JOB_EVENT_FILE has a session id outside the safe id set ([A-Za-z0-9._:-]); skipping the idle compaction rather than posting it" ;;
      *) compact_body="{\"min_percent\":40,\"session_id\":\"$event_sid\"}" ;;
    esac
  fi
  [ -z "$compact_skip" ] || event_sid=""
fi

if [ "${WA_STALE_COMPACT:-1}" = "0" ]; then
  : # idle compaction disabled by the operator: nothing to target, nothing to post
elif [ -n "$compact_skip" ]; then
  say "onStale: MALFORMED EVENT - $compact_skip; nothing was summarized"
elif [ -z "${WA_JOB_EVENT_FILE:-}" ]; then
  say "onStale: no WA_JOB_EVENT_FILE (manual or direct run) - posting min_percent:40 with no session_id, so the route uses its latest-main fallback; this request is not event-targeted"
else
  say "onStale: idle compaction targeted at the event session $event_sid"
fi

# One POST for both shapes: what differs is the body, and whether the fallback was named above.
if [ "${WA_STALE_COMPACT:-1}" != "0" ] && [ -z "$compact_skip" ]; then
  compact="$(curl -s -m 180 -X POST -H 'Content-Type: application/json' -d "$compact_body" "http://127.0.0.1:$PORT/compact" 2>/dev/null)"
  case "$compact" in
    *'"error":"node_busy"'*)
      say "onStale: a main run is still active - compaction deferred to its run-finished event"
      exit 0 ;;
    '')
      say "onStale: idle compaction returned no response (the request may still be running; not retried here)" ;;
    *)
      say "onStale: idle compaction $compact" ;;
  esac
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

busy_at="$(read_state last_busy_at)"
[ -n "$busy_at" ] || busy_at=0

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

reason="onStale: installed ${installed:0:8} is behind origin/main $head_sha; the main run finished, so this is the moment to deploy it"
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
