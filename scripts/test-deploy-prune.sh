#!/usr/bin/env bash
# The deploy's retirement rule (scripts/lib/retire-unshipped.sh), measured on a real install layout.
#
# WHY (measured 2026-11-11): the Node WhatsApp bridge was deleted from main and the next deploy left
# `whatsapp-read.mjs` installed beside the new set, because shipping is a copy loop - a UNION with the last
# release. The install then ran a file main no longer has, and its scripts-closure check said `ok:false`
# while `verify-deployed.sh` passed.
#
# Six behaviours, each on a fixture install:
#   1. a shipped script the tree no longer has is retired, bytes intact, under scripts/.retired/<utc>/;
#   2. a shipped script the tree still has is untouched;
#   3. the same rule holds for scripts/lib/* (the import closure ships there);
#   4. a job definition whose jobs/<name>.json is gone is retired with its .shipped marker, and a live job
#      keeps both (a re-put of an unchanged definition cancels pending deliveries);
#   5. a file that is NOT a shipped name (an operator's note, a log) is never touched;
#   6. a second run retires nothing - the rule is idempotent and says so by saying nothing.
set -uo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-prune-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
checks=0
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
check() { # <name> <condition...>
  local name="$1"; shift
  "$@" || fail "$name"
  checks=$((checks + 1)); printf 'ok - %s\n' "$name"
}
. "$HERE/scripts/lib/retire-unshipped.sh"

TREE="$WORK/tree"; INSTALL="$WORK/install"
mkdir -p "$TREE/scripts/lib" "$TREE/jobs" "$INSTALL/scripts/lib" "$INSTALL/scripts/.retired/20260101T000000Z"
printf 'readiness\n' > "$TREE/scripts/whatsapp-readiness.mjs"
printf 'keep module\n' > "$TREE/scripts/lib/keep.mjs"
printf '{"id":"live"}\n' > "$TREE/jobs/live.json"

# The install the LAST release left behind: the same files, plus the ones this tree no longer has.
printf 'readiness\n' > "$INSTALL/scripts/whatsapp-readiness.mjs"
printf 'keep module\n' > "$INSTALL/scripts/lib/keep.mjs"
printf 'deleted reader\n' > "$INSTALL/scripts/whatsapp-read.mjs"
printf 'deleted module\n' > "$INSTALL/scripts/lib/websocket-runtime.mjs"
printf '{"id":"live"}\n' > "$INSTALL/scripts/live.job.json"
printf '{"id":"live"}\n' > "$INSTALL/scripts/live.job.json.shipped"
printf '{"id":"gone"}\n' > "$INSTALL/scripts/gone.job.json"
printf '{"id":"gone"}\n' > "$INSTALL/scripts/gone.job.json.shipped"
printf "the operator's note\n" > "$INSTALL/scripts/NOTES.txt"
printf 'old evidence\n' > "$INSTALL/scripts/.retired/20260101T000000Z/whatsapp-read.mjs"

out="$(retire_unshipped "$INSTALL" "$TREE" 2>&1)"; rc=$?
check 'the rule ran' test "$rc" = 0
check 'it names what it retired and where' bash -c "printf '%s' \"\$1\" | grep -q 'retired 4 shipped script(s)'" _ "$out"
STAMP="$(ls -1d "$INSTALL/scripts/.retired"/*/ | tail -1)"
check 'a shipped script the tree no longer has is gone from scripts/' test ! -e "$INSTALL/scripts/whatsapp-read.mjs"
check 'its bytes are kept under scripts/.retired/<utc>/' bash -c "grep -q 'deleted reader' \"\$1/whatsapp-read.mjs\"" _ "$STAMP"
check 'the lib closure is retired by the same rule' bash -c "grep -q 'deleted module' \"\$1/lib/websocket-runtime.mjs\"" _ "$STAMP"
check 'a shipped script the tree still has is untouched' bash -c "grep -q readiness \"\$1/whatsapp-readiness.mjs\"" _ "$INSTALL/scripts"
check 'a live module is untouched' bash -c "grep -q 'keep module' \"\$1/lib/keep.mjs\"" _ "$INSTALL/scripts"
check 'a job whose definition is gone is retired with its marker' bash -c "test ! -e \"\$1/gone.job.json\" && test ! -e \"\$1/gone.job.json.shipped\"" _ "$INSTALL/scripts"
check 'a live job keeps its definition and its shipped marker' bash -c "test -f \"\$1/live.job.json\" && test -f \"\$1/live.job.json.shipped\"" _ "$INSTALL/scripts"
check "an operator's own file is never touched" bash -c "grep -q \"operator's note\" \"\$1/NOTES.txt\"" _ "$INSTALL/scripts"
check 'the previous retirement is not reprocessed' test -f "$INSTALL/scripts/.retired/20260101T000000Z/whatsapp-read.mjs"

out2="$(retire_unshipped "$INSTALL" "$TREE" 2>&1)"; rc2=$?
check 'a second run succeeds' test "$rc2" = 0
check 'and retires nothing: it says nothing' test -z "$out2"
check 'the retired set did not grow' bash -c "test \"\$(ls -1d \"\$1\"/*/ | wc -l)\" = 2" _ "$INSTALL/scripts/.retired"

printf 'deploy prune ok (%d checks, 0 skipped)\n' "$checks"
