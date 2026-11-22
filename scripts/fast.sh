#!/usr/bin/env bash
# The fast path: the day-to-day check before landing a change. Minutes, not the gate's ~50.
#
#   bash scripts/fast.sh [--jobs N] [--all-rust] [--docker] [--binary]
#   WA_FAST_ROWS=<file> bash scripts/fast.sh   # only the Lua rows a planned round's changes touch
#                                              # (scripts/lib/fast-rows.sh; the always-on core rows and
#                                              # every contract check still run, an unknown row refuses)
#
# What it runs, in parallel where it can:
#   1. every scripts/test-*.lua not listed in scripts/fast-path.exclude, each with its own scratch home and
#      ledger (hermetic: no node, no network, no shared state);
#   2. Rust unit tests for the crates this change touches (vs the merge base with origin/main, plus the
#      working tree); --all-rust runs every crate. wa-sentinel runs single-threaded (its tests share
#      process-wide environment);
#   3. contract checks: prompt docs in sync with the code; the instruction files; the landing queue; and
#      the two checks the landing baseline rests on (scripts/test-landing-baseline.mjs judges a run by
#      name, scripts/test-fast-environment.mjs proves a fork failure is the machine and not the code),
#      plus the WIT seam's own two (scripts/wit-lint.sh judges wit/, scripts/test-wit-lint.sh judges the
#      judge);
#   4. the build time of every crate and component this run compiled, printed in the summary:
#      measured and reported, never gated (ARCHITECTURE.md, "Modules over the monolith"). A crate's
#      number is its 'cargo test --no-run' in the tests' own profile - the compile the row below then
#      reuses - not a separate release build;
#   5. the module map: per module its size, its build time and the `win` line from its manifest, the
#      co-change pairs that should merge, and the split/merge decision record the cooldown reads -
#      printed in the summary as FLAGS and never gated (scripts/module-report.mjs).
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
# WHICH BINARY. Every run's first line names the `wa` the rows will run, its build commit, this tree's
# commit and the verdict (`fresh`, `stale`, `unknown`), and the tree's own binary wins over anything on
# PATH - three sessions were green against the canonical checkout's binary while their own tree was
# never loaded (scripts/lib/fast-binary.sh has the measurements). A missing or stale tree binary is
# built, stamped with this commit and with the prepared code-mode assets; when it cannot be, the run
# stops with `stale_binary` and the command that builds it. `--binary` prints that resolution and exits.
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
jobs=${WA_FAST_JOBS:-}; all_rust=0; docker_mode=0; binary_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) jobs=${2:?}; shift 2 ;;
    --all-rust) all_rust=1; shift ;;
    --docker) docker_mode=1; shift ;;
    --binary) binary_only=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# THE NODE'S OWN RECORD OF ITS BUILD ENVIRONMENT (items 3 and 6 of the node-ops round). One file -
# <home>/.wasm-agent/build.env - names the toolchain directories, zig, the target-dir policy and the
# wasi-sdk; scripts/lib/build-requirements.sh is the ONE reader of it, and this run reads it the same way
# deploy.sh, mission.sh and wa land do instead of guessing from the ambient environment. A key no build
# reads is a REFUSAL here (it looks applied and is not, and a machine can spend a day believing it set a
# toolchain directory nothing looked at); a MISSING record is not (the ambient environment is exactly what
# this runner used before it existed).
#
# RE-MEASURED 22/11 on main a8cd5348: this read was ABSENT - looking for build_env or build-requirements in
# scripts/fast.sh answered NOTHING - while scripts/test-build-env.sh (wired at scripts/test.sh:1001) asserts
# it, so the gate failed with "scripts/fast.sh with an unknown record key exited 0, not 2": the runner that
# gates a node applied none of the record the deploy on that same node had applied.
#
# IT IS APPLIED HERE AND *REPORTED* AFTER THE BANNER (measured 22/11): `wa_build_env` must run before
# `fast_binary_plan`, which builds this tree's binary and needs the record's toolchain on PATH - but the run's
# FIRST line is the binary resolution (scripts/test-fast-binary.mjs: the first line of `fast.sh --binary`),
# so the record's own lines are held here and echoed below that banner instead of in front of it.
. "$ROOT/scripts/lib/build-requirements.sh"
if build_env_note="$(wa_build_env_audit 2>&1)"; then
  BUILD_RECORD_NOTE="$(printf '%s\n' "$build_env_note" | head -1)"
else
  printf '%s\n' "$build_env_note" >&2
  echo "fast: refused($(printf '%s\n' "$build_env_note" | sed -n 's/^problem //p' | tail -1)): the build record names a setting no build reads, so a machine could spend a day believing it set a toolchain directory nothing looked at. Remove that line, or add it to WA_BUILD_ENV_KEYS with the face that consumes it. Nothing was run." >&2
  exit 2
fi
# The same function deploy.sh uses: it puts the record's toolchain directories on PATH (appended, so the
# caller's PATH still wins) and is a no-op when the record names none.
if ! wa_build_env; then
  echo "fast: refused(build_env_incomplete): the build record names a directory that is not there; the refusal above names it and the one line that fixes it. Nothing was run." >&2
  exit 2
fi
BUILD_RECORD_KEYS=""
for entry in WA_BUILD_ZIG WASI_SDK_PATH WA_BUILD_CARGO_TARGET; do
  eval "value=\${$entry:-}"
  [ -n "$value" ] && BUILD_RECORD_KEYS="$BUILD_RECORD_KEYS$entry=$value\n"
done
# ---- the environment a row must never inherit --------------------------------------------------------
# Measured, speed.log: a fixture set WASM_AGENT_LLM_BASE_URL to a dead port and was answered by the
# operator's REAL provider, because the child inherited WASM_AGENT_VAULT_URL from the session and
# `provider.providers()` prefers the vault's route over any base-URL variable on purpose (docs/VAULT.md).
# A test made a model call with the operator's credentials and nothing said so.
#
# So this run starts by removing every variable that can point a process at a vault, before any row, any
# cargo test and any node check is spawned. The names travel to each Lua row as `WA_FAST_CLEARED`, and
# `scripts/test-fast-row-environment.lua` fails by name if a row still sees one - the runner's promise,
# checked from inside the node instead of trusted here. `scripts/lib/test-provider.lua` is the other
# half for a fixture reached by hand.
WA_FAST_CLEARED_VARS="WASM_AGENT_VAULT_URL WASM_AGENT_VAULT_DIR WASM_AGENT_VAULT_KEYSTORE WASM_AGENT_VAULT_PASSPHRASE"
for name in $WA_FAST_CLEARED_VARS; do unset "$name"; done
WA_FAST_CLEARED=$(printf '%s' "$WA_FAST_CLEARED_VARS" | tr ' ' ',')
export WA_FAST_CLEARED

# The parallel rows run in `bash -c` workers, so the classifier they use has to travel with them.
export WA_FAST_ENVIRONMENT_SIGNATURES
export -f wa_environment_reason wa_environment_kind last_line_of 2>/dev/null || true
# The per-row watchdog (scripts/lib/fast-watchdog.sh): a row gets its OWN PROCESS GROUP, so a deadline
# that passes kills every child it forked, not just the one process timeout knows about, and the hung row
# is NAMED instead of reporting a bare exit 124 that reads exactly like a failed assertion.
. "$ROOT/scripts/lib/fast-watchdog.sh"
export -f wa_fast_watchdog wa_watchdog_hung 2>/dev/null || true
# The exec of one Lua row, in the only order that works (scripts/lib/fast-row-exec.sh): the watchdog
# OUTERMOST - env cannot exec a shell function, which is exit 127 on every row.
. "$ROOT/scripts/lib/fast-row-exec.sh"
export -f wa_fast_row_exec 2>/dev/null || true

# ---- the binary -------------------------------------------------------------------------------------
# Which `wa` the rows run is a fact about the verdicts, not a detail: see scripts/lib/fast-binary.sh for
# the measured failure (three sessions green against the canonical checkout's binary while their own
# tree was never loaded). The FIRST line of every run names the binary, its build commit, this tree's
# commit and the verdict; the tree's own binary wins over anything on PATH, and when it is missing or
# stale it is built, or the run stops by name - it never grades another commit silently.
. "$ROOT/scripts/lib/fast-binary.sh"
fast_binary_plan
if [ "$docker_mode" = 1 ] || [ "${FAST_BIN_ACTION:-}" = docker ]; then
  [ -z "${DOCKER_HOST:-}" ] && [ -S "/run/user/$(id -u)/docker.sock" ] && export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  image=${WA_FAST_IMAGE:-wasm-agent-sandbox:local}
  if command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
    # Still one named first line: inside the image the rows run that node, so the image is the binary.
    printf 'fast: binary %s (docker: %s)\n' "$image" "${FAST_BIN_WHY:---docker asked for the sandbox image}"
    host_timings=$(git rev-parse --absolute-git-dir)/wa-fast-timings.tsv; touch "$host_timings"
    exec docker run --rm --user 0 -v "$ROOT:/t:ro" -v "$host_timings:/t/.git/wa-fast-timings.tsv" -w /t -e WA_FAST_IN_DOCKER=1 "$image" bash scripts/fast.sh --jobs "$jobs" $([ "$all_rust" = 1 ] && echo --all-rust)
  fi
  if [ "$docker_mode" = 1 ]; then
    echo "fast: --docker asked for the sandbox image and it is not here; cannot run" >&2
    exit 2
  fi
  echo "fast: no wa binary (WA_BIN, PATH, ~/.local/bin, rust/target/release) and no sandbox image; cannot run" >&2
  exit 2
