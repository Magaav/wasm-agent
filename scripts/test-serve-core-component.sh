#!/usr/bin/env bash
# A2.4 serve smoke: the same node on both cores - `--core native` and `--core component` - answering
# three turns, one hook, one subagent and one self-wake, with the two results compared
# (docs/KERNEL.md, "A2.4").
#
#   bash scripts/test-serve-core-component.sh [port-base]
#
# Everything is local: a stub OpenAI-shaped model (scripts/mock-provider-a24.cjs) on loopback, a
# scratch home and ledger per mode, no rendezvous, no relay, no operator credentials (every
# WASM_AGENT_* variable of the calling shell is dropped first, the way scripts/test-serve-concurrency.sh
# does it). What is compared is the *behaviour*, not the log: each turn's reply, the hook's own record,
# the subagent's terminal state and result, and the fact that a [self-wake] turn reached the model
# without the harness asking again.
#
# Requires the agent-core component (bash scripts/build-agent-core.sh, wasi-sdk).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
BASE="${1:-8861}"
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "smoke: no wa binary (set WA_BIN)" >&2; exit 2; }
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "smoke: no agent-core at $core (run bash scripts/build-agent-core.sh)" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"; root_native="$(native "$ROOT")"

work="$(mktemp -d "${TMPDIR:-/tmp}/wa-core-smoke-XXXXXX")"
pids=()
cleanup() {
  local status=$?
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  for _ in $(seq 1 40); do
    local alive=0
    for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break
    sleep 0.1
  done
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  [ "$status" = 0 ] && rm -rf "$work" || echo "  logs kept at $work" >&2
  return "$status"
}
trap cleanup EXIT

mock_port=$((BASE + 50))
node scripts/mock-provider-a24.cjs "$mock_port" > "$work/mock.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 40); do curl -fsS -m 2 "http://127.0.0.1:$mock_port/" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS -m 2 "http://127.0.0.1:$mock_port/" >/dev/null 2>&1 || { echo "smoke: the stub model did not start" >&2; exit 1; }
echo "smoke: stub model on http://127.0.0.1:$mock_port"

post() { # post <port> <path> <body> [timeout]
  curl -s -m "${4:-90}" -X POST -H 'content-type: application/json' --data "$3" "http://127.0.0.1:$1$2"
}
get() { curl -s -m "${3:-30}" "http://127.0.0.1:$1$2"; }
json() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s);const p=process.argv[1].split(".");let o=v;for(const k of p)o=o==null?o:o[k];process.stdout.write(o===undefined||o===null?"":String(o))}catch(e){process.stdout.write("")}})' "$1"; }

