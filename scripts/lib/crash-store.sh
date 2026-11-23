#!/usr/bin/env bash
# LEAVE A SQLITE STORE EXACTLY AS A WRITER KILLED MID-COMMIT DOES, and prove the artifact is that.
#
# In `delete` journal mode a commit is: write the journal header's record count, sync the journal, overwrite
# the database pages, then delete the journal. A kill between the sync and the delete leaves a database that
# is part new revision and part old - no revision any run produced - beside a journal holding the pre-image
# of every page the commit had touched. Only the journal can put it back, and a READ-ONLY opener cannot roll
# it back: so a reader that opens read-only reads torn pages and reports the store as MALFORMED, and a node
# that treats that verdict as damage throws the whole index away.
#
# That is what happened on 22/11 - three `graph_db_quarantined ... reason=graph_index_failed:_
# database_disk_image_is_malformed` lines in 16 minutes across one install, and the copy kept in
# `~/.wasm-agent/graph.db.d/graph.db.malformed-20261123T000626Z` rolls back to `integrity_check: ok` with all
# 101,422 of its nodes still there. So the fixture is built the way the damage happens and verified by
# SQLite itself, never asserted:
#
#   1. a copy of the store runs the caller's transaction with a small page cache, so SQLite spills and
#      journals a real span of pages;
#   2. the transaction is committed, and the journal header's record count is watched - it reads 0 while the
#      pages are journaled and turns non-zero the instant the commit begins, which is the window this needs.
#      The journal is copied the moment that is seen, and the writer is killed while its page writes are
#      still in flight;
#   3. the torn database is built from the pre-crash store with one page of it destroyed - a page that is
#      neither revision, which is exactly what a kill inside a single page write leaves (the 22/11 store
#      reported `invalid page number` and `btreeInitPage() returns error code 11`). The page is CHOSEN by
#      SQLite: the first one the caller's own query cannot read while it is destroyed, and that the caught
#      journal rolls back to the answer the store gave before the crash.
#
# Both halves are verified before anything is installed: the torn copy must make the caller's read fail, and
# the same copy with its journal must roll back to the query's exact pre-crash answer. A fixture that cannot
# fail proves nothing and a test that cannot tell is never a pass, so a build that verifies nothing is a
# refusal by name.
#
#   crash-store.sh <db> <statements.sql> [<verify-query>] [<work-dir>]
#     <statements.sql>  the transaction body: one or more statements, run inside BEGIN IMMEDIATE
#     <verify-query>    one query whose output must be identical before the crash and after the rollback
#                       (default: SELECT COUNT(*) FROM sqlite_master)
#   exit 0 fixture verified  |  1 the commit was caught but no verified fixture was built (reason on stderr)
#   3 refused: nothing built (no sqlite3, no store, no journal written, or a journal already beside the store)
#
# Writes only inside <work-dir> (default: a new directory under TMPDIR) and beside <db>; it refuses a store
# that already has a journal, so it never overwrites another writer's pending recovery.
set -eu

db=${1-}
statements=${2-}
query=${3:-SELECT COUNT(*) FROM sqlite_master}
work=${4-}
attempts=${CRASH_STORE_ATTEMPTS:-8}

[ -n "$db" ] && [ -n "$statements" ] || { echo "crash-store: refused: usage: crash-store.sh <db> <statements.sql> [<query>] [<work-dir>]" >&2; exit 3; }
command -v sqlite3 >/dev/null 2>&1 || { echo "crash-store: refused: no sqlite3 on PATH, so no fixture can be built or verified" >&2; exit 3; }
[ -f "$db" ] || { echo "crash-store: refused: no store at $db" >&2; exit 3; }
[ -f "$statements" ] || { echo "crash-store: refused: no statements at $statements" >&2; exit 3; }
if [ -s "$db-journal" ]; then echo "crash-store: refused: $db-journal already holds a pending journal" >&2; exit 3; fi

[ -n "$work" ] || work=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/crash-store.$$")
mkdir -p "$work"
work=$(cd "$work" && pwd)
before=$work/before.db
journal=$db-journal
rm -f "$before" "$work/live.db" "$work/live.db-journal" "$work/caught-journal" "$work/alone.db" "$work/alone.db-journal" "$work/f"
cp "$db" "$before"
base=$(sqlite3 "$before" "$query" 2>&1)
verdict() { sqlite3 "$1" 'PRAGMA integrity_check;' 2>&1 | head -1; }

