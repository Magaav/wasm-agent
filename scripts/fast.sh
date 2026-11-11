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
#   3. contract checks: prompt docs in sync with the code; the instruction files; the landing queue; and
#      the two checks the landing baseline rests on (scripts/test-landing-baseline.mjs judges a run by
#      name, scripts/test-fast-environment.mjs proves a fork failure is the machine and not the code).
#
# Before any of that it builds the components the Lua rows need (`graph`, `hooks`, `memory`, `selfloop`,
# `mesh`) from this tree, pinned the way a deploy installs them, and gives each row a component directory
# inside its own home. A row gets the artifact it names installed there and switched on, so the seam suites
# RUN; a machine that cannot build one gets `SKIP <test>: <reason>`, and those reasons are printed under the
# counts. Two invariants are enforced, not hoped for: a row that names a component and still reports it
# missing is a FAIL, and so is a `scripts/test-fast-row-environment.lua` that does not confirm - from inside
# the node - that the variables this runner sets arrived. Why each row cannot share one directory is in the
# block itself.
#
# A check that cannot run here (no node, no cargo) is reported SKIPPED and counted, never passed.
# The full gate (scripts/test.sh) is the nightly job, not a landing requirement (AGENTS.md).
# --docker runs the whole fast path inside the sandbox image (a laptop with no wa binary).
#
# PARALLELISM. Default is `nproc` capped at 4 on Windows/MSYS (8 elsewhere), and WA_FAST_JOBS or
# --jobs overrides it. Measured on wasm_the_first, 2026-11-10: under three or four concurrent sessions
# the suite produced `cannot fork: Input/output error`, `CreateProcessW failed ... errno 5` and exits
# 125/126 - the process spawns, not the code. A landing was rolled back for one of them, and the same
# starvation is the attributed cause of a ten-minute `relay_busy` outage. A row that fails that way is
# classified by scripts/lib/fast-environment.sh and retried ONCE, alone, before it is reported; if it
# still cannot run, the fast path exits 3 ("the machine, not the tree") and the landing queue treats
# that as retry-later rather than as a verdict on the branch.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
jobs=${WA_FAST_JOBS:-}; all_rust=0; docker_mode=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) jobs=${2:?}; shift 2 ;;
    --all-rust) all_rust=1; shift ;;
    --docker) docker_mode=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fast: unknown option $1" >&2; exit 2 ;;
  esac
done
if [ -z "$jobs" ]; then
  jobs=$(nproc 2>/dev/null || echo 4)
  # The fork ceiling is per machine, not per process: the cap leaves room for the sessions this node is
  # running for, and a row that hits the wall is retried serially below instead of reporting a code
  # failure nobody can fix.
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) cap=4 ;;
    *) cap=8 ;;
  esac
  [ "$jobs" -gt "$cap" ] 2>/dev/null && jobs=$cap
fi
. "$ROOT/scripts/lib/fast-environment.sh"
# The parallel rows run in `bash -c` workers, so the classifier they use has to travel with them.
export WA_FAST_ENVIRONMENT_SIGNATURES
export -f wa_environment_reason wa_environment_kind last_line_of 2>/dev/null || true

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
fails=0; envfails=0; skipped=0; ran=0

