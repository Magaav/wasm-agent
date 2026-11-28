#!/bin/bash
# A TIP YOUNGER THAN ITS OWN PUBLISH MUST BE GRADED, NOT REFUSED (28/11, Victor).
#
# MEASURED: NOT GRADED on every tip at 00:32Z and 00:37Z while node-663e11d08d1d was published and complete. A tip
# lands, the loop looks within minutes, and the publish takes 6-10 min - so "the tip's own bundle" almost never exists
# at the moment of the look, and the old order refused exactly there.
#
# The order now: (1) the tip's own bundle, (2) the newest published bundle whose compiled inputs cover the tip (the
# resolver's digest search - the publish's own "covered by" answer, law 17), (3) WAIT for the tip's publish to settle,
# and only then build. This row exercises (3) and the naming, with a stub resolver so the wait is measured in seconds.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "health-settles: $*"; exit 1; }
lib=factory/lib/main-binary.sh
stub=scripts/fixtures/health-settle-stub.sh
[ -r "$lib" ] || fail "$lib is missing"
[ -r "$stub" ] || fail "$stub is missing"

grep -q 'wa_main_binary_settle' "$lib" || fail 'the lib has no wait: a tip younger than its publish is refused again'
grep -q 'WA_MAIN_PUBLISH_WAIT_SECONDS' "$lib" || fail 'the wait is unbounded or has no knob'
grep -q 'wa_main_binary_step_for' "$lib" || fail 'the step does not name WHICH bundle graded the tip'

# THE LOOP MUST NOT CAPTURE THE LIB IN A SUBSHELL. wa_main_binary names its step by EXPORTING WA_MAIN_BINARY_STEP, and
# `WA_BIN=$(wa_main_binary ...)` loses it: measured 00:53Z, a tip that WAS graded printed "with unknown" because the
# lib was current and the export died with the subshell. This is the third time that trap has bitten this file.
loop=factory/health-loop.sh
[ -r "$loop" ] || fail "$loop is missing"
grep -Eq '^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?WA_BIN=\$\(wa_main_binary' "$loop" && fail 'the loop captures wa_main_binary in a subshell, so WA_MAIN_BINARY_STEP dies and the line says unknown'
grep -q 'health-binary.out' "$loop" || fail 'the loop does not read the binary back from a file, so it cannot name the step'
grep -q 'READ BACK HERE' "$loop" || fail 'the loop does not say why the read-back exists; the next editor will put the substitution back'
# AND IT MUST SAY THAT A GRADING IS UNDER WAY: resolution takes seconds to fifteen minutes, and silence is
# indistinguishable from a stuck loop (measured 01:23Z-01:30Z: a build was running and only `ps` showed it).
grep -q 'grading ${N:0:8} - resolving a binary' "$loop" || fail 'the loop says nothing while it resolves a binary, so a long build looks like a stuck loop'  

work=$(mktemp -d "${TMPDIR:-/tmp}/settle.XXXXXX") || fail 'no temp dir'
trap 'rm -rf "$work"' EXIT
SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

export WA_SETTLE_TRIPLE=x86_64-unknown-linux-gnu
run_case() { # <refuse-count> <wait-bound> -> one line: rc= out= step= waited=
  rm -f "$work/calls"
  WA_NODE_BINARIES_LIB="$PWD/$stub" \
  WA_SETTLE_CALLS="$work/calls" WA_SETTLE_REFUSE="$1" WA_SETTLE_BUNDLE="$work/bundle" WA_SETTLE_SHA="$SHA" \
  WA_MAIN_PUBLISH_POLL_SECONDS=1 WA_MAIN_PUBLISH_WAIT_SECONDS="$2" \
  WA_SETTLE_STAGE="$work/stage" WA_SETTLE_TARGET="$work/target" WA_SETTLE_ROOT="$work/repo" \
  bash -c '
    . "$1"
    # the real pin builds sidecars through cargo; this row is about WHICH answer wins, so pin is made inert
    wa_main_binary_pin() { printf "PINNED %s\\n" "$1"; return 0; }
    # NOT in a command substitution: the lib names the step through the ENVIRONMENT, and a subshell swallows it.
    wa_main_binary "$2" "$WA_SETTLE_STAGE" "$WA_SETTLE_TARGET" "$WA_SETTLE_ROOT" >"$4" 2>"$3"
    rc=$?
    out=$(cat "$4" 2>/dev/null)
    printf "rc=%s out=%s step=%s waited=%s\\n" "$rc" "$out" "${WA_MAIN_BINARY_STEP:-}" "${WA_MAIN_BINARY_WAITED:-}"
  ' _ "$PWD/$lib" "$SHA" "$work/err" "$work/out"
}

# 1) the publish lands on the third ask: the wait must grade from it, and say which bundle it was.
out=$(run_case 2 10)
case "$out" in rc=0*) ;; *) fail "a tip whose publish settled during the wait was not graded: $out / $(cat "$work/err" 2>/dev/null | tail -2)" ;; esac
case "$out" in *"step=waited-"*) ;; *) fail "the step does not say the wait produced the binary: $out" ;; esac
case "$out" in *"release-"*) ;; *) fail "the step does not say WHICH kind of bundle answered: $out" ;; esac
case "$out" in *"${SHA:0:12}"*) ;; *) fail "the step does not name the bundle's commit: $out" ;; esac

# 2) the publish never comes: the wait must be BOUNDED, and the refusal must still name both attempts.
start=$SECONDS
out=$(run_case 99 2)
elapsed=$((SECONDS - start))
[ "$elapsed" -ge 2 ] || fail "the wait returned before its bound (${elapsed}s for a 2s bound)"
case "$out" in rc=1*) ;; *) fail "a tip with no publish at all must still refuse, not hang: $out" ;; esac
errtext=$(cat "$work/err" 2>/dev/null)
case "$errtext" in *"release:"*) ;; *) fail "the refusal no longer names the release attempt: ${errtext:-<nothing on stderr>}" ;; esac
case "$errtext" in *"build:"*) ;; *) fail "the refusal no longer names the build attempt: ${errtext:-<nothing on stderr>}" ;; esac

echo "health settles ok (a publish that arrives during the wait is graded and named; one that never arrives refuses after its bound)"
