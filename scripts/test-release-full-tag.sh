#!/bin/bash
# THE TAG RULE THAT DECIDES LATEST vs PRERELEASE (Fable 26/11, the cut itself).
#
#   bash scripts/test-release-full-tag.sh
#
# The rule is the SHIPPED expression, extracted from scripts/release-linux.sh and run here on the tags a cut meets -
# not a copy of it. A full version takes Latest; a suffix (a rehearsal, a node build) never does. WHY: v0.1.2 was
# published as a prerelease and then both a v0.1.1 node and a v0.1.2 node answered `unknown` (release-rows-real/
# latest.md, shapes S-a and S-b).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
checks=0; failed=0
ok()  { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; }

expr=$(sed -n "s/.*grep -Eq '\([^']*\)'.*/\1/p" "$ROOT/scripts/release-linux.sh" | head -1)
if [ -n "$expr" ]; then ok "the shipped rule: $expr"; else bad 'release-linux.sh states no tag rule'; exit 1; fi

rule() { if printf %s "$1" | grep -Eq "$expr"; then echo full; else echo suffix; fi; }

echo "  v0.1.2 -> $(rule v0.1.2)"
[ "$(rule v0.1.2)" = full ] && ok 'v0.1.2 is a FULL version (published as Latest)' || bad 'v0.1.2 is not treated as a full version'
[ "$(rule v0.2.0-rc1)" = suffix ] && ok 'v0.2.0-rc1 is a suffix (a rehearsal stays a prerelease)' || bad 'v0.2.0-rc1 would take Latest'
[ "$(rule node-6cead4dc760e)" = suffix ] && ok 'a node build tag never takes Latest' || bad 'a node build tag would take Latest'
[ "$(rule v1.10.3)" = full ] && ok 'multi-digit parts are still a full version' || bad 'v1.10.3 was refused'

grep -q -- '--latest --prerelease=false' "$ROOT/scripts/release-linux.sh" && ok 'the full branch asks for Latest explicitly' || bad 'no --latest in the full branch'
grep -q '\$latest_flags' "$ROOT/scripts/release-linux.sh" && ok 'and the create line uses the flags it chose' || bad 'the create line ignores the flags'

echo "release-full-tag: $checks checks, $failed failed"
if [ "$failed" -eq 0 ]; then echo 'release-full-tag ok'; exit 0; fi
exit 1
