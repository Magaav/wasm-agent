#!/usr/bin/env bash
# A2.4 measurement: what the component core costs a *serving* node (docs/KERNEL.md, "A2.4").
#
#   bash scripts/bench-serve-core-component.sh [port-base] [turns]
#
# One node per core, the same stub model, the same scratch home shape, on loopback: median wall time of
# `turns` chat turns (each in its own thread, so the prompt does not grow), median wall time of a read
# (`/sessions`), and the resident memory of the serve process once it has gone quiet. Nothing here is
# inferred from the other mode's numbers: each is measured in its own process.
#
# Prints one block per mode and a comparison. The stub model answers immediately, so a turn's number is
# the node's own cost (interpreter + tools + transcript + streaming), not the model's.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
BASE="${1:-8961}"
TURNS="${2:-10}"
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "bench: no wa binary (set WA_BIN)" >&2; exit 2; }
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "bench: no agent-core at $core (run bash scripts/build-agent-core.sh)" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"; root_native="$(native "$ROOT")"
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-core-bench-XXXXXX")"
pids=()
cleanup() {
  local status=$?
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  sleep 0.5
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

median() { sort -n | awk '{v[NR]=$1} END{if(NR%2)print v[(NR+1)/2]; else printf "%.1f", (v[NR/2]+v[NR/2+1])/2}'; }

# Resident bytes of the serve process, from the OS (the honest number: a wasm instance's linear memory
# is only part of what a node with a pool holds).
rss_mb() {
  local pid=$1 winpid=$pid
  # An MSYS pid is not a Windows pid: `ps -W` carries both, and `tasklist` only knows the second.
  if ps -W >/dev/null 2>&1; then
    winpid="$(ps -W 2>/dev/null | awk -v p="$pid" '$1==p{print $4; exit}')"
    [ -n "$winpid" ] || winpid=$pid
  fi
  if command -v tasklist >/dev/null 2>&1; then
    tasklist //FI "PID eq $winpid" //FO CSV //NH 2>/dev/null | awk -F'","' 'NR==1{v=$5; gsub(/[^0-9]/,"",v); if(v!="")printf "%.0f", v/1024}'
  elif command -v ps >/dev/null 2>&1; then
    ps -o rss= -p "$winpid" 2>/dev/null | awk '{printf "%.0f", $1/1024}'
  fi
}

measure() { # measure <mode> <port>
  local mode=$1 port=$2 home="$work/$1"
  mkdir -p "$home/.wasm-agent"
  (
    while IFS= read -r variable; do
      case "$variable" in WASM_AGENT_*|WA_SCRIPT|OPENAI_API_KEY|OPENCODE_GO_API_KEY) unset "$variable" ;; esac
    done < <(compgen -e)
    export WASM_AGENT_HOME="$(native "$home")" WASM_AGENT_LUA_ROOT="$root_native"
    export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$mock_port" WASM_AGENT_LLM_API_KEY=test-only WASM_AGENT_LLM_MODEL=stub-model
    export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY=
    exec "$bin" --db "$(native "$home/t.db")" serve --port "$port" --client-port "$((port + 1))" --ui "$root_native/ui" --core "$mode"
  ) > "$home/serve.log" 2>&1 &
  local pid=$!; pids+=("$pid")
  local code=""
  for _ in $(seq 1 160); do
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)"
    [ "$code" = 200 ] && break
    sleep 0.25
  done
  [ "$code" = 200 ] || { echo "bench[$mode]: the node did not come up" >&2; return 1; }

  # Two warm-up turns: the first turn of a node pays whatever the node pays once (plugin scan, schema,
  # a first compile), and a median of 10 must not be a median of 10 different cold starts.
  local i
  for i in 1 2; do
    curl -s -o /dev/null -m 120 -X POST -H 'content-type: application/json' \
      --data "{\"text\":\"warm $i\",\"thread\":\"warm-$i\"}" "http://127.0.0.1:$port/chat" 2>/dev/null
  done
  local turn_times="$work/$mode.turns" read_times="$work/$mode.reads"
  : > "$turn_times"; : > "$read_times"
  for i in $(seq 1 "$TURNS"); do
    local seconds
    seconds="$(curl -s -o /dev/null -m 180 -w '%{time_total}' -X POST -H 'content-type: application/json' \
      --data "{\"text\":\"turn $i\",\"thread\":\"bench-$i\"}" "http://127.0.0.1:$port/chat" 2>/dev/null)"
    awk -v s="$seconds" 'BEGIN{printf "%.0f\n", s*1000}' >> "$turn_times"
  done
  for i in $(seq 1 "$TURNS"); do
    local seconds
    seconds="$(curl -s -o /dev/null -m 120 -w '%{time_total}' "http://127.0.0.1:$port/sessions" 2>/dev/null)"
    awk -v s="$seconds" 'BEGIN{printf "%.0f\n", s*1000}' >> "$read_times"
  done
  # Let the node go quiet, then take the memory number and the pool's own counters.
  sleep 4
  local health; health="$(curl -s -m 10 "http://127.0.0.1:$port/health" 2>/dev/null)"
  local rss; rss="$(rss_mb "$pid")"
  local turn_median read_median
  turn_median="$(median < "$turn_times")"
  read_median="$(median < "$read_times")"
  echo "bench[$mode]: turn median ${turn_median}ms   read (/sessions) median ${read_median}ms   rss ${rss:-?}MiB"
  printf '%s\n' "$health" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let h={};try{h=JSON.parse(s)}catch(e){}
      const c=h.core||{};
      const parts=["mode="+c.mode];
      if(c.mode==="component"){
        parts.push("instances="+c.instances,"leased="+c.leased,"runs="+c.runs,
          "guest_run_ms="+c.guest_run_ms,"calls="+c.calls,"opened_ms="+c.opened_ms);
      }
      console.log("bench["+process.argv[1]+"]: "+(c.mode||"native")+" core: "+parts.join(" "));
    })' "$mode"
  printf '%s\n' "$turn_median" > "$work/$mode.turn.txt"
  printf '%s\n' "$read_median" > "$work/$mode.read.txt"
  printf '%s\n' "${rss:-0}" > "$work/$mode.rss.txt"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 0
}

measure native "$BASE" || exit 1
measure component "$((BASE + 10))" || exit 1

nt="$(cat "$work/native.turn.txt")"; ct="$(cat "$work/component.turn.txt")"
nr="$(cat "$work/native.read.txt")"; cr="$(cat "$work/component.read.txt")"
nm="$(cat "$work/native.rss.txt")"; cm="$(cat "$work/component.rss.txt")"
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0>0) printf "%.2f", a/b; else print "?" }'; }
echo
delta() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%+.0f", a-b}'; }
echo "turn   native ${nt}ms  component ${ct}ms   component/native $(ratio "$ct" "$nt")x  ($(delta "$ct" "$nt")ms per turn)"
echo "read   native ${nr}ms  component ${cr}ms   component/native $(ratio "$cr" "$nr")x  ($(delta "$cr" "$nr")ms per read)"
echo "rss    native ${nm}MiB component ${cm}MiB   $(delta "$cm" "$nm")MiB"
