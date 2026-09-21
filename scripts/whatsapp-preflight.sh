#!/usr/bin/env bash
# The preflight a WhatsApp job runs before it does anything: is the chain up, and if not, rebind it.
#
#   bash scripts/whatsapp-preflight.sh          # ensure + report one line
#
# It answers, in order, the questions the job depends on:
#   1. is Chrome reachable **by proof** (DevTools, on either loopback stack)? A process that merely holds
#      port 9222 is not a browser - one held it for hours answering 404 while every call failed;
#   2. is the WhatsApp page there, and is the app's own store readable in it?
#   3. is the document-start hook in the page, and if not, bind it (`scripts/whatsapp-adapter.mjs ensure`)
#      - this is the off->on transition: a job that is turned on finds the chain broken and rebinds it,
#      saying what it had to do.
#
# One line, greppable, like every other script in this pipeline:
#   whatsapp preflight ok cdp=[::1]:9222 chats=675 bound=session hook=false
#   whatsapp preflight unavailable reason=no_cdp_endpoint tried=127.0.0.1:9222,[::1]:9222
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${WA_NODE:-node}"

report="$(timeout 60 "$NODE" "$ROOT/scripts/whatsapp-adapter.mjs" ensure 2>&1 | tail -1)"
code=$?

if [ "$code" != "0" ] || [ -z "$report" ]; then
  # The adapter prints its verdict either way; a non-zero exit means it could not bind, and the reason is
  # in the JSON (or in the failure to produce any JSON at all).
  reason="$(printf '%s' "$report" | tr -d '\r' | sed -n 's/.*"errors":\["\([^"]*\)".*/\1/p')"
  # A connect failure reports `error` (there is no page to describe yet), a bind failure reports
  # `errors` - read both, so the line says which link in the chain broke.
  [ -n "$reason" ] || reason="$(printf '%s' "$report" | tr -d '\r' | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')"
  [ -n "$reason" ] || reason="adapter_did_not_report"
  echo "whatsapp preflight unavailable reason=$(printf '%s' "$reason" | tr ' ' '_')"
  exit 1
fi

# The verdict is JSON: read the three facts the line carries, without assuming they are there.
field() { printf '%s' "$report" | tr -d '\r' | sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p" | head -1 | tr -d '"'; }

# The trigger is the other half of the chain: it is what keeps the hook across reloads, and its own
# status can be optimistic (it says "listening" after a reload even when the page lost the hook - which
# is why the hook check above exists). Reported, not trusted: the pin is compared with the live target,
# because a browser restart replaces the target id and then nothing is listening at all.
trigger_line=""
if command -v node >/dev/null 2>&1; then
  trigger_line="$(timeout 60 node "$ROOT/scripts/whatsapp-trigger.mjs" status --line 2>/dev/null | tail -1)"
fi

echo "whatsapp preflight ok cdp=$(field host):$(field port) chats=$(field chats) bound=$(field bound) hook=$(field hook)"
[ -n "$trigger_line" ] && echo "whatsapp preflight $trigger_line"