run_mode() { # run_mode <mode> <port>
  local mode=$1 port=$2 home="$work/$1"
  mkdir -p "$home/.wasm-agent"
  local hook_log="$home/hook.log"
  # A UserPromptSubmit hook: it receives the payload on stdin (docs/HOOKS.md), so `cat >>` records
  # exactly the turns the node ran without depending on a shell quoting rule.
  cat > "$home/.wasm-agent/hooks.json" <<JSON
{"hooks":{"UserPromptSubmit":[{"name":"a24-smoke","command":"cat >> $(echo "$hook_log" | sed 's#\\\\#/#g')"}]}}
JSON
  : > "$hook_log"
  (
    while IFS= read -r variable; do
      case "$variable" in WASM_AGENT_*|WA_SCRIPT|OPENAI_API_KEY|OPENCODE_GO_API_KEY) unset "$variable" ;; esac
    done < <(compgen -e)
    export WASM_AGENT_HOME="$(native "$home")" WASM_AGENT_LUA_ROOT="$root_native"
    export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$mock_port" WASM_AGENT_LLM_API_KEY=test-only WASM_AGENT_LLM_MODEL=stub-model
    export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY=
    exec "$bin" --db "$(native "$home/t.db")" serve --port "$port" --client-port "$((port + 1))" --ui "$root_native/ui" --core "$mode"
  ) > "$home/serve.log" 2>&1 &
  pids+=($!)
  local code=""
  for _ in $(seq 1 120); do
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)"
    [ "$code" = 200 ] && break
    sleep 0.25
  done
  [ "$code" = 200 ] || { echo "smoke[$mode]: the node did not come up (see $home/serve.log)" >&2; tail -5 "$home/serve.log" >&2; return 1; }

  local health; health="$(get "$port" /health)"
  local core_mode; core_mode="$(printf '%s' "$health" | json core.mode)"
  echo "smoke[$mode]: /health core.mode=$core_mode"
  [ "$core_mode" = "$mode" ] || { echo "smoke[$mode]: the node reports core=$core_mode" >&2; return 1; }

  local replies="" turn
  for turn in 1 2 3; do
    local answer; answer="$(post "$port" /chat "{\"text\":\"turn $turn: answer with one word\",\"thread\":\"smoke-$turn\"}")"
    replies="$replies$(printf '%s' "$answer" | json reply)|"
  done
  echo "smoke[$mode]: three turns -> $replies"

  # One subagent: start it and wait for it to settle.
  local started id state result
  started="$(post "$port" /subagents '{"action":"start","prompt":"reply with one word","profile":"explore"}')"
  id="$(printf '%s' "$started" | json subagent_id)"
  state=""
  for _ in $(seq 1 60); do
    local status; status="$(post "$port" /subagents "{\"action\":\"status\",\"id\":\"$id\"}")"
    state="$(printf '%s' "$status" | json subagent.state)"
    [ -n "$state" ] || state="$(printf '%s' "$status" | json state)"
    case "$state" in completed|failed|unknown|stopped|cancelled) break ;; esac
    sleep 0.5
  done
  result="$(post "$port" /subagents "{\"action\":\"result\",\"id\":\"$id\"}")"
  local subagent_summary; subagent_summary="$(printf '%s' "$result" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let v={};try{v=JSON.parse(s)}catch(e){}
      const task=v.subagent||v;
      const r=task.result||{};
      const text=typeof r==="string"?r:(r.text||r.reply||r.output||"");
      process.stdout.write(String(task.state||"")+"/"+String(text).slice(0,40));
    })')"
  echo "smoke[$mode]: subagent $id -> $subagent_summary"

  # One self-wake: a turn whose prompt makes the stub answer with a `wake` tool call, then the node's
  # own placement tick must fire the wake as a [self-wake] turn - with no further request from here.
  local wake_before; wake_before="$(get "$mock_port" /calls | json self_wakes)"
  wake_before="${wake_before:-0}"
  post "$port" /chat '{"text":"wake me in two seconds","thread":"smoke-wake"}' > /dev/null
  local self_wakes="$wake_before"
  for _ in $(seq 1 60); do
    self_wakes="$(get "$mock_port" /calls | json self_wakes)"
    [ "${self_wakes:-0}" -gt "${wake_before:-0}" ] && break
    sleep 0.5
  done
  # The stub model is shared by both modes, so what is recorded is this mode's own delta.
  local wake_delta=$(( ${self_wakes:-0} - wake_before ))
  echo "smoke[$mode]: self-wake turns reaching the model: $wake_delta"

  # Each payload is one JSON document written to stdin, with no trailing newline, so count the marker
  # the payload itself carries rather than lines.
  local hooks; hooks="$(grep -o '"hook_event_name"' "$hook_log" 2>/dev/null | wc -l | tr -d ' ')"
  echo "smoke[$mode]: UserPromptSubmit hook recorded $hooks payloads"

  printf '%s\n' "$replies" > "$home/replies.txt"
  printf '%s\n' "$subagent_summary" > "$home/subagent.txt"
  printf '%s\n' "$wake_delta" > "$home/self_wakes.txt"
  printf '%s\n' "$hooks" > "$home/hooks.txt"
  # Stop this node before the next mode starts: one process per mode, never both at once.
  kill "${pids[-1]}" 2>/dev/null; wait "${pids[-1]}" 2>/dev/null
  pids[-1]=""
}

port_native=$BASE
port_component=$((BASE + 10))
run_mode native "$port_native" || exit 1
run_mode component "$port_component" || exit 1

fail=0
compare() { # compare <label> <file>
  local label=$1 file=$2
  local n c
  n="$(cat "$work/native/$file" 2>/dev/null)"
  c="$(cat "$work/component/$file" 2>/dev/null)"
  if [ "$n" = "$c" ]; then
    echo "same  $label: $n"
  else
    echo "DIFF  $label: native='$n' component='$c'"; fail=1
  fi
}
compare "three turn replies" replies.txt
compare "subagent" subagent.txt
compare "self-wakes observed" self_wakes.txt
compare "hook payloads" hooks.txt

for mode in native component; do
  [ "$(cat "$work/$mode/replies.txt" 2>/dev/null)" = "stub-ok|stub-ok|stub-ok|" ] \
    || { echo "FAIL  $mode: the three turns did not answer stub-ok"; fail=1; }
  case "$(cat "$work/$mode/self_wakes.txt" 2>/dev/null)" in ''|0) echo "FAIL  $mode: no [self-wake] turn reached the model"; fail=1 ;; esac
  [ "$(cat "$work/$mode/hooks.txt" 2>/dev/null)" -ge 4 ] 2>/dev/null \
    || { echo "FAIL  $mode: the hook recorded fewer payloads than turns"; fail=1; }
done
echo
[ "$fail" = 0 ] && echo "serve core smoke ok: three turns, one hook, one subagent and one self-wake on both cores" || { echo "serve core smoke FAILED (logs in $work)" >&2; exit 1; }
