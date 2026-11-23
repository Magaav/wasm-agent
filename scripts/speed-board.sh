#!/usr/bin/env bash
# THE SPEED BOARD: what this node's speed costs, one line per commit, and which row went red.
#
#   bash scripts/speed-board.sh --measure [--bin <wa>] [--root <tree>] [--sha <commit>] [--samples 5]
#   bash scripts/speed-board.sh --print   [--sha <commit>]
#   bash scripts/speed-board.sh --check   [--sha <commit>]
#
# WHERE IT RUNS. scripts/main-health.sh calls --measure once for the tip a landing produced, so EVERY
# commit on main gets a line; status.sh calls --print, so Victor reads the table for the commit this
# laptop runs and the change against the one before it (FACTORY rule 7: one call, no polling).
#
# THE ROWS (scripts/lib/speed-stats.lua names and judges them):
#   start            process start -> the prompt is up, in a pty       (scripts/speed/probe-cold-start.py)
#   first_token      Enter -> the first model byte, local fixture      (scripts/speed/probe-first-token.py)
#   tool_roundtrip   one tools.read inside run(code=...)               (scripts/speed/probe-tool-roundtrip.lua)
#   remote_roundtrip one signed peer call to a scratch node            (scripts/speed/probe-remote.sh)
#   landing          branch approved -> "Local is evolved"             (land-quick's own record)
#   release          cut -> published                                  (the release journal)
#
# HOW A NUMBER IS MADE STABLE, because a timing row that flakes is worse than no row (22/11: a single
# sample under load stopped suites twice):
#   * MEDIAN of the samples, never a single sample and never the mean;
#   * ONE WARM-UP DISCARDED per row where the first call pays a process's own cold state;
#   * the MACHINE LOAD is recorded beside every row, and a row above the ceiling
#     (1.5 load units per core) is recorded as 'guarded' instead of measured - a number taken at load
#     12 on 16 cores is a property of the machine, not of the commit;
#   * a row is only compared with rows at a COMPARABLE load (scripts/lib/speed-stats.lua), and a row
#     with fewer than three samples is 'unknown', never a pass.
#
# NOTHING HERE BLOCKS A LANDING. A landing runs no suite and no gate; this runs after it, with the
# numbers written down. A RED row is a brief for the orchestrator, not a refusal.
#
# EVERY PROBE RUNS IN ITS OWN SCRATCH HOME and refuses the operator's own (each probe refuses by itself;
# the fixture nodes are scratch nodes on loopback, never the fleet).
set -uo pipefail
root_default="$(cd "$(dirname "$0")/.." && pwd)"
root="$root_default"
probes="${WA_SPEED_PROBES:-$root/scripts/speed}"
missions="${WA_MISSIONS_ROOT:-$HOME/Work/missions}"
history="${WA_SPEED_HISTORY:-$missions/speed-history.jsonl}"
samples="${WA_SPEED_SAMPLES:-5}"
bin="${WA_SPEED_BIN:-}"
sha="${WA_SPEED_SHA:-}"
mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --measure|--print|--check) mode="${1#--}"; shift ;;
    --bin) bin=${2:?}; shift 2 ;;
    --root) root=${2:?}; shift 2 ;;
    --probes) probes=${2:?}; shift 2 ;;
    --history) history=${2:?}; shift 2 ;;
    --sha) sha=${2:?}; shift 2 ;;
    --samples) samples=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "speed-board: refused(unknown_argument): $1" >&2; exit 2 ;;
  esac
