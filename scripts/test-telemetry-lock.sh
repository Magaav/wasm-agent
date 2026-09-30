#!/usr/bin/env bash
# Telemetry must never be able to fail a run.
#
# Tonight two runs died on `lua/core/telemetry.lua:12: database is locked`: a child's run mid-edit and
# then the coordinator's attempt to message that session. The database is shared by every interpreter,
# every process and the UI's polling, and the run path writes to it. A record is worth less than the run
# it describes, so a write that cannot proceed must be retried briefly and then DROPPED with one visible
# line - never raised into the caller.
#
# This holds the write lock for real: a second OS process does `BEGIN IMMEDIATE`, writes a row inside
# that transaction, says "holder: locked", and only then does the subject start. Same database, same
# binaries, different connections - the contention is not simulated.
#
#   bash scripts/test-telemetry-lock.sh                 # the fix: drop visibly, run survives; retry works
#   WA_TELEMETRY_LOCK_EXPECT_DEATH=1 bash scripts/test-telemetry-lock.sh
#                                                       # the falsified direction, run after restoring the
#                                                       # pre-fix telemetry.lua (see below)
#
# Falsifying it needs the old file, so it is a deliberate two-command step rather than something this
# script does to the tree behind the operator:
#
#   git show <base>:lua/core/telemetry.lua > lua/core/telemetry.lua
#   WA_TELEMETRY_LOCK_EXPECT_DEATH=1 bash scripts/test-telemetry-lock.sh
#   git checkout HEAD -- lua/core/telemetry.lua
#
# Prints: telemetry lock ok
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WASM_AGENT_LUA_ROOT="$ROOT"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$BIN.exe"
[ -x "$BIN" ] || { echo "no wa binary at $BIN (build it first)"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-telemetry-lock-XXXXXX")"
# The test owns its database explicitly, and its home too: nothing here may read or write the operator's
# runtime state.
export WASM_AGENT_HOME="$WORK/home"
mkdir -p "$WASM_AGENT_HOME"

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# A fresh database per phase, so "events=7" means seven records and not seven more.
new_db() {
  local db="$WORK/$1.db"
  "$BIN" --db "$db" init >/dev/null 2>&1 || { fail "init $1"; return 1; }
  echo "$db"
}

holder_start() {
  local db="$1" hold_ms="$2" log="$3"
  WA_LOCK_HOLD_MS="$hold_ms" WA_SCRIPT="$ROOT/scripts/test-telemetry-lock-holder.lua" \
    "$BIN" --db "$db" >"$log" 2>&1 &
  HOLDER_PID=$!
  for _ in $(seq 1 100); do
    grep -q "holder: locked" "$log" 2>/dev/null && return 0
    kill -0 "$HOLDER_PID" 2>/dev/null || break
    sleep 0.1
  done
  fail "the holder never took the write lock: $(cat "$log" 2>/dev/null)"
  return 1
}

holder_stop() { wait "$HOLDER_PID" 2>/dev/null; }

# $1 label, $2 hold ms, $3 extra env for the subject
subject_run() {
  local label="$1" hold_ms="$2" extra="${3:-}"
  local db; db="$(new_db "$label")" || return 1
  local hlog="$WORK/$label.holder.log" slog="$WORK/$label.subject.log"
  holder_start "$db" "$hold_ms" "$hlog" || return 1
  local started=$SECONDS
  env $extra WA_SCRIPT="$ROOT/scripts/test-telemetry-lock-run.lua" "$BIN" --db "$db" >"$slog" 2>&1
  local status=$?
  local elapsed=$((SECONDS - started))
  holder_stop
  echo "--- $label (subject exit $status, ${elapsed}s, write lock held ${hold_ms}ms) ---"
  cat "$slog"
  SUBJECT_STATUS=$status SUBJECT_LOG="$slog" SUBJECT_ELAPSED=$elapsed
  return 0
}

if [ -n "${WA_TELEMETRY_LOCK_EXPECT_DEATH:-}" ]; then
  # The falsified direction: with the error propagating again, the same subject on the same lock does not
  # complete. This is what the node did twice tonight.
  db="$(new_db death)" || exit 1
  hlog="$WORK/death.holder.log"; slog="$WORK/death.subject.log"
  holder_start "$db" 8000 "$hlog" || exit 1
  WA_SCRIPT="$ROOT/scripts/test-telemetry-lock-run.lua" "$BIN" --db "$db" >"$slog" 2>&1
  status=$?
  holder_stop
  echo "--- death (subject exit $status) ---"
  cat "$slog"
  if [ "$status" = "0" ]; then
    fail "the subject completed: the telemetry write no longer dies, so this is not the falsified build"
  fi
  grep -q "telemetry.lua:[0-9]*: database is locked" "$slog" \
    || fail "the death was not the locked-database error from telemetry.lua: $(grep -i 'error\|locked' "$slog" | head -3)"
  grep -q "database is locked" "$slog" && echo "death reproduced: $(grep -o 'telemetry.lua:[0-9]*: database is locked' "$slog" | head -1)"
  [ "$fails" = "0" ] && echo "telemetry lock ok (falsified direction: the run died as tonight)" || exit 1
  rm -rf "$WORK"
  exit 0
fi

# ---- A: the write lock is held longer than one SQLite busy wait, and the write is allowed one attempt.
#      The run must still finish, and the record it could not store must appear as one line rather than
#      as the run's error. One attempt is the honest worst case: it already spends SQLite's own 5s wait.
subject_run drop 9000 "WASM_AGENT_TELEMETRY_WRITE_ATTEMPTS=1" || exit 1
[ "$SUBJECT_STATUS" = "0" ] || fail "A: the run died (exit $SUBJECT_STATUS) instead of completing"
grep -q "subject: run survived" "$SUBJECT_LOG" || fail "A: the subject never reached the end of the run"
grep -q "telemetry: dropped" "$SUBJECT_LOG" \
  || fail "A: no dropped-record line on stderr - the loss was swallowed silently"
grep -q "events=0 drops=[1-9]" "$SUBJECT_LOG" \
  || fail "A: expected the ledger to hold 0 events and a positive drop count: $(grep 'subject: completed' "$SUBJECT_LOG")"
echo "A: storage was lost, visibly; the run was not"

# ---- B: the lock is released while the subject is still retrying. The record must be stored, not
#      dropped: proof that the retry is a retry and not a longer wait for death.
subject_run retry 7000 || exit 1
[ "$SUBJECT_STATUS" = "0" ] || fail "B: the run died (exit $SUBJECT_STATUS)"
grep -q "events=7 drops=0" "$SUBJECT_LOG" \
  || fail "B: the retried write did not land: $(grep 'subject: completed' "$SUBJECT_LOG")"
if grep -q "telemetry: dropped" "$SUBJECT_LOG"; then
  fail "B: a record was dropped although the lock came back inside the budget"
fi
grep -q "subject: completed events=7" "$SUBJECT_LOG" && echo "B: the write was retried and stored (7 records, 0 dropped)"

rm -rf "$WORK"
[ "$fails" = "0" ] || { echo "$fails check(s) failed" >&2; exit 1; }
echo "telemetry lock ok"
