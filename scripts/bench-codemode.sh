#!/usr/bin/env bash
# What code mode costs, native and as a component: median and p95 of 30 runs per scenario, the Lua→host
# crossings each script cost, and each path's peak process RSS (docs/CORE-SPLIT.md, docs/CODEMODE.md).
#
#   bash scripts/bench-codemode.sh
#
# Scenarios (scripts/bench-codemode.lua): (a) `return 1`, (b) one tool call, (c) ten parallel tool calls
# through `Promise.all`, (d) a 200 KB result passed back, (e) the first script in a process (cold) against
# the steady state (warm).
#
# READ THIS BEFORE TRUSTING A CELL: the guest VM is not in these numbers. `quickjs.wasm`/`prelude.js`
# are provisioned, not vendored, and this checkout has not been provisioned, so *both* paths are driven
# by the same scripted protocol peer (the native path by patching `host.quickjs` inside the bench, the
# component path by `WA_CODEMODE_SANDBOX_STUB=1`). The peer is the same work on both sides, so the
# difference the table shows is the seam — the loop, the boundary, the copies. With the assets
# provisioned, drop the patch and the stub and the same table measures the real guest.
#
# One process per path, because RSS is a property of the process. Local only: a temp WASM_AGENT_HOME,
# an empty rendezvous/relay, no node, no network, no `wa serve`.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

bin="${WA_BIN:-}"
for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" \
         "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
         "${CARGO_TARGET_DIR:-/nonexistent}/debug/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/debug/wa" \
         "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "FAIL no wa binary" >&2; exit 2; }

TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/codemode.wasm"
if [ ! -f "$artifact" ]; then
  echo "building rust/components/codemode (wasm32-wasip2) ..."
  ( cd rust/components/codemode && cargo build --release --offline --target wasm32-wasip2 ) || exit 1
fi

RUNS="${WA_BENCH_RUNS:-30}"
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
home=$(mktemp -d "${TMPDIR:-/tmp}/wa-bench-codemode-XXXXXX")
trap 'rm -rf "$home"' EXIT
: > "$home/rss.tsv"