done
[ -n "$mode" ] || { echo "speed-board: refused(no_mode): say --measure, --print or --check" >&2; exit 2; }
[ -n "$probes" ] || probes="$root_default/scripts/speed"
for tool in lua5.4 jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "speed-board: refused(tool_missing): $tool is not on PATH, so nothing can be judged" >&2; exit 2; }
done
stats="$root_default/scripts/lib/speed-stats.lua"
[ -f "$stats" ] || { echo "speed-board: refused(stats_missing): $stats" >&2; exit 2; }
# THE LIBRARY READS lua/vendor/json.lua BY A RELATIVE PATH (it is a plain Lua module: no host, no tree), so
# every call to it runs from THIS board's tree rather than from wherever the caller started the board.
# MEASURED 23/11, in this mission's own end-to-end run: main-health started from a directory outside the
# tree measured four rows and then wrote nothing - `speed-board: refused(history_write_failed)` - because
# the json module could not be found from there. A board that measures and cannot write is the hole this
# mission exists to close, so the call, not the caller, decides the directory.
stats_lua() { ( cd "$root_default" && lua5.4 "$stats" "$@" ); }
cores=$(nproc 2>/dev/null || echo 1)
# The load this machine is under. WA_SPEED_LOAD overrides it: the tests need a load they can name, and a
# machine whose loadavg cannot be read must say 0 rather than crash the board.
load_now() { if [ -n "${WA_SPEED_LOAD:-}" ]; then printf '%s' "$WA_SPEED_LOAD"; return; fi; cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0; }

# Which commit the table is about: what the caller said, else what this laptop has installed, else the
# tree's own HEAD. An unknown commit is NAMED rather than printed as a number for somebody else.
if [ -z "$sha" ]; then
  sha=$(sed -n 's/^commit=//p' "$HOME/.local/bin/installed.txt" 2>/dev/null | head -1)
fi
if [ -z "$sha" ]; then
  sha=$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null || true)
fi
[ -n "$sha" ] || { echo "speed-board: refused(no_commit): no --sha, nothing installed and no HEAD in $root" >&2; exit 2; }

if [ "$mode" = print ]; then
  stats_lua table "$history" "$sha"
  exit 0
fi

if [ "$mode" = check ]; then
  entry=$(stats_lua last "$history")
  [ -n "$entry" ] || { echo "speed-board: no history at $history yet - nothing was judged" >&2; exit 2; }
  # The newest line's verdict, then its red rows by name and by commit. Nothing is printed as green that
  # was not measured (rule 1).
  stats_lua table "$history" "$entry" | sed -n '/RED/,$p'
  if stats_lua table "$history" "$entry" | grep -q 'RED'; then exit 3; fi
  exit 0
fi

