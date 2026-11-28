#!/bin/bash
# ONE COMMAND FOR EVERY FACTORY TEST.
#
#   bash factory/test-all.sh            all of them
#   bash factory/test-all.sh disk-watch only the ones whose name matches
#
# Each test runs in seconds, on a scratch fixture, with no network, no install and no real session. A red one
# says which, and the exit code is 1 - a test that cannot fail is not a test, and this runner is what makes
# that checkable before a script is swapped in for the live one.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
filter=${1:-}
start=$(date +%s)
ran=0; red=0
for t in "$HERE"/test-*.sh; do
  name=$(basename "$t")
  # ITSELF MATCHES THE GLOB it walks (test-all.sh is a test-*.sh), and a runner that runs itself is an
  # infinite recursion instead of a suite. Skipped by name, which is also what a reader expects.
  [ "$name" = "test-all.sh" ] && continue
  [ -n "$filter" ] && case "$name" in *"$filter"*) ;; *) continue;; esac
  ran=$((ran + 1))
  if out=$(bash "$t" 2>&1); then
    echo "ok   ${name}"
  else
    red=$((red + 1))
    echo "FAIL ${name}"
    printf '%s\n' "$out" | tail -6 | sed 's/^/     /'
  fi
done
printf 'factory tests: %s run, %s red, %ss\n' "$ran" "$red" "$(( $(date +%s) - start ))"
[ "$red" -eq 0 ]