# ---- the components the Lua rows need ---------------------------------------------------------------
# A test's node reads its components from `WA_COMPONENTS_DIR`, else `$HOME/.wasm-agent/components`
# (rust/wa-host-support/src/paths.rs), and a row's HOME is its own scratch home - so the graph tests found
# `component_not_installed:graph` on a tree whose graph was perfect, while the nightly gate never saw it:
# the gate builds `graph` once and exports WA_COMPONENTS_DIR for the whole run (scripts/test.sh, "host.graph_*
# is served by the graph component"). The fast path does the same one level down.
#
#  * The set is built from THIS tree by `scripts/build-components.sh`, so it carries its pin, its manifest
#    and its manifest's wasi-sdk requirement exactly as a deploy would install it - not whatever happens to
#    be in the node's own directory, whose graph may be another commit's.
#  * It is cached under the worktree's own git dir and rebuilt by cargo's own fingerprinting: 53 s cold on
#    wasm_the_first, 1.4 s when nothing changed. Per worktree, so two branches never overwrite each other.
#  * Each row gets WA_COMPONENTS_DIR inside its OWN home plus WA_FAST_COMPONENT_SOURCE, and gets the
#    component it names: a row whose own text names `WA_<NAME>_COMPONENT_WASM` - the variable its skip
#    message used to print - has that artifact installed, pinned, in its own directory and handed to the
#    host, so the seam suites RUN instead of skipping. Every other row pays an empty directory and keeps
#    whatever it asserted about an absent component.
#  * The directory being inside the test's home is not decoration: `scripts/test-features-gate.lua` writes
#    its own stubs into the component directory and refuses one outside its home, "never a node's component
#    directory", so a shared directory would either be polluted by that test or wrongly skipped by it.
#  * When the machine cannot build one (no cargo, no wasi-sdk, the docker fast path) the rows that need it
#    print `SKIP <test>: <reason>` and the reason names the command that would build it. A skip is counted
#    as a skip, never as a pass.
#
# `codemode` is in the set, and its parity suite is the one row that can still be held back by the
# BINARY rather than the tree: the two loops are compared field for field, including a failed script's
# reason, which crosses the seam in `done-event.error` - a host-side record field. A node whose binary
# predates it answers the suite with one named SKIP and returns in full once that node is installed;
# nothing about the comparison is narrowed while it waits (scripts/test-codemode-component.lua).
FAST_COMPONENT_NAMES=${WA_FAST_COMPONENTS:-graph hooks memory selfloop mesh codemode svc-echo}
# `svc-echo` (11/11) is the service-component fixture: `scripts/test-services-cli.lua` runs the whole
# start/status/stop/enable/disable lifecycle through the operator's `wa services` door, and it used to be
# a row whose lifecycle half silently skipped because no service artifact was ever built for it. The
# fixture is a wa:kernel@0.2 component, so it builds where the others do and caches the same way.
# The rows read this list from their own process (see `lua_run`): a shell variable that is not exported is
# simply absent in the `bash -c` worker each row runs in, and the install loop then finds nothing to do
# while every check still passes - a run that promises components and delivers none. Exported here, once.
export FAST_COMPONENT_NAMES
fast_components_prepare() {
  [ -n "$FAST_COMPONENT_NAMES" ] || return 0
  local gitdir cache log reason
  if [ "${WA_FAST_IN_DOCKER:-}" = 1 ] || ! command -v cargo >/dev/null 2>&1; then
    reason="no cargo on PATH here ($([ "${WA_FAST_IN_DOCKER:-}" = 1 ] && echo 'the sandbox image' || echo 'this machine')), so a component built from this tree is out of reach"
    echo "fast: components SKIPPED ($FAST_COMPONENT_NAMES): $reason"
    echo "fast: rows that need one print SKIP with that reason; a skip is counted as a skip, not a pass"
    return 0
  fi
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) \
    || { echo "fast: components SKIPPED ($FAST_COMPONENT_NAMES): not a git checkout, so there is nowhere to cache a build"; return 0; }
  cache="${WA_FAST_COMPONENTS_DIR:-$gitdir/wa-fast-components}"
  if ! mkdir -p "$cache/set" "$cache/target" 2>/dev/null; then
    echo "fast: components SKIPPED ($FAST_COMPONENT_NAMES): cannot create $cache"
    return 0
  fi
  log="$work/components.log"
  # The sandbox's WASI_SDK, when it has one, travels in the environment; otherwise build-components.sh finds
  # ~/wasi-sdk*. CARGO_TARGET_DIR is shared across digests so a source change is an incremental build.
  if WA_COMPONENTS_DIR="$(native "$cache/set")" CARGO_TARGET_DIR="$(native "$cache/target")" \
       bash scripts/build-components.sh $FAST_COMPONENT_NAMES >"$log" 2>&1; then
    FAST_COMPONENT_SOURCE="$(native "$cache/set")"
    export FAST_COMPONENT_SOURCE
    echo "fast: components $(printf '%s' "$FAST_COMPONENT_NAMES") built from this tree and pinned in $cache/set"
  else
    reason=$(last_line_of "$log")
    echo "fast: components SKIPPED ($FAST_COMPONENT_NAMES): ${reason:-build-components.sh failed, see $log}"
    echo "fast: rows that need one print SKIP with that reason; a skip is counted as a skip, not a pass"
  fi
}
fast_components_prepare