# ---- --measure -----------------------------------------------------------------------------------
# The history file's directory must exist before anything is written: a board that measured four rows and
# then could not write them would be a number nobody can compare (and the next landing would measure again).
mkdir -p "$(dirname "$history")" || { echo "speed-board: refused(history_unwritable): $(dirname "$history")" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/speed-board-XXXXXX") || { echo "speed-board: refused(no_scratch)" >&2; exit 2; }
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/rows"
load_before=$(load_now)
ceiling=$(lua5.4 -e "local s=dofile('$stats'); print(s.load_ceiling($cores))" 2>/dev/null || echo 0)

row_file() { printf '%s/rows/%s.json' "$work" "$1"; }

# A row from samples this harness collected: the median is the library's, never this script's.
write_row() { # write_row <name> <state> <load> <samples-csv> <reason>
  local name=$1 state=$2 load=$3 csv=$4 reason=${5:-}
  jq -n --arg name "$name" --arg state "$state" --arg reason "$reason" --argjson load "${load:-0}"      --argjson samples "$(printf '%s' "$csv" | jq -R -s 'split(",") | map(select(length > 0) | tonumber)')"      '{($name): {samples: $samples, load: $load, state: $state, reason: (if $reason == "" then null else $reason end)}}'      > "$(row_file "$name")"
}

# A row that was not measured, and why. NEVER a zero: a row with no number is not a fast row (rule 1).
skip_row() { # skip_row <name> <state> <reason> [<load>]
  jq -n --arg name "$1" --arg state "$2" --arg reason "$3" --argjson load "${4:-0}"      '{($name): {load: $load, state: $state, reason: $reason}}' > "$(row_file "$1")"
}

measure_row() { # measure_row <name> <probe base name>
  # The runner follows the FILE, not a list written here: a probe rewritten from bash to python keeps
  # the row it measures, and the tests can hand the harness their own probes in a scratch directory.
  local name=$1 base=$2 probe="" kind="" ext out="$work/$1.out" err="$work/$1.err" rc started ended
  for ext in sh py lua; do
    if [ -f "$probes/$base.$ext" ]; then probe="$probes/$base.$ext"; kind=$ext; break; fi
  done
  if [ -z "$probe" ]; then skip_row "$name" unavailable "no probe named $base in $probes"; return; fi
  if [ -n "$guard" ]; then skip_row "$name" guarded "the machine was at load $load_before on $cores cores (ceiling $ceiling): a number now would measure the machine"; return; fi
  started=$(load_now)
  case "$kind" in
    lua) WA_SCRIPT="$probe" WASM_AGENT_HOME="$work/home" WASM_AGENT_LUA_ROOT="$root"             WA_SPEED_SAMPLES="$samples" WA_SPEED_READ_PATH="$root/lua/core/memory.lua"             "$bin" --db "$work/home/$1.db" > "$out" 2> "$err" ;;
    py)  python3 "$probe" --bin "$bin" --root "$root" --samples "$samples" > "$out" 2> "$err" ;;
    sh)  bash "$probe" --bin "$bin" --root "$root" --samples "$samples" > "$out" 2> "$err" ;;
    *)   skip_row "$name" unavailable "no runner for $kind"; return ;;
  esac
  rc=$?
  ended=$(load_now)
  local csv reason
  csv=$(sed -n 's/^sample [0-9][0-9]* \([0-9][0-9]*\)$/\1/p' "$out" | paste -sd, -)
  if [ "$rc" -ne 0 ]; then
    # The probe says 'unavailable: <why>'; the row already says ` + "`unavailable`" + ` in its state, so the
    # prefix is dropped here and the table reads 'unavailable: <why>' instead of 'unavailable: unavailable'.
    reason=$(grep -m1 '^unavailable:' "$err" 2>/dev/null | sed 's/^unavailable: *//' | cut -c1-240)
    [ -n "$reason" ] || reason=$(head -1 "$err" 2>/dev/null | cut -c1-240)
    [ -n "$reason" ] || reason="the probe exited $rc and said nothing"
    skip_row "$name" unavailable "$reason" "$ended"
    return
  fi
  if [ -z "$csv" ]; then skip_row "$name" unknown "the probe printed no sample line" "$ended"; return; fi
  # The row's load is the WORST of its own window: if the machine got busy while it ran, that is the load
  # the number was taken at, and the judge must see it.
  local load
  load=$(python3 -c "print(max(float('$started'), float('$ended')))" 2>/dev/null || echo "$ended")
  write_row "$name" ok "$load" "$csv"
}

# A RECORD, not a measurement: these two rows are written by the thing that did the work (land-quick, the
# release journal), so the board only reads them back. Their load is the load at the moment they happened
# where the record carries it, and the board's own load where it does not - said in the row's reason, so a
# reader never mistakes a proxy for a measurement.
record_landing() {
  local file="${WA_SPEED_LANDINGS:-$missions/_quick/landings.jsonl}" line seconds load
  line=$(grep -v '^[[:space:]]*$' "$file" 2>/dev/null | tail -1)
  if [ -z "$line" ]; then skip_row landing unknown "no landing recorded in $file yet"; return; fi
  seconds=$(printf '%s' "$line" | jq -r '.seconds // empty' 2>/dev/null)
  load=$(printf '%s' "$line" | jq -r '.load // empty' 2>/dev/null)
  if [ -z "$seconds" ]; then skip_row landing unknown "the newest line of $file carries no seconds"; return; fi
  local ms=$(python3 -c "print(round(float('$seconds') * 1000))")
  jq -n --argjson ms "$ms" --argjson load "${load:-$load_before}"      '{landing: {ms: $ms, samples: [$ms], load: $load, state: "ok",
      reason: (if $load == 0 then "the load beside it is the board own, the landing record carries none" else null end)}}'      > "$(row_file landing)"
}

