#!/usr/bin/env bash
# ONE RELEASE ASSET, FETCHED SO A SLOW MINUTE IS NOT A FAILED UPDATE, AND SO A FAILURE SAYS WHY
# (Fable/Victor 24/11, mission download-says-why).
#
# WHY THIS EXISTS, measured. `wa update` on `work` (24/11 20:30Z) refused: the digest fallback chose the
# right release (node-9a0c589adfa0), then the asset download "failed" and the deploy stopped. Twenty-five
# minutes later the same 55.3 MB asset arrived from the same host in 13.6 s. The command was
# `curl -fsSL -m 120 ... 2>/dev/null || node_release_unreachable`: `-m 120` caps the WHOLE transfer, so
# 55 MB had to arrive at more than 460 kB/s or the update refused - and in a slow minute it did not. The
# error was thrown away (`2>/dev/null`, no HTTP code, no byte count), so nobody could tell a slow line
# from a 404 from a dropped connection: the operator was told "unreachable" and given nothing to act on.
#
# What is here instead:
#   * NO TOTAL-TIME CAP. A transfer may take as long as it takes; what is bounded is the CONNECT
#     (`--connect-timeout`, 15 s) and a STALL (`--speed-limit` 51200 `--speed-time` 30: under 50 kB/s for
#     30 s is a stall, not a slow line).
#   * RESUME. Up to WA_DOWNLOAD_ATTEMPTS (3) attempts, each continuing the partial file with `-C -`, with
#     WA_DOWNLOAD_RETRY_PAUSE (2 s) between them. A 4xx other than 408/429 is NOT retried: a wrong URL
#     stays wrong, and a 404 is one request and one refusal.
#   * A REFUSAL THAT SAYS WHY: curl's exit code with its meaning in words, the HTTP status, bytes received
#     of bytes expected, seconds, attempts. Never the URL - a release URL can carry a token or a signed
#     query, and a refusal is written to a log.
#
# The BYTES are not verified here, and that is the caller's gate on purpose: every release asset is checked
# against the signed SHA256SUMS / the manifest AFTER it lands (wa_node_verify_dir, wa_component_download),
# and a resumed file that does not match is refused by name there and the directory it is in is removed. A
# downloader that "verified" anything itself would be a second, weaker copy of that gate.
#
# Sourced by scripts/lib/node-binaries.sh (manifest, SHA256SUMS, .sig, TRUSTED-KEYS, both binaries) and by
# scripts/lib/deploy-components.sh (the component bundle). Exercised by scripts/test-node-download.sh
# against a local stub HTTP server - no network, no fleet.

# <curl exit code> -> what that exit means, in words a person can act on. The set is curl's own, printed by
# `curl --manual` "EXIT CODES"; anything not listed is named as unknown rather than guessed.
wa_download_curl_reason() {
  case "${1:-}" in
    1) printf 'unsupported protocol' ;;
    2) printf 'curl failed to initialise' ;;
    3) printf 'the URL is malformed' ;;
    5) printf 'the proxy could not be resolved' ;;
    6) printf 'the host could not be resolved (DNS)' ;;
    7) printf 'the connection was refused or the host did not answer' ;;
    9) printf 'this account is not allowed to read that URL' ;;
    16) printf 'the HTTP/2 layer failed' ;;
    18) printf 'the connection was dropped before the whole body arrived' ;;
    22) printf 'the server answered with an HTTP error code' ;;
    23) printf 'the body could not be written to disk' ;;
    26) printf 'the file could not be read' ;;
    27) printf 'out of memory' ;;
    28) printf 'the transfer timed out or ran too slow for too long' ;;
    33) printf 'the server cannot resume this file at the offset asked' ;;
    35) printf 'the TLS handshake failed' ;;
    36) printf 'the download could not be resumed' ;;
    47) printf 'too many redirects' ;;
    52) printf 'the server sent an empty reply' ;;
    55) printf 'the request could not be sent' ;;
    56) printf 'the connection failed while receiving' ;;
    60) printf 'the TLS certificate is not trusted' ;;
    61) printf 'the TLS certificate could not be checked' ;;
    63) printf 'the body was larger than allowed' ;;
    92) printf 'the HTTP/2 stream failed' ;;
    *) printf 'curl reported failure (an exit code this lib does not name)' ;;
  esac
}

# <asset name> -> the short label a progress line and a refusal use. A release asset names its commit
# (`wa-x86_64-unknown-linux-gnu-0123456789ab`), and the commit is already implied by the release being
# fetched: the line says `wa-x86_64-unknown-linux-gnu`. A trailing 12-hex segment is stripped ONLY when it
# is hex - `node-0123456789ab.manifest` and `SHA256SUMS` are printed whole.
wa_download_label() {
  local name="${1:-asset}"
  case "$name" in
    wa-*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      name="${name%-????????????}" ;;
  esac
  printf '%s' "$name"
}

# <file> -> its size in bytes, 0 when it does not exist. Written as a function because a bare
# `wc -c < "$f"` reports "No such file or directory" on the caller's stderr when a failed attempt left no
# partial file - a message that reads like a defect of the downloader rather than the fact that nothing
# arrived.
_wa_download_size() {
  local size=0
  if [ -f "${1:-}" ]; then size="$( { wc -c < "$1"; } 2>/dev/null | tr -d '[:space:]')"; size="${size:-0}"; fi
  printf '%s' "$size"
}
_wa_download_now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# <header dump> <offset this attempt resumed from> -> the whole body's length in bytes, empty when the server
# announced none. A 206 announces the REMAINING length, so the offset is added back: the number printed is
# always "of the whole file", which is the number a person compares with the release page.
_wa_download_total() {
  local value
  [ -f "${1:-}" ] || return 0
  value="$(grep -i '^content-length:' "$1" 2>/dev/null | tail -n 1 | tr -dc '0-9')"
  [ -n "$value" ] || return 0
  printf '%s' "$((value + ${2:-0}))"
}