# ---- 1. Lua -----------------------------------------------------------------------------------------
excluded=$(sed -n 's/^\(scripts\/test-[^ #]*\.lua\).*/\1/p' scripts/fast-path.exclude 2>/dev/null)
for f in scripts/test-*.lua; do printf '%s\n' "$excluded" | grep -qxF "$f" || printf '%s\n' "$f"; done > "$work/lua.list"
timings=$(git rev-parse --git-path wa-fast-timings.tsv 2>/dev/null || true)
if [ -n "$timings" ] && [ -s "$timings" ]; then
  awk -F'\t' 'NR==FNR{ms[$3]=$2; next} {print (($0 in ms)?ms[$0]:999999) "\t" $0}' "$timings" "$work/lua.list" | sort -rn | cut -f2 > "$work/lua.sorted" \
    && mv "$work/lua.sorted" "$work/lua.list"
fi
export FAST_BIN="$bin" FAST_ROOT="$(native "$ROOT")" FAST_WORK="$work"
mkdir -p "$FAST_WORK/logs"
# One definition of "run this test hermetically", used by the parallel batch AND by the serial retry,
# so the retry measures exactly what the first attempt measured. WA_COMPONENTS_DIR is inside the row's own
# home (see "the components the Lua rows need" above): a component the test installs lands there, and a
# test that never installs one sees an empty directory rather than an unset variable.
lua_run() { # <script> <home>
  local home_native components name upper base env_file
  home_native=$( (command -v cygpath >/dev/null && cygpath -w "$2") || echo "$2")
  components=$( (command -v cygpath >/dev/null && cygpath -w "$2/.wasm-agent/components") || echo "$2/.wasm-agent/components")
  mkdir -p "$2/.wasm-agent/components" 2>/dev/null || true
  # The component this row's own text names, if the runner built it: installed (pinned, with its manifest)
  # into the row's own directory AND handed to the host through the development override the suites read.
  # Both halves are needed and neither is a guess - `WA_<NAME>_COMPONENT_WASM` is the variable the suite's
  # skip message used to print, so the file says which one it needs.
  local -a overrides=()
  if [ -n "${FAST_COMPONENT_SOURCE:-}" ]; then
    for name in $FAST_COMPONENT_NAMES; do
      [ -f "$FAST_COMPONENT_SOURCE/$name.wasm" ] || continue
      upper=$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')
      grep -q "WA_${upper}_COMPONENT_WASM" "$1" 2>/dev/null || continue
      cp "$FAST_COMPONENT_SOURCE/$name.json" "$FAST_COMPONENT_SOURCE/$name.wasm" \
         "$FAST_COMPONENT_SOURCE/$name.wasm.sha256" "$2/.wasm-agent/components/" 2>/dev/null || continue
      overrides+=("WA_${upper}_COMPONENT_WASM=$( (command -v cygpath >/dev/null && cygpath -w "$2/.wasm-agent/components/$name.wasm") || echo "$2/.wasm-agent/components/$name.wasm")")
      overrides+=("WA_${upper}_COMPONENT=1")
    done
  fi
  # Every variable this row is given, on ONE line each, for the probe row that checks they arrived
  # (`scripts/test-fast-row-environment.lua`): a variable the runner sets and the row never sees is the
  # failure this table exists to catch, and it is caught from inside the row, not from here.
  base=$(basename "$1")
  env_file=$(native "$FAST_WORK/env/$base.env")
  mkdir -p "$FAST_WORK/env" 2>/dev/null || true
  {
    printf 'WASM_AGENT_LUA_ROOT=%s\n' "$FAST_ROOT"
    printf 'WASM_AGENT_HOME=%s\n' "$home_native"
    printf 'WA_COMPONENTS_DIR=%s\n' "$components"
    printf 'WA_FAST_COMPONENT_SOURCE=%s\n' "${FAST_COMPONENT_SOURCE:-}"
    printf 'WASM_AGENT_RENDEZVOUS=\n'
    printf 'WASM_AGENT_RELAY=\n'
    printf 'WASM_AGENT_MANAGED=0\n'
    printf 'WA_SCRIPT=%s\n' "$1"
    for name in "${overrides[@]}"; do printf '%s\n' "$name"; done
    printf 'WA_FAST_ROW_ENV=%s\n' "$env_file"
  } > "$env_file" 2>/dev/null || true
  env "${overrides[@]}" \
    WASM_AGENT_LUA_ROOT="$FAST_ROOT" WASM_AGENT_HOME="$home_native" \
    WA_COMPONENTS_DIR="$components" WA_FAST_COMPONENT_SOURCE="$FAST_COMPONENT_SOURCE" \
    WA_FAST_ROW_ENV="$env_file" \
    WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_SCRIPT="$1" \
    timeout 120 "$FAST_BIN" --db "$2/t.db"
}
run_lua() { # <script> -> one TSV row: exit, ms, script, verdict line, verdict kind
  f=$1; s=$(date +%s%N); code=0; kind=ok
  # A scratch home that cannot be made is the machine (the same signature the classifier reads in a
  # test's output: `mkdir ... -> nil`), never the tree. Reported as a row so it is counted, retried and
  # named rather than vanishing into a failed redirection.
  if ! h=$(mktemp -d "$FAST_WORK/h.XXXXXX" 2>/dev/null); then
    printf '1\t0\t%s\t%s\tenvironment\n' "$f" 'a scratch home could not be made (mkdir -> nil)'
    return
  fi
  # The row's output is kept OUTSIDE its home: a home is scratch, and one row in five deleted its own
  # `out` before the verdict was read (a stray `environment: .../out: No such file or directory` in the
  # runner's output, and the row's skip lines with it). `logs/` is the run's, so the verdict and the skip
  # lines are always readable, and a failing row's log is already where the FAIL line points.
  out="$FAST_WORK/logs/$(basename "$f").out"
  lua_run "$f" "$h" > "$out" 2>&1; c=$?; code=$c
  last=$(last_line_of "$out")
  # A row can pass while naming something it could not check (`SKIP <test>: <reason>`, a fixture that is
  # not installed, a component this machine cannot build). A skip inside a green row is invisible in this
  # runner's own output - the log is only kept for a failure - so the lines are collected here and printed
  # under the counts. A skip is never a pass; it is a pass with a named hole, and the hole is spoken.
  grep -h '^SKIP ' "$out" 2>/dev/null | sed "s|^SKIP |$f: |" >> "$FAST_WORK/skips" 2>/dev/null || true
  if [ "$c" != 0 ]; then
    kind=$(wa_environment_kind "$c" "$last")
    cp "$out" "$FAST_WORK/logs/$(basename "$f").log" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$c" "$(( ($(date +%s%N)-s)/1000000 ))" "$f" "$(printf '%s' "$last" | tr '\t' ' ' | cut -c1-160)" "$kind"
}
export -f lua_run run_lua native
xargs -P "$jobs" -I{} bash -c 'run_lua "$1"' _ {} < "$work/lua.list" > "$work/lua.tsv"
# The rows the machine could not run: retried once, one at a time, AFTER the batch, so the retry is
# genuinely alone on the machine. A row that passes then is a pass (reported as one); a row that still
# cannot run is marked `, environment` in its FAIL line, which is what the landing queue reads.
envrows=$(awk -F'\t' '$1!=0 && $5=="environment"{print $3}' "$work/lua.tsv")
if [ -n "$envrows" ]; then
  echo "fast: $(printf '%s\n' "$envrows" | grep -c .) row(s) could not run (fork/spawn): retrying them once, serially"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    h=$(mktemp -d "$FAST_WORK/h.XXXXXX"); log="$FAST_WORK/logs/$(basename "$f").retry.log"; s=$(date +%s%N); c=0
    wa_environment_retry "lua $f" "$log" lua_run "$f" "$h"; c=$?
    kind=ok; [ "$c" != 0 ] && kind=environment
    case "$WA_FAST_RETRY" in
      retried) echo "fast: environment retry passed: $f (exit 0 after the machine refused the first attempt)" ;;
      environment) echo "fast: ENVIRONMENT still cannot run after a serial retry: $f (exit $c)" ;;
      *) cp "$log" "$FAST_WORK/logs/$(basename "$f").log" 2>/dev/null || true ;; # a real failure: keep the retry's log
    esac
    awk -F'\t' -v f="$f" -v c="$c" -v k="$kind" -v ms="$(( ($(date +%s%N)-s)/1000000 ))" -v l="$(last_line_of "$log" | tr '\t' ' ' | cut -c1-160)" \
      'BEGIN{OFS="\t"} $3==f {print c,ms,$3,l,k; next} {print}' "$work/lua.tsv" > "$work/lua.new" && mv "$work/lua.new" "$work/lua.tsv"
  done <<< "$envrows"
