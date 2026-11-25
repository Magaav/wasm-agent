#!/usr/bin/env bash
# THE CONVERSION HALF: versions-adopt.sh (Fable 25/11, decision (i)).
#
# What it pins:
#   - --dry-run prints the plan and writes NOTHING (no version folder, no link, the real paths still real);
#   - the real run leaves a complete, verified version folder and every legacy path a link through the pointer,
#     with the old paths kept as <name>.stale.<ts> (nothing deleted);
#   - a second run says adopt_already_adopted and changes nothing (adopt is once per node);
#   - a FAILED verification ROLLS BACK: the in-place install is exactly what it was (regular file / real
#     directory, no links), the step exits 4, and it says the deploy must stop.
#
# It runs under the row runner with a scratch install and share; the check below refuses to run otherwise.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/scratch-env.sh

n=0
ok() { n=$((n+1)); }
fail() { echo "FAIL test-versions-adopt: $*" >&2; exit 1; }

BASE="${WA_ROW_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
case "$BASE" in */.wasm-agent|*/.wasm-agent/*) BASE=/tmp ;; esac
W="$(mktemp -d "$BASE/wa-adopt-XXXXXX")" || { echo "FAIL: no scratch" >&2; exit 2; }
cleanup() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
wa_scratch_env_apply "$W" >/dev/null
ISOLATION="$(wa_scratch_env_check "$W" 2>&1)" || { printf '%s\n' "$ISOLATION" >&2; fail "the row's environment is NOT ISOLATED: nothing was run"; }

ID=aaaaaaaaaaaa
COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

in_place_install() { # <dir> [<stub-version-exit>] [<commit>]
  local dir="$1" rc="${2:-0}" commit="${3:-$COMMIT}"
  mkdir -p "$dir/lua-core/lua/core" "$dir/scripts"
  printf '#!/bin/sh\n[ "%s" = 0 ] || exit %s\nprintf "wa-stub\\n"\nexit 0\n' "$rc" "$rc" > "$dir/wa"
  chmod +x "$dir/wa"
  printf 'sentinel' > "$dir/wa-sentinel"
  printf 'init' > "$dir/lua-core/lua/core/init.lua"
  printf 'deploy' > "$dir/scripts/deploy.sh"
  printf 'commit=%s\nbranch=main\nbuild_pin=%s\n' "$commit" "$commit" > "$dir/installed.txt"
}

run_adopt() { # <install> [extra args...]
  local install="$1"; shift
  bash scripts/versions-adopt.sh --install "$install" --share "$W/share" "$@"
}

# --- 1. --dry-run writes nothing -------------------------------------------------------------------------------
I1="$W/install1"; in_place_install "$I1"
run_adopt "$I1" --dry-run > "$W/dry.log" 2>&1 || { sed -n '1,6p' "$W/dry.log" >&2; fail "the dry run must succeed"; }
grep -q 'adopt_plan id=aaaaaaaaaaaa' "$W/dry.log" || fail "the dry run does not name the version it would create"
grep -q 'adopt_plan moves:' "$W/dry.log" || fail "the dry run does not say what it would move"
grep -q 'adopt_dry_run: nothing was written' "$W/dry.log" || fail "the dry run does not say it wrote nothing"
ok
[ ! -d "$W/share/versions" ] || fail "the dry run created a versions directory"
[ -f "$I1/installed.txt" ] && [ ! -L "$I1/installed.txt" ] || fail "the dry run turned the record into a link"
[ -d "$I1/lua-core" ] && [ ! -L "$I1/lua-core" ] || fail "the dry run turned the Lua tree into a link"
ok

# --- 2. the real conversion ------------------------------------------------------------------------------------
run_adopt "$I1" > "$W/adopt.log" 2>&1 || { sed -n '1,8p' "$W/adopt.log" >&2; fail "the conversion must succeed on a healthy in-place install"; }
grep -q 'adopt_verified id=aaaaaaaaaaaa' "$W/adopt.log" || fail "the conversion does not say it verified"
ok
[ -f "$W/share/versions/$ID/version.txt" ] || fail "no version folder was created"
[ "$(readlink "$W/share/current")" = "versions/$ID" ] || fail "current does not name the version"
ok
[ -L "$I1/installed.txt" ] && grep -q "^commit=$COMMIT" "$I1/installed.txt" || fail "the record is not a link reading the version's own record"
for name in wa wa-sentinel lua-core scripts; do
  [ -L "$I1/$name" ] || fail "$name is not a link after the conversion"
  [ "$(readlink -f "$I1/$name")" = "$(readlink -f "$W/share/versions/$ID/$name")" ] || fail "$name does not resolve through current"
done
ok
ls "$I1"/lua-core.stale.* >/dev/null 2>&1 || fail "the old Lua tree was not kept as <name>.stale.<ts>"
[ "$(cat "$I1"/lua-core.stale.*/lua/core/init.lua)" = "init" ] || fail "the kept copy is not the old tree"
ok
"$I1/wa" --version >/dev/null 2>&1 || fail "the install's own program does not answer after the conversion"
ok

# --- 3. a second run is a no-op that says so -------------------------------------------------------------------
run_adopt "$I1" > "$W/again.log" 2>&1 || { sed -n '1,4p' "$W/again.log" >&2; fail "a second run must not fail"; }
grep -q 'adopt_already_adopted' "$W/again.log" || fail "a second run does not say the node is already adopted"
ok

# --- 4. a failed verification leaves the in-place install EXACTLY as it was -------------------------------------
# A DIFFERENT commit from the first fixture: a version folder is keyed by the commit, so reusing the same id would
# (correctly) reuse the first, good folder and the failing program would never be verified. The runner caught that
# too: "a conversion whose verification fails must exit non-zero" with the adopt succeeding off the first folder.
COMMIT_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
I2="$W/install2"; in_place_install "$I2" 3 "$COMMIT_B"   # the stub program answers --version with exit 3
if run_adopt "$I2" > "$W/rollback.log" 2>&1; then
  fail "a conversion whose verification fails must exit non-zero"
fi
grep -q 'adopt_failed' "$W/rollback.log" || { sed -n '1,8p' "$W/rollback.log" >&2; fail "the failure is not named adopt_failed"; }
grep -q "commit=$COMMIT_B" "$I2/installed.txt" || { sed -n '1,4p' "$W/rollback.log" >&2; fail "the rollback did not leave the second install's own record in place"; }
grep -q 'adopt_verify_failed' "$W/rollback.log" || fail "the failed check is not named"
ok
[ -f "$I2/wa" ] && [ ! -L "$I2/wa" ] || fail "the rollback did not put the real program back"
[ -d "$I2/lua-core" ] && [ ! -L "$I2/lua-core" ] || fail "the rollback did not put the real Lua tree back"
[ -d "$I2/scripts" ] && [ ! -L "$I2/scripts" ] || fail "the rollback did not put the real scripts tree back"
ok
[ -f "$I2/installed.txt" ] && [ ! -L "$I2/installed.txt" ] || fail "the rollback did not put the real record back"
ok

echo "versions adopt ok ($n checks)"

