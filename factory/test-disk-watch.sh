#!/bin/bash
# ONE TEST FOR disk-watch, and it can fail.
#
# The script reads `$HOME/Work/missions/_orch` and asks `df` about `/`; both are swapped here for a scratch
# home and a stub on PATH, so the test needs no disk pressure, no network and no real session, and it runs in
# milliseconds.
#
# WHAT IT CAN CATCH: a watcher that stops writing the state file, one that warns on every tick instead of once
# an hour (the ATTENTION file would fill), one that warns below 70% (the node's disk_cap is 85%, so a warn at
# 50% is noise that trains the reader to ignore it), and a missing `.warned` mark that would make the hourly
# rule impossible.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-disk-watch.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
checks=0; failed=0
fail() { echo "FAIL test-disk-watch: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }

HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/Work/missions/_orch" "$WORK/bin"
# A `df` that answers whatever this test decides, the way the real one answers `--output=pcent /`.
# The stub reads DISK_PCT at RUN time: writing the number in here would freeze it at creation.
cat > "$WORK/bin/df" <<'STUB'
#!/bin/bash
echo "Use%"
echo "${DISK_PCT:-10}%"
STUB
chmod +x "$WORK/bin/df"

# The stub `df` reads DISK_PCT from its ENVIRONMENT, and a prefix assignment on a shell FUNCTION is not
# exported to the child in bash - so the test sets and exports it here, explicitly.
run_watch() {
  DISK_PCT="${1:-10}"; export DISK_PCT
  HOME="$HOME_DIR" PATH="$WORK/bin:$PATH" bash "$HERE/disk-watch.sh"
}

# ---- 1. under the threshold: the state file is written and nothing alarms ------------------------------
run_watch 42
ok "$(cat "$HOME_DIR/Work/missions/_orch/disk.state")" "$(date -u +%TZ) 42%" "the state file records the reading and its clock"
ok "$([ -f "$HOME_DIR/Work/missions/ATTENTION" ] && echo yes || echo no)" "no" "under 70% nothing is raised"

# ---- 1b. BETWEEN THE TWO NUMBERS: still silent. This is the case that catches a threshold moved down -
# the warn is at 70% because the node disk_cap is 85%, and a watcher that warns at 50% is noise.
run_watch 60
ok "$([ -f "$HOME_DIR/Work/missions/ATTENTION" ] && echo yes || echo no)" "no" "60% is under the 70% warn line and raises nothing"
# ---- 2. at the threshold: one line, and the mark that makes it hourly ---------------------------------
run_watch 72
grep -q 'DISK: / is at 72%' "$HOME_DIR/Work/missions/ATTENTION" || fail "72% raises a line naming the reading"
checks=$((checks + 1))
[ -s "$HOME_DIR/Work/missions/_orch/disk.warned" ] || fail "the hourly mark is written"
checks=$((checks + 1))

# ---- 3. again inside the hour: silent (the rule is one line an hour, not one a tick) ------------------
run_watch 74
ok "$(grep -c 'DISK:' "$HOME_DIR/Work/missions/ATTENTION")" "1" "a second reading inside the hour adds no line"

# ---- 4. an old mark: warns again ---------------------------------------------------------------------
date -d '2 hours ago' +%s > "$HOME_DIR/Work/missions/_orch/disk.warned"
run_watch 80
ok "$(grep -c 'DISK:' "$HOME_DIR/Work/missions/ATTENTION")" "2" "an expired mark lets the next reading through"

if [ "$failed" -gt 0 ]; then echo "test-disk-watch: $failed failed of $checks checks"; exit 1; fi
echo "test-disk-watch ok ($checks checks)"