fi
lua_total=$(wc -l < "$work/lua.list"); lua_fail=$(awk -F'\t' '$1!=0' "$work/lua.tsv" | wc -l)
envleft=$(awk -F'\t' '$1!=0 && $5=="environment"' "$work/lua.tsv" | wc -l)
[ -n "$timings" ] && cp "$work/lua.tsv" "$timings" 2>/dev/null || true
ran=$((ran + lua_total)); fails=$((fails + lua_fail));
awk -F'\t' '$1!=0{ if ($5=="environment") printf "FAIL lua %s (exit %s, environment): %s\n",$3,$1,$4; else printf "FAIL lua %s (exit %s): %s\n",$3,$1,$4 }' "$work/lua.tsv"
echo "fast: lua $((lua_total - lua_fail))/$lua_total passed ($(printf '%s\n' "$excluded" | grep -c . ) excluded: scripts/fast-path.exclude)"
[ "$envleft" -gt 0 ] && echo "fast: $envleft of them never ran: the machine ran out of processes (fork/spawn), see scripts/lib/fast-environment.sh"
# A component this runner PROMISED cannot be missing in the row that asked for it. The row names the
# artifact in its own text (`WA_<NAME>_COMPONENT_WASM`), `lua_run` installs that artifact in the row's own
# directory and hands the host the override - so a row that reports the component missing is the runner
# failing, not the test skipping. Measured once, on wasm_the_first: the component list was a shell variable
# that never reached the row's worker, so every seam suite skipped while the build line above said the set
# was installed. This is the check that would have caught it, from the two facts the run already has.
for promised in $FAST_COMPONENT_NAMES; do
  [ -n "${FAST_COMPONENT_SOURCE:-}" ] && [ -f "$FAST_COMPONENT_SOURCE/$promised.wasm" ] || continue
  upper=$(printf '%s' "$promised" | tr '[:lower:]-' '[:upper:]_')
  grep -q "WA_${upper}_COMPONENT_WASM" scripts/test-*.lua 2>/dev/null || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q "WA_${upper}_COMPONENT_WASM" "$f" 2>/dev/null || continue
    log="$work/logs/$(basename "$f").out"
    [ -f "$log" ] || continue
    if grep -qE "no ${promised} component|component_not_installed:${promised}|component_unavailable:component_not_installed:${promised}" "$log" 2>/dev/null; then
      fails=$((fails + 1))
      echo "FAIL component-provisioning $f (exit 1): the runner promised $promised (a pinned copy in this row's own home) and the row reports it missing: $(grep -m1 -E "no ${promised} component|component_not_installed:${promised}" "$log" | cut -c1-160)"
    fi
  done <<< "$(awk -F'\t' '{print $3}' "$work/lua.tsv")"
