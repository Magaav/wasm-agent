#!/usr/bin/env bash
# model-facing-diff - what did this change cost the MODEL? One table, base vs tip, on one fixed task set.
#
# ITEM model-facing-changes-are-measured (Victor 25/11): "patches and improvements must be model agnostic... how will we
# ensure we are not making things worse for models?" The answer this command gives is numbers, not a feeling:
#
#   scripts/model-facing-diff.sh <base> <tip>
#
# Each ref is checked out into a scratch worktree, the SAME task set runs against both with the same provider, the same
# reply script and its own scratch home, and one table prints per task:
#
#   request   bytes of the FIRST request of the task - the healthy call. A difference is a prompt-cache miss for every
#             caller, so a change that moves it says why in its report
#   prompt    the system prompt's content bytes (what the model reads before a word of the task)
#   tools     the tool declaration array's JSON bytes (any GROWTH needs Victor's word: the model-agnostic rule)
#   result    the tool-result bytes the model was handed back (0 for a task that calls no tool)
#   k-in/k-out kilobytes the provider saw (tokens are ~4 bytes each; these are BYTES, labelled, not a bill)
#   rounds    completion requests the task took
#   wall      milliseconds from start to exit
#
# Each cell is marked `=` same, `<` better for the model (fewer bytes, fewer rounds, less time) or `>` worse. The exit is
# 1 when any cell is worse, 0 when none is, so a brief can hold it as a gate.
#
# WHICH LAYER MOVES. Two layers can change what a model reads, and the command measures whichever pair you name:
#   * the LUA tree - `model-facing-diff.sh <base> <tip>` swaps the tree and runs both sides on ONE binary. Rounds, tool
#     results and kilobytes move here (measured 28/11: a description edit in lua/core/tools.lua moves nothing, because the
#     catalogue the wire carries is built by the host);
#   * the BINARY - add --base-bin <wa> --tip-bin <wa> to compare a rebuilt host against the old one. That is the pair that
#     moves the system prompt and the tool declaration bytes.
#
# PROVIDERS. By default the tasks are answered by scripts/lib/measuring-provider.py - a replay that writes down what each
# request cost, so there is no network, no account and no drift. `--provider <name>` runs the SAME task set against a
# provider in the node's registry instead (opencode-go today, claude-cli when it lands): that is how two MODELS are compared
# on one task set. A real provider's wire is not ours to record, so with --provider the byte columns read `-` and the run
# reports rounds, kilobytes and wall time only.
#
#   --tasks <file>   the task set (default scripts/model-tasks/tasks.json)
#   --json <file>    also write the rows as JSON
#   --keep           keep the scratch dir and print it
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=${WA_BIN:-}
if [ -z "$BIN" ]; then
  if [ -x "$ROOT/rust/target/release/wa" ]; then BIN="$ROOT/rust/target/release/wa"
  elif command -v wa >/dev/null 2>&1; then BIN=$(command -v wa)
  else printf 'model-facing-diff: no wa binary (build it, or set WA_BIN)\n' >&2; exit 2; fi
fi

BASE=""; TIP=""; TASKS="$ROOT/scripts/model-tasks/tasks.json"; JSON_OUT=""; PROVIDER=""; KEEP=0
BASE_BIN=""; TIP_BIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tasks) TASKS=${2:?}; shift 2 ;;
    --json) JSON_OUT=${2:?}; shift 2 ;;
    --provider) PROVIDER=${2:?}; shift 2 ;;
    --base-bin) BASE_BIN=${2:?}; shift 2 ;;
    --tip-bin) TIP_BIN=${2:?}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) printf 'model-facing-diff: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) if [ -z "$BASE" ]; then BASE=$1; elif [ -z "$TIP" ]; then TIP=$1
       else printf 'model-facing-diff: too many arguments\n' >&2; exit 2; fi; shift ;;
  esac
done
if [ -z "$BASE" ] || [ -z "$TIP" ]; then
  printf 'usage: scripts/model-facing-diff.sh <base> <tip> [--provider NAME] [--tasks FILE] [--json FILE]\n' >&2
  exit 2
