#!/bin/bash
# Does a scratch script get left at the repo root?
#
# Measured (refusals-that-help, ADDED 23/11): commit 7e5ff9b1 landed r2.py and u1.py - two python edit
# helpers a worker used to patch source in place and then forgot. They are at the TOP LEVEL beside README
# and Cargo.toml, where the next reader takes them for part of the project, and where a "*.py" glob in a
# release or a lint picks them up.
#
# The rule this row pins: the repo root holds no stray script. A python/JS helper belongs in scripts/ (or
# not in the tree at all), and a file this row names must be REMOVED rather than renamed into place.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
checks=0; failures=0
check() { checks=$((checks+1)); if [ "$1" != 0 ]; then echo "FAIL no-stray-root-files: $2"; failures=$((failures+1)); fi; }

# Only the class the incident named. review-*.mjs and review-lua.ps1 are project files at the root by
# design; a *.py is not (there is no python in this tree outside scripts/).
strays=$(cd "$ROOT" && ls -1 *.py 2>/dev/null | head -20)
[ -z "$strays" ]; check $? "the repo root holds stray script(s): $(printf '%s' "$strays" | tr '\n' ' ')"

# The two the incident named, by name, so a revert that restores them is caught even if the glob changes.
for named in r2.py u1.py; do
  [ ! -e "$ROOT/$named" ]; check $? "$named is back at the repo root"
done

# The legitimate exceptions stay legitimate: these are project files, not scratch.
[ -e "$ROOT/review-lua.ps1" ]; check $? "a project script at the root was removed along with the strays"

if [ "$failures" = 0 ]; then echo "no stray root files: $checks check(s), 0 failed"; else echo "no stray root files: $checks check(s), $failures FAILED"; exit 1; fi
