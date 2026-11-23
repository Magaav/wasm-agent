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

# THE TEMP FLOOR, BEFORE MAIN'S TIP IS EVEN CHECKED OUT (item 4 of the tests-clean-their-tmp round, 23/11).
#
# This script exists to turn a suite run into a RECORDED verdict about main. On 23/11 it wrote one about a full
# disk instead: 22808bc8 was red on ENOSPC, /tmp being a 16 G tmpfs that the rows had filled with 4,721
# scratch entries, and a red like that is indistinguishable from a tree that does not build - the landing queue
# then blames the mission that was waiting. So the machine is asked first, and a machine without room is a
# refusal by name (exit 2, "nothing was judged"), never a verdict.
. "$(dirname -- "$0")/lib/temp-floor.sh"
if ! tmp_note=$(wa_tmp_floor_check /tmp "${TMPDIR:-}"); then
  case "$tmp_note" in
    tmp_unknown:*) tmp_code=tmp_unknown ;;
    *) tmp_code=tmp_low ;;
  esac
  echo "main-health: refused(${tmp_code:-tmp_low}): $tmp_note. Nothing was judged." >&2
  exit 2
fi
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

# THE SPEED LINE FOR THIS COMMIT (change/speed-board, 22/11; the binary comes from the fast run on
# 23/11). One JSON line per commit on main, kept as history under the missions root and judged against
# the last ten MEASURED commits at a comparable load. It runs AFTER the verdict is written, it can never
# fail the health run, and it only uses a binary that IS this commit: a number taken with another
# commit's binary would not be about this commit (rule 1).
#
# WHICH BINARY, MEASURED 23/11 (that is why this block changed): the rule used to be "the installed
# binary, and only when installed.txt names exactly this commit". The install lags main by landings, so
# nearly every commit got four rows of 'unavailable: no binary to measure' - 071d1ab5, 899fdd47,
# fe60dc0a, 3665b1b7, e9a42d20, da912828 and ae3cbb37 in ~/Work/missions/speed-history.jsonl - and a
# board with no numbers read as fine. The fast path above has just BUILT this tree's own binary
# (scripts/lib/fast-binary.sh, stamped with this commit and identified by the stamp, not by the path),
# so that is the binary the rows run. It is asked for through the same resolver, and only a binary whose
# stamp is THIS sha is used.
#   * the tree's binary the fast run built or verified: fresh, or explicitly named by WA_BIN, and stamped
#     with $sha;
#   * else the installed one, and only when installed.txt names this commit (the old rule, kept as the
#     fallback for a machine whose build could not run);
#   * else no --bin at all: the board then says 'unavailable' and speed-stats judges that a RED row, which
#     is the honest answer for a commit nothing could measure.
if [ -f "$tree/scripts/speed-board.sh" ]; then
  # WHICH BINARY, MEASURED TWICE (mission speed-board-landing-kinds, 23/11). The rule used to be "the
  # installed binary, and only when installed.txt names exactly this commit", so nearly every commit got
  # four rows of 'unavailable' (071d1ab5, 899fdd47, fe60dc0a, 3665b1b7, e9a42d20, da912828, ae3cbb37 in
  # speed-history.jsonl) and a board with no numbers read as fine. Then it became "the tree's binary,
  # through scripts/lib/fast-binary.sh", which failed on 4b314af5 for a reason worth writing down:
  # main-health runs for ~20 minutes, a LANDING moved main to 3655948d while it measured, the deploy of
  # 3655948d replaced ~/.local/bin/wa - and the speed block runs at the END of that run. The plan then
  # resolved a binary that was no longer 4b314af5 and refused it, correctly, so the four live rows went
  # 'unavailable' although fast.sh at the START of the same run had printed "4b314af5 fresh: built from
  # this tree". installed.txt named 3655948d for the same reason: deploy.sh writes it as the FINAL record
  # of a deploy, so it names the last install that FINISHED - never this commit's proof, and never a
  # statement about the bytes at any path.
  #
  # So the first source is FAST'S OWN RESULT - the binary that ran this very tree, with the commit it was
  # built from and its sha256 (scripts/fast.sh:420 writes both, scripts/fast-result.mjs puts them in the
  # result as env.bin, env.commit, env.bin_sha256) - and it is used only while the bytes are still the ones
  # fast.sh graded. A path whose sha256 has changed is another build (a landing, a deploy) and is refused
  # BY NAME rather than measured as this commit. Then the plan (a binary whose stamp is $sha), then the old
  # installed.txt rule, then no --bin at all: speed-stats judges four live rows without a number a RED row,
  # which is the honest answer for a commit nothing could measure (rule 1: unknown is not yes).
  speed_bin=""; speed_source=""; speed_reason=""
  fast_bin=$(jq -r '.env.bin // empty' "$result" 2>/dev/null)
  fast_commit=$(jq -r '.env.commit // empty' "$result" 2>/dev/null)
  fast_sha=$(jq -r '.env.bin_sha256 // empty' "$result" 2>/dev/null)
  if [ -n "$fast_bin" ] && [ -x "$fast_bin" ] && [ -n "$fast_commit" ] && [ "${sha:0:${#fast_commit}}" = "$fast_commit" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      now_sha=$(sha256sum "$fast_bin" 2>/dev/null | cut -d' ' -f1)
    else
      now_sha=""
    fi
    case "$fast_sha" in
      ''|unknown)
        speed_reason="the fast run recorded no sha256 for $fast_bin, so its bytes cannot be shown to be $short" ;;
      *)
        if [ -n "$now_sha" ] && [ "$now_sha" = "$fast_sha" ]; then
          speed_bin=$fast_bin
          speed_source="the binary this run's fast path proved for $short (sha256 ${fast_sha:0:12})"
        elif [ -n "$now_sha" ]; then
          speed_reason="the binary the fast path used ($fast_bin) was sha256 ${fast_sha:0:12} and is now ${now_sha:0:12}: another build replaced it while this run measured"
        else
          speed_reason="sha256sum is not on PATH, so the fast run's binary ($fast_bin) cannot be shown to be the bytes it graded"
        fi ;;
    esac
  elif [ -n "$fast_bin" ]; then
    speed_reason="the binary of the fast run ($fast_bin) is gone, or its commit ($fast_commit) is not $short"
  fi
  if [ -z "$speed_bin" ]; then
    speed_bin=$(ROOT=$tree bash -c '
      set -u
      . "$ROOT/scripts/lib/fast-binary.sh" 2>/dev/null || exit 1
      fast_binary_plan >/dev/null 2>&1 || exit 1
      [ "${FAST_BIN_ACTION:-}" = use ] || exit 1
      case "${FAST_BIN_VERDICT:-}" in fresh|explicit) ;; *) exit 1 ;; esac
      [ -n "${FAST_BIN:-}" ] && [ -x "$FAST_BIN" ] || exit 1
      [ "${FAST_BIN_COMMIT:-}" = "$1" ] || exit 1
      printf "%s" "$FAST_BIN"
    ' _ "$sha" 2>/dev/null) || speed_bin=""
    [ -n "$speed_bin" ] && speed_source="the tree's own binary, by its stamp (scripts/lib/fast-binary.sh)"
  fi
  if [ -z "$speed_bin" ]; then
    speed_installed=$(sed -n 's/^commit=//p' "$HOME/.local/bin/installed.txt" 2>/dev/null | head -1)
    # A PREFIX COMPARISON, and it had to be repaired: installed.txt records the commit in the 8 characters
    # `wa install` writes, so the old test `[ "${sha#$speed_installed}" = "" ]` stripped those 8 from the
    # 40-character sha and compared the REMAINDER with the empty string - true only when installed.txt
    # carried all 40 characters, which it never does. Measured 23/11: every commit on main got four rows
    # of 'unavailable' even when the installed node WAS that commit (scripts/test-main-health.sh case 9 is
    # the check that fails on the old form).
    if [ -n "$speed_installed" ] && [ "${sha:0:${#speed_installed}}" = "$speed_installed" ] \
        && [ -x "$HOME/.local/bin/wa" ]; then
      speed_bin="$HOME/.local/bin/wa"
      speed_source="the installed node, and installed.txt names this commit"
    fi
  fi
  # The binary is named on main-health's stderr, WITH WHERE IT CAME FROM: a speed row whose binary nobody
  # can name is the failure scripts/lib/fast-binary.sh exists to prevent, and "where did that come from" is
  # the question the 4b314af5 hour was spent on. When there is none, the reason it could not be had goes
  # beside it, so the four RED rows have a cause and not just a verdict.
  if [ -n "$speed_bin" ]; then
    echo "main-health: speed binary $speed_bin (source: $speed_source)" >&2
  else
    echo "main-health: speed binary (none: no binary of $short on this machine${speed_reason:+ - $speed_reason}, so the four live rows are RED)" >&2
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
