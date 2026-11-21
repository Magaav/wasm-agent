#!/usr/bin/env bash
# scripts/main-health.sh, judged on a fixture repository whose fast path is a script this row decides.
#
# WHY A ROW FOR THIS. "Main is green" became a recorded fact on 21/11 because it was not one: main was red from
# bfad4f8f for six landings and nothing said so, and the next innocent mission paid for it twice. The record is
# only worth having if it is honest, so this row proves the three answers it must give:
#
#   * GREEN: the suite's own result file says ok -> {ok:true}, exit 0, the worktree removed afterwards;
#   * RED: a failed row -> {ok:false} naming that row and its first line, exit 1;
#   * REFUSED: no result file at all -> exit 2 and a JSON that says ok:false WITH a named why, because a run
#     that judged nothing must never be written down as green (unknown is not yes).
#
# What is real: the script, the git worktree of main's tip it builds, the suite lock, the JSON it writes.
# What is scripted: the fast path (a fixture `scripts/fast.sh` that writes the result file this row decides -
# no test may run the whole suite to test the recorder).
#
#   bash scripts/test-main-health.sh
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
script=$root/scripts/main-health.sh
# On a tree that does not have the script there is nothing to judge, and that is a SKIP the row names - not a
# pass and not a failure (scripts/test-discriminates.sh reads it that way): measured, an exit 2 here was
# `unclassified` and blocked the landing's discrimination check.
[ -f "$script" ] || { echo "SKIP test-main-health: this tree has no scripts/main-health.sh (nothing to judge)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP test-main-health: git is not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP test-main-health: jq is not on PATH"; exit 0; }

