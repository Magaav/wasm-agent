#!/usr/bin/env bash
# Run the model-agnostic task set on TWO trees and print the before/after table.
#
#   bash measure/model-agnostic/run.sh <base-tree> <base-bin> <branch-tree> <branch-bin>
#
# Each side runs in its own scratch home under the node's one root; nothing touches the operator's store and
# no call leaves this machine (the provider is a fixture). Prints one row per task:
#   rounds, convo (request bytes without the system prompt - identical means the healthy request is unchanged),
#   system bytes (the catalogue the model reads every turn), tool-result bytes and tokens, whole-body tokens,
#   wall time, and the count of unknown_argument refusals the model would see.
set -uo pipefail
BASE_TREE=${1:?base tree}; BASE_BIN=${2:?base binary}
HEAD_TREE=${3:?branch tree}; HEAD_BIN=${4:?branch binary}
HERE="$(cd "$(dirname "$0")" && pwd)"
root="${TMPDIR:-/home/victor/.wasm-agent/tmp}"; mkdir -p "$root"
run_one() {
  local tree=$1 bin=$2 out=$3 d
  d=$(mktemp -d "$root/mas-XXXXXX") || return 1
  ( cd "$tree" && env -u WASM_AGENT_DB TMPDIR="$root" GATE_ROOT="$root" WASM_AGENT_HOME="$d" \
      WASM_AGENT_LUA_ROOT="$tree" WA_SCRIPT="$HERE/task-set.lua" "$bin" --db "$d/db.sqlite" ) \
    > "$out" 2>&1
}
run_one "$BASE_TREE" "$BASE_BIN" /tmp/wa-model-agnostic-base.out
run_one "$HEAD_TREE" "$HEAD_BIN" /tmp/wa-model-agnostic-head.out
python3 - "$BASE_TREE" "$HEAD_TREE" <<'PY'
import json, re, sys
def load(path):
    text = open(path).read()
    start = text.find('{"tasks":')
    if start < 0: sys.exit('no measurement in ' + path + ':\n' + text[-400:])
    return {t['task']: t for t in json.loads(text[start:])['tasks']}
base = load('/tmp/wa-model-agnostic-base.out')
head = load('/tmp/wa-model-agnostic-head.out')
print('base tree  :', sys.argv[1])
print('branch tree:', sys.argv[2])
hdr = ('task                | rounds    | convo bytes identical | system bytes     | tool-result bytes  '
       '| tool-result tokens | body tokens   | wall ms        | unknown_argument')
print(hdr); print('-' * len(hdr))
for task in base:
    b, h = base[task], head[task]
    print('%-19s | %d->%-5d | %-21s | %d->%-10d | %d->%-11d | %d->%-14d | %d->%-9d | %.1f->%-8.1f | %d->%d' % (
        task, b['rounds'], h['rounds'], str(b['convo_sha'] == h['convo_sha']),
        b['system_bytes'], h['system_bytes'],
        b['tool_result_bytes'], h['tool_result_bytes'],
        b['tool_result_tokens'], h['tool_result_tokens'],
        b['tokens_est'], h['tokens_est'],
        b['wall_ms'], h['wall_ms'], b['refusals'], h['refusals']))
tot = lambda side, key: sum(t[key] for t in side.values())
print()
print('sum tool-result bytes %d -> %d ; sum unknown_argument refusals %d -> %d' % (
    tot(base, 'tool_result_bytes'), tot(head, 'tool_result_bytes'), tot(base, 'refusals'), tot(head, 'refusals')))
print('system prompt bytes %d -> %d (the catalogue every turn reads)' % (
    base['healthy_time']['system_bytes'], head['healthy_time']['system_bytes']))
PY
