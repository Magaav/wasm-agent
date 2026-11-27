#!/bin/bash
# A TIP THAT IS ONLY PUBLISHED MUST STILL BE GRADED (28/11: every tip NOT GRADED while c1fcda27 WAS published).
#
# MEASURED, in this order:  wa_main_binary, asked for c1fcda27 with the resolver's DEFAULT bound, answered "no release"
# on a cold stage - the digest scan stops at WA_NODE_RELEASE_DIGEST_SECONDS, whose default is 20 s - and the same call
# with 60 s resolved the published bundle in 76 s with no build. The health loop never set that bound, so a cold stage
# was read as "nothing is published".
# MEASURED, next: the published bundle holds wa-<triple>-<sha12>, wa-sentinel-<triple>-<sha12>, SHA256SUMS and the
# manifest - and NOT wa-term and NOT wa-operations-supervisor. Grading from it therefore answered
# term_program_missing / operations_supervisor_missing for every row: the storm by another road. The pin now builds
# those two beside the binary it pinned and says so (`step=release-this-commit-sidecars-built`).
#
# This row is the guard on all three: the loop gives the scan time, the lib names the step it took, and the pin
# supplies the sidecars a bundle does not carry.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "health-graded: $*"; exit 1; }

loop=factory/health-loop.sh
lib=factory/lib/main-binary.sh
[ -f "$loop" ] || fail 'factory/health-loop.sh is missing'
[ -f "$lib" ] || fail 'factory/lib/main-binary.sh is missing'

# 1. the bound the loop gives the release scan (a cold stage needs more than the 20 s default).
grep -q 'WA_NODE_RELEASE_DIGEST_SECONDS=' "$loop" || fail 'health-loop.sh does not set WA_NODE_RELEASE_DIGEST_SECONDS, so a cold stage answers "no release" at 20 s'
default_bound=$(grep -o "WA_NODE_RELEASE_DIGEST_SECONDS:-[0-9]*" "$loop" | grep -o "[0-9]*$" | head -1)
[ -n "$default_bound" ] || fail 'health-loop.sh sets the bound with no default'
[ "$default_bound" -ge 60 ] || fail "the loop's default scan bound is ${default_bound}s, which cut a published bundle off at 20 s"

# 2. every success path in the lib names the step, so a health line never reads "graded" as "built".
for step in release-this-commit release-covering-commit build; do
  grep -q "$step" "$lib" || fail "main-binary.sh no longer names the step '$step'"
done
grep -q 'WA_MAIN_BINARY_STEP' "$loop" || fail 'health-loop.sh does not print the step it graded with'

# 3. the sidecars a published bundle does not carry, and the note that says so.
grep -q 'wa_main_binary_supervisor' "$lib" || fail 'main-binary.sh does not build the supervisor a release bundle lacks'
for side in wa-term wa-operations-supervisor; do
  grep -q "$side" "$lib" || fail "main-binary.sh no longer pins $side, and a bundle does not carry it"
done

bash -n "$lib" || fail 'main-binary.sh does not parse'
bash -n "$loop" || fail 'health-loop.sh does not parse'

echo "health graded ok (scan bound ${default_bound}s, three named steps, sidecars built and pinned)"
