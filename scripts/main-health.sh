#!/usr/bin/env bash
# "main is green" as a RECORDED FACT: run the full fast path once on main's own tip and write the verdict down.
#
#   bash scripts/main-health.sh [--repo <checkout>] [--out <file>] [--keep]
#
# WHY THIS EXISTS (21/11). Main was red from bfad4f8f on `lua5.4 scripts/gen-refusal-codes.lua --check` and
# nothing said so: land243 and land244 were green (their narrowed gates never ran the row), land245 was the
# first round whose rows included it and it went red TWICE for a fault it had not made (855 s), then sat
# stopped for 40+ minutes while ten finished missions waited. Every one of those landings judged a mission
# against a main nobody had measured. So after every landing this runs the whole fast path against the tip
# that landing produced, at low priority and under the suite lock, and writes:
#
#   ~/Work/missions/main-health.json  {sha, ok, failed:[{row, first_lines}], seconds, at, ...}
#
# The preflight and the landing then compare a red row with this file: a row that is red on main ALONE is
# reported as MAIN RED and is not counted against the mission (scripts/preflight.sh). status.sh prints it on
# its first line. Nothing here changes a tree: it reads main, builds a scratch worktree of it, runs the suite
# there and deletes the worktree again.
#
# Exit: 0 green, 1 red, 2 refused (nothing was judged - and an unknown verdict is never written as green).
#
# Environment:
#   WA_MAIN_HEALTH_REPO   the checkout whose `main` is measured (default $HOME/wasm-agent/checkout)
#   WA_MAIN_HEALTH_OUT    where the verdict is written (default <missions root>/main-health.json, then
#                         $HOME/Work/missions/main-health.json)
#   WA_MAIN_HEALTH_ROOT   where the scratch worktree lives (default $HOME/.wasm-agent/main-health)
#   WA_SUITE_LOCK         the suite lock (default <missions root>/.suite.lock)
#   WA_MAIN_HEALTH_NICE   the priority (default 19: a health run never competes with a landing)
#   WA_MAIN_HEALTH_KEEP=1 keep the scratch worktree (for reading a red row's own log)
set -uo pipefail
usage() { sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
repo=${WA_MAIN_HEALTH_REPO:-$HOME/wasm-agent/checkout}
out=${WA_MAIN_HEALTH_OUT:-}
root=${WA_MAIN_HEALTH_ROOT:-$HOME/.wasm-agent/main-health}
missions=${WA_MISSIONS_ROOT:-$HOME/Work/missions}
lock=${WA_SUITE_LOCK:-$missions/.suite.lock}
nice_level=${WA_MAIN_HEALTH_NICE:-19}
keep=0
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || { echo "main-health: refused(value_missing): --repo needs a directory" >&2; exit 2; }; repo=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || { echo "main-health: refused(value_missing): --out needs a file" >&2; exit 2; }; out=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "main-health: refused(unknown_argument): $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || out=$missions/main-health.json

# WHAT THIS CANNOT DO WITHOUT, refused by name rather than half-done: without git there is no tip to measure,
# without the lock this run would compete with a landing (19/11: load 105 on 16 cores, timing rows red at
# random), and without a way to read the result file the verdict would be a guess about a log.
for tool in git flock nice; do
  command -v "$tool" >/dev/null 2>&1 || { echo "main-health: refused(tool_missing): $tool is not on PATH, so nothing can be judged" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "main-health: refused(jq_missing): jq is not on PATH, so the result file cannot be read" >&2; exit 2; }
[ -d "$repo/.git" ] || [ -f "$repo/.git" ] || { echo "main-health: refused(no_repo): $repo is not a git checkout" >&2; exit 2; }
sha=$(git -C "$repo" rev-parse --verify -q main 2>/dev/null) || {
  echo "main-health: refused(no_main): $repo has no main to measure" >&2; exit 2; }
short=${sha:0:12}

mkdir -p "$root" "$(dirname "$out")" || { echo "main-health: refused(root_unwritable): $root or $out" >&2; exit 2; }
# THE LOCK'S DIRECTORY TOO: flock cannot open a file in a directory that is not there, and the answer would
# then be "no result file" about a run that never started (measured: a scratch home with no missions root).
mkdir -p "$(dirname "$lock")" 2>/dev/null || { echo "main-health: refused(lock_unwritable): $(dirname "$lock")" >&2; exit 2; }
tree=$root/wt-$short-$$
cleanup() {
  if [ "$keep" = 1 ]; then echo "main-health: kept $tree"; return; fi
  git -C "$repo" worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A SCRATCH WORKTREE OF MAIN'S TIP: the suite always runs in a tree of its own, so a run that writes (a
# result file, a build child) cannot touch the operator's checkout.
git -C "$repo" worktree add --quiet --detach "$tree" "$sha" >/dev/null 2>&1 || {
  echo "main-health: refused(worktree_failed): cannot check out $sha into $tree" >&2; exit 2; }
result=$root/fast-result-$short.json
rm -f "$result"
started=$(date +%s)
WA_FAST_RESULT=$result WA_FAST_KEEP_LOGS=$root/fast-logs-$short \
  flock -o "$lock" nice -n "$nice_level" bash -c "cd '$tree' && bash scripts/fast.sh" \
  > "$root/fast-$short.log" 2>&1
rc=$?
seconds=$(( $(date +%s) - started ))

# THE VERDICT COMES FROM THE RUNNER'S OWN RESULT FILE, never from the exit code alone: a run that wrote no
# result file judged nothing, and that is `ok: false` with a named why (unknown is not yes).
now=$(date -u +%FT%TZ)
if [ ! -f "$result" ]; then
  jq -n --arg sha "$sha" --arg at "$now" --argjson seconds "$seconds" --argjson rc "$rc" \
    --arg log "$root/fast-$short.log" \
    '{schema:1, sha:$sha, ok:false, failed:[{row:"main-health", first_lines:["the fast path wrote no result file (exit " + ($rc|tostring) + ")"]}], seconds:$seconds, at:$at, log:$log, why:"no result file: nothing was judged"}' \
    > "$out" 2>/dev/null || printf '{"schema":1,"sha":"%s","ok":false,"failed":[],"seconds":%s,"why":"no result file and jq could not write the verdict"}\n' "$sha" "$seconds" > "$out"
  echo "main-health: REFUSED(no_result): the fast path wrote no result file (exit $rc); log $root/fast-$short.log" >&2
  exit 2
fi

jq --arg sha "$sha" --arg at "$now" --argjson seconds "$seconds" \
   --arg log "$root/fast-$short.log" --arg result "$result" '
  {schema: 1, sha: $sha, at: $at, seconds: $seconds, log: $log, result: $result,
   ok: ((.summary.ok == true) and ((.summary.failed // 1) == 0)),
   counts: {checks: (.summary.checks // null), passed: (.summary.passed // null), failed: (.summary.failed // null), skipped: (.summary.skipped // null)},
   failed: [ (.checks // [])[] | select(.status == "fail") | {row: .name, first_lines: [ (if (.first_error // "") == "" then "(the row printed no first line)" else .first_error end) ]} ] }
' "$result" > "$out.tmp" && mv "$out.tmp" "$out" || {
  echo "main-health: refused(write_failed): cannot write $out" >&2; exit 2; }

# THE SPEED LINE FOR THIS COMMIT (change/speed-board, 22/11). One JSON line per commit on main, kept as
# history under the missions root and judged against the last ten commits at a comparable load. It runs
# AFTER the verdict is written, it can never fail the health run, and it only uses a binary that IS this
# commit: a scratch worktree has none of its own, and a number taken with another commit's binary would
# not be about this commit (the row says 'unavailable: no binary to measure' instead - rule 1).
if [ -f "$tree/scripts/speed-board.sh" ]; then
  speed_bin=""
  speed_installed=$(sed -n 's/^commit=//p' "$HOME/.local/bin/installed.txt" 2>/dev/null | head -1)
  if [ -n "$speed_installed" ] && [ "${sha#$speed_installed}" = "" ] && [ -x "$HOME/.local/bin/wa" ]; then
    speed_bin="$HOME/.local/bin/wa"
  fi
  speed_args=(--measure --root "$tree" --sha "$sha")
  [ -n "$speed_bin" ] && speed_args+=(--bin "$speed_bin")
  WA_MISSIONS_ROOT="$missions" bash "$tree/scripts/speed-board.sh" "${speed_args[@]}" \
    >> "$root/speed-$short.log" 2>&1 || true
  # The board's own last line, and any RED row, on stderr: main-health's stdout stays its one verdict.
  grep -E '^speed-board:' "$root/speed-$short.log" 2>/dev/null | tail -n 8 | sed 's/^/main-health: /' >&2 || true
fi

ok=$(jq -r '.ok' "$out" 2>/dev/null)
rows=$(jq -r '(.failed // []) | map(.row) | join(" ")' "$out" 2>/dev/null)
if [ "$ok" = true ]; then
  echo "main-health: green at $short ($seconds s, $(jq -r '.counts.checks // "?"' "$out") checks) -> $out"
  exit 0
fi
echo "main-health: MAIN RED at $short: $rows ($seconds s) -> $out"
exit 1