done
# The row-environment probe must have RUN and PASSED, not merely exited 0. It is the one row that can say
# whether the variables this runner sets arrive in the node (`scripts/test-fast-row-environment.lua`), so a
# probe that skipped - the table it reads was dropped, which is exactly the incident - would otherwise let
# the run call itself green by saying nothing. Its own failure is already a FAIL row; this covers the
# silent case.
probe_row=scripts/test-fast-row-environment.lua
probe_status=$(awk -F'\t' -v f="$probe_row" '$3==f{print $1}' "$work/lua.tsv" 2>/dev/null | head -1)
if [ "${probe_status:-missing}" = "0" ] && ! grep -q '^fast row environment ok' "$work/logs/$(basename "$probe_row").out" 2>/dev/null; then
  fails=$((fails + 1))
  echo "FAIL fast-row-environment (exit 1): the probe row passed without confirming the table it was given: $(last_line_of "$work/logs/$(basename "$probe_row").out")"
elif [ -z "${probe_status:-}" ]; then
  fails=$((fails + 1))
  echo "FAIL fast-row-environment (exit 1): $probe_row never ran, so nothing checked that this runner's variables reach its rows"
fi
# The holes in those passes, by name: a row that could not check what it is about says so, and this is
# where a reader sees it without opening 150 logs. Grouped per test - one suite can name thirty of them
# (the hooks seam names one per case it cannot run) - with the count and the first reason, so the
# summary stays a table instead of thirty repeats. `sort -u` first: a serial retry appends again.
if [ -s "$work/skips" ]; then
  echo "fast: $(sort -u "$work/skips" | grep -c .) named skip(s) inside passing rows (a skip is not a pass):"
  sort -u "$work/skips" | awk -F': ' '
    { test = $1; if (!(test in seen)) { seen[test] = 1; order[++n] = test; first[test] = $0 }
      count[test]++ }
    END { for (i = 1; i <= n; i++) { t = order[i]; line = first[t]; sub(/^[^:]*: /, "", line)
            printf "fast:   %s: %d skip(s), first: %s\n", t, count[t], substr(line, 1, 150) } }'
