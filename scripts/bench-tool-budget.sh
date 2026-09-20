#!/usr/bin/env bash
# Does the tool-context budget change how well the agent works?
#
#   bash scripts/bench-tool-budget.sh [runs-per-arm]     # default 3
#
# The claim under test: a 600-character view of a tool result costs extra rounds
# and some failed calls, because the agent acts on a keyhole and only discovers it
# when an edit misses. The claim is measured the only honest way - same task, same
# model, same fixture, with WASM_AGENT_TOOL_BUDGET as the single variable.
#
# The fixture is a file whose interesting line sits well past 600 characters, and
# the task spans two turns: the first read is what gets persisted, the second turn
# is where the agent has to act on what it can see. Within one turn the whole
# result is in the message list either way, so a single-turn task would measure
# nothing - the keyhole only opens on the turn after the read.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${WA_BIN:-rust/target/release/wa}"
RUNS="${1:-3}"
WORK="$(mktemp -d /tmp/wa-bench-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$BIN" ]; then echo "no binary at $BIN" >&2; exit 1; fi

# --- the fixture ---------------------------------------------------------------
# 40 filler lines put M.CONFIG_LIMIT at roughly 2.4 KB: far past the legacy 600
# window, comfortably inside the 8000 the read tool now gets. The last function is
# past the window too, so turn one has to be answered from a full read.
gen_fixture() {
  local path="$1"
  {
    echo "-- generated fixture: the interesting lines are past the 600-character window"
    echo "local M = {}"
    echo ""
    local i=0
    while [ "$i" -lt 40 ]; do
      printf -- "-- filler %02d: %s\n" "$i" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      i=$((i + 1))
    done
    echo ""
    echo "M.CONFIG_LIMIT = 10"
    echo "function M.last() return 'the_last_function' end"
    echo ""
    echo "return M"
  } > "$path"
}

# --- metrics from the recorded transcript --------------------------------------
# Failures and calls come from the database, not from parsing the CLI output: the
# record is the thing under discussion, so measure the record.
measure() {
  local db="$1"
  cat > "$WORK/probe.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local json = dofile("lua/vendor/json.lua")
memory.setup()
local calls, failed = 0, 0
for _, session in ipairs(memory.list_sessions(nil, 10)) do
  for _, turn in ipairs(memory.session_messages(session.id, { limit = 2000 })) do
    if turn.role == "assistant" and type(turn.tool_calls) == "table" then
      calls = calls + #turn.tool_calls
    elseif turn.role == "tool" then
      local ok, decoded = pcall(json.decode, turn.content or "")
      if ok and type(decoded) == "table" and decoded.error then failed = failed + 1 end
    end
  end
end
print(calls .. " " .. failed)
LUA
  WA_SCRIPT="$WORK/probe.lua" "$BIN" --db "$db" 2>/dev/null | tail -1
}

run_one() {
  local arm="$1" mode="$2" index="$3"
  local dir="$WORK/$arm-$index"
  local db="$dir/bench.db"
  mkdir -p "$dir"
  gen_fixture "$dir/target.lua"
  export WASM_AGENT_TOOL_BUDGET="$mode"

  local started ended
  started=$(date +%s)
  # Turn 1: read the file. This is the read that gets persisted.
  printf 'read %s and tell me in one line what the last function in it returns\n/exit\n' "$dir/target.lua" \
    | "$BIN" --db "$db" chat > "$dir/turn1.txt" 2>&1
  # Turn 2: act on what you can see. The keyhole, if there is one, is here.
  printf 'change M.CONFIG_LIMIT from 10 to 20 in %s, then confirm in one line\n/exit\n' "$dir/target.lua" \
    | "$BIN" --db "$db" chat --continue > "$dir/turn2.txt" 2>&1
  ended=$(date +%s)

  local edited=0
  grep -q "M.CONFIG_LIMIT = 20" "$dir/target.lua" && edited=1
  local metrics calls failed
  metrics="$(measure "$db")"
  calls="$(echo "$metrics" | awk '{print $1}')"
  failed="$(echo "$metrics" | awk '{print $2}')"
  printf '  %-8s run %d   edited=%s  calls=%-3s failed=%-3s %ss\n' \
    "$arm" "$index" "$edited" "${calls:-?}" "${failed:-?}" "$((ended - started))"
  echo "$edited ${calls:-0} ${failed:-0}" >> "$WORK/$arm.tsv"
}

echo
echo "tool-context budget benchmark"
echo "  binary $BIN"
echo "  fixture: M.CONFIG_LIMIT at ~2.4 KB, past the legacy 600-character window"
echo "  task: turn 1 reads the file, turn 2 edits the line it saw"
echo

: > "$WORK/legacy.tsv"
: > "$WORK/default.tsv"
for index in $(seq 1 "$RUNS"); do run_one legacy legacy "$index"; done
unset WASM_AGENT_TOOL_BUDGET
for index in $(seq 1 "$RUNS"); do run_one default default "$index"; done

summarize() {
  local arm="$1"
  awk -v arm="$arm" '
    { edited += $1; calls += $2; failed += $3; n += 1 }
    END { if (n == 0) exit
          printf "  %-8s  edited %d/%d   calls %.1f   failed %.1f   (%d runs)\n",
                 arm, edited, n, calls / n, failed / n, n }' "$WORK/$arm.tsv"
}
echo
echo "summary"
summarize legacy
summarize default
echo
legacy_calls=$(awk '{c+=$2; n+=1} END {if (n) printf "%.1f", c/n}' "$WORK/legacy.tsv")
default_calls=$(awk '{c+=$2; n+=1} END {if (n) printf "%.1f", c/n}' "$WORK/default.tsv")
legacy_failed=$(awk '{f+=$3; n+=1} END {if (n) printf "%.1f", f/n}' "$WORK/legacy.tsv")
default_failed=$(awk '{f+=$3; n+=1} END {if (n) printf "%.1f", f/n}' "$WORK/default.tsv")
echo "  legacy ${legacy_calls} calls / ${legacy_failed} failed per run; default ${default_calls} / ${default_failed}"
echo "  (calls and failures are the cost; a diligent model can recover from the"
echo "   keyhole by re-reading, which is exactly what shows up as extra calls)"