fi
[ -f "$TASKS" ] || { printf 'model-facing-diff: no task set at %s\n' "$TASKS" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/model-facing-diff.XXXXXX") || exit 2
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
  if [ "$KEEP" = 1 ]; then printf 'model-facing-diff: scratch kept at %s\n' "$WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

for side in base tip; do
  ref=$([ "$side" = base ] && printf '%s' "$BASE" || printf '%s' "$TIP")
  git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || { printf 'model-facing-diff: %s is not a commit in %s\n' "$ref" "$ROOT" >&2; exit 2; }
  git -C "$ROOT" worktree add --detach "$WORK/$side" "$ref" >/dev/null 2>&1 \
    || { printf 'model-facing-diff: could not check out %s\n' "$ref" >&2; exit 2; }
done
BASE_SHA=$(git -C "$WORK/base" rev-parse --short HEAD)
TIP_SHA=$(git -C "$WORK/tip" rev-parse --short HEAD)

mapfile -t TASK_NAMES < <(python3 -c 'import json,sys; [print(t["name"]) for t in json.load(open(sys.argv[1]))]' "$TASKS")
[ "${#TASK_NAMES[@]}" -gt 0 ] || { printf 'model-facing-diff: %s names no tasks\n' "$TASKS" >&2; exit 2; }

# task_field <name> <key> -> the task's own words, printed exactly as the file has them
# task_field <name> <key> -> one of the task's own words, printed exactly as the file has it
task_field() {
  python3 - "$TASKS" "$1" "$2" <<'PY'
import json, sys
for task in json.load(open(sys.argv[1])):
    if task["name"] == sys.argv[2]:
        value = task[sys.argv[3]]
        print(value if isinstance(value, str) else json.dumps(value))
        break
PY
}

# run_task <side> <task> -> one JSON line on stdout describing that run
run_task() {
  local side=$1 name=$2 tree="$WORK/$1" dir="$WORK/$1.$2" home db ledger script port pid rc began ended prompt
  home="$dir/home"; db="$dir/run.db"; ledger="$dir/requests.jsonl"; script="$dir/replies.json"
  mkdir -p "$home" "$dir" 2>/dev/null || { printf '{"error":"no scratch home"}\n'; return; }
  task_field "$name" script > "$script" || { printf '{"error":"task %s has no script"}\n' "$name"; return; }
  prompt=$(task_field "$name" prompt)
  pid=""; port=""
  if [ -z "$PROVIDER" ]; then
    STUB_PORT=0 STUB_SCRIPT="$script" STUB_LEDGER="$ledger" STUB_MODEL=measuring-stub \
      python3 "$ROOT/scripts/lib/measuring-provider.py" > "$dir/port.txt" 2>&1 &
    pid=$!; PIDS+=("$pid")
    for _ in $(seq 1 100); do grep -q listening "$dir/port.txt" 2>/dev/null && break; sleep 0.1; done
    port=$(grep -o '[0-9]*$' "$dir/port.txt" 2>/dev/null | tail -1)
    [ -n "$port" ] || { printf '{"error":"the measuring provider never listened"}\n'; return; }
  fi
  local -a envs=(
    "WASM_AGENT_LUA_ROOT=$tree" "WASM_AGENT_HOME=$home" "WASM_AGENT_DB=$db"
    "WASM_AGENT_RENDEZVOUS=" "WASM_AGENT_RELAY=" "WASM_AGENT_MANAGED=0"
  )
  if [ -z "$PROVIDER" ]; then
    envs+=("WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:$port" "WASM_AGENT_LLM_API_KEY=measuring-key"
           "WASM_AGENT_MODEL=measuring-stub" "WASM_AGENT_PROVIDER=opencode-go")
  else
    envs+=("WASM_AGENT_PROVIDER=$PROVIDER")
  fi
  local bin="$BIN"
  if [ "$side" = base ] && [ -n "$BASE_BIN" ]; then bin="$BASE_BIN"; fi
  if [ "$side" = tip ] && [ -n "$TIP_BIN" ]; then bin="$TIP_BIN"; fi
  began=$(date +%s%3N)
  env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL "${envs[@]}" \
    timeout 180 "$bin" chat --once --offline "$prompt" --db "$db" > "$dir/run.out" 2>&1
  rc=$?
  ended=$(date +%s%3N)
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  python3 - "$ledger" "$rc" "$((ended - began))" "$dir/run.out" <<'PY'
import json, os, sys
ledger, rc, wall, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rows = [json.loads(line) for line in open(ledger, encoding="utf-8")] if os.path.exists(ledger) else []
metrics = {"wall_ms": wall, "exit": rc}
if rows:
    first, last = rows[0], rows[-1]
    prompt_bytes = sum(r.get("system_bytes", 0) for r in rows)
    tool_result = sum(r.get("tool_result_bytes", 0) for r in rows)
    metrics.update({
        "request_bytes": first["request_bytes"],
        "system_bytes": first["system_bytes"],
        "tools_bytes": first["tools_bytes"],
        "tool_result_bytes": last["tool_result_bytes"],
        "tool_count": first.get("tool_count", 0),
        "rounds": len(rows),
        "bytes_in": sum(r["request_bytes"] for r in rows),
        "bytes_out": sum(r.get("reply_bytes", 0) for r in rows),
    })
if rc != 0:
    tail = open(out, encoding="utf-8", errors="replace").read().strip().splitlines()[-2:]
    metrics["error"] = "exit %d: %s" % (rc, " | ".join(tail))
print(json.dumps(metrics))
PY
}

FAILED=0
for name in "${TASK_NAMES[@]}"; do
  run_task base "$name" > "$WORK/base.$name.json"
  run_task tip "$name" > "$WORK/tip.$name.json"
done

printf 'model-facing-diff  base %s  tip %s  tasks %s\n' "$BASE_SHA" "$TIP_SHA" "$(basename "$TASKS")"
[ -n "$PROVIDER" ] && printf 'provider            %s (a real wire: byte columns are not ours to record)\n' "$PROVIDER"
[ -n "$BASE_BIN$TIP_BIN" ] && printf 'binaries            base %s  tip %s\n' "${BASE_BIN:-$BIN}" "${TIP_BIN:-$BIN}"
printf '\n'
printf '%s\n' "${TASK_NAMES[@]}" > "$WORK/names.txt"

python3 - "$WORK" "${JSON_OUT:-}" <<'PY' || FAILED=1
import json, os, sys
work, json_out = sys.argv[1], sys.argv[2]
names = [line.strip() for line in open(os.path.join(work, "names.txt"), encoding="utf-8") if line.strip()]

COLUMNS = [("request", "request_bytes"), ("prompt", "system_bytes"), ("tools", "tools_bytes"),
           ("result", "tool_result_bytes"), ("k-in", "bytes_in"), ("k-out", "bytes_out"),
           ("rounds", "rounds"), ("wall", "wall_ms")]


def load(path):
    try:
        return json.load(open(path, encoding="utf-8"))
    except Exception:
        return {}


header = "%-14s %-6s" % ("task", "side")
for label, _ in COLUMNS:
    header += " %9s" % label
print(header)
print("-" * len(header))

worse_any = False
rows_out = []
for name in names:
    base = load(os.path.join(work, "base.%s.json" % name))
    tip = load(os.path.join(work, "tip.%s.json" % name))
    cells = []
    for label, key in COLUMNS:
        before = base.get(key)
        after = tip.get(key)
        if before is None or after is None:
            cells.append((label, before, after, "?"))
            continue
        if label == "wall":
            # WALL TIME IS REPORTED, NEVER A FAILURE. Measured 28/11: two runs of the SAME commit differed by 650 ms on
            # a shared machine, and a gate that fails on that teaches everyone to pass --something to silence it.
            band = max(150, int(before * 0.25))
            mark = "=" if abs(after - before) <= band else ("<" if after < before else ">")
        else:
            mark = "=" if after == before else ("<" if after < before else ">")
        cells.append((label, before, after, mark))
        if mark == ">" and label != "wall":
            worse_any = True
    for side, index in (("base", 1), ("tip", 2)):
        line = "%-14s %-6s" % (name, side)
        for cell in cells:
            value = cell[index]
            line += " %9s" % ("-" if value is None else value)
        print(line)
    line = "%-14s %-6s" % ("", "mark")
    for cell in cells:
        line += " %9s" % cell[3]
    print(line)
    for side, data in (("base", base), ("tip", tip)):
        if data.get("error"):
            print("    %s error: %s" % (side, data["error"]))
    rows_out.append({"task": name, "base": base, "tip": tip,
                     "marks": {cell[0]: cell[3] for cell in cells}})
    print()

print("mark: '=' same, '<' better for the model, '>' worse; a '>' outside wall time fails this command")
if json_out:
    json.dump(rows_out, open(json_out, "w"), indent=2)
    print("written: %s" % json_out)
sys.exit(1 if worse_any else 0)
PY

exit "$FAILED"
