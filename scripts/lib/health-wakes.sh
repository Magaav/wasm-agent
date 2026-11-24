#!/usr/bin/env bash
# THE SELF-WAKE RULE: what /health.wakes must say, judged in ONE place.
#
# Approved 24/11 (r8c item G). MEASURED on this laptop: the node delivered ZERO self-wakes for 2.5 h
# (15:15Z-17:55Z) because its tick raised before the claim loop, and NOTHING said so - /health answered,
# and the loopback canary stayed green the whole time because it runs a CHILD node with a fresh ledger.
# The node now publishes its own wake state (/health.wakes), and this file is the rule every reader of it runs.
#
#   . scripts/lib/health-wakes.sh
#   printf '%s' "$HEALTH" | wa_health_wakes_verdict     # judge one body: 0 green / 1 red / 2 unknown / 3 waiting
#   wa_health_wakes_wait 8799 10                        # poll until the first tick publishes, then judge
#
# THE VERDICTS, AND WHY THERE ARE FOUR OF THEM:
#
#   0 GREEN    the wake state was read, and nothing is red.
#   1 RED      one line per red, by name, in the fixed order below.
#   2 UNKNOWN  a fact this rule needs is missing or unreadable. UNKNOWN IS NOT YES: every missing field is a
#              red naming the field, and a body this rule cannot read is a failure, not a pass.
#   3 WAITING  no tick has published since THIS node started (/health says `wakes_not_reported_yet`). This is
#              an install's own moment: verify-install.sh runs right after the restart, when rows that came
#              due during the install are minutes old and the first tick has not dispatched yet. A WAITING
#              verdict is not a pass and never a red; the reader waits (wa_health_wakes_wait, bounded), and
#              only what it finds after that bound is judged.
#
# The reds, in this fixed order:
#
#   RED wakes_unknown: <reason|field>         known != true and the reason is not `wakes_not_reported_yet`, or
#                                            a field this rule needs is missing (the line names it), or
#                                            `node_state.state` is not a name this rule knows.
#   RED selfloop_tick_failed: <error>         last_tick.outcome says the tick raised (the error, by name).
#   RED wakes_not_publishing: <n> ms old      the facts were published longer ago than WA_WAKES_PUBLISH_SECONDS
#                                            (default 30): the placement tick stopped republishing.
#   RED self_wake_stalled: <n> due row(s)...  a row the node is not holding has been dispatchable for longer
#                                            than WA_WAKES_STALL_SECONDS (default 120) while no turn is
#                                            running. TWO THINGS COUNT, or the red is false:
#                                              - THE AGE IS COUNTED FROM THIS PROCESS'S FIRST TICK, not from
#                                                the row's own date: a row that came due during an install
#                                                is not older than the process that was supposed to dispatch it.
#                                              - ROWS THE NODE IS DELIBERATELY HOLDING ARE NOT STALLED: the
#                                                `deploy_waiting` rows (a build waits or installs) and the
#                                                rows of a held session are subtracted, because `dispatchable`
#                                                excludes the held sessions and the deploy is not a stall.
#
# WHAT `node_state.state` CAN SAY (closed set, built in rust/wa-capabilities/src/serve.rs):
#   idle        nothing is running
#   busy        a thread, run, queue entry or subagent is working - a turn may be running
#   upgrading   an install phase (deploy-state.json fresher than 900 s): no turn can run
# A NAME THIS RULE DOES NOT KNOW IS RED wakes_unknown, so a new state cannot silently switch the checks off.
# "No turn is running" is not `state == idle`: a WEDGED lane reports `busy` and the node's own `worker` says
# `stalled`, and a stalled lane must not hide a dead loop - so busy-with-a-stalled-worker counts as no turn.
#
# WHY AWK AND NOT jq: verify-install.sh must run on a node whose PATH has no jq (Git Bash on Windows has none),
# and the rule is the same rule everywhere. scripts/test-health-wakes-rule.cjs runs BOTH against the same real
# /health bodies when jq is present, so the two cannot drift.

