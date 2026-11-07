#!/usr/bin/env bash
# What a crossing costs, in isolation from a whole turn (docs/KERNEL.md, "A2.1"): the same Lua
# fixtures run once on the native interpreter and once inside the agent-core component.
#
#   bash scripts/bench-core-bridge.sh [reps]
#
# Fixtures (generated into the scratch dir, so nothing here is a fixture a test depends on). Each one
# times its own workload with `host.monotonic_ms()` and prints `elapsed_ms`, so process start, the
# database and the interpreter boot are outside the number and the two cores are compared on the work
# alone - the same reason the A2.1 table quotes a `run` column beside the wall time.
#
#   pure     a Lua loop with no host call at all        -> the interpreter factor, nothing else
#   calls    one `host.monotonic_ms()` per iteration     -> what one small crossing costs
#   sha      one `host.sha256(<10 KiB>)` per iteration   -> what one crossing of payload costs
#   dofile   `dofile('lua/core/paths.lua')` per iteration -> the module-read path a boot and many turn
#            steps use (read the file, digest it, run its body)
#
# Medians of `reps` runs (default 5), the modes alternated within each rep so a machine that drifts is
# seen by all of them. `AGENT_CORE_B=<other agent_core.wasm>` adds a third column measured the same
# way: that is how a change to the guest alone is measured (a = AGENT_CORE, b = AGENT_CORE_B).
# Needs a `wa` binary and a built agent-core.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
REPS="${1:-5}"
LOOP_ITERS="${LOOP_ITERS:-400000}"
CALL_ITERS="${CALL_ITERS:-100000}"
SHA_ITERS="${SHA_ITERS:-3000}"
DOFILE_ITERS="${DOFILE_ITERS:-3000}"
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
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-core-bridge-XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts"

# Every fixture prints exactly one `elapsed_ms <n>` line; the timer is the host's monotonic clock, so
# what it measures is the workload in both cores and nothing about the process around it.
cat > "$work/scripts/pure.lua" <<LUA
local t0 = host.monotonic_ms()
local x = 0
for i = 1, $LOOP_ITERS do
  x = (x + i * 3) % 1000003
  x = x + #string.format('%d', i)
end
print('elapsed_ms', host.monotonic_ms() - t0)
LUA
cat > "$work/scripts/calls.lua" <<LUA
local t0 = host.monotonic_ms()
local n = 0
for _ = 1, $CALL_ITERS do n = n + host.monotonic_ms() % 2 end
print('elapsed_ms', host.monotonic_ms() - t0)
LUA
cat > "$work/scripts/sha.lua" <<LUA
local text = string.rep('the quick brown fox jumps over the lazy dog. ', 228)
local t0 = host.monotonic_ms()
local n = 0
for _ = 1, $SHA_ITERS do n = n + #host.sha256(text) end
print('elapsed_ms', host.monotonic_ms() - t0)
LUA
cat > "$work/scripts/dofile.lua" <<LUA
local t0 = host.monotonic_ms()
local n = 0
for _ = 1, $DOFILE_ITERS do n = n + #(dofile('lua/core/paths.lua').home() or '') end
print('elapsed_ms', host.monotonic_ms() - t0)
LUA

# One process, its own scratch home and ledger, the workload's own elapsed time in microseconds.
run_once() { # run_once <mode> <script> [core]
  local mode=$1 script=$2 wasm=${3:-$core} slot out
  slot="$(mktemp -d "$work/slot-XXXXXX")"
  if [ "$mode" = native ]; then
    out=$(env -u CARGO_TARGET_DIR WASM_AGENT_HOME="$(native "$slot/home")" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= \
      WASM_AGENT_MANAGED=0 WASM_AGENT_LUA_ROOT="$root_native" \
      WA_SCRIPT="$(native "$script")" "$bin" --db "$(native "$slot/t.db")" 2>&1)
  else
    out=$(env -u CARGO_TARGET_DIR WASM_AGENT_HOME="$(native "$slot/home")" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= \
      WASM_AGENT_MANAGED=0 WASM_AGENT_LUA_ROOT="$root_native" \
      "$bin" --db "$(native "$slot/t.db")" --core-component "$wasm" "$(native "$script")" 2>&1)
  fi
  rm -rf "$slot"
  # `print` separates with a tab, and the value is milliseconds with sub-microsecond digits.
  printf '%s\n' "$out" | awk '$1=="elapsed_ms"{printf "%.0f\n", $2*1000; found=1} END{if(!found) print 0}'
}
export -f run_once native
export work bin core root_native

median() { sort -n | awk '{v[NR]=$1} END{ if (NR==0) {print "?"; exit} if (NR%2) printf "%.0f", v[(NR+1)/2]; else printf "%.0f", (v[NR/2]+v[NR/2+1])/2 }'; }
column() { awk -v f="$2" '$1==f{print $2}' "$1" | median; }

fixtures="pure calls sha dofile"
: > "$work/native.txt"; : > "$work/a.txt"; : > "$work/b.txt"
for _ in $(seq 1 "$REPS"); do
  for fixture in $fixtures; do
    printf '%s %s
' "$fixture" "$(run_once native "$work/scripts/$fixture.lua")" >> "$work/native.txt"
    printf '%s %s
' "$fixture" "$(run_once component "$work/scripts/$fixture.lua" "$core")" >> "$work/a.txt"
    if [ -n "$core_b" ]; then
      printf '%s %s
' "$fixture" "$(run_once component "$work/scripts/$fixture.lua" "$core_b")" >> "$work/b.txt"
    fi
  done
done

printf 'bench: reps=%s loop=%s calls=%s sha=%s dofile=%s (%s)
'   "$REPS" "$LOOP_ITERS" "$CALL_ITERS" "$SHA_ITERS" "$DOFILE_ITERS" "$(uname -s)"
if [ -n "$core_b" ]; then
  printf 'bench: %-10s %10s %10s %10s %8s %8s %12s %12s
' fixture native a b a/native b/a per-op-a per-op-b
else
  printf 'bench: %-10s %11s %11s %8s %12s
' fixture native component ratio per-op
fi

per_op() { awk -v d="$1" -v o="$2" 'BEGIN{ if (o+0>0) printf "%+.2fus", d / o; else printf "-" }'; }
ratio_of() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0>0) printf "%.2f", a/b; else print "?" }'; }
ms() { awk -v v="$1" 'BEGIN{printf "%.1f", v/1000}'; }

for fixture in $fixtures; do
  case "$fixture" in
    pure) ops="$LOOP_ITERS" ;;
    calls) ops="$CALL_ITERS" ;;
    sha) ops="$SHA_ITERS" ;;
    dofile) ops="$DOFILE_ITERS" ;;
  esac
  n=$(column "$work/native.txt" "$fixture")
  a=$(column "$work/a.txt" "$fixture")
  if [ -n "$core_b" ]; then
    b=$(column "$work/b.txt" "$fixture")
    printf 'bench: %-10s %8sms %8sms %8sms %7sx %7sx %12s %12s
' "$fixture"       "$(ms "$n")" "$(ms "$a")" "$(ms "$b")" "$(ratio_of "$a" "$n")" "$(ratio_of "$b" "$a")"       "$(per_op "$((a - n))" "$ops")" "$(per_op "$((b - n))" "$ops")"
  else
    printf 'bench: %-10s %9sms %9sms %7sx %12s
' "$fixture"       "$(ms "$n")" "$(ms "$a")" "$(ratio_of "$a" "$n")" "$(per_op "$((a - n))" "$ops")"
  fi
done