record_release() {
  local journal
  journal=$(ls -t "$HOME"/.wasm-agent/land/release-*/journal.json 2>/dev/null | head -1)
  if [ -z "$journal" ]; then skip_row release unknown "no release journal on this machine yet"; return; fi
  local done created updated
  done=$(jq -r '.result // empty' "$journal" 2>/dev/null)
  created=$(jq -r '.created_at // empty' "$journal" 2>/dev/null)
  updated=$(jq -r '.updated_at // empty' "$journal" 2>/dev/null)
  if [ "$done" != done ] || [ -z "$created" ] || [ -z "$updated" ]; then
    skip_row release unknown "the newest release journal ($(basename "$(dirname "$journal")")) is not a finished release"; return
  fi
  local ms=$(( (updated - created) * 1000 ))
  jq -n --argjson ms "$ms" --argjson load "$load_before" --arg journal "$(basename "$(dirname "$journal")")"      '{release: {ms: $ms, samples: [$ms], load: $load, state: "ok",
      reason: ("cut -> published from " + $journal + "; the load beside it is the board own, the journal carries none")}}'      > "$(row_file release)"
}

# THE LOAD GUARD IS A GUARD, NOT A SKIP: above the ceiling the four live rows are recorded as guarded with
# the reason and no number, and the two records are still written (they cost nothing and are facts).
guard=""
if python3 -c "import sys; sys.exit(0 if float('$load_before') > float('$ceiling') else 1)" 2>/dev/null; then guard=1; fi

if [ -z "$guard" ]; then
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    for row in start first_token tool_roundtrip remote_roundtrip; do
      skip_row "$row" unavailable "no binary to measure (pass --bin; a scratch worktree has none)"
    done
  else
    measure_row start probe-cold-start
    measure_row first_token probe-first-token
    measure_row tool_roundtrip probe-tool-roundtrip
    measure_row remote_roundtrip probe-remote
  fi
else
  for row in start first_token tool_roundtrip remote_roundtrip; do
    skip_row "$row" guarded "the machine was at load $load_before on $cores cores (ceiling $ceiling)"
  done
fi
record_landing
record_release

rows=$(jq -s 'add' "$work"/rows/*.json)
entry_file="$work/entry.json"
jq -n --arg sha "$sha" --arg at "$(date -u +%FT%TZ)" --argjson load "$load_before" --argjson cores "$cores"    --argjson rows "$rows" '{schema: 1, sha: $sha, at: $at, load: $load, cores: $cores, rows: $rows}'    > "$entry_file" || { echo "speed-board: refused(entry_build_failed)" >&2; exit 2; }

# THE MEDIAN IS THE LIBRARY'S: the entry is handed to speed-stats, which fills every row's ms from its
# samples before anything is written.
stats_lua finish "$entry_file" > "$work/finished.json" 2>/dev/null && mv "$work/finished.json" "$entry_file"

stats_lua append "$history" "$entry_file" > /dev/null || { echo "speed-board: refused(history_write_failed)" >&2; exit 2; }
verdict_file="$(dirname "$history")/speed-verdict.json"
stats_lua judge "$history" "$entry_file" > "$verdict_file" 2>/dev/null || verdict_file=""

# The line the orchestrator reads, and the RED rows by name. A guarded or unavailable row is printed with
# its reason: a speed board that hid what it could not measure would be the thing this mission exists to
# replace. And a hole in one of the four LIVE rows is RED itself (speed-stats judges it so, 23/11): a
# board whose rows are all 'unavailable' must not read as fine, so it exits 3 with the row and the reason
# named, exactly like a row that got slower.
summary=$(jq -r '[.rows | to_entries[] | .key + "=" + (if .value.state == "ok" then ((.value.ms|tostring) + "ms@" + ((.value.load // 0)|tostring)) else .value.state end)] | join(" ")' "$entry_file" 2>/dev/null)
echo "speed-board: $(printf '%s' "$sha" | cut -c1-12) $summary (load $load_before)"
if [ -n "$verdict_file" ]; then
  red=$(jq -r '.rows[] | select(.red == true) | if .hole == true then "\(.name): \(.state) - \(.reason // "no number and no reason")" else "\(.name): \(.ms) ms, \(.delta_pct * 10 | round / 10)% slower than the best of the last 10 commits at a comparable load (\(.best_ms) ms at \(.best_sha[0:12]))" end' "$verdict_file" 2>/dev/null)
  if [ -n "$red" ]; then
    printf '%s\n' "$red" | sed 's/^/speed-board: RED /'
    exit 3
  fi
fi
exit 0