fi

# ---- 2. Rust: the crates this change touches ----------------------------------------------------------
if [ "${WA_FAST_IN_DOCKER:-}" = 1 ]; then
  echo "fast: rust SKIPPED (inside the sandbox image: no toolchain; run on a node with cargo)"; skipped=$((skipped + 1))
elif ! command -v cargo >/dev/null 2>&1; then
  echo "fast: rust SKIPPED (cargo not on PATH)"; skipped=$((skipped + 1))
else
  # Test builds, not shippable ones: the same switch the gate sets (scripts/test.sh) so the build script
  # that embeds the code-mode assets (wa-capabilities/build.rs) does not demand one only a shipping build
  # prepares.
  export WA_CODEMODE_ALLOW_EMPTY=1
  base=$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)
  changed=$( { git diff --name-only "$base" -- rust; git diff --name-only -- rust; git diff --name-only --cached -- rust; } | sort -u)
  crates=""
  # The crates of the host split (docs/KERNEL.md) are listed by their directory, so a change under
  # rust/wa-term/ tests wa-term instead of rebuilding and testing the whole binary.
  # wa-whatsapp-outbox is the explicit-send payload/JID/dedupe crate and wa-whatsapp-index the query
  # request/answer seam; both are shared by the node and the wa-whatsapp component, and both are
  # workspace members with no host dependency, so they are cheap here. The component itself is its own
  # workspace and is built and tested from its directory (docs/SERVICE-COMPONENTS.md).
  # wa-model-gateway is the model gateway's rules (`docs/MODEL-GATEWAY.md`): a leaf crate with no host
  # dependency, so its 79 native tests are seconds, and they are the only place the seam's decisions are
  # exercised (the component itself is its own workspace, like every other component).
  # wa-tool-progress is the long-call row's decision (`docs/TOOL-PROGRESS.md`): a leaf with one
  # dependency, and the only place the parsers, the clocks and the stall rule are exercised.
  # wa-model-router is the routing-policy modules (`wit/model/router.wit`, docs/MODEL-GATEWAY.md) and
  # wa-fleetview the fleet-view record contract (docs/FLEET-OPS.md); both are leaves with one dependency,
  # so their tests are seconds and there is no reason to leave them out.
  for crate in wa-sqlite wa-host wa-host-support wa-governance wa-term wa-rendezvous wa-kernel-runtime wa-capabilities wa-operation wa-jobs wa-graph wa-sentinel wa-whatsapp-outbox wa-whatsapp-index wa-mesh wa-stt-remote wa-model-gateway wa-tool-progress wa-model-router wa-fleetview; do
    if [ "$all_rust" = 1 ] || printf '%s\n' "$changed" | grep -q "^rust/$crate/"; then crates="$crates $crate"; fi
  done
  printf '%s\n' "$changed" | grep -qE '^rust/(Cargo\.(toml|lock))$' && [ "$all_rust" = 0 ] && crates=" wa-sqlite wa-host wa-host-support wa-governance wa-term wa-rendezvous wa-kernel-runtime wa-capabilities wa-operation wa-jobs wa-graph wa-mesh"
  if [ -z "$crates" ]; then echo "fast: rust - no crate touched"; fi
  for crate in $crates; do
    s=$(date +%s)
    if [ "$crate" = wa-sentinel ]; then
      cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1 > "$work/rust-$crate.log" 2>&1
    elif [ "$crate" = wa-capabilities ]; then
      # wa-capabilities holds the streaming timeout tests (http_transport's phase budgets: 250 ms for
      # response headers, 500 ms of body silence) next to the agent-core pool's heavy ones. Those
      # budgets are wall-clock facts about a *quiet* process, so they get their own process: the rest
      # of the crate first (the pool's engines, compiles and wasm instances cannot starve them), then
      # the streaming tests alone. Neither run skips anything - the split is the isolation, not a
      # filter on what is proved (docs/KERNEL.md, "A2.3").
      cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities \
        -- --skip http_transport::streaming_timeout_tests > "$work/rust-$crate.log" 2>&1 \
      && cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities \
        -- http_transport::streaming_timeout_tests >> "$work/rust-$crate.log" 2>&1
    else
      cargo test --release --offline --manifest-path rust/Cargo.toml -p "$crate" > "$work/rust-$crate.log" 2>&1
    fi
    c=$?; ran=$((ran + 1))
    if [ "$c" = 0 ]; then echo "fast: rust $crate ok ($(( $(date +%s) - s ))s)"
    else fails=$((fails + 1)); echo "FAIL rust $crate (exit $c):"; { grep -E "^test .* FAILED|panicked at|^error" "$work/rust-$crate.log" || tail -5 "$work/rust-$crate.log"; } | head -8; fi
  done
