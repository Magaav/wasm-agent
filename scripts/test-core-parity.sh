#!/usr/bin/env bash
# A2.4 parity: the Lua test set the fast path runs, once on the native interpreter and once inside the
# agent-core component, with the two outputs diffed (docs/KERNEL.md, "A2.4").
#
#   bash scripts/test-core-parity.sh [--jobs N] [--keep]
#
# The set is exactly `scripts/test-*.lua` minus `scripts/fast-path.exclude`: the same self-contained
# tests the day-to-day path runs, each with its own scratch home and ledger, so nothing here needs the
# network, a node or a provider. Every script runs twice - `WA_SCRIPT=...` for the native core and
# `--core-component agent_core.wasm` for the component core - and the harness fails when the exit code
# differs or when the normalized output differs.
#
# What is normalized away: values that differ between any two runs of the *same* mode (uuids, `Nms`
# timings, the scratch home's own path, epoch seconds). Everything else is compared byte for byte, so a
# check that answers a different string, loses a line or gains one fails here.
#
# A test that needs a capability the component core refuses is not hidden: it fails, and the report
# lists it. Requires the agent-core component (bash scripts/build-agent-core.sh, wasi-sdk).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
jobs=$(nproc 2>/dev/null || echo 4); keep=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) jobs=${2:?}; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "parity: unknown option $1" >&2; exit 2 ;;
  esac
done

bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
[ -n "$bin" ] || { echo "parity: no wa binary (set WA_BIN)" >&2; exit 2; }
core="${AGENT_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}"
[ -f "$core" ] || { echo "parity: no agent-core at $core (run bash scripts/build-agent-core.sh)" >&2; exit 2; }

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
bin="$(native "$bin")"; core="$(native "$core")"; root_native="$(native "$ROOT")"
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-parity-XXXXXX")"
trap '[ "$keep" = 1 ] || rm -rf "$work"' EXIT

excluded=$(sed -n 's/^\(scripts\/test-[^ #]*\.lua\).*/\1/p' scripts/fast-path.exclude 2>/dev/null)
for f in scripts/test-*.lua; do printf '%s\n' "$excluded" | grep -qxF "$f" || printf '%s\n' "$f"; done > "$work/list"

# One script in one mode: its own home, its own ledger, no node and no network.
run_mode() {
  mode=$1; f=$2
  # The output lives beside the home, never inside it: `test-update-banner` deletes its own
  # WASM_AGENT_HOME as part of its fixture, and an `out` under it would vanish with the run's exit code.
  # One letter per mode, so the two runs' paths are the same length: a byte count or a path length in a
  # test's own measurement must not differ because of how this harness names its directories.
  case "$mode" in native) short=n ;; *) short=c ;; esac
  slot="$work/$short/$(basename "$f" .lua)"; h="$slot/home"; mkdir -p "$h"
  if [ "$mode" = native ]; then
    WASM_AGENT_LUA_ROOT="$root_native" WASM_AGENT_HOME="$(native "$h")" \
      WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT="$f" \
      timeout 180 "$bin" --db "$(native "$h/t.db")" > "$slot/out" 2>&1
  else
    WASM_AGENT_LUA_ROOT="$root_native" WASM_AGENT_HOME="$(native "$h")" \
      WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
      timeout 300 "$bin" --db "$(native "$h/t.db")" --core-component "$core" "$(native "$ROOT/$f")" > "$slot/out" 2>&1
  fi
  echo "$?" > "$slot/code"
}
export -f run_mode native
export bin core root_native work ROOT

# The two modes' outputs, normalized: only values that differ between two runs of the same mode.
normalize() {
  sed -E \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
    -e 's/[0-9]+(\.[0-9]+)? ?ms\b/<ms>/g' \
    -e 's/[0-9]{10}(\.[0-9]+)?/<epoch>/g' \
    -e 's/"cpu_seconds":[0-9.]+/"cpu_seconds":<n>/g' \
    -e 's/"wall_ms":\{[^}]*\}/"wall_ms":<n>/g' \
    -e 's/(ms )[0-9]+(\.[0-9]+)?/\1<n>/g' \
    -e 's/\[string "[^"]*"\]/[string <chunk>]/g' \
    -e 's#(wa-parity-[A-Za-z0-9]{6})[/\\](n|c)[/\\]#\1/<mode>/#g' \
    -e 's#(wa-parity-[A-Za-z0-9]{6}|/tmp/wa-parity-[A-Za-z0-9]{6})#<work>#g' \
    -e 's#(\\\\)?[A-Za-z]:[\\/][^ "]*wa-parity-[A-Za-z0-9]{6}[^ "]*#<work>#g' \
    -e 's/^(lua root unset:.*)$//' \
    "$1" | sed -e '/^[[:space:]]*$/d'
}

while IFS= read -r f; do
  echo "$f"
done < "$work/list" | xargs -P "$jobs" -I{} bash -c 'run_mode native "$1"; run_mode component "$1"' _ {}

pass=0; fail=0; same_fail=0; failed=""
for f in $(cat "$work/list"); do
  name=$(basename "$f" .lua)
  nc=$(cat "$work/n/$name/code" 2>/dev/null || echo 999)
  cc=$(cat "$work/c/$name/code" 2>/dev/null || echo 999)
  normalize "$work/n/$name/out" > "$work/n/$name/norm"
  normalize "$work/c/$name/out" > "$work/c/$name/norm"
  reason=""
  [ -f "$work/n/$name/out" ] && [ -f "$work/c/$name/out" ] || reason="the harness did not run it"
  [ -z "$reason" ] && { [ "$nc" = "$cc" ] || reason="exit $nc vs $cc"; }
  if [ -z "$reason" ] && ! diff -q "$work/n/$name/norm" "$work/c/$name/norm" >/dev/null 2>&1; then
    reason="output differs"
  fi
  if [ -z "$reason" ] && [ "$nc" != 0 ]; then
    # Identical failure in both modes is parity - the test is broken or unsuited to this environment,
    # not the component. Counted apart so it can never be read as a pass.
    same_fail=$((same_fail + 1)); printf 'both-fail %s (exit %s, same output)\n' "$f" "$nc"
    continue
  fi
  if [ -z "$reason" ]; then
    pass=$((pass + 1)); printf 'same  %s\n' "$f"
  else
    fail=$((fail + 1)); failed="$failed$f: $reason\n"
    printf 'DIFF  %s (%s)\n' "$f" "$reason"
    diff -u "$work/n/$name/norm" "$work/c/$name/norm" 2>/dev/null | sed -n '1,14p' | sed 's/^/      /'
  fi
done

total=$((pass + fail + same_fail))
echo
echo "parity: $pass/$total scripts pass on both cores with identical output"
echo "parity: $same_fail/$total fail identically on both cores (environment or fixture, not the core)"
if [ "$fail" -gt 0 ]; then
  printf "$failed" | sed 's/^/  /'
  echo "  outputs kept at $work"
  exit 1
fi
