#!/usr/bin/env bash
# The hooks seam's cost, before and after: the latency of one event fire with 0, 1 and 10 hooks, the
# host crossings that costs, and the peak RSS of each path (docs/CORE-SPLIT.md, "Cost").
#
#   bash scripts/bench-hooks.sh
#
# One process per path, because RSS is a property of the process: each run prints its p50/p95 and its
# crossings, and this wrapper samples that run's peak resident set. Local only: a temp WASM_AGENT_HOME,
# an empty rendezvous/relay, an unmanaged node, no network, no `wa serve`, and only processes this
# script started.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

bin="${WA_BIN:-}"
for c in "${CARGO_TARGET_DIR:-/nonexistent}/release/wa.exe" "${CARGO_TARGET_DIR:-/nonexistent}/release/wa" \
         "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/release/wa" \
         "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "FAIL no wa binary" >&2; exit 2; }

TARGET="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
artifact="$TARGET/wasm32-wasip2/release/hooks.wasm"
if [ ! -f "$artifact" ]; then
  echo "building rust/components/hooks (wasm32-wasip2) ..."
  ( cd rust/components/hooks && cargo build --release --offline --target wasm32-wasip2 ) || exit 1
fi

native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
home=$(mktemp -d "${TMPDIR:-/tmp}/wa-bench-hooks-XXXXXX")
trap 'rm -rf "$home"' EXIT
: > "$home/rss.tsv"

# One measured run of one path; prints the run's peak RSS in KB (empty when nothing can sample it).
measure() {
  local path=$1
  local out="$home/$path.tsv" log="$home/$path.log" pid peak=""
  if awk '/VmHWM/ {found=1} END {exit !found}' /proc/self/status 2>/dev/null; then
    env WASM_AGENT_LUA_ROOT="$(native_path "$ROOT")" \
        WASM_AGENT_HOME="$(native_path "$home")" \
        WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
        WA_SCRIPT=scripts/bench-hooks.lua \
        WA_BENCH_PATH="$path" \
        WA_BENCH_OUT="$(native_path "$out")" \
        WA_HOOKS_COMPONENT="$([ "$path" = native ] && echo 0 || echo 1)" \
        WA_HOOKS_COMPONENT_WASM="$(native_path "$artifact")" \
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
        WA_SCRIPT=scripts/bench-hooks.lua \
        WA_BENCH_PATH="$path" \
        WA_BENCH_OUT="$(native_path "$out")" \
        WA_HOOKS_COMPONENT="$([ "$path" = native ] && echo 0 || echo 1)" \
        WA_HOOKS_COMPONENT_WASM="$(native_path "$artifact")" \
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
        WA_SCRIPT=scripts/bench-hooks.lua \
        WA_BENCH_PATH="$path" \
        WA_BENCH_OUT="$(native_path "$out")" \
        WA_HOOKS_COMPONENT="$([ "$path" = native ] && echo 0 || echo 1)" \
        WA_HOOKS_COMPONENT_WASM="$(native_path "$artifact")" \
        "$bin" --db "$(native_path "$home/$path.db")" > "$log" 2>&1 || {
      echo "FAIL the $path run failed:" >&2; tail -3 "$log" >&2; }
  fi
  printf '%s\t%s\n' "${peak:-n/a}" "$path" >> "$home/rss.tsv"
}

measure native
measure component

echo
echo "hooks seam cost (median of 21 in-process fires per scenario; crossings are host.hooks calls"
echo "per fire, so the native path - where the engine is the interpreter - has none)"
printf '%-9s %-32s %7s %7s %10s %8s\n' path scenario p50-ms p95-ms crossings rss-kb
while IFS=$'\t' read -r path scenario p50 p95 crossings runs; do
  [ -n "${path:-}" ] || continue
  rss=$(awk -F'\t' -v p="$path" '$2==p {print $1}' "$home/rss.tsv" | tail -1)
  printf '%-9s %-32s %7s %7s %10s %8s\n' "$path" "$scenario" "$p50" "$p95" "${crossings:-n/a}" "${rss:-n/a}"
done < <(cat "$home/native.tsv" "$home/component.tsv" 2>/dev/null)

echo
echo "The p50/p95 of a fire include the hook's own process spawn (a shell per hook, milliseconds on"
echo "this host); the 'decide one row' row is the seam's own cost with the row already in hand. rss is"
echo "the peak resident set of that path's whole process (n/a when this machine has no sampler)."