fi

# ---- 3. contract checks -------------------------------------------------------------------------------
check() { name=$1; shift; s=$(date +%s%N)
  wa_environment_retry "$name" "$work/check-$name.log" "$@"; c=$?
  ran=$((ran + 1))
  if [ "$c" = 0 ]; then echo "fast: $name ok ($(( ($(date +%s%N)-s)/1000000 ))ms)"; return 0; fi
  fails=$((fails + 1))
  case "$WA_FAST_RETRY" in environment) envfails=$((envfails + 1)); echo "FAIL $name (exit $c, environment): $(last_line_of "$work/check-$name.log")" ;;
    *) echo "FAIL $name (exit $c): $(tail -3 "$work/check-$name.log" | tr '\n' ' ')" ;; esac
}
WA_BIN="$bin" check prompt-docs bash scripts/sync-prompt-docs.sh --check
if command -v node >/dev/null 2>&1; then
  check instructions node scripts/check-instructions.mjs
  check direct-workflow node scripts/test-direct-workflow-instructions.mjs
  # The landing queue's own evidence: one lander at a time, FIFO, reclaim of a dead holder, the
  # dirty-canonical refusal, and the upstream-delta classification that decides what is retested.
  # Seconds, self-contained (a fixture repository and a fixture ledger), so it belongs here and not
  # only in the nightly gate.
  check landing-queue node scripts/test-landing-queue.mjs
  # Session liveness comes from the running process, never from a ledger row another process can
  # close: the 10/11 `owner_ended` refusal of a live session, pinned against a real ledger and a
  # real pid.
  check session-liveness node scripts/test-session-liveness.mjs
  # The automatic disk reclaim (weakness #81): each safe category's rule, the keep-newest counts, the
  # never-touch list (both as a predicate and as what survives a real run), the deploy guard, and that
  # the dry run removes nothing while the active run frees exactly the plan it printed.
  check reclaim-disk node scripts/test-reclaim-disk.mjs
  # The known-failures baseline the landing queue judges a candidate against: same failures pass, a new
  # failure refuses, a fixed failure is tolerated, an environment-only failure is a retry (not a
  # verdict), and a recorded baseline is reused instead of a pristine run when the tree's check inputs
  # are unchanged.
  check landing-baseline node scripts/test-landing-baseline.mjs
  # The cutover exporter (docs/WHATSAPP-CUTOVER.md): a synthetic whatsmeow store in, the wacore
  # device record out, plus the guard rails around a live state directory. Seconds, no phone.
  check whatsapp-adopt node --test scripts/test-whatsapp-adopt.mjs
  # The JavaScript tests no harness named (measured 2026-11-11: 45 of 237) were audited: the ones that are
  # self-contained and test live code run here, and scripts/test-orphans.json carries the reason for every
  # one that cannot. The ledger check fails on a new orphan, a stale entry or a declared one gone wired.
  check orphan-tests node scripts/test-orphan-tests.mjs
  check run-key-ui node scripts/test-run-key-ui.mjs
  check wave-current-user-record node scripts/test-wave-current-user-record.mjs
  check whatsapp-lifecycle node scripts/test-whatsapp-lifecycle.mjs
  check agent-benchmark-forced node scripts/test-agent-benchmark-forced.mjs
  check agent-benchmark-proxy node scripts/test-agent-benchmark-proxy.mjs
  check delivery-intent-race node scripts/test-delivery-intent-race.mjs
  check wave-no-third-party node scripts/test-wave-no-orca.mjs
  check wave-ship-mutation node scripts/test-wave-ship-mutation.mjs
