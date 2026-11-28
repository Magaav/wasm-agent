#!/usr/bin/env bash
# Does the fast runner report EVERY failed assertion of a row, or only the first?
#
# refusals-that-help (e)+(g). fast.sh's per-row failure line comes from wa_fast_row_failure_line, which
# greps -m1: the FIRST failure line only. A row stops at its first assertion, so that line names the first
# assertion in the file rather than the one the test was written for, and a suite that prints one line per
# case is reduced to one of them.
#
# This row reads the runner's own helper out of scripts/fast.sh (the real bytes, not a copy), feeds it a
# fixture log with two assertions and one line that is not a failure, and asserts what comes back. Where
# the plural helper does not exist (main), it falls back to the -m1 shape every reader sees today, so it
# fails here as an assertion and not as a missing symbol.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
checks=0; failures=0
check() { checks=$((checks+1)); if [ "$1" != 0 ]; then echo "FAIL fast-report: $2"; failures=$((failures+1)); fi; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fast-report.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

# the helper as this tree defines it (extracted, so the row tests the shipped bytes)
awk '/^wa_fast_row_failure_lines\(\)/,/^}/' "$ROOT/scripts/fast.sh" > "$tmp/fn.sh" 2>/dev/null || true
if [ -s "$tmp/fn.sh" ]; then
  # shellcheck disable=SC1090
  . "$tmp/fn.sh"
else
  # today's behaviour: the first failure line, and only it
  wa_fast_row_failure_lines() { [ -s "$1" ] && grep -aE '^(FAIL|FAILED|not ok)( |:|$)|assertion failed|lua error:' "$1" 2>/dev/null | head -1 | cut -c1-300; }
fi

cat > "$tmp/row.log" <<'LOG'
running the row
assertion failed: the first value did not match
just a note that is not a failure
assertion failed: the second value did not match
done
LOG

got=$(wa_fast_row_failure_lines "$tmp/row.log" 8)
n=$(printf '%s' "$got" | grep -c . )

[ "$n" -ge 2 ]; check $? "the runner reported $n failure line(s); the row failed two (got: $(printf '%s' "$got" | tr '\n' '; '))"
printf '%s' "$got" | grep -q 'the first value did not match';  check $? "the FIRST failed assertion is missing from the report"
printf '%s' "$got" | grep -q 'the second value did not match'; check $? "the SECOND failed assertion is missing: the report stopped at the first, which is the hurt"
! printf '%s' "$got" | grep -q 'just a note'; check $? "a line that is not a failure was reported as one"

if [ "$failures" = 0 ]; then echo "fast report: $checks check(s), 0 failed"; else echo "fast report: $checks check(s), $failures FAILED"; exit 1; fi
