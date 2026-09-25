#!/usr/bin/env bash
# Keep the WhatsApp source up, deterministically and with no model in the loop.
#
#   bash scripts/whatsapp-source-ensure.sh [--task NAME] [--port N] [--wait SECONDS] [--quiet]
#
# `--port` exists for tests: a fixture binds a foreign listener on a scratch port and proves the refusal
# without touching the live source.
#
# The source is Chrome on the agent profile with DevTools on loopback:9222. Four different things can be
# wrong, and they are not the same thing, so each has its own categorical answer:
#
#   nothing on 9222                     -> start the wrapper through its logon task (the task scheduler is
#                                          the only spawner: a browser started by an operation dies with it)
#   9222 held, DevTools not answering   -> if the holder is *our* Chrome (its command line names the agent
#                                          profile) it is hung: kill that pid and start fresh. If it is
#                                          anything else, refuse and name the pid and image - that port is
#                                          not ours to take.
#   a browser, no WhatsApp page         -> open the page in it, over CDP (deterministic, no keystrokes)
#   a page, the store unreadable        -> reported, not "fixed": a logged-out WhatsApp needs a human
#
# One JSON object on stdout (the `run` contract), human lines on stderr, exit 0 only when the chain
# answers by proof. Idempotent: with the source up it is one HTTP probe and exits.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK="wasm-agent-whatsapp-chrome"
PORT=9222
WAIT=60
QUIET=0
PROFILE_MARK="AgentBrowserChromeProfile"

while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --port) PORT="${2:-9222}"; shift 2 ;;
    --wait) WAIT="${2:-60}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "whatsapp-source-ensure: unknown argument $1" >&2; exit 2 ;;
  esac
done
CDP="127.0.0.1:$PORT"

say() { [ "$QUIET" = 1 ] || echo "$*" >&2; }

