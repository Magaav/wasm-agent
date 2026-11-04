#!/usr/bin/env bash
# The fast path: the day-to-day check before landing a change. Minutes, not the gate's ~50.
#
#   bash scripts/fast.sh [--jobs N] [--all-rust] [--docker]
#
# What it runs, in parallel where it can:
#   1. every scripts/test-*.lua not listed in scripts/fast-path.exclude, each with its own scratch home and
#      ledger (hermetic: no node, no network, no shared state);
#   2. Rust unit tests for the crates this change touches (vs the merge base with origin/main, plus the
#      working tree); --all-rust runs every crate. wa-sentinel runs single-threaded (its tests share
#      process-wide environment);
#   3. contract checks: prompt docs in sync with the code; instruction-file checks when node is present.
#
# A check that cannot run here (no node, no cargo) is reported SKIPPED and counted, never passed.
# The full gate (scripts/test.sh) is the nightly job, not a landing requirement (AGENTS.md).
# --docker runs the whole fast path inside the sandbox image (a laptop with no wa binary).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
jobs=$(nproc 2>/dev/null || echo 4); all_rust=0; docker_mode=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) jobs=${2:?}; shift 2 ;;
    --all-rust) all_rust=1; shift ;;
    --docker) docker_mode=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fast: unknown option $1" >&2; exit 2 ;;
  esac
done

# ---- the binary -------------------------------------------------------------------------------------
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa" "$ROOT/rust/target/release/wa" "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ "$docker_mode" = 1 ] || [ -z "$bin" ]; then
  [ -z "${DOCKER_HOST:-}" ] && [ -S "/run/user/$(id -u)/docker.sock" ] && export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  image=${WA_FAST_IMAGE:-wasm-agent-sandbox:local}
  if command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
    echo "fast: no wa binary here; running inside $image"
    host_timings=$(git rev-parse --absolute-git-dir)/wa-fast-timings.tsv; touch "$host_timings"
    exec docker run --rm --user 0 -v "$ROOT:/t:ro" -v "$host_timings:/t/.git/wa-fast-timings.tsv" -w /t -e WA_FAST_IN_DOCKER=1 "$image" bash scripts/fast.sh --jobs "$jobs" $([ "$all_rust" = 1 ] && echo --all-rust)
  fi
  echo "fast: no wa binary (WA_BIN, PATH, ~/.local/bin, rust/target/release) and no sandbox image; cannot run" >&2
  exit 2
