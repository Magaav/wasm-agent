#!/usr/bin/env bash
# START THE WATCHER IN A CONTAINER, AND SAY SO (Fable 26/11, the work container).
#
# MEASURED on work (a Docker container with no systemd), twice on 26/11 (10:36Z, 18:05Z): the image's entrypoint ran
# `wa-install --if-new`, then `wa-sentinel autostart on`, then `wa-sentinel start`. The start failed both times, its
# reason went to the container's stdout only, and the last "sentinel started" line in sentinel.log was 25/11 20:59Z. A
# `wa update` an hour later said "no sentinel watcher ownership was verified", so the node had two symptoms and no cause.
#
# What this does, and why each part is here:
#
#   * RETRIES with a bounded backoff (1s, 2s, 4s, 8s, 16s - five tries by default), because a container's start races
#     the node it is starting: the first attempt can fail on a lock that a second earlier holder is still releasing;
#   * SAYS SO ON EVERY TRY, on stdout (the container's own log), naming the attempt and the reason the last one gave;
#   * WRITES THE GIVE-UP to sentinel.log, in the same tabbed shape the sentinel's own audits use
#     (`epoch<TAB>start_gave_up<TAB>N attempts<TAB>reason`), because that is the one file a person reads later - and it
#     is the file `wa update` and `wa-sentinel status` are read beside.
#
# Usage: deploy/wa-start-watcher.sh [attempts] [first-delay-seconds]
#   The image's entrypoint should call this instead of a bare `wa-sentinel start`:
#     /usr/local/bin/wa-start-watcher.sh
#
# Nothing here guesses which sentinel: `WA_SENTINEL_BIN` when a caller names one, else the one beside this script, else
# `wa-sentinel` on PATH - and the path used is printed on every try, so the log says which binary was asked.
set -uo pipefail
attempts=${1:-5}
case "$attempts" in ''|*[!0-9]*|0) attempts=5 ;; esac
delay=${2:-1}
case "$delay" in ''|*[!0-9]*) delay=1 ;; esac

sentinel=${WA_SENTINEL_BIN:-}
if [ -z "$sentinel" ]; then
  here=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  if [ -n "$here" ] && [ -x "$here/wa-sentinel" ]; then sentinel="$here/wa-sentinel"; else sentinel=$(command -v wa-sentinel 2>/dev/null || echo wa-sentinel); fi
fi

home=${WASM_AGENT_HOME:-$HOME}/.wasm-agent
log="$home/sentinel/sentinel.log"
mkdir -p "$home/sentinel" 2>/dev/null || true

try=0
wait_s=$delay
last=""
while [ "$try" -lt "$attempts" ]; do
  try=$((try + 1))
  printf 'wa-start-watcher: try %s of %s: %s start\n' "$try" "$attempts" "$sentinel"
  last="$("$sentinel" start 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'wa-start-watcher: the watcher is up after %s attempt(s)\n' "$try"
    exit 0
  fi
  # A `start` that answers 0 but leaves nothing watching is not a start: the sentinel's own status is the fact.
  if "$sentinel" status 2>/dev/null | grep -q 'watching'; then
    printf 'wa-start-watcher: the watcher is up after %s attempt(s) (start answered %s)\n' "$try" "$rc"
    exit 0
  fi
  printf 'wa-start-watcher: try %s failed (rc=%s): %s\n' "$try" "$rc" "$(printf '%s' "$last" | head -3 | tr '\n' ' ' | cut -c1-300)"
  [ "$try" -ge "$attempts" ] && break
  sleep "$wait_s"
  wait_s=$((wait_s * 2))
done

reason=$(printf '%s' "$last" | tr '\n\t' '  ' | cut -c1-400)
printf '%s\tstart_gave_up\t%s attempt(s)\t%s\n' "$(date +%s)" "$try" "$reason" >> "$log" 2>/dev/null || true
printf 'wa-start-watcher: gave up after %s attempt(s); the reason is in %s\n' "$try" "$log"
exit 1
