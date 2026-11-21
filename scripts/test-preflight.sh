#!/usr/bin/env bash
# scripts/preflight.sh, judged against a SCRATCH missions root, a scratch land root and a stub `wa`.
#
# What is real here: the script itself, the suite lock it takes (the stub asks for the lock from inside and
# records whether it was held), the journal it reads and the preflight.json it writes. What is scripted: the
# landing (a stub writes the journal a `wa land --until gate` run leaves), because a preflight runs the
# whole gate and no test may run the fast path seventeen times.
#
# Nothing here touches ~/Work/missions, the operator's land root or a provider: HOME and WASM_AGENT_HOME are
# this fixture's, and the mission, the land root and the lock live under it.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
SCRIPT=$ROOT/scripts/preflight.sh
[ -f "$SCRIPT" ] || { echo "preflight: refused(no_script): no such file or directory: $SCRIPT (this tree has no preflight.sh: the row cannot judge the base)"; exit 3; }
# The scratch directory is made where a scratch directory belongs, NOT through an inherited TMPDIR that may
# point inside the node store this row must not write.
WORK=$(TMPDIR=/tmp mktemp -d)
cleanup() { [ -n "${KEEP-}" ] && { printf 'kept %s\n' "$WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { printf 'preflight FAILED: %s\n' "$*" >&2; exit 1; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | head -3)" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3: '$2' IS in: $(printf '%s' "$1" | head -3)" ;; *) ok ;; esac; }

# HOME and WASM_AGENT_HOME are different directories on purpose: a row handed the node's store writes the
# operator's real land root.
export HOME=$WORK/user WASM_AGENT_HOME=$WORK/node
[ "$WASM_AGENT_HOME" = "$HOME" ] && fail 'the scratch home must not be the node home'
mkdir -p "$HOME" "$WASM_AGENT_HOME" "$WORK/missions/demo" "$WORK/land" "$WORK/tmp"
# This row's own TMPDIR: the node's store is not where a fixture's scratch directories belong, and on this
# machine TMPDIR points inside it.
export TMPDIR=$WORK/tmp
export WA_MISSIONS_ROOT=$WORK/missions WA_PREFLIGHT_LAND_ROOT=$WORK/land WA_SUITE_LOCK=$WORK/lock/.suite.lock
mkdir -p "$WORK/lock"

# ---- the stub `wa`: it records its arguments, says whether the suite lock was held while it ran, and
# writes the journal a `land --until gate` run leaves: base, tree_sha, the gate step and its rows.
cat > "$WORK/wa" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$WA_STUB_ARGS"
if flock -n "$WA_STUB_LOCK" true 2>/dev/null; then echo 'LOCK_HELD=no' >> "$WA_STUB_ARGS"; else echo 'LOCK_HELD=yes' >> "$WA_STUB_ARGS"; fi
# The node answers where its land root is; the preflight derives <config>/land from this instead of
if [ "$1" = "paths" ]; then
  # The REAL format, including the trailing "config file <path>" line: a reader that matched every line
  # whose first word is "config" took "file" for the directory and looked for a journal at
  # "<config>\nfile/land" (measured 21/11, the second replay: the answer was written but the journal was
  # never found). The stub speaks it so the test can catch that.
  printf "home         %s/h\nconfig       %s\ndata         %s/h\ncache        %s/h/cache\ntemp         /tmp\nconfig file  %s/env  (missing, nothing to read)\n" "$WA_STUB_HOME" "$WA_STUB_CONFIG" "$WA_STUB_HOME" "$WA_STUB_HOME" "$WA_STUB_CONFIG"
  exit 0
fi
run=''
prev=''
for word in "$@"; do [ "$prev" = '--run' ] && run=$word; prev=$word; done
[ -n "$run" ] || { echo 'stub: no --run' >&2; exit 9; }
dir=$WA_STUB_LAND/$run
mkdir -p "$dir/evidence/fast-logs"
case "${WA_STUB_MODE:-green}" in
  green)
    cat > "$dir/journal.json" <<JSON
{"run":"$run","result":"stopped_at_until","stopped_at":"gate","base":"1111111111111111111111111111111111111111","tree_commit":"2222222222222222222222222222222222222222","tree_sha":"3333333333333333333333333333333333333333","steps":{"gate":{"state":"done","seconds":412,"evidence":"$dir/evidence/gate.log"}},"gate":[{"name":"fast","ok":true,"tests":347}]}
JSON
    echo 'land: stopped after gate (--until): nothing after it ran'
    exit 0 ;;
  red)
    cat > "$dir/journal.json" <<JSON
{"run":"$run","result":"stopped","stopped_at":"gate","base":"1111111111111111111111111111111111111111","tree_commit":"4444444444444444444444444444444444444444","tree_sha":"5555555555555555555555555555555555555555","steps":{"gate":{"state":"failed","seconds":489,"evidence":"$dir/evidence/gate.log"}},"gate":[{"name":"fast","ok":false,"failed":[{"row":"scripts/test-a.lua","first":"a failed"},{"row":"scripts/test-c.lua","first":"c failed"}]}]}
JSON
    printf 'FAIL lua scripts/test-a.lua (exit 1): a failed\n' > "$dir/evidence/fast-logs/test-a.lua.log"
    echo 'land: STOPPED at gate'
    exit 1 ;;
  nothing)
    echo 'land: collect: STOPPED (no_main)'
    exit 1 ;;
  *) echo 'stub: unknown mode' >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/wa"