# One measured run of one path; prints the run's peak RSS in KB (empty when nothing can sample it).
measure() {
  local path=$1 extra=()
  if [ "$path" = component ]; then
    extra=("WA_CODEMODE_SANDBOX_STUB=1" "WA_CODEMODE_COMPONENT_WASM=$(native_path "$artifact")")
  fi
  local out="$home/$path.tsv" log="$home/$path.log" pid peak=""
  # Git Bash emulates `/proc` well enough to have a status file and not well enough to have `VmHWM`:
  # the sampler is /proc only when it actually reports a peak.
  if awk '/VmHWM/ {found=1} END {exit !found}' /proc/self/status 2>/dev/null; then
    env WASM_AGENT_LUA_ROOT="$(native_path "$ROOT")" \
        WASM_AGENT_HOME="$(native_path "$home")" \
        WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
        WA_SCRIPT=scripts/bench-codemode.lua \
        WA_BENCH_PATH="$path" \
        WA_BENCH_RUNS="$RUNS" \
        WA_BENCH_OUT="$(native_path "$out")" \
        "${extra[@]}" \
        "$bin" --db "$(native_path "$home/$path.db")" > "$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      local sample
      sample=$(awk '/VmHWM/ {print $2}' "/proc/$pid/status" 2>/dev/null)
      [ -n "$sample" ] && peak=$sample
      sleep 0.05
    done
    wait "$pid" || { echo "FAIL the $path run exited $?:" >&2; tail -3 "$log" >&2; }
  elif command -v powershell >/dev/null 2>&1; then
    # Windows has no /proc: the peak comes from the process object PowerShell started.
    peak=$(env WASM_AGENT_LUA_ROOT="$(native_path "$ROOT")" \
        WASM_AGENT_HOME="$(native_path "$home")" \
        WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
        WA_SCRIPT=scripts/bench-codemode.lua \
        WA_BENCH_PATH="$path" \
        WA_BENCH_RUNS="$RUNS" \
        WA_BENCH_OUT="$(native_path "$out")" \
        "${extra[@]}" \
        BENCH_BIN="$(native_path "$bin")" BENCH_DB="$(native_path "$home/$path.db")" \
        BENCH_LOG="$(native_path "$log")" BENCH_ERR="$(native_path "$log.err")" \
        powershell -NoProfile -Command '
          $p = Start-Process -FilePath $env:BENCH_BIN -ArgumentList @("--db", $env:BENCH_DB) -NoNewWindow -PassThru `
               -RedirectStandardOutput $env:BENCH_LOG -RedirectStandardError $env:BENCH_ERR
          $peak = 0
          while (-not $p.HasExited) {
            try { $p.Refresh(); if ($p.WorkingSet64 -gt $peak) { $peak = $p.WorkingSet64 } } catch {}
            Start-Sleep -Milliseconds 20
          }
          [math]::Round($peak/1024)' 2>/dev/null | tr -d '\r' | awk '{printf "%d", $1}')
  else
    env WASM_AGENT_LUA_ROOT="$(native_path "$ROOT")" \
        WASM_AGENT_HOME="$(native_path "$home")" \
        WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
        WA_SCRIPT=scripts/bench-codemode.lua \
        WA_BENCH_PATH="$path" \
        WA_BENCH_RUNS="$RUNS" \
        WA_BENCH_OUT="$(native_path "$out")" \
        "${extra[@]}" \
        "$bin" --db "$(native_path "$home/$path.db")" > "$log" 2>&1 || {
      echo "FAIL the $path run failed:" >&2; tail -3 "$log" >&2; }
  fi
  printf '%s\t%s\n' "${peak:-n/a}" "$path" >> "$home/rss.tsv"
}

measure native
measure component

for path in native component; do
  [ -s "$home/$path.tsv" ] || { echo "FAIL the $path run produced no measurements:" >&2; tail -5 "$home/$path.log" >&2; exit 1; }
done

echo
echo "code-mode cost: median / p95 of $RUNS in-process runs per scenario (ms), crossings per script"
printf '%-9s %-14s %8s %8s %10s %9s %8s\n' path scenario median p95 crossings sandbox-kb rss-kb
while IFS=$'\t' read -r path scenario median p95 crossings; do
  [ -n "${path:-}" ] || continue
  rss=$(awk -F'\t' -v p="$path" '$2==p {print $1}' "$home/rss.tsv" | tail -1)
  # The sandbox crossings are the same number on every run of a scenario; take the last row's.
  sandbox=$(awk -F'\t' -v p="$path" -v s="$scenario" '$1==p && $2==s {value=$6} END {print value}' "$home/native.tsv" "$home/component.tsv")
  printf '%-9s %-14s %8s %8s %10s %9s %8s\n' "$path" "$scenario" "$median" "$p95" "$crossings" "${sandbox:-n/a}" "${rss:-n/a}"
done < <(cat "$home/native.tsv" "$home/component.tsv" | python -c '
import sys, collections, math
rows = collections.OrderedDict()
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 6:
        continue
    path, scenario, run, ms, crossings, sandbox = parts
    rows.setdefault((path, scenario), {"ms": [], "crossings": set()})
    rows[(path, scenario)]["ms"].append(float(ms))
    rows[(path, scenario)]["crossings"].add(int(crossings))
for (path, scenario), data in rows.items():
    values = sorted(data["ms"])
    n = len(values)
    median = values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2
    rank = max(0, math.ceil(0.95 * n) - 1)
    p95 = values[rank]
    crossings = "/".join(str(value) for value in sorted(data["crossings"]))
    print("%s\t%s\t%.2f\t%.2f\t%s" % (path, scenario, median, p95, crossings))
')

echo
echo "crossings are Lua->host capability calls per script (native: host.quickjs+host.uuid+host.sha256;"
echo "component: host.codemode calls). sandbox-kb is the component's own count of sandbox crossings for"
echo "that script (the native path's equals its host.quickjs count). rss-kb is the peak resident set of"
echo "that path's whole process."
echo
echo "THE GUEST VM IS NOT IN THESE NUMBERS: the pinned assets are not provisioned in this checkout, so"
echo "both paths run the same scripted protocol peer (see the header of scripts/bench-codemode.lua)."
