#!/usr/bin/env bash
# waiting-costs-no-turns, the stub-model row: a long job costs ONE tool round, not a poll loop.
#
# Everything is local: scripts/mock-provider-wct.cjs answers the first request with one `run` tool call
# (a script that starts a job of $WCT_JOB_SECONDS seconds and ends with the handle live) and every later
# request with the tool result it was given, so `GET /calls` counts the model round trips for exactly that
# shape. Before this change the script answered with a pending handle and the model had to call again; the
# count is what tells the two apart, and the reply is what proves the settled output was in the ONE result.
#
# The 7-minute case in the queue is this same shape with a bigger number: the cost is measured against the
# job's length, not against a constant, so the row runs seconds and states the scaling instead of spending
# seven minutes of a gate.
set -u
export LC_ALL=C

here=$(cd "$(dirname "$0")/.." && pwd)
lua_root=${WCT_LUA_ROOT:-$here}
bin=${WCT_BIN:-${WA_BIN:-$here/rust/target/release/wa}}
[ -x "$bin" ] || { echo "wct-serve-step: no node binary at $bin (set WCT_BIN)" >&2; exit 1; }
command -v node >/dev/null || { echo "wct-serve-step: node is required for the stub model" >&2; exit 1; }

base=${1:-$((46000 + RANDOM % 2000))}
mock_port=$((base + 50))
job_seconds=${WCT_JOB_SECONDS:-6}
work=$(mktemp -d "${TMPDIR:-/tmp}/wct-step.XXXXXX")
pids=()
status=0
cleanup() {
  local rc=$?
  set +e
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  if [ "$status" = 0 ]; then rm -rf "$work"; else echo "  logs kept at $work" >&2; fi
  return $rc
}
trap cleanup EXIT

get() { curl -s -m "${3:-30}" "http://127.0.0.1:$1$2"; }
post() { curl -s -m "${4:-180}" -X POST -H 'content-type: application/json' --data "$3" "http://127.0.0.1:$1$2"; }
json() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s);const p=process.argv[1].split(".");let o=v;for(const k of p)o=o==null?o:o[k];process.stdout.write(o===undefined||o===null?"":String(o))}catch(e){process.stdout.write("")}})' "$1"; }

node "$here/scripts/mock-provider-wct.cjs" "$mock_port" "$job_seconds" > "$work/mock.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 60); do curl -fsS -m 2 "http://127.0.0.1:$mock_port/" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS -m 2 "http://127.0.0.1:$mock_port/" >/dev/null 2>&1 || { echo "wct-serve-step: the stub model did not start (see $work/mock.log)" >&2; exit 1; }

home="$work/node"
mkdir -p "$home/.wasm-agent"
(
  while IFS= read -r variable; do
    case "$variable" in WASM_AGENT_*|WA_SCRIPT|OPENAI_API_KEY|OPENCODE_GO_API_KEY) unset "$variable" ;; esac
  done < <(compgen -e)
  export WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$lua_root"
  export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$mock_port" WASM_AGENT_LLM_API_KEY=test-only WASM_AGENT_LLM_MODEL=stub-model
  export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY=
  exec "$bin" --db "$home/t.db" serve --port "$base" --client-port "$((base + 1))"
) > "$work/serve.log" 2>&1 &
pids+=($!)
code=""
for _ in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:$base/health" 2>/dev/null)
  [ "$code" = 200 ] && break
  sleep 0.25
done
[ "$code" = 200 ] || { echo "wct-serve-step: the node did not come up (see $work/serve.log)" >&2; tail -5 "$work/serve.log" >&2; exit 1; }

started_at=$(date +%s)
reply=$(post "$base" /chat '{"text":"start the wct job","thread":"wct-step"}' 240)
seconds=$(( $(date +%s) - started_at ))
text=$(printf '%s' "$reply" | json reply)
calls=$(get "$mock_port" /calls | json count)
reqbytes=$(get "$mock_port" /calls | json request_bytes)
rounds=$(get "$mock_port" /calls | json tool_rounds)

fail=0
say() { echo "wct-serve-step: $*"; }
# The numbers, always - a failing run must still be readable as a measurement, and the before/after
# row is exactly those numbers from the same binary with a different Lua root (WCT_LUA_ROOT).
echo "wct-serve-step: numbers calls=${calls:-0} rounds=${rounds:-0} request_bytes=${reqbytes:-0} seconds=$seconds lua_root=$lua_root"
if [ "${WCT_MEASURE_ONLY:-0}" = "1" ]; then exit 0; fi

# 1. The answer the model was given carries the job's REAL output: the hold settled it, the model never
#    had to ask again. This is the difference the change is about.
case "$text" in
  *settled-output:present*) say "the settled output reached the model in the one tool result" ;;
  *) say "FAIL: the one tool result did not carry the settled output: $(printf '%s' "$text" | head -c 300)" ; fail=$((fail + 1)) ;;
esac
# The note itself, because a model that cannot see WHY the work settled reads the next call as new work.
case "$text" in
  *pending-note:present*) say "the settled note travelled with it" ;;
  *) say "FAIL: the result carried the output but no settled note: $(printf '%s' "$text" | head -c 300)" ; fail=$((fail + 1)) ;;
esac

# 2. ONE tool round. Two model calls: the call that asked for the script, and the answer after its result.
[ "${calls:-0}" -le 2 ] || { say "FAIL: $calls model calls for one job (at most 2 expected: the call and the answer)" ; fail=$((fail + 1)) ; }
[ "${rounds:-0}" = 1 ] || { say "FAIL: $rounds tool rounds for one job (expected 1)" ; fail=$((fail + 1)) ; }

# 3. It really held: the answer came no sooner than the job, and not long after it.
[ "$seconds" -ge "$job_seconds" ] || { say "FAIL: answered in ${seconds}s for a ${job_seconds}s job - it did not hold" ; fail=$((fail + 1)) ; }
[ "$seconds" -le $((job_seconds + 60)) ] || { say "FAIL: answered in ${seconds}s for a ${job_seconds}s job - the hold ran past it" ; fail=$((fail + 1)) ; }

if [ "$fail" = 0 ]; then
  say "ok: one job of ${job_seconds}s cost $calls model call(s), $rounds tool round(s), ${reqbytes:-0} request bytes, answered in ${seconds}s"
else
  say "FAILED ($fail)"
  status=1
fi
exit "$status"
