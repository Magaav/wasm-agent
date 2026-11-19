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
fail() { echo "test-fast-skip-count: $*" >&2; exit 1; }

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

echo 'test-fast-skip-count: ok (a green row that printed SKIP is recorded skip and counted, a silent green row is still a pass, and a failure stays a failure)'
