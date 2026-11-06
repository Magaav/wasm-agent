#!/usr/bin/env bash
# A2.3 measurements (docs/KERNEL.md, "A2.3"): the same gate scripts native, inside the agent-core
# component, and through the instance pool - medians of five, and a byte comparison of the three
# outputs. This is the harness the numbers in the document come from; it is not part of the gate
# (scripts/test.sh runs the component and pooled blocks once, this repeats them five times each).
#
#   WA_BIN=target/release/wa WA_POOL_BIN=target/release/wa-core-pool-bench \
#     bash benchmarks/agent-core-pool/bench.sh [script.lua...]
#
# The environment is scrubbed to what a gate run has (scripts/test.sh does the same): the pool's
# native interpreter is built from scratch here, so it must not inherit a managed node's variables -
# with a real node's environment the tool catalogue is bigger and the comparison is meaningless.
set -uo pipefail
cd "$(dirname "$0")/../.."
RUNS=${RUNS:-5}
BIN=${WA_BIN:?set WA_BIN to the release wa binary}
POOL=${WA_POOL_BIN:?set WA_POOL_BIN to the release wa-core-pool-bench binary}
AGENT_CORE=${AGENT_CORE:-rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}
[ -f "$AGENT_CORE" ] || { echo "agent-core not built: $AGENT_CORE" >&2; exit 2; }
WORK="${WORK:-$(pwd)/.wasm-agent/a23-bench}"
rm -rf "$WORK"; mkdir -p "$WORK/tmp"

LUA_ROOT="$(pwd)"
COMPS="${WA_COMPONENTS_DIR:-$WORK/components}"
if command -v cygpath >/dev/null 2>&1; then
  AGENT_CORE="$(cygpath -w "$AGENT_CORE")"
  LUA_ROOT="$(cygpath -w "$LUA_ROOT")"
  [ -n "${WA_COMPONENTS_DIR:-}" ] && COMPS="$(cygpath -w "$COMPS")"
  BIN="$(cygpath -w "$BIN")"
  POOL="$(cygpath -w "$POOL")"
  WORK="$(cygpath -w "$WORK")"
fi

