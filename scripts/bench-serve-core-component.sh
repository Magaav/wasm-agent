#!/usr/bin/env bash
# A2.4 measurement: what the component core costs a *serving* node (docs/KERNEL.md, "A2.4").
#
#   bash scripts/bench-serve-core-component.sh [port-base] [turns] [rounds]
#
# One node per core, the same stub model, the same scratch home shape, on loopback: median wall time of
# `turns` chat turns (each in its own thread, so the prompt does not grow), median wall time of a read
# (`/sessions`), and the resident memory of the serve process once it has gone quiet. Nothing here is
# inferred from the other mode's numbers: each is measured in its own process.
#
# Prints one block per mode and a comparison. The stub model answers immediately, so a turn's number is
# the node's own cost (interpreter + tools + transcript + streaming), not the model's.
#
# `AGENT_CORE_B=<other agent_core.wasm>` adds a third column, measured in the same round as the first
# two: A and B are the same node, the same stub model and the same turns minutes apart, so a change to
# the guest alone is measured without a machine that drifted in between. b = AGENT_CORE_B.
# `B_ENV="NAME=VALUE ..."` is set in b's node only, so one node setting (a deadline, a pool size) can be
# measured the same way without running the two nodes in different minutes.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
BASE="${1:-8961}"
TURNS="${2:-10}"
ROUNDS="${3:-1}"
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "bench: no wa binary (set WA_BIN)" >&2; exit 2; }
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "bench: no agent-core at $core (run bash scripts/build-agent-core.sh)" >&2; exit 2; }
core_b="${AGENT_CORE_B:-}"
[ -z "$core_b" ] || [ -f "$core_b" ] || { echo "bench: AGENT_CORE_B=$core_b does not exist" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"; root_native="$(native "$ROOT")"
[ -z "$core_b" ] || core_b="$(native "$core_b")"
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

measure() { # measure <mode> <port> [core]
  local mode=$1 port=$2 wasm=${3:-$core} home="$work/$1"
  mkdir -p "$home/.wasm-agent"
  (
    while IFS= read -r variable; do
      case "$variable" in WASM_AGENT_*|WA_SCRIPT|OPENAI_API_KEY|OPENCODE_GO_API_KEY) unset "$variable" ;; esac
    done < <(compgen -e)
    export WASM_AGENT_HOME="$(native "$home")" WASM_AGENT_LUA_ROOT="$root_native"
    export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$mock_port" WASM_AGENT_LLM_API_KEY=test-only WASM_AGENT_LLM_MODEL=stub-model
    export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_CORE=""
    export WA_AGENT_CORE_WASM="$wasm"
    # `b` is the same node as `component` with another guest (and, when `B_ENV` names some, other node
    # settings); the mode flag it passes is `component`.
    local flag="$mode"; [ "$flag" = b ] && flag=component
    if [ "$mode" = b ] && [ -n "${B_ENV:-}" ]; then
      for pair in $B_ENV; do export "$pair"; done
    fi
    exec "$bin" --db "$(native "$home/t.db")" serve --port "$port" --client-port "$((port + 1))" --ui "$root_native/ui" --core "$flag"
  ) > "$home/serve.log" 2>&1 &
  local pid=$!; pids+=("$pid")
  local code=""
  for _ in $(seq 1 320); do
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
  local served expected; served="$(printf '%s' "$health" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let h={};try{h=JSON.parse(s)}catch(e){}process.stdout.write(String((h.core||{}).mode||""))})' 2>/dev/null)"
  expected="$([ "$mode" = b ] && printf component || printf '%s' "$mode")"
  if [ "$served" != "$expected" ]; then
    echo "bench[$mode]: the node on port $port answered core.mode='$served' (not '$expected'); this round is not a measurement" >&2
    tail -3 "$home/serve.log" >&2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 1
  fi
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

# Rounds: the two modes run one after the other, so a machine that is busy for one of them (this is
# often an operator's desktop, not a quiet benchmark box) shows up as drift between the columns rather
# than as a difference between the cores. `rounds` (third argument, default 1) alternates the modes and
# reports each round; the summary then quotes the least-contended round per mode, the standard treatment
# of a noisy host, and prints every round so the noise is visible instead of hidden.
rounds=${3:-1}
: > "$work/rounds.txt"
for round in $(seq 1 "$rounds"); do
  base=$((BASE + (round - 1) * 100))
  [ "$rounds" -gt 1 ] && echo "bench: round $round"
  measure native "$base" || exit 1
  measure component "$((base + 10))" || exit 1
  if [ -n "$core_b" ]; then measure b "$((base + 20))" "$core_b" || exit 1; fi
  printf "%s %s %s %s %s %s %s %s %s %s\n" "$round" "$(cat "$work/native.turn.txt")" "$(cat "$work/component.turn.txt")" "$(cat "$work/native.read.txt")" "$(cat "$work/component.read.txt")" "$(cat "$work/native.rss.txt")" "$(cat "$work/component.rss.txt")" "$([ -f "$work/b.turn.txt" ] && cat "$work/b.turn.txt" || echo 0)" "$([ -f "$work/b.read.txt" ] && cat "$work/b.read.txt" || echo 0)" "$([ -f "$work/b.rss.txt" ] && cat "$work/b.rss.txt" || echo 0)" >> "$work/rounds.txt"
done

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0>0) printf "%.2f", a/b; else print "?" }'; }
delta() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%+.0f", a-b}'; }
least() { awk -v column="$2" 'NR==1 || $column+0 < best+0 {best=$column; line=$0} END{print line}' "$1"; }