fi
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
started=$(date +%s)
work=$(mktemp -d "${TMPDIR:-/tmp}/wa-fast-XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0; skipped=0; ran=0

# ---- 1. Lua -----------------------------------------------------------------------------------------
excluded=$(sed -n 's/^\(scripts\/test-[^ #]*\.lua\).*/\1/p' scripts/fast-path.exclude 2>/dev/null)
for f in scripts/test-*.lua; do printf '%s\n' "$excluded" | grep -qxF "$f" || printf '%s\n' "$f"; done > "$work/lua.list"
# Slowest first, from this checkout's previous run, so a long test does not start last and set the tail.
timings=$(git rev-parse --git-path wa-fast-timings.tsv 2>/dev/null || true)
if [ -n "$timings" ] && [ -s "$timings" ]; then
  awk -F'\t' 'NR==FNR{ms[$3]=$2; next} {print (($0 in ms)?ms[$0]:999999) "\t" $0}' "$timings" "$work/lua.list" | sort -rn | cut -f2 > "$work/lua.sorted" \
    && mv "$work/lua.sorted" "$work/lua.list"
fi
export FAST_BIN="$bin" FAST_ROOT="$(native "$ROOT")" FAST_WORK="$work"
run_lua() {
  f=$1; h=$(mktemp -d "$FAST_WORK/h.XXXXXX"); s=$(date +%s%N)
  WASM_AGENT_LUA_ROOT="$FAST_ROOT" WASM_AGENT_HOME="$( (command -v cygpath >/dev/null && cygpath -w "$h") || echo "$h")" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT="$f" \
    timeout 120 "$FAST_BIN" --db "$h/t.db" > "$h/out" 2>&1; c=$?
  printf '%s\t%s\t%s\t%s\n' "$c" "$(( ($(date +%s%N)-s)/1000000 ))" "$f" "$(tail -1 "$h/out" | tr '\t' ' ' | cut -c1-160)"
}
export -f run_lua
xargs -P "$jobs" -I{} bash -c 'run_lua "$1"' _ {} < "$work/lua.list" > "$work/lua.tsv"
lua_total=$(wc -l < "$work/lua.list"); lua_fail=$(awk -F'\t' '$1!=0' "$work/lua.tsv" | wc -l)
[ -n "$timings" ] && cp "$work/lua.tsv" "$timings" 2>/dev/null || true
ran=$((ran + lua_total)); fails=$((fails + lua_fail))
awk -F'\t' '$1!=0{printf "FAIL lua %s (exit %s): %s\n",$3,$1,$4}' "$work/lua.tsv"
echo "fast: lua $((lua_total - lua_fail))/$lua_total passed ($(printf '%s\n' "$excluded" | grep -c . ) excluded: scripts/fast-path.exclude)"

# ---- 2. Rust: the crates this change touches ----------------------------------------------------------
if [ "${WA_FAST_IN_DOCKER:-}" = 1 ]; then
  echo "fast: rust SKIPPED (inside the sandbox image: no toolchain; run on a node with cargo)"; skipped=$((skipped + 1))
elif ! command -v cargo >/dev/null 2>&1; then
  echo "fast: rust SKIPPED (cargo not on PATH)"; skipped=$((skipped + 1))
else
  # Test builds, not shippable ones: the same switch the gate sets (scripts/test.sh) so wa-host's build
  # script does not demand the code-mode assets only a shipping build prepares.
  export WA_CODEMODE_ALLOW_EMPTY=1
  base=$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)
  changed=$( { git diff --name-only "$base" -- rust; git diff --name-only -- rust; git diff --name-only --cached -- rust; } | sort -u)
  crates=""
  for crate in wa-host wa-operation wa-jobs wa-graph wa-sentinel; do
    if [ "$all_rust" = 1 ] || printf '%s\n' "$changed" | grep -q "^rust/$crate/"; then crates="$crates $crate"; fi
  done
  printf '%s\n' "$changed" | grep -qE '^rust/(Cargo\.(toml|lock))$' && [ "$all_rust" = 0 ] && crates=" wa-host wa-operation wa-jobs wa-graph"
  if [ -z "$crates" ]; then echo "fast: rust - no crate touched"; fi
  for crate in $crates; do
    s=$(date +%s)
    if [ "$crate" = wa-sentinel ]; then
      cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1 > "$work/rust-$crate.log" 2>&1
    else
      cargo test --release --offline --manifest-path rust/Cargo.toml -p "$crate" > "$work/rust-$crate.log" 2>&1
    fi
    c=$?; ran=$((ran + 1))
    if [ "$c" = 0 ]; then echo "fast: rust $crate ok ($(( $(date +%s) - s ))s)"
    else fails=$((fails + 1)); echo "FAIL rust $crate (exit $c):"; { grep -E "^test .* FAILED|panicked at|^error" "$work/rust-$crate.log" || tail -5 "$work/rust-$crate.log"; } | head -8; fi
  done
fi

# ---- 3. contract checks -------------------------------------------------------------------------------
check() { name=$1; shift; s=$(date +%s%N); out=$("$@" 2>&1); c=$?; ran=$((ran + 1))
  if [ "$c" = 0 ]; then echo "fast: $name ok ($(( ($(date +%s%N)-s)/1000000 ))ms)"; else fails=$((fails + 1)); echo "FAIL $name (exit $c): $(printf '%s' "$out" | tail -3)"; fi; }
WA_BIN="$bin" check prompt-docs bash scripts/sync-prompt-docs.sh --check
if command -v node >/dev/null 2>&1; then
  check instructions node scripts/check-instructions.mjs
  check direct-workflow node scripts/test-direct-workflow-instructions.mjs
else
  echo "fast: instructions, direct-workflow SKIPPED (node not on PATH)"; skipped=$((skipped + 2))
fi

elapsed=$(( $(date +%s) - started ))
if [ "$fails" = 0 ]; then
  echo "fast path ok ($ran checks, $skipped skipped, ${elapsed}s)"
else
  echo "fast path FAILED ($fails of $ran checks, $skipped skipped, ${elapsed}s)"; exit 1
fi