fi
if [ "$binary_only" = 1 ]; then fast_binary_banner; exit 0; fi
# The banner first, then the build it announces: one line that says which binary this run is about,
# and only then the minutes of work.
fast_binary_banner
if [ "${FAST_BIN_ACTION:-}" = build ]; then
  if ! fast_binary_build; then
    fast_binary_refuse
  fi
  fast_binary_banner
fi
if [ "${FAST_BIN_ACTION:-}" = refuse ]; then fast_binary_refuse; fi
# THE RECORD'S OWN LINES, AFTER THE BANNER (item 3/6). The run's FIRST line is the binary resolution by
# contract (scripts/test-fast-binary.mjs reads it) and a stale binary prints its banner again after the
# build, so what the record applied is said HERE, once the banner block is done - measured 22/11: printed
# before it, the record line was the run's first line and the contract was broken where no check looks.
echo "fast: build record: $BUILD_RECORD_NOTE"
[ -n "$BUILD_RECORD_KEYS" ] && printf '%b' "$BUILD_RECORD_KEYS"
# ---- the one build root ------------------------------------------------------------------------------
# Every cargo invocation this run makes - the rows' `cargo test`, the components, a build a row does for
# itself - writes into the node's ONE build root, this tree's child of it (`docs/ONEROOT.md`), and the
# sweep runs BEFORE the first of them so nothing new is spent while another layout's target dir is still
# on the disk. The sweep prints what it reclaimed and the cap prints what it holds; both are on the run's
# own output, next to the rest of the environment facts, because "how much build space is this node
# using" was the question nobody could answer on 13/11 (73 folders, ~196 GB).
. "$ROOT/scripts/lib/build-target.sh"
fast_build_target=$(wa_build_target "$ROOT" 2>/dev/null) || fast_build_target=''
if [ -n "$fast_build_target" ]; then
  wa_build_prepare "$ROOT" >/dev/null
  case "$fast_build_target" in
    [A-Za-z]:[\\/]*) : ;;
    *) [ "$(command -v cygpath 2>/dev/null)" ] && fast_build_target=$(cygpath -w "$fast_build_target") ;;
  esac
  echo "fast: build root $fast_build_target ($(du -sh "$fast_build_target" 2>/dev/null | cut -f1 || echo unmeasured) of a $(wa_build_human "$(wa_build_cap_bytes)") cap)"
  # NOT exported: a row inherits what it is given, and `CARGO_TARGET_DIR` in a row's environment means
  # "the caller named this directory" to `scripts/lib/fast-binary.sh` - the row would then resolve the
  # fast path against this run's build dir instead of its own fixture (measured on this branch: the
  # `fast-binary` check failed exactly there). The cargo rows below get it named explicitly instead.
fi
case "${FAST_BIN_CODEMODE:-unknown}" in
  no) echo "fast: this binary has no code-mode assets; the rows that need them: $(fast_binary_rows_needing_assets)" ;;
  unknown) echo "fast: this binary does not report code-mode assets; a row that needs them says so by name" ;;
esac
bin="$FAST_BIN"
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
# Milliseconds, portably. `date +%s%N` is a GNU extension: on BSD/macOS it prints a literal 'N', and
# inside $(( )) that is a shell error rather than a duration, so every row time in this file was wrong
# there. scripts/lib/build-target.sh:wa_build_now_ms answers the same question for the build scripts;
# the fast path keeps its own copy (it does not source that file's build machinery) and EXPORTS it,
# because the Lua rows run in an xargs child.
fast_now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in ''|*[!0-9]*) printf '%s' "$(( $(date +%s) * 1000 ))" ;; *) printf '%s' "$(( ns / 1000000 ))" ;; esac
}
export -f fast_now_ms
started=$(date +%s)
# THE RUN'S OWN SCRATCH ROOT MUST BE OUTSIDE THE OPERATOR STORE (item 0, measured on this node).
#
# This node sets TMPDIR=/home/<user>/.wasm-agent/tmp (measured 19/11), so a plain mktemp under TMPDIR made
# every row's home a directory INSIDE the operator's own store, and the four rows that check their home with
# scripts/lib/scratch-home.sh refused it - correctly, and by name:
#   REFUSED test-backup-restore: WASM_AGENT_HOME (.../tmp/wa-fast-XXXX/h.YYY) is inside the operator store
# They were the only 4 failures in a 254-row run whose cause was the RUNNER, not the rows.
. scripts/lib/scratch-home.sh
if ! scratch_root=$(wa_scratch_root wa-fast); then
  echo "fast: no scratch root outside the operator store; set WA_TEST_ROOT=<a directory outside it>" >&2
  exit 2
fi
# AN INTERRUPTED RUN CLEANS ITS SCRATCH ON THE NEXT START (review item 4). The trap below only runs when
# THIS process exits; a run that was OOM-killed or cancelled left its work dir behind, and this session
# own leftovers were 1.4 GB of them.
#
# A LIVE RUN IS NEVER RECLAIMED (review SHOULD, and it is a real race). The first shape asked
# "kill -0 <pid>", and kill -0 is not the same question: a pid in ANOTHER PID NAMESPACE answers EPERM,
# which this code read as "gone" - it would have deleted the work dir of a run that was still working.
# Nor can a pid be trusted on its own: pids are reused. So the owner holds an EXCLUSIVE flock on
# <workdir>/lock for its whole life, and a start reclaims a directory only when it can TAKE that lock
# (flock -n). A running owner holds it, so the lock cannot be taken; a killed owner's lock is released by
# the kernel, so the next start takes it and removes the directory. No pid, no EPERM, no reuse window.
for stale in "$scratch_root"/wa-fast-*; do
  [ -d "$stale" ] || continue
  [ -f "$stale/pid" ] || continue
  # -n: do not wait. Success means NOBODY holds it, and the fd stays open only for this test.
  if ( exec 9>>"$stale/lock" 2>/dev/null && flock -n 9 ) 2>/dev/null; then
    stale_pid=$(cat "$stale/pid" 2>/dev/null)
    rm -rf "$stale" 2>/dev/null && echo "fast: reclaimed $stale (pid ${stale_pid:-unknown} released its lock: an interrupted run)"
  fi
done
work=$(mktemp -d "$scratch_root/wa-fast-XXXXXX")
# THE OWNER'S LOCK COMES BEFORE THE PID (review r2, A3 - a real race in the shape I wrote first).
#
# The order was: write pid, then open+flock lock. Between those two lines the directory has a pid and NO
# holder, so a concurrent start's reclaim loop saw a pid, took the lock, and rm -rf'd a directory whose
# owner was alive and about to lock it. The pid is not what protects a run - the LOCK is - so the lock is
# taken first and the pid is written only once this process provably holds it. A reclaim therefore can
# never see "pid exists, nobody holds the lock" for a live run: if the pid file is there, the lock was
# already held when it was written.
exec 8>>"$work/lock" 2>/dev/null || true
if flock -n 8 2>/dev/null; then
  printf '%s\n' "$$" > "$work/pid" 2>/dev/null || true
else
  # Cannot lock a directory we just made: say so rather than run unprotected. A run whose scratch cannot
  # be claimed is a machine problem, and it must not look like a normal start.
  echo "fast: refused(scratch_unlocked): cannot take the owner lock in $work; a concurrent run could reclaim this directory. Nothing was run." >&2
  rm -rf "$work" 2>/dev/null
  exit 2
