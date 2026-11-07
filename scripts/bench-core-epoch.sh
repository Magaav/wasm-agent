#!/usr/bin/env bash
# What the pool's epoch deadline costs the guest (docs/KERNEL.md, "A2.5"). With
# `Config::epoch_interruption(true)` wasmtime compiles an epoch check into every function entry and
# loop back-edge; the Lua core is one large loop-heavy C program, so the check is not free.
#
#   bash scripts/bench-core-epoch.sh [reps] [fixture.lua]
#
# Three runs of the *same* guest code and the same script, alternated, `reps` times each, all reporting
# the guest's own run time so the process around it is not counted:
#
#   plain        `wa --core-component`: an engine with no epoch interruption (what a one-shot run has)
#   epoch        the same run with `WA_CORE_EPOCH=1`: the identical engine plus epoch checks, and no
#                deadline, so the two columns differ in exactly one compile-time flag
#   pool         `wa-core-pool-bench gate`: the pooling engine a deadline-free pool builds
#                (`CorePoolConfig::run_deadline == ZERO`; with a deadline configured the pool builds
#                `core_pool::epoch_engine` instead, which is the `epoch` column plus a ticker)
#
# Prints medians, the ratios and the machine's load, so a contended measurement is visible instead of
# hidden.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
REPS="${1:-7}"
FIXTURE="${2:-}"
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "bench: no wa binary (set WA_BIN)" >&2; exit 2; }
pool_bin="${WA_POOL_BENCH:-}"
for c in "$ROOT/rust/target/release/wa-core-pool-bench" "$ROOT/rust/target/release/wa-core-pool-bench.exe"; do
  [ -n "$pool_bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && pool_bin="$c"
done
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "bench: no agent-core at $core" >&2; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"; root_native="$(native "$ROOT")"
[ -z "$pool_bin" ] || pool_bin="$(native "$pool_bin")"
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-core-epoch-XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ -z "$FIXTURE" ]; then
  FIXTURE="$work/pure.lua"
  # A loop with no host call: the guest's own Lua, so the only differences between the modes are their
  # engine's compile-time configuration.
  cat > "$FIXTURE" <<'LUA'
local t0 = host.monotonic_ms()
local x = 0
for i = 1, 400000 do
  x = (x + i * 3) % 1000003
  x = x + #string.format('%d', i)
end
print('work_ms', host.monotonic_ms() - t0)
LUA
fi

oneshot() { # oneshot <epoch: on|off>
  local epoch=$1 slot out flag=""
  slot="$(mktemp -d "$work/slot-XXXXXX")"
  [ "$epoch" = on ] && flag="WA_CORE_EPOCH=1"
  out=$(env -u CARGO_TARGET_DIR WASM_AGENT_HOME="$(native "$slot/home")" WASM_AGENT_LUA_ROOT="$root_native" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_CORE_TIMING=1 $flag \
    "$bin" --db "$(native "$slot/t.db")" --core-component "$core" "$(native "$FIXTURE")" 2>&1)
  rm -rf "$slot"
  printf '%s\n' "$out" | awk '$1=="core_component_timing:"{for(i=1;i<=NF;i++) if($i ~ /^run=/){gsub(/run=|ms/,"",$i); print $i}}' | head -1
}

pooled() {
  local slot; slot="$(mktemp -d "$work/slot-XXXXXX")"
  local out
  out=$(env -u CARGO_TARGET_DIR WASM_AGENT_HOME="$(native "$slot/home")" WASM_AGENT_LUA_ROOT="$root_native" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    "$pool_bin" gate "$core" "$(native "$FIXTURE")" 2>&1)
  rm -rf "$slot"
  printf '%s\n' "$out" | awk '$1=="pool_timing:"{for(i=1;i<=NF;i++) if($i ~ /^run=/){gsub(/run=|ms/,"",$i); print $i}}' | head -1
}

median() { sort -n | awk '{v[NR]=$1} END{ if (NR==0) {print "?"; exit} if (NR%2) printf "%.1f", v[(NR+1)/2]; else printf "%.1f", (v[NR/2]+v[NR/2+1])/2 }'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0>0) printf "%.2f", a/b; else print "?" }'; }

# The modes alternate and which one goes first rotates every rep: a machine that drifts within a rep (a
# build finishing, a fan spinning up) must not be able to look like a property of the engine.
: > "$work/plain.txt"; : > "$work/epoch.txt"; : > "$work/pool.txt"
rep=1
while [ "$rep" -le "$REPS" ]; do
  case $((rep % 3)) in
    1) printf '%s\n' "$(oneshot off)" >> "$work/plain.txt"; printf '%s\n' "$(oneshot on)" >> "$work/epoch.txt"
       [ -z "$pool_bin" ] || printf '%s\n' "$(pooled)" >> "$work/pool.txt" ;;
    2) printf '%s\n' "$(oneshot on)" >> "$work/epoch.txt"; [ -z "$pool_bin" ] || printf '%s\n' "$(pooled)" >> "$work/pool.txt"
       printf '%s\n' "$(oneshot off)" >> "$work/plain.txt" ;;
    *) [ -z "$pool_bin" ] || printf '%s\n' "$(pooled)" >> "$work/pool.txt"; printf '%s\n' "$(oneshot off)" >> "$work/plain.txt"
       printf '%s\n' "$(oneshot on)" >> "$work/epoch.txt" ;;
  esac
  rep=$((rep + 1))
done

load="n/a"; [ -r /proc/loadavg ] && load="$(cut -d' ' -f1-3 /proc/loadavg)"
cargo_running="$(tasklist //FO CSV //NH 2>/dev/null | grep -ciE '"(cargo|rustc)\.exe"' || true)"
plain="$(median < "$work/plain.txt")"; epoch="$(median < "$work/epoch.txt")"
echo "bench: epoch-interruption cost, reps=$REPS, fixture=$(basename "$FIXTURE")"
echo "bench: plain (no epoch)   $(paste -sd' ' "$work/plain.txt")  median ${plain}ms"
echo "bench: epoch checks on    $(paste -sd' ' "$work/epoch.txt")  median ${epoch}ms   ratio $(ratio "$epoch" "$plain")x"
if [ -n "$pool_bin" ]; then
  pool="$(median < "$work/pool.txt")"
  echo "bench: pool (no deadline) $(paste -sd' ' "$work/pool.txt")  median ${pool}ms   ratio $(ratio "$pool" "$plain")x vs plain"
fi
echo "bench: load ${load}  cargo/rustc processes ${cargo_running:-0}"
