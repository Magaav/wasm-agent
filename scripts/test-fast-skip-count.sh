#!/usr/bin/env bash
# A green row that printed SKIP is a SKIP, not a pass (item 10 of the node-ops round).
#
#   bash scripts/test-fast-skip-count.sh
#
# MEASURED 19/11: 52 test files print "SKIP <test>: <reason>" and exit 0 - a component this machine
# cannot build, a fixture that is not installed. scripts/fast.sh collected those lines into the skips
# table and then recorded the row as `pass`, so "fast path ok (N checks, 0 skipped)" was true of the
# count and false of the run.
#
# WHAT THIS RUNS: the check() function READ OUT OF scripts/fast.sh - not a copy of it - with stubs for
# the four things it calls (a runner, the clock, the row recorder and the counters). A copy would pass
# here while the shipped function drifted; this test fails if the shipped function changes behaviour.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-fast-skip-$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/home/.wasm-agent" "$SCRATCH/work/logs" || exit 2
cleanup() { local s=$?; set +e; rm -rf "$SCRATCH"; exit $s; }
trap cleanup EXIT
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$SCRATCH/home" || exit 2
fail() { echo "FAIL test-fast-skip-count: $*" >&2; exit 1; }

# The function, from the shipped file: from 'check() {' to the first line that is '}' at column 0.
check_body="$(awk '/^check\(\) \{/{inside=1} inside{print} inside&&/^}$/{exit}' scripts/fast.sh)"
[ -n "$check_body" ] || fail 'scripts/fast.sh has no check() function, so this test proves nothing'
case "$check_body" in *"SKIP"*) ;; *) fail 'the shipped check() does not look for a SKIP line: a green skip is counted as a pass' ;; esac

# The stubs: the runner is whatever the case needs, the clock is fixed, the recorder appends its row.
fast_now_ms() { printf '1'; }
# The real one runs the command and keeps its output in the log the caller names (scripts/fast.sh
# wa_environment_retry): the stub must do the same, or check() reads a file that was never written
# and every case looks like a silent pass - measured here before the stub was fixed.
wa_environment_retry() { local n=$1 log=$2; shift 2; "$@" > "$log" 2>&1; }
record_row() { printf '%s\t%s\n' "$1" "$7" >> "$SCRATCH/rows"; }
# The failure path also calls these three, and this test runs under set -u: an unset variable would end
# the script instead of failing a case (measured: the first failing case exited 1 with no message).
last_line_of() { tail -1 "$1" 2>/dev/null; }
first_error_of() { head -1 "$1" 2>/dev/null; }
WA_FAST_RETRY=""
work="$SCRATCH/work"
WORK="$SCRATCH/work"
eval "$check_body"

# THE EVIDENCE A FAILING ROW LEAVES BEHIND (23/11). Two /undo pty rows failed in every fast.sh run and
# passed when run by hand; the run reported "ok - /help lists /undo ... 16 ok, 1 failed" - the failing
# assertion was three lines above the tail it kept, and the directory the row kept "for diagnosis" was
# deleted with the run's scratch. So the shipped check() must print the row's OWN failure line and name
# its log, and the shipped keeper must copy a `check-<name>.log` row (a pty row's log is not under logs/)
# together with the directory that row kept. Both are read out of scripts/fast.sh, as check() itself is.
function_body() { # <name> -> the shipped function, or nothing
  # A prefix, not the whole line: a shipped function may carry a comment after its brace
  # (`wa_fast_rows_logged() { # every log a row wrote`), and an exact match found nothing.
  awk -v want="$1() {" 'index($0, want) == 1 {inside=1} inside{print} inside && $0 == "}" {exit}' scripts/fast.sh
}
failure_line_body="$(function_body wa_fast_row_failure_line)"
# A base with no such helper gets a no-op: the case below then fails on WHAT WAS PRINTED, which is the
# behaviour this test is about, instead of dying on a missing function before it asserts anything.
[ -n "$failure_line_body" ] || failure_line_body='wa_fast_row_failure_line() { :; }'
eval "$failure_line_body"
# The keepers, or - on a base that has none of them - the shape it DID have, so the case below fails on
# what was kept rather than on a missing function (a missing symbol is evidence of nothing).
for keeper in wa_fast_evidence_dir wa_fast_rows_logged wa_fast_keep_failed_logs; do
  body="$(function_body "$keeper")"
  [ -n "$body" ] && eval "$body"
done
# The base's own shape: no evidence-dir helper, and only `logs/*.log` collected.
type wa_fast_evidence_dir >/dev/null 2>&1 || eval 'wa_fast_evidence_dir() { printf "%s" "${WA_FAST_KEEP_LOGS:-}"; }'
type wa_fast_rows_logged >/dev/null 2>&1 || eval 'wa_fast_rows_logged() { local log; for log in "$work"/logs/*.log; do [ -f "$log" ] && printf "%s\n" "$log"; done; }'