json_escape() { printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
verdict() { # verdict <ok> <action> <reason> <chats>
  printf '{"ok":%s,"action":"%s","reason":"%s","cdp":"%s","chats":%s}\n' \
    "$1" "$(json_escape "$2")" "$(json_escape "$3")" "$CDP" "${4:-null}"
}

# A real browser answers /json/version with a Browser field. A process that merely holds the port is not a
# browser - one held it for hours answering 404 while every call failed (docs/WHATSAPP-COPILOT.md).
cdp_answers() {
  local body
  body="$(curl -s --max-time 3 "http://$CDP/json/version" 2>/dev/null)"
  case "$body" in *'"Browser"'*) return 0 ;; *) return 1 ;; esac
}
whatsapp_page() {
  # A *page* target whose URL is WhatsApp, and nothing weaker. Grepping the whole target list for
  # `web.whatsapp.com` was wrong and looked right: Chrome keeps a **service-worker** target for the app
  # after its tab is closed, so a closed tab read as open and the keeper answered `already-up` while the
  # copilot failed `no_whatsapp_tab` (measured). Chrome prints `"type"` before `"url"` in each target, so
  # "the last type seen is page" is the whole parse.
  curl -s --max-time 3 "http://$CDP/json/list" 2>/dev/null | tr -d '\r' | awk '
    /"type": *"page"/ { page = 1; next }
    /"type": *"/ { page = 0 }
    /"url": *"[^"]*web\.whatsapp\.com/ { if (page) { found = 1 } }
    END { exit(found ? 0 : 1) }'
}
listener_pid() {
  # The pid listening on our port, or empty. The gate also exercises this refusal on Linux, whose
  # netstat columns and state spelling are different from Windows'.
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep ":$PORT " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
  elif [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    netstat -ltnp 2>/dev/null | grep ":$PORT .*LISTEN" | sed -n 's#.* \([0-9][0-9]*\)/.*#\1#p' | head -1
  else
    netstat -ano -p TCP 2>/dev/null | tr -d '\r' | awk -v want="127.0.0.1:$PORT" '$2 == want && $4 == "LISTENING" { print $5; exit }'
  fi
}
pid_image() {
  if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    ps -p "$1" -o comm= 2>/dev/null | awk 'NF { print; exit }'
  else
    # tasklist prints a blank line before the row, so the first *non-empty* line is the process.
    tasklist //FI "PID eq $1" //NH 2>/dev/null | tr -d '\r' | awk 'NF { print $1; exit }'
  fi
}
pid_commandline() {
  if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    ps -p "$1" -o args= 2>/dev/null
  else
    powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"ProcessId=$1\").CommandLine" 2>/dev/null | tr -d '\r'
  fi
}

start_via_task() {
  if ! schtasks //query //tn "$TASK" >/dev/null 2>&1; then
    verdict false "refused" "task_not_registered" null
    say "whatsapp source: the logon task '$TASK' is not registered, so nothing can start the browser."
    say "  register it once:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-whatsapp-chrome-task.ps1"
    return 1
  fi
  say "whatsapp source: starting the browser through $TASK"
  schtasks //run //tn "$TASK" >/dev/null 2>&1 || true
  return 0
}

wait_for_cdp() {
  local waited=0
  while [ "$waited" -lt "$WAIT" ]; do
    cdp_answers && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# ---- 1. already up? the fast path: one probe, and the page has to be the page -----------------------
if cdp_answers; then
  if whatsapp_page; then
    verdict true "already-up" "cdp_answering" null
    exit 0
  fi
  say "whatsapp source: DevTools answers but no WhatsApp page is open - opening it over CDP"
  curl -s --max-time 5 -X PUT "http://$CDP/json/new?https://web.whatsapp.com" >/dev/null 2>&1 || true
  waited=0
  while [ "$waited" -lt 30 ] && ! whatsapp_page; do sleep 2; waited=$((waited + 2)); done
  if ! whatsapp_page; then
    verdict false "failed" "no_whatsapp_page" null
    say "whatsapp source: DevTools is up but the WhatsApp page did not appear; open it by hand in the agent browser"
    exit 1
  fi
else
  # ---- 2. nothing answering: who holds the port, and is it ours to take? ----------------------------
  holder="$(listener_pid)"
  if [ -n "$holder" ]; then
    image="$(pid_image "$holder")"
    if printf '%s' "$image" | grep -qi '^chrome.exe$' && pid_commandline "$holder" | grep -q "$PROFILE_MARK"; then
      say "whatsapp source: pid $holder is our agent Chrome and DevTools is dead - restarting it"
      taskkill //PID "$holder" //F >/dev/null 2>&1 || true
      sleep 2
    else
      verdict false "refused" "port_held_by_other" null
      say "whatsapp source: $CDP is held by pid $holder ($image), which is not the agent-profile Chrome."
      say "  DevTools is not answering there, so this is not our source. Free the port or change WA_CDP_PORT;"
      say "  refusing to take a port this pipeline does not own."
      exit 1
    fi
  fi
  start_via_task || exit 1
  if ! wait_for_cdp; then
    verdict false "failed" "cdp_never_answered" null
    say "whatsapp source: no DevTools on $CDP after ${WAIT}s. Check the agent Chrome window, and:"
    say "  bash scripts/whatsapp-preflight.sh"
    exit 1
  fi
  say "whatsapp source: DevTools answered after restart"
fi

# ---- 3. the browser is there: the page, the hook and the store are the preflight's job --------------
# Polled, not asked once: a browser that just started is loading WhatsApp Web, and a store that is not
# readable *yet* is not the same fact as one that needs a human. Bounded by the same WAIT budget.
deadline=$(( $(date +%s) + WAIT ))
preflight=""
chats=""
while :; do
  preflight="$(bash "$ROOT/scripts/whatsapp-preflight.sh" 2>&1 | head -1)"
  case "$preflight" in
    "whatsapp preflight ok"*)
      chats="$(printf '%s' "$preflight" | sed -n 's/.*chats=\([0-9]*\).*/\1/p')"
      chats="${chats:-0}"
      [ "$chats" -gt 0 ] && break ;;
  esac
  [ "$(date +%s)" -ge "$deadline" ] && break
  say "whatsapp source: waiting for the chain (${preflight})"
  sleep 3
done
case "$preflight" in
  "whatsapp preflight ok"*)
    if [ "${chats:-0}" -gt 0 ]; then
      verdict true "ready" "preflight_ok" "$chats"
      exit 0
    fi
    verdict false "reported" "store_unreadable_chats_zero" "${chats:-0}"
    say "whatsapp source: the page is up but the store has no conversations - WhatsApp Web is probably"
    say "  logged out in the agent browser. That needs a human: scan the QR once, then this keeps it up."
    exit 1
    ;;
  *)
    verdict false "failed" "$(printf '%s' "$preflight" | sed -n 's/.*reason=\([^ ]*\).*/\1/p' | head -1)" null
    say "whatsapp source: $preflight"
    exit 1
    ;;
esac