writer=''
fifo_open=''
cleanup() { [ -n "$writer" ] && kill -9 "$writer" 2>/dev/null || true; if [ -n "$fifo_open" ]; then exec 3>&-; fi; [ -n "$writer" ] && wait "$writer" 2>/dev/null || true; writer=''; fifo_open=''; }
trap cleanup EXIT

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  live=$work/live.db
  cp "$before" "$live"
  rm -f "$live-journal"
  fifo=$work/f
  rm -f "$fifo"
  mkfifo "$fifo"
  sqlite3 "$live" < "$fifo" > "$work/attempt.log" 2>&1 &
  writer=$!
  exec 3> "$fifo"
  fifo_open=1
  printf 'PRAGMA journal_mode=delete;\nPRAGMA cache_size=1;\nPRAGMA synchronous=FULL;\nBEGIN IMMEDIATE;\n' >&3
  printf '.read %s\n' "$statements" >&3
  i=0
  while [ $i -lt 600 ]; do
    [ -s "$live-journal" ] && break
    i=$((i + 1))
    sleep 0.02
  done
  if [ ! -s "$live-journal" ]; then
    echo "crash-store: refused: the statements journaled no page, so there is nothing to tear ($(tr '\n' ' ' < "$work/attempt.log"))" >&2
    exit 3
  fi
  sleep 0.3
  printf 'COMMIT;\n' >&3
  caught=''
  j=0
  while [ $j -lt 200000 ]; do
    if [ -s "$live-journal" ]; then
      count=$(dd if="$live-journal" bs=1 skip=8 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
      if [ -n "$count" ] && [ "$count" != 00000000 ]; then caught=$count; break; fi
    else
      break
    fi
    j=$((j + 1))
  done
  if [ -z "$caught" ]; then
    cleanup
    echo "crash-store: attempt $attempt: the commit finished before it was seen" >&2
    attempt=$((attempt + 1))
    continue
  fi
  cp "$live-journal" "$work/caught-journal" 2>/dev/null || true
  cleanup
  if [ ! -s "$work/caught-journal" ]; then
    echo "crash-store: attempt $attempt: the journal was deleted before it could be copied" >&2
    attempt=$((attempt + 1))
    continue
  fi
  # The torn database: the pre-crash store with one page destroyed, the page chosen by SQLite (see the
  # header of this file). Only pages the caught journal covers can pass the rollback half, so the journal
  # and the damage are guaranteed to be the same crash.
  pages=$(($(wc -c < "$before") / 4096))
  if [ "$pages" -lt 2 ]; then echo "crash-store: refused: a one-page store has no page to tear" >&2; exit 3; fi
  page=2
  while [ "$page" -le "$pages" ]; do
    # Three copies, and they are not interchangeable: the damaged one is never opened with the journal (so
    # it stays torn for the store this installs), the probe is the one SQLite is allowed to roll back, and
    # the journal is kept pristine because a rollback SPENDS it.
    rm -f "$work/damaged.db" "$work/probe.db" "$work/probe.db-journal"
    cp "$before" "$work/damaged.db"
    dd if=/dev/zero of="$work/damaged.db" bs=4096 seek=$((page - 1)) count=1 conv=notrunc status=none
    if torn=$(sqlite3 "$work/damaged.db" "$query" 2>&1); then torn_code=0; else torn_code=$?; fi
    if [ "$torn_code" = 0 ] || [ "$torn" = "$base" ]; then page=$((page + 1)); continue; fi
    cp "$work/damaged.db" "$work/probe.db"
    cp "$work/caught-journal" "$work/probe.db-journal"
    recovered=$(verdict "$work/probe.db") || true
    rows=$(sqlite3 "$work/probe.db" "$query" 2>&1) || true
    if [ "$recovered" = "ok" ] && [ "$rows" = "$base" ]; then
      cp "$work/damaged.db" "$db"
      cp "$work/caught-journal" "$journal"
      echo "crash-store: mid-commit store at $db - page $page of $pages torn, journal record count 0x$caught, attempt $attempt; without the journal the read fails: $torn | with it: $recovered | '$query' -> $base"
      exit 0
    fi
    page=$((page + 1))
  done
  echo "crash-store: attempt $attempt: the caught journal covers no page that breaks the caller's read and still rolls back to '$base'" >&2
  attempt=$((attempt + 1))
done

echo "crash-store: refused: $attempts attempts left no verified mid-commit store" >&2
exit 1
