#!/usr/bin/env bash
# The narrowed fast-path run's row list (`scripts/lib/fast-rows.sh`): what `wa land` asks for, and what the
# runner refuses to give up.
#
# WHY A ROW FOR THIS. The narrowing is the one place a plan can make a green run mean LESS than a full one, so
# the three rules it must never break are proved here, on lists - no node, no cargo, no build, a second:
#
#   1. the always-on core rows run whatever the request says (the row-environment probe and `test-land.lua`);
#   2. a request naming a row this run cannot execute is a REFUSAL by name, never a silent omission - a plan
#      that asks for the wrong thing has to be fixed;
#   3. an empty request runs nothing, which is refused too (a plan that maps no row to a change must ask for
#      the whole suite, not for silence).
#
#   bash scripts/test-fast-rows.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
. "$ROOT/scripts/lib/fast-rows.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "fast-rows FAILED: $*" >&2; exit 1; }

candidates="$WORK/candidates"
printf '%s\n' scripts/test-alpha.lua scripts/test-beta.lua scripts/test-land.lua \
  scripts/test-fast-row-environment.lua > "$candidates"

# ---- 1. the core rows are added, first, and only once ---------------------------------------------------
: > "$WORK/request-one"
printf '%s\n' scripts/test-alpha.lua > "$WORK/request-one"
out="$(wa_fast_row_filter "$candidates" "$WORK/request-one")" || fail "a valid request was refused"
first="$(printf '%s\n' "$out" | head -1)"
[ "$first" = scripts/test-fast-row-environment.lua ] || fail "the row-environment probe is not first: $out"
ok
printf '%s\n' "$out" | grep -qx scripts/test-land.lua || fail "test-land.lua is not in the narrowed run: $out"
ok
printf '%s\n' "$out" | grep -qx scripts/test-alpha.lua || fail "the requested row is missing: $out"
ok
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] || fail "expected 3 rows (2 core + 1 requested), got: $out"
ok
# `test-beta.lua` was not asked for and is not core: it is NOT run, and the omission is the point.
printf '%s\n' "$out" | grep -qx scripts/test-beta.lua && fail "a row nobody asked for ran: $out"
ok

# ---- 2. a request that names a core row does not duplicate it -------------------------------------------
printf '%s\n' scripts/test-land.lua scripts/test-alpha.lua > "$WORK/request-dup"
out="$(wa_fast_row_filter "$candidates" "$WORK/request-dup")" || fail "a request naming a core row was refused"
[ "$(printf '%s\n' "$out" | grep -c '^scripts/test-land.lua$')" = 1 ] || fail "test-land.lua appears twice: $out"
ok
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] || fail "expected 3 unique rows, got: $out"
ok

# ---- 3. an unknown row is a refusal, by name ----------------------------------------------------------
printf '%s\n' scripts/test-nope.lua > "$WORK/request-bad"
err="$(wa_fast_row_filter "$candidates" "$WORK/request-bad" 2>&1 >/dev/null)"
status=$?
[ "$status" = 2 ] || fail "an unknown row was not refused (status $status)"
ok
grep -q 'fast_narrow:unknown_row: scripts/test-nope.lua' <<< "$err" || fail "the refusal does not name the row: $err"
ok

# ---- 4. an empty request is a refusal, not a green run of nothing --------------------------------------
: > "$WORK/request-empty"
err="$(wa_fast_row_filter "$candidates" "$WORK/request-empty" 2>&1 >/dev/null)"
status=$?
[ "$status" = 2 ] || fail "an empty request was not refused (status $status)"
ok
grep -q 'fast_narrow:empty_request' <<< "$err" || fail "the empty request refusal is not named: $err"
ok

# ---- 5. a missing list is a refusal too (a caller that lost its list must not run less) ----------------
err="$(wa_fast_row_filter "$WORK/does-not-exist" "$WORK/request-one" 2>&1 >/dev/null)"
status=$?
[ "$status" = 2 ] || fail "a missing candidate list was not refused (status $status)"
ok
grep -q 'fast_narrow:candidates_unreadable' <<< "$err" || fail "the missing list refusal is not named: $err"
ok

# ---- 6. the core rows are what the runner says they are, and they exist in this tree -------------------
core="$(wa_fast_core_rows)"
printf '%s\n' "$core" | grep -qx scripts/test-fast-row-environment.lua || fail "the probe row is no longer core"
ok
printf '%s\n' "$core" | grep -qx scripts/test-land.lua || fail "test-land.lua is no longer core"
ok
for row in $core; do
  [ -f "$ROOT/$row" ] || fail "a core row does not exist in this tree: $row"
done
ok
# ...and `scripts/fast.sh` really uses the filter (a lib nobody calls is a rule nobody enforces).
grep -q 'wa_fast_row_filter' "$ROOT/scripts/fast.sh" || fail "scripts/fast.sh does not use scripts/lib/fast-rows.sh"
ok
grep -q 'WA_FAST_ROWS' "$ROOT/scripts/fast.sh" || fail "scripts/fast.sh does not honour WA_FAST_ROWS"
ok

echo "fast-rows ok ($checks checks)"