# The value of a TOP-LEVEL key of one JSON object, as the raw token: `{...}` for an object, `true`/`false`/`null`,
# a number, or `"text"` (quotes kept). The FIRST occurrence at depth 1 wins: a key that appears twice cannot
# change the answer, which is what the sed readers this replaces got wrong (a greedy `.*` took the LAST match).
wa_health_json_at() { # <key>  (the object on stdin)
  awk -v key="$1" '
    BEGIN { RS = "\001" }
    { body = $0
      depth = 0; in_string = 0; escaped = 0; text = ""
      for (i = 1; i <= length(body); i++) {
        c = substr(body, i, 1)
        if (in_string) {
          if (escaped) { text = text c; escaped = 0 }
          else if (c == "\\") { text = text c; escaped = 1 }
          else if (c == "\"") {
            in_string = 0
            if (depth == 1 && text == key) {
              j = i + 1
              while (j <= length(body) && substr(body, j, 1) ~ /[ \t\r\n]/) j++
              if (j <= length(body) && substr(body, j, 1) == ":") { print wa_value(substr(body, j + 1)); exit 0 }
            }
          } else text = text c
        } else if (c == "\"") { in_string = 1; text = "" }
        else if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") depth--
      }
      exit 1 }
    function wa_value(rest,  j, d, ins, esc, c2) {
      sub(/^[ \t\r\n]+/, "", rest)
      if (substr(rest, 1, 1) == "{") {
        d = 0; ins = 0; esc = 0
        for (j = 1; j <= length(rest); j++) {
          c2 = substr(rest, j, 1)
          if (ins) { if (esc) esc = 0; else if (c2 == "\\") esc = 1; else if (c2 == "\"") ins = 0 }
          else if (c2 == "\"") ins = 1
          else if (c2 == "{") d++
          else if (c2 == "}") { d--; if (d == 0) return substr(rest, 1, j) }
        }
        return ""
      }
      if (substr(rest, 1, 1) == "\"") {
        for (j = 2; j <= length(rest); j++) if (substr(rest, j, 1) == "\"") return substr(rest, 1, j)
        return ""
      }
      if (match(rest, /^(true|false|null)/)) return substr(rest, 1, RLENGTH)
      if (match(rest, /^-?[0-9]+(\.[0-9]+)?/)) return substr(rest, 1, RLENGTH)
      return ""
    }'
}

# A string field of one object (quotes stripped). Absent reads as empty, and the caller decides what that means.
wa_health_json_text() {
  local raw; raw="$(printf '%s' "$1" | wa_health_json_at "$2")" || raw=""
  case "$raw" in
    '"'*) raw="${raw#\"}"; raw="${raw%\"}" ;;
    true|false|null) raw="" ;;
  esac
  printf '%s' "$raw"
}

# A non-negative integer field. Absent is NOT zero: it returns 1 and prints nothing.
wa_health_json_number() {
  local raw; raw="$(printf '%s' "$1" | wa_health_json_at "$2")" || return 1
  case "$raw" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$raw"
}

# true|false, and nothing else.
wa_health_json_bool() {
  local raw; raw="$(printf '%s' "$1" | wa_health_json_at "$2")" || return 1
  case "$raw" in true|false) printf '%s' "$raw" ;; *) return 1 ;; esac
}

