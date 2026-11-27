#!/bin/bash
# ONE TEST FOR quarantine-watch, and it can fail.
#
# The script follows the user journal and writes a five-line evidence block per quarantine: when it happened,
# the line itself, and WHAT WAS RUNNING (deploys, missions, orch units) beside the installed build and the
# load. That context is the whole point - a quarantine with no "what was running" cannot be attributed - and
# most of this test is about the block being complete and being written ONCE per event.
#
# WHAT IT CAN CATCH: a block that loses one of the three unit lists, a watcher that writes a block for every
# journal line instead of only the matching ones, a missing `installed:`/`load:` half, and a watcher that
# writes outside the evidence file it names.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wa-quarantine.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
checks=0; failed=0
fail() { echo "FAIL test-quarantine-watch: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }
like() { checks=$((checks + 1)); case "$1" in *"$2"*) ;; *) fail "$3 (got: $1)";; esac; }

HOME_DIR="$WORK/home"; BIN="$WORK/bin"
M="$HOME_DIR/Work/missions"; O="$M/_orch"
mkdir -p "$O/evidence" "$BIN" "$HOME_DIR/.local/bin" "$O/run-copies"
printf 'installed: build abcdef12 at 2026-11-27T10:00:00Z\n' > "$HOME_DIR/.local/bin/installed.txt"

# journalctl: two lines, one that matters and one that does not.
cat > "$BIN/journalctl" <<'STUB'
#!/bin/bash
echo "2026-11-27T10:00:00Z host wa-deploy-1234: graph_db_quarantined: the store was locked"
echo "2026-11-27T10:00:01Z host wa-deploy-1234: something else entirely"
STUB
# systemctl: one active unit per family, so each list has something to lose.
cat > "$BIN/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
  *wa-deploy-*) echo "wa-deploy-1234.service loaded active running";;
  *mission-*) echo "mission-alpha.service loaded active running";;
  *orch-*) echo "orch-q-runner.service loaded active running";;
esac
STUB
chmod +x "$BIN/journalctl" "$BIN/systemctl"

HOME="$HOME_DIR" PATH="$BIN:$PATH" timeout 10 bash "$HERE/quarantine-watch.sh" >/dev/null 2>&1; rc=$?
OUT="$O/evidence/quarantines.txt"
ok "$rc" "0" "a journal that ends ends the watcher: it FOLLOWS the journal, it does not poll a clock"
[ -f "$OUT" ] || { echo "FAIL test-quarantine-watch: nothing was written to $OUT" >&2; exit 1; }
body=$(cat "$OUT")
ok "$(grep -c '^== ' "$OUT")" "1" "ONE block for the one quarantining line (the other line is ignored)"
like "$body" "graph_db_quarantined" "the block carries the journal line itself"
like "$body" "deploys: wa-deploy-1234.service" "with the deploys that were running"
like "$body" "missions: mission-alpha.service" "and the missions"
like "$body" "orch: orch-q-runner.service" "and the orch units"
like "$body" "installed: installed: build abcdef12" "and the installed build"
like "$body" "load:" "and the load"
like "$body" "== 2026-11-27T" "the block carries its own UTC stamp"

if [ "$failed" -gt 0 ]; then echo "test-quarantine-watch: $failed failed of $checks checks"; exit 1; fi
echo "test-quarantine-watch ok ($checks checks)"
