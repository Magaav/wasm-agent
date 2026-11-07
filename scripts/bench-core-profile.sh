#!/usr/bin/env bash
# What one serve turn spends inside the agent-core component (docs/KERNEL.md, "A2.1"-"A2.5"):
# how many `host.*` crossings a turn makes, per name, how many bytes cross in each direction, and how
# the item's wall time splits between the handlers (the node's own work, the same in both cores) and
# everything else (the guest's Lua plus the crossings). `WA_CORE_CALL_PROFILE=1` in
# rust/wa-capabilities/src/core_component.rs prints one block per work item to the node's stderr; this
# script runs one node with it on and sums the blocks of the measured turns.
#
#   bash scripts/bench-core-profile.sh [port-base] [turns]
#
# Its own scratch home, empty rendezvous/relay, a stub model on loopback: it never joins a node
# network and never touches the operator's home. Prints a per-name table sorted by handler time and a
# one-line summary; the raw blocks stay in the work dir when `KEEP=1`.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
BASE="${1:-9021}"
TURNS="${2:-20}"
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "profile: no wa binary (set WA_BIN)" >&2; exit 2; }
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "profile: no agent-core at $core (run bash scripts/build-agent-core.sh)" >&2; exit 2; }
[ "$BASE" != 8799 ] || { echo "profile: 8799 is the operator's port; pick another" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"; root_native="$(native "$ROOT")"
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-core-profile-XXXXXX")"
pids=()
cleanup() {
  local status=$?
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  sleep 0.5
  for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  [ "${KEEP:-0}" = 1 ] || [ "$status" != 0 ] || rm -rf "$work"
  return "$status"
}
trap cleanup EXIT

mock_port=$((BASE + 50))
node scripts/mock-provider-a24.cjs "$mock_port" > "$work/mock.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 40); do curl -fsS -m 2 "http://127.0.0.1:$mock_port/" >/dev/null 2>&1 && break; sleep 0.1; done

home="$work/home"; mkdir -p "$home/.wasm-agent"
port="$BASE"
(
  while IFS= read -r variable; do
    case "$variable" in WASM_AGENT_*|WA_SCRIPT|OPENAI_API_KEY|OPENCODE_GO_API_KEY) unset "$variable" ;; esac
  done < <(compgen -e)
  export WASM_AGENT_HOME="$(native "$home")" WASM_AGENT_LUA_ROOT="$root_native"
  export WASM_AGENT_LLM_BASE_URL="http://127.0.0.1:$mock_port" WASM_AGENT_LLM_API_KEY=test-only WASM_AGENT_LLM_MODEL=stub-model
  export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0
  export WA_AGENT_CORE_WASM="$core" WA_CORE_CALL_PROFILE=1
  exec "$bin" --db "$(native "$home/t.db")" serve --port "$port" --client-port "$((port + 1))" \
    --ui "$root_native/ui" --core component
) > "$work/serve.log" 2>&1 &
pid=$!; pids+=("$pid")
code=""
for _ in $(seq 1 200); do
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)"
  [ "$code" = 200 ] && break
  sleep 0.25
done
[ "$code" = 200 ] || { echo "profile: the node did not come up" >&2; tail -5 "$work/serve.log" >&2; exit 1; }

# Two warm-up turns, so the blocks being summed are steady-state ones.
for i in 1 2; do
  curl -s -o /dev/null -m 120 -X POST -H 'content-type: application/json' \
    --data "{\"text\":\"warm $i\",\"thread\":\"warm-$i\"}" "http://127.0.0.1:$port/chat" 2>/dev/null
done
: > "$work/mark"
mark="$(wc -l < "$work/serve.log")"
for i in $(seq 1 "$TURNS"); do
  curl -s -o /dev/null -m 180 -X POST -H 'content-type: application/json' \
    --data "{\"text\":\"profile turn $i\",\"thread\":\"profile-$i\"}" "http://127.0.0.1:$port/chat" 2>/dev/null
done
for i in $(seq 1 "$TURNS"); do
  curl -s -o /dev/null -m 120 "http://127.0.0.1:$port/sessions" 2>/dev/null