else
  echo "fast: instructions, direct-workflow, landing-queue, session-liveness, landing-baseline, orphan-tests and the JS test rows SKIPPED (node not on PATH)"; skipped=$((skipped + 5))
fi
# The deploy's retirement rule: a shipped script main deleted must not survive in the install (measured
# 2026-11-11: the removed Node WhatsApp bridge stayed installed beside the new set).
check deploy-prune bash scripts/test-deploy-prune.sh
# The runner's half of "the machine, not the code": the classifier and the serial retry, against fixture
# commands that fail the way a starved machine fails (and a real failure that must NOT be excused).
check fast-environment bash scripts/test-fast-environment.sh

elapsed=$(( $(date +%s) - started ))
if [ "$fails" = 0 ]; then
  echo "fast path ok ($ran checks, $skipped skipped, ${elapsed}s)"
elif [ "${envfails:-0}" -gt 0 ] && [ "${envfails:-0}" = "$fails" ]; then
  # Every failure was the machine refusing to start a process. That is not a verdict on the tree, and
  # the landing queue reads exit 3 as "retry", never as "this branch is worse than main".
  echo "fast path could not run: $fails check(s) were the machine (fork/spawn, retried serially once), ${skipped} skipped, ${elapsed}s"
  exit 3
else
  echo "fast path FAILED ($fails of $ran checks, $skipped skipped, ${elapsed}s)"; exit 1
fi
