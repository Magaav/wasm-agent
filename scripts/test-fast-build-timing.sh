#!/usr/bin/env bash
# scripts/fast.sh's Rust build row, judged without a toolchain: WHICH build it measures, and which
# clock it measures it with.
#
# WHY. The row exists so that "a module compiles faster" is a number (ARCHITECTURE.md, "Modules over
# the monolith"). A number is worthless if it is the wrong build: it used to run 'cargo build --release
# -p <crate>' and then the test row ran 'cargo test' in the profile IT needs, so the figure was a
# compile the tests never consumed (and for wa-sentinel, a second profile and a second compile of the
# same source). What the row must measure now is 'cargo test --no-run' in the tests' own profile: the
# compile the row below reuses, paid once.
#
# This proves that pairing by reading the file - the same manifest and the same profile in both
# invocations - and the portable clock the durations are taken with ('date +%s%N' is a GNU extension;
# on BSD/macOS it prints a literal N and every row time became a shell error there).
#
# It cannot prove the compile itself: that needs cargo, and this file runs where there may be none. What
# it can prove is that the command it would run is the row's own - and it says so when it cannot.
#
#   bash scripts/test-fast-build-timing.sh
set -uo pipefail
cd "$(dirname "$0")/.."
checks=0; skipped=0
ok() { checks=$((checks + 1)); }
fail() { echo "fast-build-timing FAILED: $*" >&2; exit 1; }
src=scripts/fast.sh
[ -f "$src" ] || fail "no $src here"

# ---- 1. one compile, not two: the build row is the tests' build -----------------------------------
grep -qF 'cargo test --no-run --offline $test_args' "$src" \
  && ok || fail "the build row must compile the tests (cargo test --no-run), not a release build"
grep -qF 'cargo build --offline $build_args' "$src" \
  && fail "the separate release build is still there: that is the second compile the row is about" || ok

# The profile and the manifest are the pair that makes the compile reusable: if either stops matching
# the test row below, the number is a second compile again.
grep -qF 'test_args="--release --manifest-path rust/Cargo.toml -p $crate"' "$src" \
  && ok || fail "the measured build must use the workspace manifest and the release profile the test row uses"
grep -qF 'cargo test --release --offline --manifest-path rust/Cargo.toml -p "$crate"' "$src" \
  && ok || fail "the test row's own invocation changed: the measured build is no longer its build"
grep -qF 'test_args="--manifest-path rust/wa-sentinel/Cargo.toml"' "$src" \
  && ok || fail "wa-sentinel's measured build must use its own manifest, in its own (default) profile"
grep -qF 'cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml' "$src" \
  && ok || fail "wa-sentinel's test row is no longer the invocation the build row measures"

# The build comes first, and the recorded time is the build's: bstart before --no-run, the record after.
b_line=$(grep -n 'bstart=\$(fast_now_ms)' "$src" | cut -d: -f1 | head -1)
n_line=$(grep -n 'cargo test --no-run --offline \$test_args' "$src" | cut -d: -f1 | head -1)
r_line=$(grep -n 'wa_build_time_record crate "\$crate"' "$src" | cut -d: -f1 | head -1)
[ -n "$b_line" ] && [ -n "$n_line" ] && [ -n "$r_line" ] && ok || fail "the build timing rows are not all present (bstart=$b_line no-run=$n_line record=$r_line)"
[ "$b_line" -lt "$n_line" ] && [ "$n_line" -lt "$r_line" ] && ok \
  || fail "the clock must start before the build and be recorded after it (bstart=$b_line no-run=$n_line record=$r_line)"

# ---- 2. the clock is portable: one helper, and it survives a BSD-shaped date ---------------------
# The only 'date +%s%N' left is the helper's own, guarded by a 2>/dev/null and the case that rejects a
# literal N; every duration goes through fast_now_ms.
bad=$(grep -n 'date +%s%N' "$src" | grep -v '^[0-9]*: *#' | grep -v 'ns=\$(date +%s%N 2>/dev/null)')
[ -z "$bad" ] && ok || fail "date +%s%N is used outside the portable helper: $bad"
grep -q 'fast_now_ms() {' "$src" && ok || fail "no fast_now_ms helper"
grep -q 'export -f fast_now_ms' "$src" && ok || fail "the Lua rows run in an xargs child: the helper must be exported"

# A date that answers the BSD way (a literal N on +%s%N, whole seconds on +%s) must still produce a
# millisecond count - the fallback, exercised rather than asserted.
fallback=$(bash -c '
  source <(sed -n "/^fast_now_ms() {/,/^}/p" scripts/fast.sh)
  date() { case "$1" in
    +%s%N) echo 1700000000N ;;
    +%s) echo 1700000000 ;;
    *) command date "$@" ;;
  esac; }
  fast_now_ms')
[ "$fallback" = 1700000000000 ] && ok || fail "a BSD-shaped date must fall back to seconds*1000, got '"$fallback"'"

# ... and on a GNU date the same helper counts real milliseconds (a 50ms sleep cannot read 0).
delta=$(bash -c '
  source <(sed -n "/^fast_now_ms() {/,/^}/p" scripts/fast.sh)
  a=$(fast_now_ms); sleep 0.05; b=$(fast_now_ms); echo $(( b - a ))')
[ "$delta" -ge 30 ] && ok || fail "fast_now_ms must count milliseconds, a 50ms sleep read $delta ms"

if ! command -v cargo >/dev/null 2>&1; then
  echo "fast-build-timing: cargo is not on PATH, so the compile these rows describe was NOT run here"
  skipped=$((skipped + 1))
fi
echo "fast-build-timing ok ($checks checks, $skipped skipped)"
