#!/usr/bin/env bash
# The append race, for real: several OS processes appending to the same session in one database at once.
#
# The single-process smoke tests cannot catch this. `seq` is the transcript's order, and it used to be
# `MAX(seq)+1` read and then inserted as two statements with no transaction - so two writers could read the
# same MAX and either collide on a seq or land out of order. That is not hypothetical: a restart left the
# previous turn's final message *after* the wake's user message (session 4ef4e372, seq 4195/4196), and the
# woken turn, handed a transcript ending on the old answer, echoed it. The fix is one `BEGIN IMMEDIATE`
# transaction per append; this proves it under contention, which is the only place it can fail.
#
# Usage:  WA_BIN=rust/target/release/wa bash scripts/test-append-race.sh
# Prints: append race ok
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WASM_AGENT_LUA_ROOT="$ROOT"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$BIN.exe"
[ -x "$BIN" ] || BIN="$ROOT/rust/target/release/wa.exe"
[ -x "$BIN" ] || { echo "no wa binary at $BIN (build it first)"; exit 2; }

PROCS="${RACE_PROCS:-6}"
N="${RACE_N:-12}"
DB="$(mktemp -u /tmp/wa-append-race-XXXXXX.db)"

"$BIN" --db "$DB" init >/dev/null

pids=""
for proc in $(seq 1 "$PROCS"); do
  RACE_PROC="$proc" RACE_N="$N" WA_SCRIPT="$ROOT/scripts/test-append-race-worker.lua" \
    "$BIN" --db "$DB" >"$DB.writer.$proc.log" 2>&1 &
  pids="$pids $!"
done

status=0
for pid in $pids; do wait "$pid" || status=1; done
if [ "$status" != "0" ]; then
  echo "FAIL: a concurrent writer exited nonzero (the transaction did not serialise)" >&2
  for proc in $(seq 1 "$PROCS"); do
    [ -s "$DB.writer.$proc.log" ] && { echo "--- writer $proc ---" >&2; cat "$DB.writer.$proc.log" >&2; }
  done
  rm -f "$DB" "$DB"-* "$DB".writer.*.log
  exit 1
fi

RACE_PROCS="$PROCS" RACE_N="$N" WA_SCRIPT="$ROOT/scripts/test-append-race-check.lua" \
  "$BIN" --db "$DB" 2>&1 | tee "$DB.check.log"
check_status=${PIPESTATUS[0]}

rm -f "$DB" "$DB"-* "$DB".writer.*.log "$DB".check.log
[ "$check_status" = "0" ] || { echo "FAIL: the append race invariants did not hold" >&2; exit 1; }