done
sleep 3
curl -s -m 10 "http://127.0.0.1:$port/health" > "$work/health.json" 2>/dev/null
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

tail -n "+$((mark + 1))" "$work/serve.log" | grep -E '^core_call_profile:' > "$work/blocks"
[ -s "$work/blocks" ] || { echo "profile: no core_call_profile lines (is WA_CORE_CALL_PROFILE reaching the node?)" >&2; exit 1; }

echo "profile: $TURNS turns + $TURNS reads, component core, $(cat "$work/health.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let h={};try{h=JSON.parse(s)}catch(e){};const c=h.core||{};process.stdout.write("instances="+(c.instances??"?")+" leased="+(c.leased??"?")+" runs="+(c.runs??"?")+" calls="+(c.calls??"?")+" boots="+(c.boots??"?")+" guest_run_ms="+(c.guest_run_ms??"?"))})')"
node - "$work/blocks" <<'JS'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean);
const summary = { items: 0, run_ms: 0, host_ms: 0, guest_ms: 0, calls: 0, arg_bytes: 0, result_bytes: 0, json_ms: 0, arm_ms: 0 };
const names = new Map();
for (const line of lines) {
  const rest = line.slice("core_call_profile:".length);
  if (/^\s+item=/.test(rest)) continue;
  const head = rest.match(/^\s+(\S+) run_ms=([\d.]+) host_ms=([\d.]+) guest_ms=([\d.]+) calls=(\d+) names=(\d+) arg_bytes=(\d+) result_bytes=(\d+) json_decode_ms=([\d.]+) arm_ms=([\d.]+)/);
  if (head) {
    summary.items += 1;
    summary.run_ms += +head[2]; summary.host_ms += +head[3]; summary.guest_ms += +head[4];
    summary.calls += +head[5]; summary.arg_bytes += +head[7]; summary.result_bytes += +head[8];
    summary.json_ms += +head[9]; summary.arm_ms += +head[10];
    continue;
  }
  const row = rest.match(/^\s+(\S+) calls=(\d+) arg_bytes=(\d+) result_bytes=(\d+) host_ms=([\d.]+)/);
  if (row) {
    const entry = names.get(row[1]) || { calls: 0, arg_bytes: 0, result_bytes: 0, host_ms: 0 };
    entry.calls += +row[2]; entry.arg_bytes += +row[3]; entry.result_bytes += +row[4]; entry.host_ms += +row[5];
    names.set(row[1], entry);
  }
}
const n = Math.max(summary.items, 1);
console.log(`profile: ${summary.items} work items after warm-up`);
console.log(`profile: per item  run ${(summary.run_ms / n).toFixed(1)}ms  in handlers ${(summary.host_ms / n).toFixed(1)}ms  guest+crossing ${(summary.guest_ms / n).toFixed(1)}ms  calls ${(summary.calls / n).toFixed(0)}  arg ${(summary.arg_bytes / n / 1024).toFixed(1)}KiB  result ${(summary.result_bytes / n / 1024).toFixed(1)}KiB  json_decode ${(summary.json_ms / n).toFixed(2)}ms  epoch_arm ${(summary.arm_ms / n).toFixed(3)}ms`);
const rows = [...names.entries()].sort((a, b) => b[1].host_ms - a[1].host_ms);
console.log("profile:   name                 calls/item  arg_B/item  result_B/item  handler_ms/item");
for (const [name, s] of rows) {
  console.log(`profile:   ${name.padEnd(20)} ${(s.calls / n).toFixed(1).padStart(10)} ${(s.arg_bytes / n).toFixed(0).padStart(11)} ${(s.result_bytes / n).toFixed(0).padStart(14)} ${(s.host_ms / n).toFixed(2).padStart(15)}`);
}
JS
# The trap keeps the work dir only when the run failed or KEEP=1, so the raw blocks are there to read
# when a number needs explaining.
[ "${KEEP:-0}" = 1 ] && echo "profile: raw blocks kept at $work/blocks" >&2
exit 0