export WA_STUB_ARGS=$WORK/stub-args WA_STUB_LOCK=$WA_SUITE_LOCK WA_STUB_LAND=$WA_PREFLIGHT_LAND_ROOT
export WA_BIN=$WORK/wa

# ---- 1. green: exit 0, a report a machine can read, and the question that was actually asked
: > "$WA_STUB_ARGS"
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 0 ] || fail "a green preflight exits 0 (got $code): $out"
ok
has "$out" 'preflight green' 'it says green'
has "$(cat "$WA_STUB_ARGS")" 'land --branches change/demo --until gate --run preflight-' 'it asks the landing for the gate only, by branch and by run id'
has "$(cat "$WA_STUB_ARGS")" 'LOCK_HELD=yes' 'the suite lock was held while the landing ran'
[ -f "$WORK/missions/demo/preflight.json" ] || fail 'no preflight.json was written'
ok
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'the green report does not say what it must'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["ok"] is True, report
assert report["main_sha"] == "1" * 40, report
assert report["tree_commit"] == "2" * 40, report
assert report["tree_sha"] == "3" * 40, report
assert report["failed"] == [], report
assert report["gate_evidence"].endswith("evidence/gate.log"), report
assert isinstance(report["seconds"], int), report
assert report["result"] == "stopped_at_until", report
print("green report ok")
PY
ok
has "$(cat "$WORK/missions/demo/preflight.log")" '--- preflight preflight-' 'the land log keeps the run it judged'
has "$(cat "$WORK/missions/demo/preflight.log")" 'ended rc=0' 'and how it ended'

# ---- 2. red: exit 1, the rows by name with their first lines, and ok never true
: > "$WA_STUB_ARGS"
export WA_STUB_MODE=red
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 1 ] || fail "a red preflight exits 1 (got $code): $out"
ok
has "$out" 'preflight RED: 2 row(s)' 'it counts the rows that failed'
has "$out" 'scripts/test-a.lua: a failed' 'and names the first one with its first line'
has "$out" 'scripts/test-c.lua: c failed' 'and the second'
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'the red report does not say what it must'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["ok"] is False, report
assert [row["row"] for row in report["failed"]] == ["scripts/test-a.lua", "scripts/test-c.lua"], report
assert report["failed"][0]["first_lines"][0] == "a failed", report
assert report["why"].endswith("row(s) failed"), report
print("red report ok")
PY
ok

# ---- 3. a landing that never got as far as writing a journal is NOT a green one
export WA_STUB_MODE=nothing
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 2 ] || fail "an unjudged run exits 2 (got $code): $out"
ok
has "$out" 'refused(no_verdict)' 'it says it judged nothing'
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'the refused report does not say what it must'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["ok"] is False, report
assert "no journal" in (report["why"] or ""), report
assert report["failed"] == [], report
print("refused report ok")
PY
ok

# ---- 4. the refusals: a mission that is not there, and a wa that is not there
out=$("$SCRIPT" nosuchmission 2>&1); code=$?
[ "$code" = 2 ] || fail "a missing mission is a refusal (got $code): $out"
ok
has "$out" 'refused(no_mission)' 'named'
out=$(WA_BIN=$WORK/no-such-wa "$SCRIPT" demo 2>&1); code=$?
[ "$code" = 2 ] || fail "a missing wa is a refusal (got $code): $out"
ok
has "$out" 'refused(wa_missing)' 'named'
out=$("$SCRIPT" 2>&1); code=$?
[ "$code" = 2 ] || fail "no mission name is a usage answer (got $code): $out"
ok

# ---- 5. the land root is the NODE'S answer, not a guess: with no WA_PREFLIGHT_LAND_ROOT the script asks
# "wa paths" for the config directory, and a journal under that config's land/ is found and judged. Measured
# 21/11: the guess was right for the default home only, and the first replay reported "the landing never
# started" about a landing that had run.
unset WA_PREFLIGHT_LAND_ROOT
export WA_STUB_CONFIG=$WORK/node/.wasm-agent WA_STUB_HOME=$WORK/node
mkdir -p "$WA_STUB_CONFIG/land"
WA_STUB_LAND=$WA_STUB_CONFIG/land
export WA_STUB_LAND
export WA_STUB_MODE=green
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 0 ] || fail "a preflight that derives its land root exits 0 (got $code): $out"; ok
has "$out" 'preflight green' 'it found the journal under the config directory the node named'
has "$(cat "$WORK/missions/demo/preflight.log")" "land root $WA_STUB_CONFIG/land" 'the land root it USED is the node config directory plus /land' # with a reader that also matched the "config file <path>" line the root became "<config>/file/land", and this line is where that shows up
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'the derived-root report is not green'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["ok"] is True, report
PY
ok

