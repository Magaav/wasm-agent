#!/usr/bin/env bash
# THE CONTAINER'S WATCHER START RETRIES, SAYS SO, AND WRITES ITS GIVE-UP (Fable 26/11, work).
#
# MEASURED on work (a Docker container with no systemd), twice on 26/11: the entrypoint's `wa-sentinel start` failed, the
# reason went to stdout only, and sentinel.log - the file a person reads later - said nothing about it; an hour later
# `wa update` could only answer "no sentinel watcher ownership was verified".
#
# This row drives deploy/wa-start-watcher.sh against a stub sentinel that FAILS ON PURPOSE, and holds the three things
# the brief asks for:
#   1. a start that fails twice then succeeds is retried, prints every try, and exits 0 with nothing given up;
#   2. a start that always fails gives up after the bounded number of tries, exits non-zero, and writes EXACTLY ONE
#      `start_gave_up` line to sentinel.log - the sentinel's own tabbed shape (epoch, event, what, why);
#   3. the backoff is bounded: with the schedule's first delay at zero the whole sequence is bounded by the attempts, not
#      by a sleep nobody measured.
#
# Scratch only (own HOME, refused against the operator's), and the stub is a stub because a sentinel that fails on
# demand does not exist: what is under test is the retry policy and the line it leaves, not the sentinel's own start.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
. "$ROOT/scripts/lib/scratch-home.sh"
if [ -n "${WA_ROW_SCRATCH_ROOT:-}" ]; then W="$WA_ROW_SCRATCH_ROOT/row-start-retry"; else W="$(TMPDIR=/tmp mktemp -d /tmp/wa-start-retry.XXXXXX)"; fi
mkdir -p "$W/home" "$W/bin" || exit 1
wa_scratch_home_guard "$W/home" || { echo 'start-retry REFUSED: the scratch home is the operator node home' >&2; exit 2; }
export HOME="$W/home" WASM_AGENT_HOME="$W/home"

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "start-retry FAILED: $*" >&2; exit 1; }
says() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' is not in: $(printf '%s' "$1" | head -3 | tr '\n' ' ')" ;; esac; }

LOG="$W/home/.wasm-agent/sentinel/sentinel.log"
# A file that does not exist yet is ZERO lines, not an empty string: `grep -c` prints nothing when it cannot open the
# file, so the first version of this helper made "no give-up yet" read as a failure of the case under test.
GAVE_UP() { local n; n="$(grep -c "start_gave_up" "$LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# A stub sentinel: `start` fails N times (`FAIL_TIMES`), then succeeds; `status` says watching only after a success.
STUB="$W/bin/wa-sentinel"
install_stub() { # <times to fail, or "always">
  # A heredoc, not a quoted printf: the first version built this file through `printf '%q'` inside a single-quoted
  # format and the escapes came out wrong, so the stub never failed at all and the retry wrote a give-up for a start
  # that had succeeded (measured while writing this row).
  cat > "$STUB" <<STUB_EOF
#!/bin/sh
FILE="$W/attempts"
TIMES="$1"
case "\$1" in
  start)
    n=\$(cat "\$FILE" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$FILE"
    if [ "\$TIMES" = always ] || [ "\$n" -le "\$TIMES" ]; then
      echo "the lock is held by pid 4242; nothing was started" >&2; exit 1
    fi
    exit 0 ;;
  status)
    n=\$(cat "\$FILE" 2>/dev/null || echo 0)
    if [ "\$TIMES" = always ] || [ "\$n" -le "\$TIMES" ]; then echo "sentinel: not running"; exit 0; fi
    echo "sentinel: up watching (pid 999)"; exit 0 ;;
esac
exit 2
STUB_EOF
  chmod +x "$STUB"
  rm -f "$W/attempts"
}
run_retry() { # <attempts> <delay> -> stdout
  WA_SENTINEL_BIN="$STUB" "$ROOT/deploy/wa-start-watcher.sh" "$@" 2>&1
}

# ---- 1. two failures, then a start ------------------------------------------------------------------------
install_stub 2
out="$(run_retry 5 0)"; rc=$?
[ "$rc" = 0 ] || fail "a start that succeeds on the third try must exit 0, got $rc: $out"
ok
says "$out" 'try 1 of 5' 'says which try it is on'
says "$out" 'try 2 of 5' 'on every try, not only the first'
says "$out" 'try 3 of 5' 'and on the one that worked'
says "$out" 'the watcher is up after 3 attempt(s)' 'and says when it is up, with the count'
says "$out" 'the lock is held by pid 4242' 'printing the reason the failed tries gave'
[ "$(cat "$W/attempts" 2>/dev/null)" = 3 ] || fail "the stub was asked to start $(cat "$W/attempts" 2>/dev/null) time(s), wanted 3"
ok
[ "$(GAVE_UP)" = 0 ] || fail 'a start that succeeded wrote a give-up line'
ok

# ---- 2. always failing: bounded, and exactly one give-up line --------------------------------------------
install_stub always
out="$(run_retry 4 0)"; rc=$?
[ "$rc" = 1 ] || fail "an exhausted retry must exit 1, got $rc: $out"
ok
[ "$(cat "$W/attempts" 2>/dev/null)" = 4 ] || fail "the stub was asked $(cat "$W/attempts" 2>/dev/null) time(s), wanted the bound of 4"
ok
says "$out" 'wa-start-watcher: gave up after 4 attempt(s)' 'the run says it gave up, with the count'
says "$out" "$LOG" 'and names the file the reason went to'
[ "$(GAVE_UP)" = 1 ] || fail "sentinel.log holds $(GAVE_UP) give-up line(s), wanted exactly 1: $(cat "$LOG" 2>/dev/null)"
ok
line="$(grep "start_gave_up" "$LOG" 2>/dev/null | head -1)"
case "$(printf '%s' "$line" | cut -f1)" in ''|*[!0-9]*) fail "the give-up line must start with the epoch: $line" ;; *) ok ;; esac
case "$line" in *'4 attempt(s)'*) ok ;; *) fail "the line names how many attempts there were: $line" ;; esac
case "$line" in *'the lock is held by pid 4242'*) ok ;; *) fail "and the reason the last attempt gave: $line" ;; esac
# A second run adds a second line - it is an append, never a rewrite - and each line is its own record.
out="$(run_retry 2 0)"; rc=$?
[ "$rc" = 1 ] || fail "the second exhausted run must also exit 1, got $rc"
ok
[ "$(GAVE_UP)" = 2 ] || fail "two giving-up runs must leave two lines, found $(GAVE_UP)"
ok

echo "start retry ok ($checks checks): a container's watcher start retries with a bound, says so on every try, and its give-up is in sentinel.log"
