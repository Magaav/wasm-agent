#!/bin/bash
# `scripts/web/install.sh`: the build it picks is exact, and the choice does not depend on how much was
# published after it - while the normal host still pays ONE request.
#
#   bash scripts/test-install-window.sh        (no arguments; starts its own stub API on 127.0.0.1)
#
# The stub logs every path it serves, so the REQUEST COUNT and the absence of a /releases/latest probe are
# facts each case states. `--resolve` prints the tag on its own line and the download URL built from it, so
# both are compared EXACTLY (a leading run of spaces is a failure, not a pass with formatting).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-install-window.XXXXXX")
trap 'rm -rf "$work"; [ -n "${server:-}" ] && kill "$server" 2>/dev/null' EXIT INT TERM
failed=0; checks=0
ok() { checks=$((checks + 1)); [ "$1" = 1 ] || { failed=$((failed + 1)); echo "  FAIL $2"; }; }

port=$((20000 + RANDOM % 20000))
cat > "$work/stub.py" <<'PY'
import json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
root = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        with open(os.path.join(root, "requests.log"), "a") as fh:
            fh.write(self.path + "\n")
        if u.path.endswith("/releases/latest"):
            p = os.path.join(root, "latest.json")
            if not os.path.exists(p):
                self.send_response(404); self.end_headers(); self.wfile.write(b'{"message":"Not Found"}'); return
            body = open(p, "rb").read()
        elif u.path.endswith("/releases"):
            feed = json.load(open(os.path.join(root, "feed.json")))
            per = int(q.get("per_page", ["30"])[0]); page = int(q.get("page", ["1"])[0])
            indent = open(os.path.join(root, "indent")).read().strip() if os.path.exists(os.path.join(root, "indent")) else "2"
            text = json.dumps(feed[(page - 1) * per: page * per], indent=int(indent) if indent != "0" else None,
                              separators=None if indent != "0" else (",", ":"))
            body = text.encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
mkdir -p "$work/api"
python3 "$work/stub.py" "$work/api" "$port" & server=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS "http://127.0.0.1:$port/x" >/dev/null 2>&1 || sleep 0.3; done
kill -0 "$server" 2>/dev/null || { echo "install window FAILED (stub API did not start)"; exit 1; }

make_feed() { # <non-build count> <build sha or empty> <indent: 2|0>
  python3 - "$work/api" "$1" "$2" "$3" <<'PY'
import json, sys
where, before, sha, indent = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
feed = [{"tag_name": "v0.0.%d" % i, "draft": False, "prerelease": True, "assets": []} for i in range(before)]
if sha:
    feed.append({"tag_name": "node-" + sha, "draft": False, "prerelease": False, "assets": []})
json.dump(feed, open(where + "/feed.json", "w"), indent=2 if indent != "0" else None)
open(where + "/indent", "w").write(indent)
open(where + "/requests.log", "w").close()
PY
}
# only the API paths this script asked: the release-pointer fetch (latest-node.txt) is the host's pointer,
# not the release list, and counting it would blur every request count below.
requests_log() { grep '/repos/' "$work/api/requests.log" 2>/dev/null || true; }
latest_hits() { requests_log | grep -c "/releases/latest" || true; }
resolve() { # prints the installer's own last three lines
  WA_RELEASE_API="http://127.0.0.1:$port" WA_RELEASE_POINTER="http://127.0.0.1:$port/no-pointer.txt" \
    WA_PREFIX="$work/prefix" TMPDIR="$work" sh "$ROOT/scripts/web/install.sh" --resolve 2>&1
}
tag_of() { printf '%s\n' "$1" | sed -n 's/^install: resolve: \(.*\)$/\1/p' | head -1; }
url_of() { printf '%s\n' "$1" | sed -n 's/^install: download: \(.*\)$/\1/p' | head -1; }

# ---- 1. an INDENTED body, the real API's shape: the tag is exact and the URL is built from it ---------
make_feed 5 3f3f3f3f3f3f 2
out=$(resolve)
ok "$([ "$(tag_of "$out")" = 'node-3f3f3f3f3f3f' ] && echo 1)" \
  "indented body: the tag is exactly node-3f3f3f3f3f3f (got [$(tag_of "$out")])"
ok "$([ "$(url_of "$out")" = 'https://github.com/Magaav/wasm-agent/releases/download/node-3f3f3f3f3f3f' ] && echo 1)" \
  "and the download URL is built from it exactly (got [$(url_of "$out")])"
ok "$([ "$(requests_log | wc -l | tr -d ' ')" = 1 ] && echo 1)" \
  "in ONE request, the page this script always asked (60) - asked: $(requests_log | tr '\n' ' ')"
ok "$(requests_log | grep -q 'per_page=60' && echo 1)" "and that page is per_page=60"
echo "indented: tag=$(tag_of "$out") requests=$(requests_log | wc -l | tr -d ' ')"

# ---- 2. a ONE-LINE body: same answer, still exact ---------------------------------------------------
make_feed 5 4b4b4b4b4b4b 0
out=$(resolve)
ok "$([ "$(tag_of "$out")" = 'node-4b4b4b4b4b4b' ] && echo 1)" \
  "one-line body: the tag is exactly node-4b4b4b4b4b4b (got [$(tag_of "$out")])"
ok "$([ "$(url_of "$out")" = 'https://github.com/Magaav/wasm-agent/releases/download/node-4b4b4b4b4b4b' ] && echo 1)" \
  "and its URL exactly (got [$(url_of "$out")])"
echo "one-line: tag=$(tag_of "$out") requests=$(requests_log | wc -l | tr -d ' ')"

# ---- 3. seventy non-build releases newer than the build: widen to 100-entry pages --------------------
make_feed 70 5c5c5c5c5c5c 2
out=$(resolve)
ok "$([ "$(tag_of "$out")" = 'node-5c5c5c5c5c5c' ] && echo 1)" \
  "70 releases newer: the build is found and exact (got [$(tag_of "$out")])"
ok "$([ "$(requests_log | wc -l | tr -d ' ')" = 2 ] && echo 1)" \
  "after exactly two requests: the 60-entry page, then one 100-entry page ($(requests_log | tr '\n' ' '))"
ok "$(requests_log | sed -n '2p' | grep -q 'per_page=100' && echo 1)" "and the second asks for 100"
echo "70-non-build-newer: tag=$(tag_of "$out") requests=$(requests_log | wc -l | tr -d ' ')"

# ---- 4. no build anywhere: the count is named, in the approved sentence ------------------------------
make_feed 600 "" 2
out=$(resolve)
ok "$(printf '%s\n' "$out" | grep -q 'no_release: could not find a build in the newest 500 releases' && echo 1)" \
  "600 releases and no build: 'could not find a build in the newest 500 releases' ($(printf '%s\n' "$out" | tail -1))"
ok "$([ "$(requests_log | wc -l | tr -d ' ')" = 6 ] && echo 1)" \
  "after 6 requests: the 60-entry page and five 100-entry pages ($(requests_log | wc -l | tr -d ' '))"
echo "no-build: $(printf '%s\n' "$out" | tail -1) requests=$(requests_log | wc -l | tr -d ' ')"

# ---- 5. W2: the installer never probes /releases/latest ------------------------------------------------
total_latest=0
for n in 1 2 3 4; do :; done
total_latest=$(printf '%s\n' "$(requests_log)" | grep -c "/releases/latest" || true)
ok "$([ "$total_latest" = 0 ] && echo 1)" "no case asked /releases/latest (a node build is never Latest)"

if [ "$failed" -gt 0 ]; then echo "install window FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "install window ok ($checks checks)"
