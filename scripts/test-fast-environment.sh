#!/usr/bin/env bash
# The evidence for scripts/lib/fast-environment.sh: a check that could not run is told apart from a
# check that failed, and the environmental one is retried exactly once, alone.
#
# Every case below is a real command, not a string assertion where it can be helped: the retry is
# proved by a command that fails the way a starved machine fails on its first attempt and succeeds on
# its second (a counter file), and the "not the machine" cases prove the classifier stays quiet about
# ordinary failures, which is what keeps a real regression from being excused as environment.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/fast-environment.sh"

checks=0
ok() { if [ "$2" = 1 ]; then checks=$((checks + 1)); echo "ok - $1"; else echo "FAIL - $1${3:+: $3}"; exit 1; fi; }
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-fast-env-XXXXXX")
trap 'rm -rf "$work"' EXIT

# ---- 1. the shapes a starved machine makes, and the ones it does not ---------------------------------
# The last line of a failing row is the window the classifier reads. Each of these was measured on
# wasm_the_first on 2026-11-10.
expect_kind() { # <expected> <exit> <last line> <label>
  local got; got=$(wa_environment_kind "$2" "$3")
  ok "$4" "$([ "$got" = "$1" ] && echo 1 || echo 0)" "classified '$got', expected '$1' (exit $2: $3)"
}
expect_kind environment 125 'lua: cannot fork: Resource temporarily unavailable' 'exit 125 is the shell saying it could not execute'
expect_kind environment 126 'lua: cannot fork' 'exit 126 is the shell saying it could not execute'
expect_kind environment 1 'cannot fork: Input/output error' 'a fork that returned EIO is the machine'
expect_kind environment 1 'CreateProcessW failed error:5' 'a Windows spawn that returned errno 5 is the machine'
expect_kind environment 1 'mkdir -p C:\Users\x\.wasm-agent/tmp/h -> nil' 'a scratch home that could not be made is the machine'
expect_kind environment 1 'Too many open files' 'an exhausted handle table is the machine'
expect_kind environment 1 'No space left on device' 'a full disk is the machine'
expect_kind code 1 'FAILED: expected 3 events, saw 2' 'an ordinary assertion failure is the code'
expect_kind code 1 'cannot fork the session: the tool never returned a pid' 'a test that merely talks about forking is the code, not the machine'
expect_kind code 101 'test result: FAILED. 4 passed; 1 failed' 'a Rust test failure is the code'

# The reason is named, not just the class: a refusal that says "environment" without saying why cannot
# be acted on.
ok 'the classification names what happened' "$(wa_environment_reason 'lua: cannot fork: Input/output error' | grep -qi 'cannot fork' && echo 1 || echo 0)"

# ---- 2. the retry: once, serially, and only for the machine ------------------------------------------
# A row that fails its first attempt the way a starved machine fails and passes its second: `wa` is
# simulated by the script itself, and the counter file is the proof that it ran twice and only twice.
starved() {
  local counter=$WA_FAST_TEST_COUNTER
  local n=0; [ -f "$counter" ] && n=$(cat "$counter")
  n=$((n + 1)); printf '%s' "$n" > "$counter"
  if [ "$n" = 1 ]; then
    printf 'lua: cannot fork: Resource temporarily unavailable\n'
    return 125
  fi
  [ "${WA_FAST_SERIAL:-}" = 1 ] || { printf 'the retry did not run serially (WA_FAST_SERIAL=%s)\n' "${WA_FAST_SERIAL:-}"; return 9; }
  [ "${WA_FAST_JOBS:-}" = 1 ] || { printf 'the retry did not run alone (WA_FAST_JOBS=%s)\n' "${WA_FAST_JOBS:-}"; return 9; }
  printf 'lua: all checks passed\n'
  return 0
}
export -f starved
WA_FAST_TEST_COUNTER="$work/counter1" wa_environment_retry 'lua scripts/test-x.lua' "$work/log1" starved > "$work/announce1" 2>&1
code=$?
ok 'a starved row is retried and passes' "$([ "$code" = 0 ] && [ "$WA_FAST_RETRY" = retried ] && echo 1 || echo 0)" "exit $code, retry=$WA_FAST_RETRY"
ok 'the retry ran exactly twice' "$([ "$(cat "$work/counter1")" = 2 ] && echo 1 || echo 0)" "ran $(cat "$work/counter1") time(s)"
ok 'the retry announces itself as the environment, with the reason' "$(grep -q 'ENVIRONMENT lua scripts/test-x.lua (exit 125: cannot fork) - retrying once, serially' "$work/announce1" && echo 1 || echo 0)" "$(cat "$work/announce1")"

# A row that is starved twice: reported as blocked, never as a code failure, and still only two runs.
starved_always() {
  local counter=$WA_FAST_TEST_COUNTER
  local n=0; [ -f "$counter" ] && n=$(cat "$counter")
  printf '%s' "$((n + 1))" > "$counter"
  printf 'lua: cannot fork: Input/output error\n'
  return 125
}
export -f starved_always
WA_FAST_TEST_COUNTER="$work/counter2" wa_environment_retry 'lua scripts/test-y.lua' "$work/log2" starved_always
code=$?
ok 'a row starved twice is environment, not a verdict' "$([ "$code" = 125 ] && [ "$WA_FAST_RETRY" = environment ] && echo 1 || echo 0)" "exit $code, retry=$WA_FAST_RETRY"
ok 'it was tried exactly twice, never in a loop' "$([ "$(cat "$work/counter2")" = 2 ] && echo 1 || echo 0)" "ran $(cat "$work/counter2") time(s)"

# A real failure is NOT retried: one run, one verdict, and the classifier does not excuse it.
real_failure() {
  local counter=$WA_FAST_TEST_COUNTER
  local n=0; [ -f "$counter" ] && n=$(cat "$counter")
  printf '%s' "$((n + 1))" > "$counter"
  printf 'FAILED: expected 3 events, saw 2\n'
  return 1
}
export -f real_failure
WA_FAST_TEST_COUNTER="$work/counter3" wa_environment_retry 'lua scripts/test-z.lua' "$work/log3" real_failure
code=$?
ok 'a real failure is reported as a failure' "$([ "$code" = 1 ] && [ "$WA_FAST_RETRY" = failed ] && echo 1 || echo 0)" "exit $code, retry=$WA_FAST_RETRY"
ok 'a real failure is not retried' "$([ "$(cat "$work/counter3")" = 1 ] && echo 1 || echo 0)" "ran $(cat "$work/counter3") time(s)"

# A passing check is not touched at all.
passing() { printf 'tool-progress: all checks passed\n'; return 0; }
export -f passing
wa_environment_retry 'lua scripts/test-ok.lua' "$work/log4" passing
ok 'a passing row is passed and not retried' "$([ "$WA_FAST_RETRY" = passed ] && echo 1 || echo 0)" "retry=$WA_FAST_RETRY"

# ---- 3. the same verdict from the command line, which is how a session reads a saved log -----------
printf 'lua: cannot fork\n' > "$work/starved.log"
ok 'the CLI classifies a saved log' "$([ "$(bash scripts/lib/fast-environment.sh kind 1 "$work/starved.log" || true)" = environment ] && echo 1 || echo 0)"
printf 'FAILED: expected 3\n' > "$work/real.log"
ok 'the CLI does not excuse a real failure' "$([ "$(bash scripts/lib/fast-environment.sh kind 1 "$work/real.log" || true)" = code ] && echo 1 || echo 0)"

echo "fast-environment: $checks checks passed"
