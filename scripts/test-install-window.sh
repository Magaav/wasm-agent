#!/bin/bash
# `scripts/web/install.sh`: the release it picks does not depend on how much was published after it.
#
#   bash scripts/test-install-window.sh        (no arguments; starts its own stub API on 127.0.0.1)
#
# MEASURED BEFORE THIS ROW (25/11, the published script): the fallback listing was ONE page of 60, so with
# the pointer host answering nothing (a mirror that serves no latest-node.txt) and seventy releases newer
# than the build, the installer said
#
#   install: no_release: no node-<commit> release found
#
# while the build existed one page further on. This row answers that: a stub API that pages honestly, and
# `--resolve` so the choice is measured without downloading or installing anything.
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
        if u.path.endswith("/releases/latest"):
            p = os.path.join(root, "latest.json")
            if not os.path.exists(p):
                self.send_response(404); self.end_headers(); self.wfile.write(b'{"message":"Not Found"}'); return
            body = open(p, "rb").read()
        elif u.path.endswith("/releases"):
            feed = json.load(open(os.path.join(root, "feed.json")))
            per = int(q.get("per_page", ["30"])[0]); page = int(q.get("page", ["1"])[0])
            body = json.dumps(feed[(page - 1) * per: page * per], indent=2).encode()
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

# a feed of <n> releases that are NOT node builds, then one that is
make_feed() { # <before> <build sha or empty>
  python3 - "$work/api" "$1" "$2" <<'PY'
import json, sys
where, before, sha = sys.argv[1], int(sys.argv[2]), sys.argv[3]
feed = [{"tag_name": "v0.0.%d" % i, "draft": False, "prerelease": True, "assets": []} for i in range(before)]
if sha:
    feed.append({"tag_name": "node-" + sha, "draft": False, "prerelease": False, "assets": []})
json.dump(feed, open(where + "/feed.json", "w"), indent=2)
PY
}
latest() { python3 - "$work/api" "$1" <<'PY'
import json, sys
where, tag = sys.argv[1], sys.argv[2]
if tag == "none":
    import os
    p = where + "/latest.json"
    if os.path.exists(p): os.remove(p)
else:
    json.dump({"tag_name": tag, "draft": False, "prerelease": False, "assets": []}, open(where + "/latest.json", "w"))
PY
}
resolve() { # prints the tag the installer resolved (or the failure line)
  WA_RELEASE_API="http://127.0.0.1:$port" WA_RELEASE_POINTER="http://127.0.0.1:$port/no-pointer.txt" \
    WA_PREFIX="$work/prefix" TMPDIR="$work" sh "$ROOT/scripts/web/install.sh" --resolve 2>&1 | tail -1
}

# ---- 1. seventy non-build releases newer than the build (the old 60-entry window's blind spot) ---------
make_feed 70 3f3f3f3f3f3f; latest none
out=$(resolve)
ok "$(case $out in *"resolve:"*"node-3f3f3f3f3f3f"*) echo 1 ;; *) echo 0 ;; esac)" \
  "70 releases newer than the build: the build is found and resolved ($out)"
echo "70-non-build-newer: ${out}"

# ---- 2. twenty-five (inside the old window) ----------------------------------------------------------
make_feed 25 4a4a4a4a4a4a; latest none
out=$(resolve)
ok "$(case $out in *"node-4a4a4a4a4a4a"*) echo 1 ;; *) echo 0 ;; esac)" \
  "25 releases newer than the build: resolved ($out)"

# ---- 3. Latest is a VERSION TAG: never taken for a build ---------------------------------------------
make_feed 5 5b5b5b5b5b5b; latest v0.1.2
out=$(resolve)
ok "$(case $out in *"node-5b5b5b5b5b5b"*) echo 1 ;; *) echo 0 ;; esac)" \
  "a Latest that is a version tag is not installed as a build ($out)"
echo "latest-is-a-version: ${out}"

# ---- 4. no build anywhere: the count is named, and it is not 'nothing to do' -------------------------
make_feed 600 ""; latest none
out=$(resolve)
ok "$(case $out in *"could not find a release in 500 entries"*) echo 1 ;; *) echo 0 ;; esac)" \
  "600 releases and no build: the installer names the 500 entries it read ($out)"
echo "no-build: ${out}"

if [ "$failed" -gt 0 ]; then echo "install window FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "install window ok ($checks checks)"