# The verdict. Reads the body on stdin; prints its lines; returns 0 green / 1 red / 2 unknown / 3 waiting.
wa_health_wakes_verdict() {
  local body; body="$(cat)"
  local stall="${WA_WAKES_STALL_SECONDS:-120}" publish="${WA_WAKES_PUBLISH_SECONDS:-30}"
  case "$stall" in ''|*[!0-9]*) stall=120 ;; esac
  case "$publish" in ''|*[!0-9]*) publish=30 ;; esac
  case "$body" in *[![:space:]]*) ;; *) printf 'UNKNOWN wakes: no /health body to judge\n'; return 2 ;; esac

  local wakes; wakes="$(printf '%s' "$body" | wa_health_json_at wakes)" || wakes=""
  case "$wakes" in
    '') printf 'UNKNOWN wakes: /health has no wakes object (a node older than this rule, or a body that is not one)\n'; return 2 ;;
    '{'*) ;;
    *) printf 'RED wakes_unknown: /health.wakes is not an object\n'; return 1 ;;
  esac

  local known; known="$(wa_health_json_bool "$wakes" known)" || known=""
  case "$known" in
    true) ;;
    false)
      local reason why
      reason="$(wa_health_json_text "$wakes" reason)"
      if [ "$reason" = "wakes_not_reported_yet" ]; then
        printf 'WAITING wakes: no tick has published wake facts since this node started (wakes_not_reported_yet)\n'
        return 3
      fi
      why="$(wa_health_json_text "$wakes" error)"
      printf 'RED wakes_unknown: %s%s\n' "${reason:-no reason given}" "${why:+ ($why)}"
      return 1 ;;
    *) printf 'RED wakes_unknown: known is missing from /health.wakes\n'; return 1 ;;
  esac

  local red=0
  local tick; tick="$(printf '%s' "$wakes" | wa_health_json_at last_tick)" || tick=""
  case "$tick" in
    '{'*) ;;
    *) printf 'RED wakes_unknown: last_tick is missing from /health.wakes\n'; return 1 ;;
  esac
  local outcome; outcome="$(wa_health_json_text "$tick" outcome)"
  case "$outcome" in
    ok) ;;
    selfloop_tick_failed)
      local error; error="$(wa_health_json_text "$tick" error)"
      printf 'RED selfloop_tick_failed: %s\n' "${error:-no error recorded}"
      red=1 ;;
    '') printf 'RED wakes_unknown: last_tick.outcome is missing\n'; return 1 ;;
    *) printf 'RED wakes_unknown: last_tick outcome %s\n' "$outcome"; return 1 ;;
  esac

  # EVERY FIELD THIS RULE READS, OR A RED THAT NAMES IT. A missing field used to skip its check, which is the
  # same lie as green: the reader cannot tell "nothing due" from "the field is not there".
  local ticks ticking published dispatchable oldest held
  ticks="$(wa_health_json_number "$wakes" ticks_since_start)" || { printf 'RED wakes_unknown: ticks_since_start is missing from /health.wakes\n'; return 1; }
  ticking="$(wa_health_json_number "$wakes" ticking_for_s)" || { printf 'RED wakes_unknown: ticking_for_s is missing from /health.wakes\n'; return 1; }
  published="$(wa_health_json_number "$wakes" published_age_ms)" || { printf 'RED wakes_unknown: published_age_ms is missing from /health.wakes\n'; return 1; }
  dispatchable="$(wa_health_json_number "$wakes" dispatchable)" || { printf 'RED wakes_unknown: dispatchable is missing from /health.wakes\n'; return 1; }
  oldest="$(wa_health_json_number "$wakes" oldest_dispatchable_age_s)" || { printf 'RED wakes_unknown: oldest_dispatchable_age_s is missing from /health.wakes\n'; return 1; }
  held="$(wa_health_json_number "$wakes" deploy_waiting)" || held=0
  if [ "$ticks" -eq 0 ]; then
    printf 'WAITING wakes: the node published a tick count of 0 (no tick since it started)\n'
    return 3
  fi

  local lane worker
  lane="$(wa_health_json_text "$(printf '%s' "$body" | wa_health_json_at node_state)" state)"
  case "$lane" in
    idle|busy|upgrading) ;;
    '') printf 'RED wakes_unknown: node_state.state is missing from /health\n'; return 1 ;;
    *) printf 'RED wakes_unknown: node_state.state "%s" is not a name this rule knows (idle, busy, upgrading)\n' "$lane"; return 1 ;;
  esac
  worker="$(wa_health_json_text "$body" worker)"
  [ -n "$worker" ] || { printf 'RED wakes_unknown: worker is missing from /health\n'; return 1; }

  if [ "$published" -gt $((publish * 1000)) ]; then
    printf 'RED wakes_not_publishing: %s ms old (bound %ss)\n' "$published" "$publish"
    red=1
  fi

  local not_held=$((dispatchable - held)); [ "$not_held" -lt 0 ] && not_held=0
  # THE ROW'S AGE COUNTS FROM THIS PROCESS'S FIRST TICK: a row that came due while the node was being installed
  # was never dispatchable by this process, and counting its own date would fail every good install.
  local age="$oldest"; [ "$ticking" -lt "$age" ] && age="$ticking"
  local turn=1
  case "$lane" in busy) [ "$worker" = "stalled" ] && turn=0 ;; *) turn=0 ;; esac
  if [ "$not_held" -gt 0 ] && [ "$age" -gt "$stall" ] && [ "$turn" = 0 ]; then
    printf 'RED self_wake_stalled: %s due row(s) the node is not holding, oldest %ss (counted from this process, %ss), lane %s\n' \
      "$not_held" "$age" "$ticking" "$lane"
    red=1
  fi
  [ "$red" = 1 ] && return 1
  printf 'GREEN wakes: last_tick ok, %s dispatchable (%s held for a deploy), oldest %ss, ticking %ss, lane %s, worker %s\n' \
    "$dispatchable" "$held" "$oldest" "$ticking" "$lane" "$worker"
  return 0
}

# WAIT, THEN JUDGE: the reader an install runs. It polls /health until the node has published a tick, and only
# what it finds after the bound is judged - so a good install is never red for the tick it has not run yet, and
# a node that never publishes is a failure, not a pass.
#
# THE BOUND IS 30 s, and it is sized against the placement tick's own interval (2 s: `sleep(Duration::from_secs(2))`
# in rust/wa-capabilities/src/serve.rs). 30 s is fifteen ticks, not two: a first tick on a loaded node with a large
# ledger can take far longer than a scratch node's 1.3 s (MEASURED there), and the bound only costs time when
# something is already wrong - a node that is publishing answers in the first second.
wa_health_wakes_wait() { # <port|url> [bound_seconds]
  local url="$1" bound="${2:-${WA_WAKES_WAIT_SECONDS:-30}}"
  case "$bound" in ''|*[!0-9]*) bound=30 ;; esac
  case "$url" in
    http://*|https://*) ;;
    *) url="http://127.0.0.1:$url" ;;
  esac
  case "$url" in */health) ;; *) url="$url/health" ;; esac
  local waited=0 body lines rc
  while :; do
    body="$(curl -s -m 6 "$url" 2>/dev/null || true)"
    if [ -z "$body" ]; then
      printf 'UNKNOWN wakes: %s did not answer\n' "$url"
      return 2
    fi
    lines="$(printf '%s' "$body" | wa_health_wakes_verdict)"; rc=$?
    if [ "$rc" -ne 3 ]; then printf '%s\n' "$lines"; return "$rc"; fi
    if [ "$waited" -ge "$bound" ]; then
      printf 'UNKNOWN wakes: no tick published %ss after the node answered (wakes_not_reported_yet past the bound)\n' "$bound"
      return 2
    fi
    sleep 1; waited=$((waited + 1))
  done
}
