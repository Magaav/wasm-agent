#!/usr/bin/env bash
# Does the budget only cost rounds, or does it lose information?
#
#   bash scripts/bench-tool-tail.sh [runs-per-arm]     # default 3
#
# The first benchmark (bench-tool-budget.sh) showed a cost of one extra round per
# read-then-act turn and *no* failed calls: the agent simply re-read the file, so
# a keyhole on a read is recoverable. This one removes the recovery, which is the
# only way to test whether the loss is real rather than merely inconvenient.
#
# The shape of the fixture is the point:
#
#   turn 1  run a command whose output is long and whose ONE interesting line is at
#           the very end (where a failure's message always is)
#   then    delete the file the command read, so the output cannot be reproduced
#   turn 2  ask for that last line verbatim, from the recorded transcript alone
#
# Head-only truncation (the legacy 600-character view) keeps the noise and drops
# the line. Keeping both ends keeps it. Nothing here depends on the model
# guessing: one arm has the information and the other does not, so "answered" is a
# fact about the context, not about the model's diligence.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
RUNS="${1:-3}"
WORK="$(mktemp -d /tmp/wa-tail-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$BIN" ]; then echo "no binary at $BIN" >&2; exit 1; fi

MARKER="FATAL: disk 7 is degraded"

gen_fixture() {
  local path="$1"
  local i=0
  : > "$path"
  while [ "$i" -lt 60 ]; do
    printf 'log line %02d %s\n' "$i" "outine noise from the storage controller aaaaaaaaaaaaaaaaaa" >> "$path"
    i=$((i + 1))
  done
  printf '%s\n' "$MARKER" >> "$path"
}

run_one() {
  local arm="$1" mode="$2" index="$3"
  local dir="$WORK/$arm-$index"
  local db="$dir/bench.db"
  mkdir -p "$dir"
  gen_fixture "$dir/controller.log"
  export WASM_AGENT_TOOL_BUDGET="$mode"

  # Turn 1: produce the output. Its last line is the only thing that matters, and
  # it sits ~2.6 KB in, well past the legacy window.
  printf 'run this with bash and tell me in one line whether it succeeded: cat %s\n/exit\n' "$dir/controller.log" \
    | "$BIN" --db "$db" chat > "$dir/turn1.txt" 2>&1
  # Remove the source: the output cannot be regenerated, so the transcript is the
  # only place the information can live.
  rm -f "$dir/controller.log"

  # Turn 2: ask for the line, from the record alone.
  printf 'quote the very last line of that command output exactly, character for character\n/exit\n' \
    | "$BIN" --db "$db" chat --continue > "$dir/turn2.txt" 2>&1

  local answered=0
  grep -qF "$MARKER" "$dir/turn2.txt" && answered=1
  printf '  %-8s run %d   answered=%s\n' "$arm" "$index" "$answered"
  echo "$answered" >> "$WORK/$arm.tsv"
}

echo
echo "information loss benchmark (the recovery is removed on purpose)"
echo "  binary  $BIN"
echo "  fixture: 60 log lines then '$MARKER' - the interesting line is last"
echo "  source file deleted between turns, so the transcript is the only record"
echo

: > "$WORK/legacy.tsv"
: > "$WORK/default.tsv"
for index in $(seq 1 "$RUNS"); do run_one legacy legacy "$index"; done
unset WASM_AGENT_TOOL_BUDGET
for index in $(seq 1 "$RUNS"); do run_one default default "$index"; done

echo
echo "summary"
for arm in legacy default; do
  awk -v arm="$arm" '{ ok += $1; n += 1 } END { if (n) printf "  %-8s  recovered the line in %d/%d runs\n", arm, ok, n }' "$WORK/$arm.tsv"
done
echo
echo "  A loss here is not a slow model: the information is absent from one arm's"
echo "  context and present in the other's. That is the difference between costing"
echo "  rounds and losing evidence."

# Measured result, recorded here so nobody over-claims from this script:
#   legacy recovered the line in 2 of 3 runs, not 0.
# The recovery path is the one this fixture failed to close: the assistant's own
# turn-1 reply is prose, prose is not budgeted, and it had already mentioned the
# last line in passing. So head-only truncation is usually recoverable through the
# model's own summary and mostly costs rounds. Demonstrating real loss needs a case
# where the answer is not echoed in prose - a file that changes between turns, or
# several truncated results that no summary carries. Until then the honest claim is
# the cost, not the failures.