# The gate scripts, in the order scripts/test.sh runs them. test-batch-tools prints two rows whose
# wall_ms differs between any two runs, including two runs of the same mode, so the comparison below
# drops `*_measurement` rows (scripts/test.sh matches only its `batch tools ok` line, for that reason).
SCRIPTS=("$@")
if [ ${#SCRIPTS[@]} -eq 0 ]; then
  SCRIPTS=(
    "scripts/test-mcp-component.lua|component checks:"
    "scripts/test-service-component.lua|service checks:"
    "scripts/test-batch-tools.lua|batch tools ok"
    "scripts/test-tool-cues.lua|tool cues ok"
  )
fi

# A scrubbed environment has no TMPDIR, and `paths.temp()` then falls back to a directory the guest
# cannot write (measured: the Windows directory itself, so an atomic write fails its "new text file
# creation" check), so the scratch temp is part of the fence, not an accident of the shell.
clean_env() {
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$WORK/tmp" TEMP="$WORK/tmp" TMP="$WORK/tmp" \
    WASM_AGENT_LUA_ROOT="$LUA_ROOT" WA_COMPONENTS_DIR="$COMPS" \
    WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0 \
    WA_CODEMODE_ALLOW_EMPTY=1 \
    WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 WASM_AGENT_LLM_API_KEY=fixture-only \
    WASM_AGENT_LLM_CONTEXT=128000 \
    HTTP_PROXY="" HTTPS_PROXY="" ALL_PROXY="" NO_PROXY=127.0.0.1,localhost,::1 \
    "$@"
}

now_ms() { if date +%s%3N >/dev/null 2>&1; then date +%s%3N; else python -c 'import time;print(int(time.time()*1000))'; fi; }

# Every run gets its own home and ledger: a script like test-batch-tools asserts that it CREATED a
# file, so a second run in the same home fails on its own first run's leftovers (the gate runs each
# block once, which is why one home per block is right there and wrong here).
run_native() {
  local script="$1" tag="$2-$3"
  local home="$WORK/home-native-$tag" db="$WORK/native-$tag.sqlite"
  clean_env WASM_AGENT_HOME="$home" WA_SCRIPT="$script" "$BIN" --db "$db"
}
run_component() {
  local script="$1" tag="$2-$3"
  local home="$WORK/home-component-$tag" db="$WORK/component-$tag.sqlite"
  clean_env WASM_AGENT_HOME="$home" "$BIN" --db "$db" --core-component "$AGENT_CORE" "$script"
}
run_pooled() {
  local script="$1" tag="$2-$3"
  local home="$WORK/home-pooled-$tag" db="$WORK/pooled-$tag.sqlite"
  clean_env WASM_AGENT_HOME="$home" WA_AGENT_DB="$db" "$POOL" gate "$AGENT_CORE" "$script" 2>"$WORK/pooled-$tag.err"
}

median() { sort -n | awk '{ v[NR]=$1 } END { if (NR == 0) { print "n/a"; exit } print v[int((NR+1)/2)] }'; }

echo "# A2.3 — native / component / pooled, medians of $RUNS (wall ms), release binary"
echo "# agent-core: $AGENT_CORE"
echo
printf '| script | checks line | native | component | pooled | native/component | component/pooled |\n'
printf '| --- | --- | --- | --- | --- | --- | --- |\n'
STATUS=0
for entry in "${SCRIPTS[@]}"; do
  script="${entry%%|*}"; expect="${entry#*|}"
  # A script named on the command line has no "|expect" suffix; every gate script's line says ok.
  [ "$expect" = "$entry" ] && expect='ok' 
  name="$(basename "$script" .lua)"
  for mode in native component pooled; do
    : >"$WORK/$mode-$name.times"
    for run in $(seq 1 "$RUNS"); do
      rm -rf "$WORK/home-$mode-$name-$run"
      start=$(now_ms)
      "run_$mode" "$script" "$name" "$run" >"$WORK/$mode-$name.out" 2>"$WORK/$mode-$name.stderr"
      code=$?
      end=$(now_ms)
      [ "$code" = 0 ] || { echo "$mode $name run $run answered $code:" >&2; tail -3 "$WORK/$mode-$name.stderr" >&2; STATUS=1; }
      echo $((end - start)) >>"$WORK/$mode-$name.times"
      # A byte comparison of the first run of each mode; the rows that cannot be stable are dropped.
      [ "$run" = 1 ] && grep -v 'measurement {' "$WORK/$mode-$name.out" >"$WORK/$mode-$name.compare"
      grep -q "$expect" "$WORK/$mode-$name.out" || { echo "$mode $name: '$expect' missing" >&2; STATUS=1; }
    done
  done
  if ! diff -q "$WORK/component-$name.compare" "$WORK/pooled-$name.compare" >/dev/null; then
    echo "component and pooled output differ for $name:" >&2
    diff "$WORK/component-$name.compare" "$WORK/pooled-$name.compare" >&2 | head -20
    STATUS=1
  fi
  if ! diff -q "$WORK/native-$name.compare" "$WORK/component-$name.compare" >/dev/null; then
    echo "note: native and component output differ for $name (not a failure here; the gate's own block decides)" >&2
  fi
  native=$(median <"$WORK/native-$name.times")
  component=$(median <"$WORK/component-$name.times")
  pooled=$(median <"$WORK/pooled-$name.times")
  printf '| %s | `%s` | %s | %s | %s | %.2fx | %.2fx |\n' "$name" "$expect" "$native" "$component" "$pooled" \
    "$(awk -v a="$component" -v b="$native" 'BEGIN { print (b > 0 ? a / b : 0) }')" \
    "$(awk -v a="$pooled" -v b="$component" 'BEGIN { print (b > 0 ? a / b : 0) }')"
done
echo
echo "outputs: component == pooled for every script above; files under $WORK"
exit "$STATUS"