run_case() { # <name> <expected status> <expected skipped delta> <command...>
  local name=$1 want=$2 want_skip=$3; shift 3
  : > "$SCRATCH/rows"
  ran=0; fails=0; envfails=0; skipped=0
  check "$name" "$@" > "$SCRATCH/out" 2>&1 || true
  local got got_skip
  got="$(cut -f1 "$SCRATCH/rows" | head -1)"
  got_skip="$skipped"
  [ "$got" = "$want" ] || fail "$name: recorded '$got', expected '$want' ($(cat "$SCRATCH/out"))"
  [ "$got_skip" = "$want_skip" ] || fail "$name: counted $got_skip skips, expected $want_skip ($(cat "$SCRATCH/out"))"
}

# A row that says it skipped, and exits 0: the status is skip, the count moves, and the reason travels.
run_case says-skip skip 1 bash -c 'echo "SKIP says-skip: no component here"; exit 0'
case "$(cat "$SCRATCH/rows")" in *'no component here'*) ;; *) fail 'the skip reason did not reach the recorded row' ;; esac
# A row that passed silently is still a pass, and no skip is counted.
run_case clean-pass pass 0 bash -c 'echo "all good"; exit 0'
# A row that failed is a failure, and its SKIP line does not launder it into a skip.
run_case failed fail 0 bash -c 'echo "SKIP failed: pretending"; exit 1'
# The line the runner prints says SKIPPED, so a reader of the run is not told 'ok'.
run_case says-skip skip 1 bash -c 'echo "SKIP says-skip: no component here"; exit 0'
case "$(cat "$SCRATCH/out")" in *"SKIPPED"*) ;; *) fail "the runner printed no SKIPPED line: $(cat "$SCRATCH/out")" ;; esac

# THE FAILING LINE IS THE ROW'S OWN, NOT THE TAIL (23/11). A row whose failing assertion is followed by
# three more lines: on the base the runner reported only those three (all green) and the summary, which is
# exactly how "16 ok, 1 failed" arrived with nothing saying what failed.
run_case three-lines-kept fail 0 bash -c 'printf "ok - one\nFAIL - it names the version the file now holds\nok - two\nok - three\nundo pty: 16 ok, 1 failed\n"; exit 1'
grep -q 'FAIL - it names the version the file now holds' "$SCRATCH/out" || fail "the runner did not print the failing line: $(cat "$SCRATCH/out")"
grep -q 'check-three-lines-kept.log' "$SCRATCH/out" || fail "the runner did not name the row's whole log: $(cat "$SCRATCH/out")"

# THE EVIDENCE OUTLIVES THE RUN: a check row's log (a pty row writes `check-<name>.log`, which the keeper
# used to skip), a Lua row's log, and the directory a row kept "for diagnosis" inside the scratch.
# Only this case's two logs exist, so the counts below are the keeper's own: the earlier cases left one
# `check-<name>.log` each in the same scratch.
rm -f "$work"/check-*.log
mkdir -p "$work/tmp/wa-undo-pty-KEEP/data"
printf 'alpha\nbeta\n' > "$work/tmp/wa-undo-pty-KEEP/data/demo.txt"
printf 'ok - one\nFAIL - it names the version\nok - two\nok - three\nscratch kept for diagnosis: %s/tmp/wa-undo-pty-KEEP\nundo pty: 16 ok, 1 failed\n' "$work" > "$work/check-undo-pty.log"
printf 'lua error: boom\n' > "$work/logs/test-some-row.lua.log"
fails=1
WA_FAST_KEEP_LOGS="$SCRATCH/evidence" wa_fast_keep_failed_logs > "$SCRATCH/keep.out" 2>&1
[ -f "$SCRATCH/evidence/check-undo-pty.log" ] || fail "a pty row's log (check-<name>.log) was not kept: $(cat "$SCRATCH/keep.out")"
[ -f "$SCRATCH/evidence/test-some-row.lua.log" ] || fail "a Lua row's log was not kept: $(cat "$SCRATCH/keep.out")"
[ -f "$SCRATCH/evidence/wa-undo-pty-KEEP/data/demo.txt" ] || fail "the directory the row kept for diagnosis was not kept: $(cat "$SCRATCH/keep.out")"
grep -q 'FAIL - it names the version' "$SCRATCH/evidence/failures.txt" 2>/dev/null || fail "failures.txt does not name the failing line: $(cat "$SCRATCH/evidence/failures.txt" 2>/dev/null)"
grep -q 'kept 2 failed row log(s) and 1 scratch dir(s)' "$SCRATCH/keep.out" || fail "the keeper did not say what it kept: $(cat "$SCRATCH/keep.out")"

echo 'test-fast-skip-count: ok (a green row that printed SKIP is recorded skip and counted, a silent green row is still a pass, a failure stays a failure, the runner prints the line that failed with the log it came from, and the logs and kept directories of failed rows survive the run)'
