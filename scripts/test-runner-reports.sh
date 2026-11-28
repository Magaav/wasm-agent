#!/usr/bin/env bash
# Does the factory's own report name WHY a row failed?
#
# The measured hurt (refusals-that-help (e)+(g), notes 78/81/82/87/99/101/222): a runner says a row is
# red and not which assertion, or names only the FIRST one because the row stopped there, or does not say
# which tree and which binary each side ran, or drops the log it kept. A mission then re-runs the row by
# hand to learn what the runner already knew.
#
# So: a scratch repo where a changed test fails TWO assertions at known lines, run through
# scripts/test-discriminates.sh, and the report is read back:
#   - every failed assertion, each with its `file:line:` prefix (not just the first);
#   - the log it kept, as a path that EXISTS;
#   - both sides' trees, distinct, and the binary that ran them (here: named as none).
#
# Fails on main: the report there carries verdict/test/reason only, so `assertions` and `log` are absent
# and neither tree is named.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
checks=0
check() { checks=$((checks+1)); if [ "$1" != 0 ]; then echo "FAIL runner-reports: $2"; failures=$((failures+1)); fi; }
failures=0

FX=$(mktemp -d "${TMPDIR:-/tmp}/runner-reports-fx.XXXXXX")
trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/scripts"
(
  cd "$FX" || exit 1
  git init -q -b main
  git config user.name Victor
  git config user.email fixture@example.invalid
  printf '#!/bin/bash\necho ok\n' > scripts/row.sh
  printf '#!/bin/bash\necho "the base version of this row passes"\nexit 0\n' > scripts/test-sample.sh
  git add -A >/dev/null 2>&1
  git commit -qm base
  git checkout -qb change/sample
  {
    echo '#!/bin/bash'
    echo 'echo "scripts/test-sample.sh:3: assertion failed: the first value did not match"'
    echo 'echo "scripts/test-sample.sh:7: assertion failed: the second value did not match"'
    echo 'exit 1'
  } > scripts/test-sample.sh
  git add -A >/dev/null 2>&1
  git commit -qm "the row now fails two assertions"
) || { echo "FAIL runner-reports: the fixture repo could not be made"; exit 1; }

OUT=$FX/report.json
( cd "$ROOT" && bash scripts/test-discriminates.sh main --repo "$FX" --json ) > "$OUT" 2>&1

json=$(grep -a '^{' "$OUT" | tail -1)
[ -n "$json" ] ; check $? "the runner printed no JSON line; its output was: $(tail -2 "$OUT" | tr '\n' ' ')"

# 1. EVERY failed assertion, and each names where it fired.
assertions=$(printf '%s' "$json" | sed -n 's/.*"assertions":"\([^"]*\)".*/\1/p')
printf '%s' "$assertions" | grep -q 'first value did not match'; check $? "the report dropped the FIRST failed assertion: assertions=[$assertions]"
printf '%s' "$assertions" | grep -q 'second value did not match'; check $? "the report stopped at the first failed assertion (the row failed two): assertions=[$assertions]"
printf '%s' "$assertions" | grep -q 'test-sample.sh:7:'; check $? "the second assertion does not carry its file:line, so the report does not name where it fired: [$assertions]"

# 2. The log it kept, named as a path that exists.
log=$(printf '%s' "$json" | sed -n 's/.*"log":"\([^"]*\)".*/\1/p' | sed 's/ (attempt.*//')
[ -n "$log" ]; check $? "the report named no log for a failed row, so a reader must re-run it"
[ -f "$log" ]; check $? "the log the report named does not exist: [$log]"
grep -q 'second value did not match' "$log" 2>/dev/null; check $? "the named log does not hold the failure it reports: [$log]"

# 3. Both sides' trees, distinct, and the binary that ran them.
base_tree=$(printf '%s' "$json" | sed -n 's/.*"base":{"ref":"[^"]*","sha":"[^"]*","tree":"\([^"]*\)".*/\1/p')
branch_tree=$(printf '%s' "$json" | sed -n 's/.*"branch":{"sha":"[^"]*","tree":"\([^"]*\)".*/\1/p')
[ -n "$base_tree" ]; check $? "the report does not name the base tree it ran"
[ -n "$branch_tree" ]; check $? "the report does not name the branch tree"
[ "$base_tree" != "$branch_tree" ]; check $? "both sides report the same tree ($base_tree), so the report cannot say what ran what"
printf '%s' "$json" | grep -q '"binary":"'; check $? "the report does not name the binary that ran the rows"

# 4. The human report says the same thing, for a reader who does not pass --json.
( cd "$ROOT" && bash scripts/test-discriminates.sh main --repo "$FX" ) > "$FX/plain.txt" 2>&1
grep -q 'trees: base' "$FX/plain.txt"; check $? "the plain report does not name the trees: $(head -3 "$FX/plain.txt" | tr '\n' ' ')"

if [ "$failures" = 0 ]; then echo "runner reports: $checks check(s), 0 failed"; else echo "runner reports: $checks check(s), $failures FAILED"; exit 1; fi
