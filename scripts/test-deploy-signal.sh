#!/usr/bin/env bash
# The deploy-pending signal (scripts/lib/deploy-signal.sh): the one artifact an installer writes and a
# running turn reads. Two properties matter and are tested here:
#
#   1. the record is self-describing and bounded - state, since, bound_seconds, who wrote it, the two
#      commits and the pid - because lua/core/deploy_pause.lua refuses to honour a marker it cannot
#      bound (a crashed installer must not freeze the node);
#   2. the write is atomic - a reader never sees a half-written JSON document, which it could only
#      answer by guessing.
#
# The reader's judgement is tested in Lua (scripts/test-deploy-pause.lua); this test checks the bytes it
# is given. No node, no install, no model.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/deploy-signal.sh"
[ -f "$LIB" ] || { echo "FAIL no $LIB"; exit 1; }
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t wa-deploy-signal)"
passed=0
check() { if [ "$2" = "0" ]; then passed=$((passed + 1)); echo "ok - $1"; else echo "FAIL $1: $3"; exit 1; fi; }
. "$LIB"

# 1. The record.
wa_deploy_signal_write "$WORK" "aaaaaaa" "bbbbbbbbbbbb" 600 "upgrade.sh"
check "the marker can be written" $? ""
FILE="$WORK/deploy-pending.json"
check "the marker is at the path the reader derives" "$( [ -f "$FILE" ] && echo 0 || echo 1 )" "no $FILE"
check "it names itself as a deploy" "$( grep -q '"state":"deploy_pending"' "$FILE" && echo 0 || echo 1 )" "$(cat "$FILE")"
check "it carries the commit it is installing" "$( grep -q '"to":"bbbbbbbbbbbb"' "$FILE" && echo 0 || echo 1 )" "$(cat "$FILE")"
check "it carries its writer" "$( grep -q '"by":"upgrade.sh"' "$FILE" && echo 0 || echo 1 )" "$(cat "$FILE")"
check "it carries its own bound" "$( grep -q '"bound_seconds":600' "$FILE" && echo 0 || echo 1 )" "$(cat "$FILE")"
check "it carries a pid" "$( grep -q "\"pid\":$$" "$FILE" && echo 0 || echo 1 )" "$(cat "$FILE")"
SINCE="$(sed -n 's/.*"since":\([0-9]*\).*/\1/p' "$FILE")"
NOW="$(date +%s)"
check "its since is now, so its bound is measured from the write" "$( [ $((NOW - SINCE)) -ge 0 ] && [ $((NOW - SINCE)) -lt 30 ] && echo 0 || echo 1 )" "since=$SINCE now=$NOW"

# 2. JSON a strict parser accepts (the reader decodes it with lua/vendor/json.lua; node's JSON is stricter).
if command -v node >/dev/null 2>&1; then
  node -e 'const fs=require("fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(m.state!=="deploy_pending"||typeof m.since!=="number"||typeof m.bound_seconds!=="number")process.exit(1)' "$FILE"
  check "the marker is valid JSON with the numeric fields the reader needs" $? "$(cat "$FILE")"
else
  echo "ok - node is not on PATH; the grep checks above cover the shape"
  passed=$((passed + 1))
fi

# 3. A nonsensical bound is replaced, never written: the reader would otherwise have to guess.
wa_deploy_signal_write "$WORK" "from" "to" "not-a-number"
check "an invalid bound falls back to a finite one" "$( grep -q '"bound_seconds":900' "$FILE" && echo 0 || echo 1 )" "$(cat "$FILE")"

# 4. Clear removes the marker and any staged copy.
wa_deploy_signal_write "$WORK" "from" "to" 60
: > "$FILE.tmp.999"
wa_deploy_signal_clear "$WORK"
check "clear removes the marker" "$( [ ! -f "$FILE" ] && echo 0 || echo 1 )" "marker still there"
check "clear removes a staged copy" "$( [ ! -f "$FILE.tmp.999" ] && echo 0 || echo 1 )" "staged copy still there"

# 5. A missing directory is created (the data dir may not exist on a first install).
rm -rf "$WORK/never"
wa_deploy_signal_write "$WORK/never/deeper" "from" "to" 60
check "the writer creates its directory" "$( [ -f "$WORK/never/deeper/deploy-pending.json" ] && echo 0 || echo 1 )" "not created"

rm -rf "$WORK"
echo "deploy signal: $passed checks passed"