# ---- 6. MAIN RED: a row that is red on main's own tip is not counted against the mission -----------
# 21/11: main was red from bfad4f8f on a whole-tree row, land245 (a 2-line change) went red twice for it and
# then sat stopped with ten missions behind it. The record scripts/main-health.sh writes is what tells the two
# apart, and it may only do so for the SAME commit (unknown is not yes).
export WA_PREFLIGHT_LAND_ROOT=$WORK/land WA_STUB_CONFIG=$WORK/node/.wasm-agent WA_STUB_HOME=$WORK/node
WA_STUB_LAND=$WA_PREFLIGHT_LAND_ROOT
export WA_STUB_LAND
health=$WORK/main-health.json
export WA_MAIN_HEALTH=$health
export WA_STUB_MODE=red   # the stub journal's rows: scripts/test-a.lua and scripts/test-c.lua, main 1*40
# (a) both rows are red on main too: the mission is not blamed at all.
python3 - "$health" <<'PY'
import json, sys
json.dump({"schema": 1, "sha": "1" * 40, "ok": False, "seconds": 12,
           "failed": [{"row": "scripts/test-a.lua", "first_lines": ["a failed"]},
                      {"row": "scripts/test-c.lua", "first_lines": ["c failed"]}]}, open(sys.argv[1], "w"))
PY
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 1 ] || fail "a MAIN RED preflight exits 1, not 0 (got $code): $out"
ok
has "$out" 'preflight MAIN RED: 2 row(s) are red on main 111111111111 itself, not on change/demo' 'it says MAIN RED, on which main, and that the branch is not the cause'
has "$out" 'the mission is NOT blamed, and no landing runs until main is fixed' 'and that nothing lands until main is fixed'
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'the MAIN RED report does not say what it must'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["ok"] is False, report
assert [row["row"] for row in report["main_red"]] == ["scripts/test-a.lua", "scripts/test-c.lua"], report
assert report["failed"] == [], report
assert report["main_health"]["same_commit"] is True, report
assert report["why"].startswith("MAIN RED"), report
print("main red report ok")
PY
ok
# (b) ONE row is red on main and one is this branch's: the branch's row is still the mission's.
python3 - "$health" <<'PY'
import json, sys
json.dump({"schema": 1, "sha": "1" * 40, "ok": False,
           "failed": [{"row": "scripts/test-a.lua", "first_lines": ["a failed"]}]}, open(sys.argv[1], "w"))
PY
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 1 ] || fail "a mixed preflight exits 1 (got $code): $out"
ok
has "$out" 'preflight MAIN RED: 1 row(s)' 'it names how many are main red'
has "$out" 'and 1 row(s) failed on this branch too' 'and how many are the mission’s own'
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'the mixed report does not say what it must'
import json, sys
report = json.load(open(sys.argv[1]))
assert [row["row"] for row in report["main_red"]] == ["scripts/test-a.lua"], report
assert [row["row"] for row in report["failed"]] == ["scripts/test-c.lua"], report
print("mixed report ok")
PY
ok
# (c) the record is about ANOTHER main: it excuses nothing.
python3 - "$health" <<'PY'
import json, sys
json.dump({"schema": 1, "sha": "9" * 40, "ok": False,
           "failed": [{"row": "scripts/test-a.lua", "first_lines": ["a failed"]},
                      {"row": "scripts/test-c.lua", "first_lines": ["c failed"]}]}, open(sys.argv[1], "w"))
PY
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 1 ] || fail "a red preflight with a stale record exits 1 (got $code): $out"
ok
has "$out" 'preflight RED: 2 row(s)' 'a record about another commit excuses nothing'
python3 - "$WORK/missions/demo/preflight.json" <<'PY' || fail 'a stale record excused a row'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["main_red"] == [], report
assert len(report["failed"]) == 2, report
assert report["main_health"]["same_commit"] is False, report
print("stale record ok")
PY
ok
# (d) main is GREEN: the same rows are the mission's own fault, exactly as before this change.
python3 - "$health" <<'PY'
import json, sys
json.dump({"schema": 1, "sha": "1" * 40, "ok": True, "failed": []}, open(sys.argv[1], "w"))
PY
out=$("$SCRIPT" demo 2>&1); code=$?
[ "$code" = 1 ] || fail "a red preflight on a green main exits 1 (got $code): $out"
ok
has "$out" 'preflight RED: 2 row(s)' 'a green main blames the mission, as it must'
rm -f "$health"
printf 'preflight ok (%d checks)\n' "$checks"