if [ "$rounds" -gt 1 ]; then
  echo
  if [ -n "$core_b" ]; then
    echo "per round: turn native/component/b, read native/component/b, rss native/component/b (ms, ms, MiB)"
    awk '{print "  round", $1, "  turn", $2, "/", $3, "/", $8, "  read", $4, "/", $5, "/", $9, "  rss", $6, "/", $7, "/", $10}' "$work/rounds.txt"
  else
    echo "per round: turn native/component, read native/component, rss native/component (ms, ms, MiB)"
    awk '{print "  round", $1, "  turn", $2, "/", $3, "  read", $4, "/", $5, "  rss", $6, "/", $7}' "$work/rounds.txt"
  fi
fi
# The ratio per round, then the median across rounds: the two modes run one after the other on a host
# that is often an operator's desktop, so a pair from a quiet minute and a pair from a busy one are two
# samples of the same two cores, and a median is what they can support.
median_of() { sort -n | awk '{v[NR]=$1} END{ if (NR==0) {print "?"; exit} if (NR%2) print v[(NR+1)/2]; else printf "%.0f", (v[NR/2]+v[NR/2+1])/2 }'; }
# The same for a ratio, which needs its two decimals: a median rounded to a whole number is not a ratio.
median_ratio() { sort -n | awk '{v[NR]=$1} END{ if (NR==0) {print "?"; exit} if (NR%2) printf "%.2f", v[(NR+1)/2]; else printf "%.2f", (v[NR/2]+v[NR/2+1])/2 }'; }
awk '{print sprintf("%.2f", ($3+0)/(($2+0)>0?$2:1))}' "$work/rounds.txt" > "$work/turn.ratios"
awk '{print sprintf("%.2f", ($5+0)/(($4+0)>0?$4:1))}' "$work/rounds.txt" > "$work/read.ratios"
awk '{print $2}' "$work/rounds.txt" | median_of > "$work/native.turn.median"
awk '{print $3}' "$work/rounds.txt" | median_of > "$work/component.turn.median"
awk '{print $4}' "$work/rounds.txt" | median_of > "$work/native.read.median"
awk '{print $5}' "$work/rounds.txt" | median_of > "$work/component.read.median"
awk '{print $6}' "$work/rounds.txt" | median_of > "$work/native.rss.median"
awk '{print $7}' "$work/rounds.txt" | median_of > "$work/component.rss.median"
if [ -n "$core_b" ]; then
  # The A/B pair is the two *component* numbers; native is the physical reference both are compared to.
  awk '{print sprintf("%.2f", ($8+0)/(($3+0)>0?$3:1))}' "$work/rounds.txt" > "$work/b.turn.ratios"
  awk '{print sprintf("%.2f", ($9+0)/(($5+0)>0?$5:1))}' "$work/rounds.txt" > "$work/b.read.ratios"
  awk '{print $8}' "$work/rounds.txt" | median_of > "$work/b.turn.median"
  awk '{print $9}' "$work/rounds.txt" | median_of > "$work/b.read.median"
  awk '{print $10}' "$work/rounds.txt" | median_of > "$work/b.rss.median"
fi

nt="$(cat "$work/native.turn.median")"; ct="$(cat "$work/component.turn.median")"
nr="$(cat "$work/native.read.median")"; cr="$(cat "$work/component.read.median")"
nm="$(cat "$work/native.rss.median")"; cm="$(cat "$work/component.rss.median")"
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0>0) printf "%.2f", a/b; else print "?" }'; }
delta() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%+.0f", a-b}'; }
echo
if [ "$rounds" -gt 1 ]; then
  echo "medians across $rounds rounds (each round: turn native ${nt}ms component ${ct}ms; read native ${nr}ms component ${cr}ms)"
  echo "turn   component/native $(cat "$work/turn.ratios" | paste -sd' ' -)  median $(cat "$work/turn.ratios" | median_ratio)x"
  echo "read   component/native $(cat "$work/read.ratios" | paste -sd' ' -)  median $(cat "$work/read.ratios" | median_ratio)x"
else
  echo "turn   native ${nt}ms  component ${ct}ms   component/native $(ratio "$ct" "$nt")x  ($(delta "$ct" "$nt")ms per turn)"
  echo "read   native ${nr}ms  component ${cr}ms   component/native $(ratio "$cr" "$nr")x  ($(delta "$cr" "$nr")ms per read)"
fi
echo "rss    native ${nm}MiB component ${cm}MiB   $(delta "$cm" "$nm")MiB"
if [ -n "$core_b" ]; then
  bt="$(cat "$work/b.turn.median")"; br="$(cat "$work/b.read.median")"; bm="$(cat "$work/b.rss.median")"
  echo "a/b    turn $(cat "$work/b.turn.ratios" | paste -sd' ' -)  median $(cat "$work/b.turn.ratios" | median_ratio)x  (b ${bt}ms vs a ${ct}ms)"
  echo "a/b    read $(cat "$work/b.read.ratios" | paste -sd' ' -)  median $(cat "$work/b.read.ratios" | median_ratio)x  (b ${br}ms vs a ${cr}ms)"
  echo "a/b    rss  b ${bm}MiB vs a ${cm}MiB   $(delta "$bm" "$cm")MiB"
fi