fi
# A FAILED ROW'S LOG OUTLIVES THE RUN (item 3 of the harness-fixes-2 round). The scratch work dir is
# deleted on exit - that is why the reclaim above exists - so a failed row's own output died with it, and
# the landing gate (lua/core/land.lua) could only report the one line it had already copied. A caller that
# names a directory here gets every failed row's log copied into it BEFORE the cleanup: the run's evidence
# then holds the words that failed, not a pointer to a directory that is gone.
wa_fast_keep_failed_logs() {
  [ -n "${WA_FAST_KEEP_LOGS:-}" ] || return 0
  [ -d "$work/logs" ] || return 0
  mkdir -p "$WA_FAST_KEEP_LOGS" 2>/dev/null || { echo "fast: refused(keep_logs_unwritable): cannot keep failed row logs in $WA_FAST_KEEP_LOGS" >&2; return 0; }
  local kept=0 log
  for log in "$work"/logs/*.log; do
    [ -f "$log" ] || continue
    cp "$log" "$WA_FAST_KEEP_LOGS/$(basename "$log")" 2>/dev/null && kept=$((kept + 1))
  done
  echo "fast: kept $kept failed row log(s) in $WA_FAST_KEEP_LOGS"
}
trap 'wa_fast_keep_failed_logs; rm -rf "$work"' EXIT

# The build-time ledger: one line per build this run performs, printed in the summary
# below, because "a module compiles faster" is a claim about a number (scripts/lib/build-times.sh).
. "$ROOT/scripts/lib/build-times.sh"
wa_build_times_init "$work/build-times.tsv"
fails=0; envfails=0; skipped=0; ran=0

# ---- the environment this verdict belongs to ---------------------------------------------------------
# A red row is a fact about the TREE only if the machine is named with it. Measured 11/12 on wa-desktop:
# main was red there, four sessions each paid an extra full run to prove the failure was main's own, and
# nothing in the output could have told them - no node version, no cargo, no wasi-sdk, and no
# machine-readable list of WHICH checks failed. Both are stated here, before the first check runs, and
# both travel in the JSON result (scripts/fast-result.mjs), so a reader never has to re-run the suite to
# attribute a failure to a machine.
version_of() { local out; out=$("$@" 2>&1 | head -1) || true; printf '%s' "${out:-absent}"; }
wasi_sdk_version() {
  local sdk="${WASI_SDK_PATH:-}" candidate
  if [ -z "$sdk" ]; then
    for candidate in "$HOME"/wasi-sdk* /opt/wasi-sdk*; do
      [ -d "$candidate/share/wasi-sysroot" ] && sdk="$candidate"
    done
  fi
  [ -n "$sdk" ] || { printf 'absent'; return; }
  if [ -f "$sdk/VERSION" ]; then head -1 "$sdk/VERSION" | tr -d '[:space:]'
  else basename "$sdk" | sed 's/^wasi-sdk-//'; fi
}
node_version=absent; node_sqlite=absent
if command -v node >/dev/null 2>&1; then
  node_version=$(version_of node --version)
  # `require("node:sqlite")` is the real question: a Node without it turns the ledger rows into skips,
  # and a reader must be able to see that here instead of inferring it from a row's absence later.
  if node -e 'require("node:sqlite")' >/dev/null 2>&1; then node_sqlite=yes; else node_sqlite=no; fi
fi
cargo_version=$(command -v cargo >/dev/null 2>&1 && version_of cargo --version || printf 'absent')
if command -v lua5.4 >/dev/null 2>&1; then lua_version=$(version_of lua5.4 -v)
elif command -v lua >/dev/null 2>&1; then lua_version=$(version_of lua -v)
else lua_version=absent; fi
wasi_sdk=$(wasi_sdk_version)
commit=$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
if command -v sha256sum >/dev/null 2>&1; then bin_sha=$(sha256sum "$bin" 2>/dev/null | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then bin_sha=$(shasum -a 256 "$bin" 2>/dev/null | cut -d' ' -f1)
else bin_sha=unknown; fi
echo "fast: env: node $node_version (node:sqlite $node_sqlite), cargo $cargo_version, wasi-sdk $wasi_sdk, lua $lua_version"
echo "fast: env: root $ROOT at $commit on $branch; binary $bin (sha256 ${bin_sha:-unknown})"
# What a row is promised, so a green row that could not check something is read against the contract it
# was run under rather than against what the reader assumed. A row sets its own variables for anything
# this line does not name.
echo "fast: env contract: every row gets its own scratch WASM_AGENT_HOME, WA_COMPONENTS_DIR inside it, WASM_AGENT_LUA_ROOT=$ROOT, no rendezvous or relay, WASM_AGENT_MANAGED=0"

# ---- the machine-readable result ---------------------------------------------------------------------
# One row per check, written as the check finishes (parallel workers write their own file, so no two
# rows can interleave), plus the named skips a passing row reports and the environment above. The
# assembly is scripts/fast-result.mjs; the file lives in the worktree's own git dir unless WA_FAST_RESULT
# names another path, so a run never writes into the tree it is judging.
result_rows="$work/result"; mkdir -p "$result_rows" 2>/dev/null || true
export RESULT_ROWS="$result_rows"
named_skips="$work/named-skips.tsv"; : > "$named_skips" 2>/dev/null || true
printf 'node\t%s\nnode_sqlite\t%s\ncargo\t%s\nwasi_sdk\t%s\nlua\t%s\nroot\t%s\ncommit\t%s\nbranch\t%s\nbin\t%s\nbin_sha256\t%s\n' \
  "$node_version" "$node_sqlite" "$cargo_version" "$wasi_sdk" "$lua_version" "$ROOT" "$commit" "$branch" "$bin" "${bin_sha:-unknown}" \
  > "$work/env.tsv" 2>/dev/null || true
record_row() { # <status: pass|fail|skip> <section> <name> <exit> <ms> <environment 0|1> <first error or reason>
  local file
  # `run_lua` runs in a `bash -c` worker, so the directory travels as an exported variable: a variable
  # that is merely set here is absent there, and every row would be written to `/` and lost.
  file="${RESULT_ROWS:-/nonexistent}/$(printf '%s' "$3" | sed 's#[^A-Za-z0-9._-]#_#g').row"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(printf '%s' "$7" | tr '\t\n' '  ' | cut -c1-300)" \
    > "$file" 2>/dev/null || true
}
# The FIRST line that looks like the failure, not the last line of the log: a suite's last line is often
# its own summary of the failure (measured on this very suite: "the fence is not in the guest tool
# table" came first and the whole comparison came after). Falls back to the last line.
first_error_of() { # <log>
  local strong
  [ -s "$1" ] || return 0
  strong=$(grep -m1 -iE 'lua error|panicked at|(^|: )error|assertion|assert failed|refus' "$1" 2>/dev/null | tr '\t' ' ')
  [ -n "$strong" ] || strong=$(last_line_of "$1")
  printf '%s' "$strong" | cut -c1-300
}
export -f record_row first_error_of

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
  if ! mkdir -p "$cache/set" 2>/dev/null; then
    echo "fast: components SKIPPED ($FAST_COMPONENT_NAMES): cannot create $cache"
    return 0
  fi
  log="$work/components.log"
  # The sandbox's WASI_SDK, when it has one, travels in the environment; otherwise build-components.sh finds
  # ~/wasi-sdk*. Cargo writes into the node's ONE build root, this tree's child of it (the same dir the
  # rows' cargo tests use): a second target dir per worktree is what 13/11 left behind 73 of.
  # A timing file beside the build, so the summary can say what each component cost to compile.
  component_times="$work/component-times.tsv"; : > "$component_times" 2>/dev/null || true
  if WA_COMPONENTS_DIR="$(native "$cache/set")" WA_COMPONENT_BUILD_TIMINGS="$component_times" \
       bash scripts/build-components.sh $FAST_COMPONENT_NAMES >"$log" 2>&1; then
    FAST_COMPONENT_SOURCE="$(native "$cache/set")"
    export FAST_COMPONENT_SOURCE
    echo "fast: components $(printf '%s' "$FAST_COMPONENT_NAMES") built from this tree and pinned in $cache/set"
    # What each of those builds cost, from build-components.sh own measurement: the units it
    # compiled say whether the row is a rebuild or a warm cache hit.
    if [ -s "$component_times" ]; then
      while IFS="$(printf '\t')" read -r cname cms cunits; do
        [ -n "${cname:-}" ] || continue
        if [ "${cunits:-0}" = 0 ]; then cnote="warm, nothing to compile"; else cnote="${cunits} unit(s) compiled"; fi
        wa_build_time_record component "$cname" "${cms:-0}" "$cnote"
      done < "$component_times"
    fi
  else
    reason=$(last_line_of "$log")
    echo "fast: components SKIPPED ($FAST_COMPONENT_NAMES): ${reason:-build-components.sh failed, see $log}"
    echo "fast: rows that need one print SKIP with that reason; a skip is counted as a skip, not a pass"
  fi
}
fast_components_prepare

# ---- 1. Lua -----------------------------------------------------------------------------------------
# The candidate rows come from the ONE inventory (scripts/lib/fast-rows.sh, wa_fast_row_candidates): the same
# function the landing planner (lua/core/land.lua, M.row_inventory) draws the rows it requests from, so a plan
# can only name a row this run lists - and a row scripts/fast-path.exclude declares not run is reported by the
# plan, not requested here.
. "$ROOT/scripts/lib/fast-rows.sh"
wa_fast_row_candidates > "$work/lua.list"
# WA_FAST_ROWS narrows the run to the rows a planned round's changed paths touch (scripts/lib/fast-rows.sh,
# the caller is `wa land`). It is a REQUEST, not an authority: the always-on core rows are added here, an
# unknown row is a refusal by name (exit 2, nothing runs), and the contract `check` lines below are not
# narrowable at all. The count and the reason are printed, so a narrowed run never reads like a full one.
if [ -n "${WA_FAST_ROWS:-}" ]; then
  lua_before=$(wc -l < "$work/lua.list")
  if ! wa_fast_row_filter "$work/lua.list" "$WA_FAST_ROWS" > "$work/lua.narrow" 2> "$work/lua.narrow.err"; then
    echo "fast: narrowed run REFUSED by $WA_FAST_ROWS: $(tr '\n' ' ' < "$work/lua.narrow.err")" >&2
    echo "fast: nothing ran; a plan that names a row this runner cannot execute has to be fixed, not obeyed" >&2
    exit 2
  fi
  mv "$work/lua.narrow" "$work/lua.list"
  echo "fast: narrowed by the landing plan ($WA_FAST_ROWS): $(wc -l < "$work/lua.list") of $lua_before Lua rows; the never-dropped core rows are included, and every contract check below still runs"
fi
timings=$(git rev-parse --git-path wa-fast-timings.tsv 2>/dev/null || true)
if [ -n "$timings" ] && [ -s "$timings" ]; then
  awk -F'\t' 'NR==FNR{ms[$3]=$2; next} {print (($0 in ms)?ms[$0]:999999) "\t" $0}' "$timings" "$work/lua.list" | sort -rn | cut -f2 > "$work/lua.sorted" \
    && mv "$work/lua.sorted" "$work/lua.list"
fi
# THE BINARY THE ROWS SPAWN IS THE ONE THIS RUN RESOLVED (item 3 of the node-ops round). A shell row that
# needs a `wa` of its own resolves WA_BIN, then the tree's release path, then PATH - and on this node PATH
# holds ~/.local/bin/wa, another commit build. MEASURED: the four scratch-home rows under the fast path
# ran that older binary, which rewrites HOME from WASM_AGENT_HOME without recording the home it replaced,
# so their guards refused a correct scratch home. WA_BIN is exported here so a row's node is THIS tree.
export WA_BIN="$bin"
# THE ROW SCRATCH ROOT, EXPORTED (item 0, measured). scripts/lib/test-home-guard.lua is an
# allow-list: a row home must sit under GATE_ROOT (else TMPDIR). This node TMPDIR is INSIDE the
# operator store, so without this a ledger-writing row refused to run ("this test writes a ledger:
# it refuses to run") - one row of 114 here, and the same cause would refuse all of them on a
# machine whose TMPDIR is the real home. Both names point at THIS run work dir, which the run has
# just proved is outside the operator store and outside the tree under test.
mkdir -p "$work/tmp" 2>/dev/null || true
export TMPDIR="$work/tmp" GATE_ROOT="$work"
export FAST_BIN="$bin" FAST_ROOT="$(native "$ROOT")" FAST_WORK="$work" NAMED_SKIPS="$named_skips"
mkdir -p "$FAST_WORK/logs"
# The definition of "run this test hermetically" lives in scripts/lib/fast-row-exec.sh, so the
# watchdog test can RUN it instead of grepping for it.
run_lua() { # <script> -> one TSV row: exit, ms, script, verdict line, verdict kind
  f=$1; s=$(fast_now_ms); code=0; kind=ok
  # A scratch home that cannot be made is the machine (the same signature the classifier reads in a
  # test's output: `mkdir ... -> nil`), never the tree. Reported as a row so it is counted, retried and
  # named rather than vanishing into a failed redirection.
  if ! h=$(mktemp -d "$FAST_WORK/h.XXXXXX" 2>/dev/null); then
    printf '1\t0\t%s\t%s\tenvironment\n' "$f" 'a scratch home could not be made (mkdir -> nil)'
    record_row fail lua "$f" 1 0 1 'a scratch home could not be made (mkdir -> nil)'
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
  # The same holes, as a table the JSON result can carry (check<TAB>reason): the printed summary above
  # groups them per suite and keeps only the first reason, which is right for a reader and not enough
  # for a consumer that wants every one.
  if grep -q '^SKIP ' "$out" 2>/dev/null; then
    grep -h '^SKIP ' "$out" 2>/dev/null | sed 's/^SKIP //' | while IFS= read -r reason; do
      printf '%s\t%s\n' "$f" "$reason" >> "$NAMED_SKIPS" 2>/dev/null || true
    done
  fi
  if [ "$c" != 0 ]; then
    kind=$(wa_environment_kind "$c" "$last")
    # A hang is only a hang when the watchdog said so in its own line: an exit 124 on its own is also what
    # a fixture that calls timeout returns, and calling that a hang would be a guess (item 8). The predicate
    # is scripts/lib/fast-watchdog.sh's, not a grep here, so there is one answer to "was this the watchdog".
    if wa_watchdog_hung "$c" "$(cat "$out" 2>/dev/null)"; then kind=hung; last=$(grep "$WA_FAST_WATCHDOG_HANG_LINE" "$out" | tail -1); fi
    cp "$out" "$FAST_WORK/logs/$(basename "$f").log" 2>/dev/null || true
  fi
  ms=$(( $(fast_now_ms) - s ))
  if [ "$c" = 0 ]; then
    record_row pass lua "$f" "$c" "$ms" 0 ''
  else
    record_row fail lua "$f" "$c" "$ms" "$( { [ "$kind" = environment ] || [ "$kind" = hung ]; } && echo 1 || echo 0)" "$(first_error_of "$out")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$c" "$ms" "$f" "$(printf '%s' "$last" | tr '\t' ' ' | cut -c1-160)" "$kind"
}
export -f lua_run run_lua native wa_fast_row_exec wa_fast_watchdog
xargs -P "$jobs" -I{} bash -c 'run_lua "$1"' _ {} < "$work/lua.list" > "$work/lua.tsv"
# The rows the machine could not run: retried once, one at a time, AFTER the batch, so the retry is
# genuinely alone on the machine. A row that passes then is a pass (reported as one); a row that still
# cannot run is marked `, environment` in its FAIL line, which is what the landing queue reads.
envrows=$(awk -F'\t' '$1!=0 && $5=="environment"{print $3}' "$work/lua.tsv")
if [ -n "$envrows" ]; then
  echo "fast: $(printf '%s\n' "$envrows" | grep -c .) row(s) could not run (fork/spawn): retrying them once, serially"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    h=$(mktemp -d "$FAST_WORK/h.XXXXXX"); log="$FAST_WORK/logs/$(basename "$f").retry.log"; s=$(fast_now_ms); c=0
    wa_environment_retry "lua $f" "$log" lua_run "$f" "$h"; c=$?
    kind=ok; [ "$c" != 0 ] && kind=environment
    case "$WA_FAST_RETRY" in
      retried) echo "fast: environment retry passed: $f (exit 0 after the machine refused the first attempt)" ;;
      environment) echo "fast: ENVIRONMENT still cannot run after a serial retry: $f (exit $c)" ;;
      *) cp "$log" "$FAST_WORK/logs/$(basename "$f").log" 2>/dev/null || true ;; # a real failure: keep the retry's log
    esac
    awk -F'\t' -v f="$f" -v c="$c" -v k="$kind" -v ms="$(( $(fast_now_ms) - s ))" -v l="$(last_line_of "$log" | tr '\t' ' ' | cut -c1-160)" \
      'BEGIN{OFS="\t"} $3==f {print c,ms,$3,l,k; next} {print}' "$work/lua.tsv" > "$work/lua.new" && mv "$work/lua.new" "$work/lua.tsv"
    # The JSON row follows the retry: a row that passed alone is a pass, and one that still cannot run is
    # the machine refusing, never a verdict on the code.
    if [ "$c" = 0 ]; then record_row pass lua "$f" "$c" "$(( $(fast_now_ms) - s ))" 0 ''
    else record_row fail lua "$f" "$c" "$(( $(fast_now_ms) - s ))" "$([ "$kind" = environment ] && echo 1 || echo 0)" "$(first_error_of "$log")"; fi
  done <<< "$envrows"
fi
lua_total=$(wc -l < "$work/lua.list"); lua_fail=$(awk -F'\t' '$1!=0' "$work/lua.tsv" | wc -l)
envleft=$(awk -F'\t' '$1!=0 && $5=="environment"' "$work/lua.tsv" | wc -l)
[ -n "$timings" ] && cp "$work/lua.tsv" "$timings" 2>/dev/null || true
ran=$((ran + lua_total)); fails=$((fails + lua_fail));
awk -F'\t' '$1!=0{ if ($5=="hung") printf "FAIL lua %s (hung): %s\n",$3,$4; else if ($5=="environment") printf "FAIL lua %s (exit %s, environment): %s\n",$3,$1,$4; else printf "FAIL lua %s (exit %s): %s\n",$3,$1,$4 }' "$work/lua.tsv"
echo "fast: lua $((lua_total - lua_fail))/$lua_total passed ($(wa_fast_row_skips | grep -c . ) excluded: scripts/fast-path.exclude)"
[ "$envleft" -gt 0 ] && echo "fast: $envleft of them never ran: the machine ran out of processes (fork/spawn), see scripts/lib/fast-environment.sh"
# A hung row is neither a pass nor a verdict on the code, and it is counted apart from both: its process
# group was killed (scripts/lib/fast-watchdog.sh), so the run that follows it is not measuring a tree that
# leaked a writer, a lock or a pipe into it.
hungleft=$(awk -F'\t' '$1!=0 && $5=="hung"' "$work/lua.tsv" | wc -l)
[ "$hungleft" -gt 0 ] && echo "fast: $hungleft row(s) HUNG and were killed with their whole process group: the line names the row, the seconds and the group (see scripts/lib/fast-watchdog.sh)"
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
  record_row skip rust 'rust (all crates)' 0 0 0 'inside the sandbox image: no toolchain; run on a node with cargo'
elif ! command -v cargo >/dev/null 2>&1; then
  echo "fast: rust SKIPPED (cargo not on PATH)"; skipped=$((skipped + 1))
  record_row skip rust 'rust (all crates)' 0 0 0 'cargo is not on PATH'
else
  # Test builds, not shippable ones - but NOT empty ones when a prepared asset directory is here. The
  # empty switch (WA_CODEMODE_ALLOW_EMPTY=1) is what the gate sets, and it does not only relax the build
  # script: `cargo test --release` rebuilds `target/release/wa` with NO code-mode assets, so a later row
  # - or a later run of this script - finds a node that cannot run code mode at all (measured: 72 598 376
  # B empty vs 73 904 880 B with assets). With the assets, the test build is the same artifact shape as
  # the shipping one, so a test run cannot replace a capable node with an incapable one.
  if [ -n "${FAST_CODEMODE_ASSETS:-}" ] && [ -d "$FAST_CODEMODE_ASSETS" ]; then
    export WA_CODEMODE_BUILD_ASSETS="$FAST_CODEMODE_ASSETS"
    unset WA_CODEMODE_ALLOW_EMPTY
  else
    export WA_CODEMODE_ALLOW_EMPTY=1
  fi
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
  # wa-tls is the one answer to "whose certificates do we trust" (SSL_CERT_FILE / SSL_CERT_DIR, review
  # r1 item 5): a change there decides the anchors of every other rust row, and until now the fast path
  # never ran its own tests at all - the row list is explicit, so a crate left out of it is a crate
  # whose tests do not run however it changed.
  # wa-keystore is the crate every other vault row depends on and the one whose decisions are invisible
  # from above it: which protection wraps the root key, what a wrapped-root file is read as, and what a
  # kernel-keyring refusal means. Its tests are seconds (a leaf with ring/chacha20/argon2), and until now
  # they ran nowhere in the fast path - which is how two defects in it reached a landing (13/11: the key
  # quota leak behind `keystore_keyring_unavailable`, and a wrapped root read with the wrong cipher behind
  # `sealed_blob_version_unknown`).
  for crate in wa-sqlite wa-host wa-host-support wa-governance wa-term wa-rendezvous wa-kernel-runtime wa-capabilities wa-operation wa-jobs wa-graph wa-sentinel wa-whatsapp-outbox wa-whatsapp-index wa-mesh wa-stt-remote wa-model-gateway wa-tool-progress wa-model-router wa-fleetview wa-keystore wa-tls; do
    # A HERE-STRING, NOT A PIPE (measured 19/11: under \`set -o pipefail\`, \`printf | grep -q\` fails about 0.15% of the
    # time - grep exits at the first match and printf dies of SIGPIPE - and here that silently DROPS a crate from the
    # run, so the fast path tested less than it said. Measured: 3 false failures in 2000 calls.)
    if [ "$all_rust" = 1 ] || grep -q "^rust/$crate/" <<< "$changed"; then crates="$crates $crate"; fi
  done
  grep -qE '^rust/(Cargo\.(toml|lock))$' <<< "$changed" && [ "$all_rust" = 0 ] && crates=" wa-sqlite wa-host wa-host-support wa-governance wa-term wa-rendezvous wa-kernel-runtime wa-capabilities wa-operation wa-jobs wa-graph wa-mesh wa-tls"
  if [ -z "$crates" ]; then echo "fast: rust - no crate touched"; fi
  # A RUST ROW GETS ITS OWN HOME (review r2, item 3). Two wa-capabilities tests (operations::
  # adoption_survives_the_relay_deadline and operations::await_returns_at_its_own_wait) START REAL
  # OPERATIONS and refuse to run outside a scratch HOME - they were red on origin/main for exactly that
  # reason, on any machine whose HOME is the operator's. The gate runs them with HOME=$GATE_HOME; this
  # runner gave Rust rows no home at all. Each row now gets a scratch HOME of its own, and CARGO_HOME and
  # the target dir still point where they did, so `--offline` keeps resolving the same registry cache.
  # CARGO_HOME and RUSTUP_HOME are captured from the REAL environment before HOME changes, so --offline
  # keeps resolving the same registry and toolchain (review r3: the earlier comment claimed this and the
  # code did not do it).
  real_cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  real_rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  rust_home=''
  if command -v mktemp >/dev/null 2>&1; then rust_home=$(mktemp -d "$work/home.XXXXXX" 2>/dev/null || true); fi
  if [ -z "$rust_home" ]; then
    # A SKIP that is recorded, never a silent success. The old line ran `return 0 2>/dev/null || exit 0`
    # at top level: the whole fast path ended with success and every later row was skipped unannounced
    # (review r3, B-fast).
    echo "SKIP: the Rust rows need a scratch HOME and mktemp failed"
    record_row skip rust 'rust rows' 0 0 0 'mktemp failed: the Rust rows need a scratch HOME and the operator own is refused'
    skipped=$((skipped + 1))
  fi
  for crate in $( [ -n "$rust_home" ] && printf '%s' "$crates" ); do
    # THE BUILD, measured as the build the tests themselves need - never a second one. 'cargo test
    # --no-run' in the tests' own profile compiles exactly what the row below runs, and the row then
    # reuses that compile, so the number the module claim rests on is the cost of the crate's test build
    # and is paid once (ARCHITECTURE.md, "Modules over the monolith"). The seconds the tests then take
    # are the row's own measurement.
    if [ "$crate" = wa-sentinel ]; then test_args="--manifest-path rust/wa-sentinel/Cargo.toml"
    else test_args="--release --manifest-path rust/Cargo.toml -p $crate"; fi
    bstart=$(fast_now_ms); build_rc=0
    # The exit code is KEPT, not discarded: a build that failed compiled nothing, and the note must say
    # so rather than print the warm row's sentence under a red one (scripts/lib/build-times.sh).
    HOME="$rust_home" CARGO_HOME="$real_cargo_home" RUSTUP_HOME="$real_rustup_home" CARGO_TARGET_DIR="${fast_build_target:-$ROOT/rust/target}" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(wa_build_jobs)}" wa_build_host_lock cargo test --no-run --offline $test_args > "$work/build-$crate.log" 2>&1 || build_rc=$?
    wa_build_time_record crate "$crate" "$(( $(fast_now_ms) - bstart ))" "$(wa_build_time_note "$work/build-$crate.log" "$build_rc")"
    s=$(date +%s)
    if [ "$crate" = wa-sentinel ]; then
      HOME="$rust_home" CARGO_HOME="$real_cargo_home" RUSTUP_HOME="$real_rustup_home" CARGO_TARGET_DIR="${fast_build_target:-$ROOT/rust/target}" cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=1 > "$work/rust-$crate.log" 2>&1
    elif [ "$crate" = wa-capabilities ]; then
      # wa-capabilities holds the streaming timeout tests (http_transport's phase budgets: 250 ms for
      # response headers, 500 ms of body silence) next to the agent-core pool's heavy ones. Those
      # budgets are wall-clock facts about a *quiet* process, so they get their own process: the rest
      # of the crate first (the pool's engines, compiles and wasm instances cannot starve them), then
      # the streaming tests alone. Neither run skips anything - the split is the isolation, not a
      # filter on what is proved (docs/KERNEL.md, "A2.3").
      HOME="$rust_home" CARGO_HOME="$real_cargo_home" RUSTUP_HOME="$real_rustup_home" CARGO_TARGET_DIR="${fast_build_target:-$ROOT/rust/target}" cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities \
        -- --skip http_transport::streaming_timeout_tests > "$work/rust-$crate.log" 2>&1 \
      && HOME="$rust_home" CARGO_HOME="$real_cargo_home" RUSTUP_HOME="$real_rustup_home" CARGO_TARGET_DIR="${fast_build_target:-$ROOT/rust/target}" cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-capabilities \
        -- http_transport::streaming_timeout_tests >> "$work/rust-$crate.log" 2>&1
    else
      HOME="$rust_home" CARGO_HOME="$real_cargo_home" RUSTUP_HOME="$real_rustup_home" CARGO_TARGET_DIR="${fast_build_target:-$ROOT/rust/target}" cargo test --release --offline --manifest-path rust/Cargo.toml -p "$crate" > "$work/rust-$crate.log" 2>&1
    fi
    c=$?; ran=$((ran + 1)); ms=$(( ($(date +%s) - s) * 1000 ))
    if [ "$c" = 0 ]; then echo "fast: rust $crate ok ($(( $(date +%s) - s ))s)"; record_row pass rust "rust $crate" "$c" "$ms" 0 ''
    else fails=$((fails + 1)); echo "FAIL rust $crate (exit $c):"; { grep -E "^test .* FAILED|panicked at|^error" "$work/rust-$crate.log" || tail -5 "$work/rust-$crate.log"; } | head -8
      record_row fail rust "rust $crate" "$c" "$ms" 0 "$(first_error_of "$work/rust-$crate.log")"; fi
  done
  # A COMPONENT IS ITS OWN CARGO WORKSPACE, so the `-p` loop above cannot reach its tests: they are run
  # from its own directory. Until now nothing ran them automatically anywhere - the component suite was
  # green only when someone ran it by hand, which is how the 13/11 `contacts` defect (every name query
  # answering `count: 0` on a full index) reached a deploy beside component tests that passed. Same rule
  # as the crates above: a component this change touches has its tests run here, into this tree's child
  # of the one build root (docs/ONEROOT.md) so no build lands inside the checkout.
  for component in $(printf '%s\n' "$changed" | sed -n 's|^rust/components/\([^/]*\)/.*|\1|p' | sort -u); do
    [ -f "rust/components/$component/Cargo.toml" ] || continue
    s=$(date +%s)
    CARGO_TARGET_DIR="${fast_build_target:-$ROOT/rust/target}/components/$component" \
      cargo test --offline --manifest-path "rust/components/$component/Cargo.toml" > "$work/rust-component-$component.log" 2>&1
    c=$?; ran=$((ran + 1)); ms=$(( ($(date +%s) - s) * 1000 ))
    if [ "$c" = 0 ]; then echo "fast: rust component $component ok ($(( $(date +%s) - s ))s)"; record_row pass rust "rust component $component" "$c" "$ms" 0 ''
    else fails=$((fails + 1)); echo "FAIL rust component $component (exit $c):"; { grep -E "^test .* FAILED|panicked at|^error" "$work/rust-component-$component.log" || tail -5 "$work/rust-component-$component.log"; } | head -8
      record_row fail rust "rust component $component" "$c" "$ms" 0 "$(first_error_of "$work/rust-component-$component.log")"; fi
  done
fi

# ---- 3. contract checks -------------------------------------------------------------------------------
check() { name=$1; shift; s=$(fast_now_ms)
  wa_environment_retry "$name" "$work/check-$name.log" "$@"; c=$?
  ran=$((ran + 1)); ms=$(( $(fast_now_ms) - s ))
  if [ "$c" = 0 ]; then
    # A GREEN ROW THAT PRINTED SKIP IS A SKIP, NOT A PASS (item 10 of the node-ops round). Measured 19/11:
    # 52 test files print "SKIP <test>: <reason>" and exit 0 - a component this machine cannot build, a
    # fixture that is not installed. This runner collected those lines into the skips table and then recorded
    # the row as "pass", so "fast path ok (N checks, 0 skipped)" was true of the count and false of the run:
    # a consumer reading the row status saw a proof where there was a named hole. The row is now recorded
    # "skip" with that reason and counted in $skipped, which is what its own line said.
    #
    # RE-MEASURED 22/11 on main a8cd5348: this branch was GONE - check() went straight from a zero exit to
    # record_row pass - so scripts/test-fast-skip-count.sh (wired at scripts/test.sh:1008) failed with "the
    # shipped check() does not look for a SKIP line". It was dropped by 2975b6c5 ("they come back with
    # their own test") and never came back.
    local skip_reason
    skip_reason="$(grep -h '^SKIP ' "$work/check-$name.log" 2>/dev/null | sed 's/^SKIP //' | head -1)"
    if [ -n "$skip_reason" ]; then
      skipped=$((skipped + 1))
      echo "fast: $name SKIPPED (${ms}ms): $skip_reason"
      record_row skip checks "$name" "$c" "$ms" 0 "$skip_reason"
      return 0
    fi
    echo "fast: $name ok (${ms}ms)"; record_row pass checks "$name" "$c" "$ms" 0 ''; return 0
  fi
  fails=$((fails + 1))
  case "$WA_FAST_RETRY" in environment) envfails=$((envfails + 1)); echo "FAIL $name (exit $c, environment): $(last_line_of "$work/check-$name.log")"
      record_row fail checks "$name" "$c" "$ms" 1 "$(first_error_of "$work/check-$name.log")" ;;
    *) echo "FAIL $name (exit $c): $(tail -3 "$work/check-$name.log" | tr '\n' ' ')"
      record_row fail checks "$name" "$c" "$ms" 0 "$(first_error_of "$work/check-$name.log")" ;; esac
}
WA_BIN="$bin" check prompt-docs bash scripts/sync-prompt-docs.sh --check
if command -v node >/dev/null 2>&1; then
  # Which binary the rows run (11/11): the tree's own and named in the first line, or a named refusal.
  # A lane whose rows graded the canonical checkout's node instead of its own tree was green and wrong.
  check fast-binary node scripts/test-fast-binary.mjs
  check instructions node scripts/check-instructions.mjs
  check direct-workflow node scripts/test-direct-workflow-instructions.mjs
  # The mail wrapper's repairs of mail-mcp's API (cursor, account_id, limit range), through the real wrapper.
  check mcp-mail-repairs node scripts/test-mcp-mail-repairs.mjs
  # The landing queue's own evidence: one lander at a time, FIFO, reclaim of a dead holder, the
  # dirty-canonical refusal, and the upstream-delta classification that decides what is retested.
  # Seconds, self-contained (a fixture repository and a fixture ledger), so it belongs here and not
  # only in the nightly gate.
  # Does this branch's own test catch this branch's own change? A test that still passes with the
  # branch's non-test changes reverted would not have caught the bug it was written for, and it is
  # named here by its path (19-20/11: three of ten hidden tests did not discriminate, and every
  # review of that round carried a test MUST). Self-contained: a fixture repository, no binary.
  check discrimination node scripts/test-discriminates-test.mjs
  check landing-queue node scripts/test-landing-queue.mjs
  # The one build root (13/11: 73 build folders, ~196 GB, none ever deleted): one directory every build
  # kind resolves through, one child per tree inside it, a sweep that deletes what older layouts left,
  # the build cap that evicts the oldest, and the measurement that keeps the per-tree child honest.
  check onebuild node scripts/test-onebuild.mjs
  # The gate's own cost, kept honest (change/gate-speed, 21/11): a NEW target dir is seeded from the
  # newest sibling for the same toolchain (a cold wa-host build measured 144 s, the same build seeded 61 s
  # / 64 s), and one heavy build runs at a time with a job cap. Both rows are seconds and self-contained:
  # they build two tiny two-member workspaces in their own scratch home.
  check build-heat node scripts/test-build-heat.mjs
  check build-seed node scripts/test-build-seed.mjs
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
  # The machine-readable result a red run leaves behind (scripts/fast-result.mjs): every check by name,
  # its verdict, the FIRST error line it printed, and the environment (node/cargo/wasi-sdk/lua,
  # node:sqlite, the binary and its hash) the verdict belongs to. Measured 11/12: four sessions paid an
  # extra full run each to establish facts this file states.
  check fast-result node scripts/test-fast-result.mjs
  # The front door (scripts/install.sh): the platform matrix, which channel each OS gets, the exact
  # arguments the core is handed, the installer pin, and install -> re-run -> update -> rollback against
  # file: fixtures. No network, no systemd, no built binary - seconds.
  # Both halves of the tool-environment rule (session isolation, finding 5 round 2): a secret is withheld by
# shape, and the node policy hands a NAME over. One script, two invocations - which is why it is a .sh
# check here and its .lua half is declared not-a-row in scripts/fast-path.exclude.
# The session-isolation suite holds the canaries its own environment sections withhold
WA_BIN="$bin" check session-isolation bash scripts/test-session-isolation.sh
WA_BIN="$bin" check tool-env-allow bash scripts/test-tool-env-allow.sh
# A session whose mission was stopped must STAY stopped (22/11): the verb a stop recipe runs parks it,
# its due wake is held rather than dropped or dispatched, `wa chat --resume`/`--continue` refuse it by name,
# and the release runs that same wake exactly once. Cross-process by construction - the park is written by
# one `wa`, read by a second, and performed by the tick in a third. Its Lua half
# (scripts/test-session-park.lua) is a fast-path row by name.
check session-park bash scripts/test-session-park.sh
# fast.sh runs under set -u: every incremented counter is initialised (test-fast-counters.sh).
check fast-counters bash scripts/test-fast-counters.sh
check install-front-door bash scripts/test-install.sh
  # The canonical runtime binding is decided in PREFLIGHT, before anything is built, and a refusal names
  # every worktree that is on branch main (measured 18/11: a deploy refused after ~4 minutes of build with
  # "exactly one canonical main checkout is required" and named neither path the operator had to choose
  # between). The row arrived with that fix and no harness named it, so the preflight the deploy depends
  # on was itself unchecked by every gate: the orphan ledger said so and nothing else ran it.
  check runtime-binding-preflight node scripts/test-runtime-binding-preflight.mjs
  # A scripted `wa chat` (`wa chat "<prompt>"` from a script, `x | wa chat`, or `--once`) must run its
  # turn(s), release the session and EXIT with the run's status - and a session whose run is in flight
  # must be steerable with `wa steer` instead of killed (docs/SCRIPTED-RUNS.md). It drives the real
  # binary, because the failure it covers is a process that never exits: a Lua-only test cannot see it.
  WA_BIN="$bin" check cli-scripted node scripts/test-cli-scripted.mjs
  # A fenced code card keeps its border when the screen is narrower than the width it was rendered at
  # (a focused block is boxed two columns in; a resize redraws at the new width). It drives the REAL
  # binary in a private tmux pty and REFUSES to run unless its fixture served the request, so a run
  # that reached any other endpoint fails instead of passing.
  WA_BIN="$bin" check fence-card-pty node scripts/test-fence-card-pty.mjs
  # The TWO BLOCKS OF change/tui-reflow-blocks FOLLOW THE WINDOW (Victor 22/11): a ```bash card and a
  # ```js run block, drawn at 120, 60, 120 and 60 columns in a real pty. Each is whole and unmarked where
  # it fits, cut with ONE mark in the left gutter of the row the line goes on where it does not (the run
  # box used to put it in the last cell of the cut row), and the second visit to a width draws the rows
  # the first one did. A view change cannot be judged by a Lua double alone, hence a real pty here too.
  WA_BIN="$bin" check reflow-blocks-pty node scripts/test-reflow-blocks-pty.mjs
  # THE RUN BLOCK, AS THE OPERATOR READS IT (Victor 21/11): a script the model writes inside run,
  # then only bash x2 and a four-kilobyte JSON blob where the two commands own output belonged. It
  # drives the REAL binary twice - wa chat --once and the interactive window in a private tmux pty -
  # against a local SSE fixture, and reads the rows back. A row of this run for the same reason
  # fence-card-pty is one: a view change cannot be judged by a Lua double alone.
  WA_BIN="$bin" check run-live-pty node scripts/test-run-live-pty.mjs
  # THE WINDOW'S CHROME (change/tui-chrome, Victor 21/11): the input box grows to max(3, 30% of the
  # window), scrolls with the transcript's scrollbar and takes the wheel when the pointer is over it.
  # And a fenced card's copy icon sits after its corner, where a click on it still copies the content.
  # The real binary in a private tmux pty, as the two rows above.
  WA_BIN="$bin" check tui-chrome-pty node scripts/test-tui-chrome-pty.mjs
  # THE STATUS ROWS' ICONS, MEASURED IN THE FONT FILES (tui-chrome item 2): advance and bearings of
  # every glyph the two rows draw. The brief's box does not hold today, so the script ends with a named
  # SKIP line and exit 0; the line is carried into the skips this run prints and counts - a hole that is
  # spoken, never a pass. (`--strict` makes it a failure once the glyphs are redrawn.)
  if command -v python3 >/dev/null 2>&1; then
    check status-icon-metrics python3 scripts/test-status-icon-metrics.py
    if grep -q '^SKIP ' "$work/check-status-icon-metrics.log" 2>/dev/null; then
      grep -h '^SKIP ' "$work/check-status-icon-metrics.log" | sed 's|^SKIP |status-icon-metrics: |' >> "$FAST_WORK/skips" 2>/dev/null || true
      grep -h '^SKIP ' "$work/check-status-icon-metrics.log" | sed 's/^SKIP //' | while IFS= read -r reason; do
        printf '%s\t%s\n' status-icon-metrics "$reason" >> "$NAMED_SKIPS" 2>/dev/null || true
      done
    fi
  else
    echo "fast: status-icon-metrics SKIPPED (python3 not on PATH)"; skipped=$((skipped + 1))
  fi
  # THE RUN BLOCK AS THE OPERATOR READS IT (change/tui-run-block): the script streams while the
  # fixture sends the code argument in paced deltas, the output is shown once (one compact result
  # row that a click opens and folds, one row per call), and the scrollbar is one bar while a call
  # waits. Its own row, its own fixture: about twenty seconds.
  WA_BIN="$bin" check run-block-pty node scripts/test-run-block-pty.mjs
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
  record_row skip checks 'node checks' 0 0 0 'node is not on PATH: instructions, direct-workflow, landing-queue, session-liveness, landing-baseline, orphan-tests and the JS rows could not run'
fi
# The deploy's retirement rule: a shipped script main deleted must not survive in the install (measured
# 2026-11-11: the removed Node WhatsApp bridge stayed installed beside the new set).
check deploy-prune bash scripts/test-deploy-prune.sh
check prune-kept-binaries bash scripts/test-prune-kept-binaries.sh
# The per-row watchdog (item 6 of the node-ops round): a hung row is NAMED and its whole process group
# dies with it. Measured 18/11 on avell: a row whose fixture forked a long sleep child outlived the row
# every time, because the bare timeout ends only the process it was given. Seconds, scratch home, no node.
check fast-watchdog bash scripts/test-fast-watchdog.sh
# The gate's cargo-codemode check builds into this tree's ONE named build dir, the one this run's own
# Rust rows just filled, and never a second cold copy under rust/target (138 s of every landing, measured
# 21/11). A stub cargo, a scratch build root: seconds, no compile.
check gate-cargo-codemode bash scripts/test-gate-cargo-codemode.sh
# A row that exits 0 still owns its process group: the children it forked are reclaimed and the sweep
# says how many, so the accumulation that reached 1,234 processes cannot build up (test-fast-watchdog-reap.sh).
check fast-watchdog-reap bash scripts/test-fast-watchdog-reap.sh
# The reclaim of an interrupted run never removes a live run's directory (test-fast-reclaim-race.sh).
check fast-reclaim-race bash scripts/test-fast-reclaim-race.sh
# The rule those guards rest on, judged: WASM_AGENT_HOME is the USER home, so the operator home, its
# store, anything inside it and anything above it are refused (item 4 of the node-ops round).
check scratch-home bash scripts/test-scratch-home.sh
# A probe child never probes again, across module instances and across a fresh Lua state: two real
# dofiles, the unmarked one fans out, the marked one starts nothing, and a joiner gets the ANSWER
# (test-nodes-probe-instances.lua; the 19/11 recursion and the 554-process crowd).
check nodes-probe-instances bash scripts/test-nodes-probe-instances.sh
# A REAL node probes a stub peer over HTTP and gets its capabilities back - asked, not
# probe_leaseholder_pending - which is the only row that can see an ownerless await
# (test-nodes-probe-real.sh).
check nodes-probe-real bash scripts/test-nodes-probe-real.sh
# lua_run hands every row fast.sh's WA_FAST_CLEARED unchanged and clears the vault/node variables (test-fast-row-cleared.sh).
check fast-row-cleared bash scripts/test-fast-row-cleared.sh
# ROWS THIS BRANCH CANNOT RUN ARE NOT WIRED HERE (review r2, A1). Eleven `check` lines named scripts that
# only exist on change/node-ops (the probe rows, the build-record rows, the rollback row, the restore row,
# row-at-sha): on this branch each was an exit-127 FAIL, so the split reported eleven failures that were
# only files that were never here. A row is wired where its script lives.
check publish-artifacts bash scripts/test-publish-artifacts.sh
# THE DEPLOY'S ANCESTRY AND ITS RECORD (round 4 of the deploy-ancestry review). Seven files were written with
# that fix and named by no harness, so every gate here was green without running one of them; the full gate now
# runs all seven (scripts/test.sh) and these are the ones measured at seconds - a landing round that touches the
# install path should not need the hour-long gate to learn whether the machine can still tell what is running.
# test-deploy-ancestry.sh is NOT here: it runs a real deploy.sh detached (setsid --fork) per case, 28 s measured,
# and the guard it proves is in the full gate. The measurement and the reason are in
# docs/missions/reports/deploy-ancestry.md.
WA_BIN="$bin" check install-record bash scripts/test-install-record.sh
check install-guards bash scripts/test-install-guards.sh
WA_BIN="$bin" check node-pins bash scripts/test-node-pins.sh
# One composer for the build name (rust/wa-host/src/build_info.rs): a fleet-wide pin ledger marks
# the node a record NAMES, and a cleared record releases it in either line order. Driven through
# `wa --version`, because the composer runs before any Lua.
WA_BIN="$bin" check pin-label bash scripts/test-pin-label.sh
check publish-shared-commit bash scripts/test-publish-shared-commit.sh
check bootstrap-gate bash scripts/test-bootstrap-gate.sh
WA_BIN="$bin" check build-info bash scripts/test-build-info.sh
WA_BIN="$bin" WA_TEST_SCRATCH_HOME=1 check ancestry-window bash scripts/test-ancestry-window.sh
# The mission loop's mechanism (docs/MISSIONS.md): stage, start, status, verify and clean against a scratch
# repository and a stub wa. Seconds, and no node, no cargo, no model - it proves the runner's environment,
# the done marker with its rc and the failure count without launching a session.
check mission bash scripts/test-mission.sh
# The mission verb in the CLI (change/mastermind item 2): launch -> start -> status -> stop against a
# scratch root and a stub CLI, and the refusals that keep a second writer out of one worktree.
check mission-verb bash scripts/test-mission-verb.sh
# The preflight (item 2 of the factory round): the script that runs a mission's gate BEFORE anybody lands
# it, judged on a scratch missions root and a stub landing - exit 0 green, 1 red with the failed rows by
# name, 2 refused when it judged nothing, and the suite lock held while the landing ran.
check preflight bash scripts/test-preflight.sh
# THE CHANGES ROUND'S OWN ROWS (factory-3, 21/11): a derived file cannot go stale in a merge; "main is green"
# is a recorded fact; and a finished mission lands itself. Each is seconds and self-contained (a fixture
# repository, a stub landing, a stub fast path), so they belong on the fast path and not only in the nightly.
check regenerate bash scripts/test-regenerate.sh
check main-health bash scripts/test-main-health.sh
check drive bash scripts/test-drive.sh
# The worker's own gate loop (item 3): a red preflight resumes the SAME session with the failed rows up to
# three rounds, and <mission>/done carries rc=<rc> preflight=<verdict> rounds=<n>. Judged on a scratch
# mission, a stub preflight and a stub CLI.
check worker-gate bash scripts/test-worker-gate.sh
# The fastlane's two halves, both seconds and self-contained. The row list a narrowed run executes: the core
# rows are never dropped, an unknown row is a refusal and an empty request runs nothing (scripts/lib/fast-rows.sh,
# the one place a plan could make a green run mean less). And the signing chain a round depends on: the
# manifest and SHA256SUMS are produced once, so a re-run of the publisher after the vault host signed them does
# not invalidate the signature - the 13/11 failure that needed a hand-frozen build (the lua-tree record is
# covered by the same row).
check fast-rows bash scripts/test-fast-rows.sh
check land-signing bash scripts/test-land-signing.sh
# The Go WhatsApp connector was removed in Phase 4 (11/11) and must not come back: no Go source, no
# build/install entry point, no unit that starts it - while the Rust component, its MCP, the operator
# client and the STT/OCR workers stay. The scan is proved on fixtures, so it is a gate and not a grep
# nobody tests.
check whatsapp-go-retired bash scripts/test-whatsapp-go-retired.sh
# The runner's half of "the machine, not the code": the classifier and the serial retry, against fixture
# commands that fail the way a starved machine fails (and a real failure that must NOT be excused).
check fast-environment bash scripts/test-fast-environment.sh
# A pinned component's bytes are the build of the source this tree ships (13/11: `change/waroute` added
# the `contacts` op to `rust/components/wa-whatsapp` and to the seam crate it shares with the node, and
# `components.lock` kept pinning the artifact built before it - every deploy installed those bytes and
# the tool answered `whatsapp_contacts_bad_op`; the component's tests were green because they ran
# against the source). Two halves, both for EVERY pinned component: the pin must move when anything under
# a pinned component's tree or a crate it path-depends on moves (git only - it never skips, no toolchain,
# no network), and every pinned `<name>.wasm` must be the bytes its line names (sha256 and size) - with
# `wa-whatsapp`'s own seam scan on top, because its op list is a crate of this tree. Half 2 says
# `SKIP <name>-pin: <why>` per component when no copy of the pinned bytes is reachable;
# `WA_PIN_CHECK_REQUIRE=1` (a release gate) makes every skip a failure instead.
check component-pins bash scripts/test-component-pins.sh
# The row above judges THIS tree; this one judges the CHECK, because a gate nobody proves is a gate that
# can quietly judge less. Its fixtures are the shapes that shipped: a component changed without a repin -
# including a non-whatsapp one, while another pinned component was repinned in the same commit - a copy
# that is not its pin failing by name, a per-component SKIP, and eight parallel rows fetching two pinned
# names from one cache at once (the 13/11 race). Seconds: no toolchain, no network, no build.
check component-pins-selftest bash scripts/test-component-pins.sh --self-test
# The WIT seam is two shapes and a check (ARCHITECTURE.md, "Seams are WIT, and async by default"):
# a string that carries JSON says so in its name, and nothing new exposes a status to poll. The
# baseline file is what lets the rule bind new code without breaking the tree - and its own stale
# lines fail, so a hole that is closed has to leave the file.
check wit-lint bash scripts/wit-lint.sh
# The check judged by fixtures: both rules fail where they must and NOT where they must not (a doc
# naming hooks.json, a doc describing a RETURN value), the baseline accepts the recorded holes, and
# the marker alone turns a polling func green. Seconds, no toolchain.
check wit-lint-selftest bash scripts/test-wit-lint.sh
# The module map's own fixtures: the counts by kind (a component counted once, a modules/ dir without a
# manifest not at all), a win line and the flag for the modules without one, a ledger's seconds, a
# co-change pair over 70% and a decision inside the 30-day / 100-commit cooldown - plus the exit code
# that keeps a report a map and never a gate.
check module-report-selftest bash scripts/test-module-report.sh
# The Rust build row's own shape: the number it records is the compile the test row below reuses (not a
# second release build), and every duration goes through a portable clock. Static by design, so it runs
# where the build rows themselves are skipped for want of a toolchain.
check fast-build-timing bash scripts/test-fast-build-timing.sh
# A short and a long spelling of one commit are one commit (deploy refused bcacbf38 vs bcacbf38eb3b, 21/11).
check commit-id bash scripts/test-commit-id.sh

# The measured build times of everything this run compiled, before the verdict, so the claim
# and the numbers are one screen apart (no gate: scripts/lib/build-times.sh says why).
wa_build_time_summary
# The module map, from the same ledger (ARCHITECTURE.md, "Modules over the monolith"): what the tree is
# made of, what each part cost to build, which parts state a measured win, which pairs moved together in
# >70% of the last 50 commits, and which split/merge is still inside the cooldown. FLAGS, NOT FAILURES:
# it prints and the verdict below never reads it (scripts/module-report.mjs says why), so a module with no
# win is a line to read, never a landing to block. WA_FAST_MODULE_ROWS keeps it to one screen; the whole
# map is `node scripts/module-report.mjs` (its default is every module).
if command -v node >/dev/null 2>&1; then
  node scripts/module-report.mjs --timings "$work/build-times.tsv" --rows "${WA_FAST_MODULE_ROWS:-8}" 2>&1 || echo "fast: module report SKIPPED (scripts/module-report.mjs exited $?)"
else
  echo "fast: module report SKIPPED (node is not on PATH, so scripts/module-report.mjs cannot run)"
fi

elapsed=$(( $(date +%s) - started ))
# The exit code is decided first so the JSON result and the printed verdict can never disagree.
if [ "$fails" = 0 ]; then
  exit_code=0
  verdict_line="fast path ok ($ran checks, $skipped skipped, ${elapsed}s)"
elif [ "${envfails:-0}" -gt 0 ] && [ "${envfails:-0}" = "$fails" ]; then
  # Every failure was the machine refusing to start a process. That is not a verdict on the tree, and
  # the landing queue reads exit 3 as "retry", never as "this branch is worse than main".
  exit_code=3
  verdict_line="fast path could not run: $fails check(s) were the machine (fork/spawn, retried serially once), ${skipped} skipped, ${elapsed}s"
else
  exit_code=1
  verdict_line="fast path FAILED ($fails of $ran checks, $skipped skipped, ${elapsed}s)"
fi

# ---- the machine-readable result ---------------------------------------------------------------------
# The JSON is written even when the run failed: that is the whole point of it (a red run is the one a
# reader has to attribute). It goes into the worktree's own git dir, never into the tree under test.
cat "$result_rows"/*.row > "$work/results.tsv" 2>/dev/null || : > "$work/results.tsv"
printf 'ok\t%s\nexit_code\t%s\nelapsed_seconds\t%s\nverdict\t%s\n' \
  "$([ "$exit_code" = 0 ] && echo 1 || echo 0)" "$exit_code" "$elapsed" "$verdict_line" > "$work/summary.tsv"
result_file="${WA_FAST_RESULT:-$(git rev-parse --git-path wa-fast-result.json 2>/dev/null || printf '%s' "$ROOT/wa-fast-result.json")}"
if command -v node >/dev/null 2>&1; then
  node scripts/fast-result.mjs --results "$work/results.tsv" --env "$work/env.tsv" \
    --skips "$NAMED_SKIPS" --summary "$work/summary.tsv" --out "$result_file" \
    || echo "fast: result NOT written (scripts/fast-result.mjs exited $?); the verdict below still stands"
else
  echo "fast: result SKIPPED (node is not on PATH, so scripts/fast-result.mjs cannot write the JSON)"
  skipped=$((skipped + 1))
fi
echo "$verdict_line"
exit "$exit_code"
