#!/usr/bin/env bash
# worker-gate.sh <mission directory> <rc> [session id] - the worker's own gate loop, run when its turn ends.
#
# WHY THIS EXISTS. "Done" used to mean "the worker stopped talking". The gate that decides whether the
# branch may land was run only at the landing, so a red one sent the round back to the worker by hand, and
# the same minutes were paid twice: the gate failed in 10 of 16 landings on 20-21/11 and took 185 of ~225
# landing minutes (~/Work/missions/FACTORY.md). So when a worker's turn ends with rc=0, its branch is
# asked the landing's own question - `preflight.sh <mission>`, i.e. `wa land --branches change/<name>
# --until gate` on the current main - and if the answer is red the SAME session is resumed with the rows
# that failed and one instruction: fix these, do not weaken a test. Up to WORKER_ROUNDS (3) rounds.
#
# The orchestrator's model is NOT in this loop: no reader has to notice the red, re-prompt, or decide
# whether it is worth another round. A mission still red after the last round is recorded red, with the
# rows in preflight.json, and that is the answer.
#
# <mission>/done is what it writes, and it is what everything else reads:
#   rc=<rc> preflight=<green|red|refused|not_asked|unknown> rounds=<n>
# where rounds is the number of times the worker was resumed to fix reds (0 = green at the first ask).
#   green      the gate is green on the current main: the branch may land
#   red        still red after WORKER_ROUNDS rounds (or there was no session to resume)
#   refused    the preflight could not judge (exit 2): nothing was proved either way
#   not_asked  the worker's own rc was not 0, so its branch was not asked
#   unknown    preflight.sh is not installed under the missions root
#
# Exit: 0 green, 1 red or refused, 0 not_asked/unknown (the worker's own result stands in those two).
set -uo pipefail

M=${1:-}
RC=${2:-}
SID=${3:-}
if [ -z "$M" ] || [ -z "$RC" ]; then
  echo "usage: worker-gate.sh <mission directory> <rc> [session id]" >&2
  exit 2
fi
M=${M%/}
NAME=$(basename "$M")
MISSIONS=$(dirname "$M")
PREFLIGHT=${WORKER_PREFLIGHT:-$MISSIONS/preflight.sh}
WA=${WA_BIN:-wa}
PY=${WA_PYTHON:-python3}
ROUNDS=${WORKER_ROUNDS:-3}
DONE=$M/done
OUT=$M/out.log
ERR=$M/err.log

done_file() { # <verdict> <rounds>
  printf 'rc=%s preflight=%s rounds=%s %s\n' "$RC" "$1" "$2" "$(date -u +%FT%TZ)" > "$DONE"
}
say() { printf '%s\n' "$*" >> "$OUT"; printf 'worker-gate: %s\n' "$*" >&2; }

# THE WORKER'S OWN RC IS NOT THE GATE'S BUSINESS. A run that ended non-zero did not claim to be finished,
# so nothing is asked and the worker's rc stands as the record - the old line, unchanged.
if [ "$RC" != "0" ]; then
  done_file not_asked 0
  say "the worker's rc is $RC: the gate was not asked (done records preflight=not_asked)"
  exit 0
fi
if [ ! -f "$PREFLIGHT" ]; then
  done_file unknown 0
  say "no preflight at $PREFLIGHT: the gate was not asked (done records preflight=unknown)"
  exit 0
fi

# THE SESSION TO RESUME: the one this run named, else the last one the node printed for it. Read from the
# runner's own err.log, which is where the node says `wa: session <id> ok|failed` - the same line
# launch.sh's stall net reads, so the two cannot disagree about which session is being continued.
if [ -z "$SID" ] && [ -f "$ERR" ]; then
  SID=$(grep -oE 'wa: session [0-9a-f-]{36} (failed|ok)' "$ERR" 2>/dev/null | tail -1 | awk '{print $3}')
fi

rows_of() { # -> the failed rows of the last preflight, one "row: first line" per line
  "$PY" - "$M/preflight.json" <<'PY'
import json, sys
try:
    report = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print("preflight.json could not be read")
    raise SystemExit(0)
rows = report.get("failed") or []
if not rows:
    print(report.get("why") or "the preflight named no row")
for entry in rows:
    first = (entry.get("first_lines") or [""])
    print("- %s: %s" % (entry.get("row"), first[0] if first else ""))
PY
}

rounds=0
while :; do
  output=$(bash "$PREFLIGHT" "$NAME" 2>&1)
  code=$?
  printf '%s\n' "$output" >> "$OUT"
  if [ "$code" = 0 ]; then
    done_file green "$rounds"
    say "preflight green after $rounds round(s) of reds: the branch may land"
    exit 0
  fi
  if [ "$code" != 1 ]; then
    # Nothing was judged (2): a refusal is neither a green nor a red, and a worker asked to fix rows that
    # were never named would be fixing the wrong thing.
    done_file refused "$rounds"
    say "the preflight could not judge (exit $code): nothing was proved either way - read $M/preflight.log"
    exit 1
  fi
  if [ "$rounds" -ge "$ROUNDS" ]; then
    done_file red "$rounds"
    say "still red after $rounds round(s): the rows are in $M/preflight.json - the mission is NOT done"
    exit 1
  fi
  if [ -z "$SID" ]; then
    done_file red "$rounds"
    say "red, and no session to resume was found in $ERR: the rows are in $M/preflight.json"
    exit 1
  fi
  rounds=$((rounds + 1))
  message="[preflight] The gate of your branch (change/$NAME) is RED on the current main. The landing would stop
on these rows. Fix them, and do not weaken a test to do it (no assertion deleted, no row removed from a
list, no timeout raised to hide a hang):

$(rows_of)

The whole report is $M/preflight.json and the landing log is $M/preflight.log. Round $rounds of $ROUNDS:
work on the branch in $M/wt, run the failing rows yourself, and commit."
  say "round $rounds of $ROUNDS: resuming session $SID with $(rows_of | grep -c '^- ') red row(s)"
  "$WA" chat --resume "$SID" --once "$message" >> "$OUT" 2>> "$ERR"
  resumed=$?
  if [ "$resumed" != 0 ]; then
    say "the resume of session $SID ended rc=$resumed: asking the gate again anyway (the branch may have moved)"
  fi
done