# ITS OWN HOME, and it refuses the operator's (rule 2).
work=$(TMPDIR=/tmp mktemp -d) || { echo "SKIP test-main-health: mktemp failed"; exit 0; }
trap 'rm -rf "$work"' EXIT
export HOME=$work/user WASM_AGENT_HOME=$work/node TMPDIR=$work/tmp
mkdir -p "$HOME" "$WASM_AGENT_HOME" "$TMPDIR" "$work/missions"
operator_home=${OPERATOR_NODE_HOME:-/home/$(id -un)/.wasm-agent}
case "$work" in
  "$operator_home"|"$operator_home"/*) echo "test-main-health: refused(real_node_home): $work is the operator's node home" >&2; exit 2 ;;
esac

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "test-main-health FAILED: $*" >&2; exit 1; }
git_c() { git -c user.email=test@example.invalid -c user.name=Test -c commit.gpgsign=false "$@"; }

repo=$work/repo
mkdir -p "$repo/scripts"
cd "$repo" || fail "cannot enter the fixture repository"
git_c init -q -b main . || fail "git init"
# The fixture fast path: it writes the result file scripts/fast.sh writes, with the verdict this row chooses in
# $MAIN_HEALTH_FIXTURE_VERDICT, and it proves it is running on a checkout of MAIN (the whole point).
cat > scripts/fast.sh <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
test "$(git rev-parse HEAD)" = "$(git rev-parse main)" || { echo "fixture: not on main's tip" >&2; exit 3; }
case "${MAIN_HEALTH_FIXTURE_VERDICT:-green}" in
  green) jq -n '{schema:1, summary:{checks:3, passed:3, failed:0, skipped:0, ok:true, exit_code:0}, checks:[{name:"alpha",status:"pass",first_error:""}]}' > "$WA_FAST_RESULT" ;;
  red)   jq -n '{schema:1, summary:{checks:3, passed:2, failed:1, skipped:0, ok:false, exit_code:1}, checks:[{name:"alpha",status:"pass",first_error:""},{name:"test-beta",status:"fail",first_error:"beta is stale"}]}' > "$WA_FAST_RESULT"; exit 1 ;;
  none)  exit 1 ;;
esac
exit 0
STUB
chmod +x scripts/fast.sh
printf 'base\n' > a.txt
git_c add -A >/dev/null && git_c commit -q -m base || fail "the base commit"
main_sha=$(git_c rev-parse main)

# `json`, not `out`: `out=$(run ...)` captures the script's own words, and a variable named for both made this
# row read its own stdout as if it were the file (measured while writing it).
json=$work/missions/main-health.json
run() { MAIN_HEALTH_FIXTURE_VERDICT=$1 bash "$script" --repo "$repo" --out "$json"; }

# ---- 1. green: the verdict is recorded, and it names the sha it judged -------------------------------
out=$(run green); rc=$?
[ "$rc" = 0 ] || fail "a green run exited $rc: $out"
ok
[ -f "$json" ] || fail "no main-health.json was written"
ok
eq_sha=$(jq -r '.sha' "$json")
[ "$eq_sha" = "$main_sha" ] || fail "the record names $eq_sha, not main's tip $main_sha"
ok
[ "$(jq -r '.ok' "$json")" = true ] || fail "a green run is not recorded ok: $(cat "$json")"
ok
[ "$(jq -r '.counts.checks' "$json")" = 3 ] || fail "the record lost the run's own counts: $(cat "$json")"
ok
[ "$(jq -r '.seconds >= 0' "$json")" = true ] || fail "the record lost the seconds"
ok
# The worktree the run built is gone: a health run must not leave trees behind (the 13/11 lesson).
[ "$(git -C "$repo" worktree list | grep -c "main-health") " = "0 " ] || fail "the health run left a worktree behind: $(git -C "$repo" worktree list)"
ok

# ---- 2. red: the row is named, with its first line, and the exit is non-zero ------------------------
out=$(run red); rc=$?
[ "$rc" = 1 ] || fail "a red run exited $rc, not 1: $out"
ok
[ "$(jq -r '.ok' "$json")" = false ] || fail "a red run is recorded green: $(cat "$json")"
ok
[ "$(jq -r '.failed[0].row' "$json")" = test-beta ] || fail "the red row is not named: $(cat "$json")"
ok
[ "$(jq -r '.failed[0].first_lines[0]' "$json")" = 'beta is stale' ] || fail "the row's first line is not kept: $(cat "$json")"
ok

# ---- 3. refused: no result file is NOT green --------------------------------------------------------
out=$(run none); rc=$?
[ "$rc" = 2 ] || fail "a run that wrote no result file exited $rc, not 2: $out"
ok
[ "$(jq -r '.ok' "$json")" = false ] || fail "a run that judged nothing is recorded green: $(cat "$json")"
ok
jq -r '.why' "$json" | grep -q 'no result file' || fail "the refusal is not named: $(cat "$json")"
ok

# ---- 4. refused by name when it cannot even start ---------------------------------------------------
out=$(bash "$script" --repo "$work/nowhere" --out "$json" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "a missing repository was not refused (exit $rc): $out"
ok
grep -qF 'refused(no_repo)' <<< "$out" || fail "the refusal does not name the cause: $out"
ok

# ---- 5. it is the caller's file, not a second opinion: it is never written when the run cannot be read -
before=$(jq -r '.sha' "$json")
out=$(bash "$script" --repo "$repo" --out "$work/never/x.json" --keep 2>&1 || true)
[ "$(jq -r '.sha' "$json" 2>/dev/null || echo bad)" = "$before" ] && ok

# ---- 6. the wiring: the driver runs it after a landing, at low priority, and --keep keeps the tree -----
# Read from the two scripts rather than from a run: this is the property that makes "main is green" true after
# every landing instead of only when someone remembers to measure.
grep -q 'main-health.sh' "$root/scripts/drive.sh" || fail "the driver does not start main-health after a landing"
ok
grep -q 'nice -n' "$root/scripts/main-health.sh" || fail "main-health does not run at a low priority"
ok
grep -q 'flock -o' "$root/scripts/main-health.sh" || fail "main-health does not take the suite lock (it would compete with a landing)"
ok

echo "test-main-health ok ($checks checks)"