# <label> <http> <got> <want> <secs> <attempts made> <attempts allowed> <curl rc> <reason>
_wa_download_refusal() {
  local status bytes
  case "${2:-}" in
    ''|000) status='no HTTP status' ;;
    *) status="HTTP $2" ;;
  esac
  if [ -n "${4:-}" ]; then bytes="$3 of $4 bytes"; else bytes="$3 bytes received"; fi
  printf 'node_release_unreachable: %s: %s, %s in %ss, %s of %s attempts: curl exit %s (%s)\n' \
    "$1" "$status" "$bytes" "$5" "$6" "$7" "$8" "$9"
}

# <url> <dest> [label] -> 0 and <dest> holds the whole body, or 8 and the refusal is on stdout.
#
# The body is written to `<dest>.part` and moved into place only when it is whole, so a caller never sees a
# short file at <dest> and a later attempt can resume what a dropped connection left.
wa_download_asset() {
  local url="$1" dest="$2" label="${3:-}"
  [ -n "$label" ] || label="$(wa_download_label "${dest##*/}")"
  local part="$dest.part" hdr="$dest.part.hdr" code="$dest.part.code" err="$dest.part.err"
  local attempts="${WA_DOWNLOAD_ATTEMPTS:-3}" attempt=0 pause="${WA_DOWNLOAD_RETRY_PAUSE:-2}"
  local connect="${WA_DOWNLOAD_CONNECT_TIMEOUT:-15}" speed_limit="${WA_DOWNLOAD_SPEED_LIMIT:-51200}"
  local speed_time="${WA_DOWNLOAD_SPEED_TIME:-30}"
  local rc=0 http got want offset started secs reason retry pid
  local -a args
  case "$attempts" in ''|*[!0-9]*|0) attempts=3 ;; esac
  case "$pause" in ''|*[!0-9]*) pause=2 ;; esac
  case "$connect" in ''|*[!0-9]*|0) connect=15 ;; esac
  case "$speed_limit" in ''|*[!0-9]*|0) speed_limit=51200 ;; esac
  case "$speed_time" in ''|*[!0-9]*|0) speed_time=30 ;; esac
  command -v curl >/dev/null 2>&1 \
    || { printf 'node_release_unreachable: %s: no curl on this host, so nothing can be fetched\n' "$label"; return 8; }
  mkdir -p "${dest%/*}" 2>/dev/null \
    || { printf 'node_cache_unwritable: %s\n' "${dest%/*}"; return 8; }
  rm -f "$dest"
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    offset="$(_wa_download_size "$part")"
    rm -f "$hdr" "$code" "$err"
    started="$(_wa_download_now)"
    args=( -sS -f -L --connect-timeout "$connect" --speed-limit "$speed_limit" --speed-time "$speed_time" \
      --dump-header "$hdr" -o "$part" -w '%{http_code}' )
    [ "$offset" -gt 0 ] && args+=( -C - )
    curl "${args[@]}" "$url" </dev/null > "$code" 2> "$err" &
    pid=$!
    # Wait for the transfer. The exit code is read from `wait`, never from the file it writes.
    while [ ! -s "$code" ] && kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
    wait "$pid" 2>/dev/null
    rc=$?
    http="$(tr -dc '0-9' < "$code" 2>/dev/null)"
    got="$(_wa_download_size "$part")"
    # THE EXPECTED LENGTH IS THE BODY'S ONLY WHEN THE ANSWER IS A BODY: a 404's Content-Length is its error
    # page, and printing "0 of 13 bytes" for a missing asset reads as a truncated download instead of a
    # wrong URL.
    case "$http" in
      200|206|'') want="$(_wa_download_total "$hdr" "$offset")" ;;
      *) want="" ;;
    esac
    secs=$(( $(_wa_download_now) - started ))
    # A BODY SHORTER THAN ITS OWN Content-Length is a dropped transfer, whatever curl made of it.
    if [ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$got" -ne "$want" ]; then rc=18; fi
    if [ "$rc" -eq 0 ]; then
      rm -f "$hdr" "$code" "$err"
      mv -f "$part" "$dest" || { printf 'node_cache_unwritable: %s\n' "$dest"; return 8; }
      return 0
    fi
    reason="$(wa_download_curl_reason "$rc")"
    # THE STALL IS NAMED as a stall: exit 28 with bytes already on disk is the speed window, exit 28 with
    # none is a connect that never completed - two different things to fix.
    if [ "$rc" -eq 28 ] && [ "$got" -gt "$offset" ]; then
      reason="the transfer stalled: under $speed_limit bytes/s for ${speed_time}s (a stall, not a slow line)"
    fi
    retry=0
    case "$rc" in
      6|7|16|18|28|35|52|55|56|92) retry=1 ;;
      33) rm -f "$part"; retry=1 ;;   # the server cannot resume: start this asset again from zero
      22) case "${http:-}" in 408|429|5??) retry=1 ;; *) retry=0 ;; esac ;;
      *) retry=0 ;;
    esac
    [ "$attempt" -lt "$attempts" ] || retry=0
    if [ "$retry" -eq 1 ]; then
      sleep "$pause"
      continue
    fi
    break
  done
  rm -f "$part" "$hdr" "$code" "$err"
  _wa_download_refusal "$label" "${http:-}" "${got:-0}" "${want:-}" "${secs:-0}" "$attempt" "$attempts" "$rc" "$reason"
  return 8
}
