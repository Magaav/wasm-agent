#!/usr/bin/env bash
# A 403 FROM THE RELEASE API IS NOT "NOT PUBLISHED" (work update retry #3, 27/11). A tokenless node is rate-limited; the
# deploy turned that into `components_unknown: ... unknown is not published`, telling the operator a bundle did not exist
# when the API had simply refused to answer. The node already holds a release list for its own updates: that list answers,
# and the answer names its source. With no list, the honest answer is unknown - never a verdict.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/lib/release-completeness.sh"
NBL="$ROOT/scripts/lib/node-binaries.sh"
[ -r "$LIB" ] && [ -r "$NBL" ] || { echo "SKIP release-completeness-403: libs missing"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'SKIP release-completeness-403: no python3'; exit 0; }
case "${TMPDIR:-/tmp}" in /home/*/.wasm-agent/*) TMPBASE="${TMPDIR}" ;; *) TMPBASE="$ROOT/.tmp" ;; esac
mkdir -p "$TMPBASE"; W=$(mktemp -d "$TMPBASE/wa-r403.XXXXXX") || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

python3 - "$W" <<'PYEOF' &
import http.server, socketserver, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(403); self.send_header('Content-Length','0'); self.end_headers()
    def log_message(self, *a): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(root + '/port', 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
SERVER_PID=$!
for _ in $(seq 1 60); do [ -s "$W/port" ] && break; sleep 0.05; done
PORT=$(cat "$W/port" 2>/dev/null)
[ -n "$PORT" ] || { echo 'SKIP release-completeness-403: the 403 server did not start'; exit 0; }

mkdir -p "$W/shelf" "$W/empty"
printf 'node-aaaaaaaaaaaa\ncomponents-bbbbbbbbbbbb\n' > "$W/shelf/releases.txt"
# shellcheck disable=SC1090
. "$NBL"; . "$LIB"
export WA_RELEASE_API_BASE="http://127.0.0.1:$PORT"
export WA_NODE_BINARIES_URL="$W/shelf"
answer=$(wa_release_tag_state Magaav/wasm-agent components-bbbbbbbbbbbb 2>&1); rc=$?
[ "$rc" = 0 ] && ok '403 + a tag the node list holds answers published (rc 0)' || bad "not published (rc $rc): $answer"
case "$answer" in *'release list the node already holds'*) ok 'and the answer names its source' ;; *) bad "no source named: $answer" ;; esac
answer2=$(wa_release_tag_state Magaav/wasm-agent components-cccccccccccc 2>&1); rc=$?
[ "$rc" = 1 ] && ok '403 + a tag the list does not hold answers missing (rc 1)' || bad "expected missing, got rc $rc: $answer2"
export WA_NODE_BINARIES_URL="$W/empty"
answer3=$(wa_release_tag_state Magaav/wasm-agent components-dddddddddddd 2>&1); rc=$?
[ "$rc" = 2 ] && ok '403 with no list stays unknown (rc 2), never a verdict' || bad "expected unknown, got rc $rc: $answer3"
case "$answer3" in *'rate limiting'*) ok 'and the reason names rate limiting' ;; *) bad "reason unclear: $answer3" ;; esac

printf 'release completeness 403: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'release completeness 403 ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
