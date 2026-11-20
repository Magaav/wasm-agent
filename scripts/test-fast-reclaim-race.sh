#!/usr/bin/env bash
# A CONCURRENT START NEVER RECLAIMS A LIVE RUN (review r2, A3).
#
# MEASURED SHAPE BEFORE THE FIX: fast.sh wrote its `<workdir>/pid` and only THEN opened and flocked
# `<workdir>/lock`. A second fast.sh starting in that window saw a pid file, took the lock (free, because
# the owner had not taken it yet), and rm -rf'd a directory whose owner was alive and one line away from
# locking it. The pid was never the protection - the lock is - so the fix is lock first, pid second, and
# this row runs the reclaim in exactly that window and asserts the directory survives.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. scripts/lib/scratch-home.sh
WA_ROOT="$(wa_scratch_root test-reclaim-race 2>/dev/null)" || { echo "SKIP test-fast-reclaim-race: no scratch root"; exit 0; }
WORK="$(wa_test_workdir "$WA_ROOT" reclaim-race)" || exit 2
cleanup() { local s=$?; exec 7>&- 2>/dev/null; rm -rf "$WORK"; exit $s; }
trap cleanup EXIT

# THE OWNER, exactly as fast.sh now does it: lock first, then pid.
LIVE="$WORK/wa-fast-live"
mkdir -p "$LIVE" || exit 2
exec 7>>"$LIVE/lock" || exit 2
flock -n 7 || { echo "test-fast-reclaim-race: the owner could not take its own lock" >&2; exit 1; }
printf "%s\n" "$$" > "$LIVE/pid" || exit 2

# THE RECLAIM A CONCURRENT START RUNS, verbatim from scripts/fast.sh.
reclaim() {
  local stale stale_pid
  for stale in "$1"/wa-fast-*; do
    [ -d "$stale" ] || continue
    [ -f "$stale/pid" ] || continue
    if ( exec 9>>"$stale/lock" 2>/dev/null && flock -n 9 ) 2>/dev/null; then
      stale_pid=$(cat "$stale/pid" 2>/dev/null)
      rm -rf "$stale" 2>/dev/null && echo "reclaimed $stale"
    fi
  done
}

out="$(reclaim "$WORK")"
if [ ! -d "$LIVE" ]; then
  echo "test-fast-reclaim-race: a LIVE directory was reclaimed by a concurrent start (pid $$ held its lock)" >&2
  exit 1
fi
case "$out" in
  *reclaimed*) echo "test-fast-reclaim-race: the reclaim removed a directory whose owner holds the lock: $out" >&2; exit 1 ;;
esac

# AND A DEAD OWNER IS STILL RECLAIMED: the lock is released by the kernel, so the same code takes it.
DEAD="$WORK/wa-fast-dead"
mkdir -p "$DEAD" || exit 2
printf "%s\n" "999999" > "$DEAD/pid"
out="$(reclaim "$WORK")"
if [ -d "$DEAD" ]; then
  echo "test-fast-reclaim-race: an interrupted run lock (no holder) was NOT reclaimed: $out" >&2
  exit 1
fi
if [ ! -d "$LIVE" ]; then
  echo "test-fast-reclaim-race: the reclaim that took the dead directory also took the live one" >&2
  exit 1
fi

echo "test-fast-reclaim-race: ok (a live run lock is never reclaimed, an interrupted run lock is, and both were asked in the same sweep)"
