#!/bin/bash
# ONE TEST FOR what-hurt-loop, and it can fail.
#
# The loop is two lines: harvest, then sleep half an hour, forever. Both halves are stubbed on PATH, and the
# loop is stopped after two harvests - so the test proves the CONTRACT (the harvester is called with `-I`, in
# isolation, and the interval is 1800 s) without waiting half an hour.
#
# WHAT IT CAN CATCH: a loop that calls the harvester without `-I` (the isolation flag is the point: the harvest
# must not import the node's environment), a loop that sleeps the wrong interval, and a loop that stops after
# one pass instead of running forever (the unit is Restart=always, but a loop that exits is a gap of up to the
# restart delay).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-what-hurt-loop.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
checks=0; failed=0
fail() { echo "FAIL test-what-hurt-loop: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }

HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/Work/missions/_orch" "$WORK/bin"
: > "$HOME_DIR/Work/missions/_orch/harvest-what-hurt.py"
# python3 records its arguments; sleep records the interval and counts, and stops the loop on the second.
printf '#!/bin/bash\necho "$*" >> "%s/python.calls"\n' "$WORK" > "$WORK/bin/python3"
printf '#!/bin/bash\necho "$*" >> "%s/sleep.calls"\n' "$WORK" > "$WORK/bin/sleep"
chmod +x "$WORK/bin/python3" "$WORK/bin/sleep"

# The loop never ends on its own (the unit is Restart=always, and a loop that exits is a gap), so the test
# runs it under a cap and asserts that the cap - not the script - is what stopped it: exit 124.
HOME="$HOME_DIR" PATH="$WORK/bin:$PATH" timeout 2 bash "$HERE/what-hurt-loop.sh" >/dev/null 2>&1
ok "$?" "124" "the loop is still running when the cap stops it (it does not exit on its own)"

ok "$([ "$(wc -l < "$WORK/python.calls" 2>/dev/null | tr -d ' ')" -ge 2 ] && echo yes || echo no)" "yes" "the harvester is called on every pass (at least twice inside the cap)"
ok "$(head -1 "$WORK/python.calls" 2>/dev/null)" "-I $HOME_DIR/Work/missions/_orch/harvest-what-hurt.py" "it is called in isolation (-I) on the mission tree's own harvester"
ok "$(sort -u "$WORK/sleep.calls" 2>/dev/null | tr -d ' ')" "1800" "and the interval is half an hour, not some other number"

if [ "$failed" -gt 0 ]; then echo "test-what-hurt-loop: $failed failed of $checks checks"; exit 1; fi
echo "test-what-hurt-loop ok ($checks checks)"
