#!/usr/bin/env bash
# Smoke test for the Rust+Lua wasm-agent: build, then exercise memory and a WASM plugin.
set -euo pipefail
# A skipped test must be visible in the verdict, not only in the middle of the log:
# "smoke ok" over a run that skipped the UI tests claims more than it did.
SKIPPED=0
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

# The disk is a reserved resource too, and this is the reservation. It is read here - before the
# environment fence below and before the first `cargo` line - so a run that cannot finish is refused
# before any of it is paid for. On 2026-09-30 this node reached 1.9 GB free and nothing said so: a gate
# died 10.6 seconds into its build with `There is not enough space on the disk. (os error 112)` and the
# only signal was a cargo error deep in a log, while the same commit passed in 21.4 minutes once space
# was freed. The floor is a measurement of what one run costs, and the refusal names both numbers; the
# derivation, and what that measurement does not settle, are the header of scripts/check-disk-floor.sh.
# It runs outside the fence deliberately: the floor is this file's, an ambient variable cannot move it,
# and `--floor-bytes` is the one deliberate way past it.
bash scripts/check-disk-floor.sh

# A scratch DB does not isolate profile/config/effect files. Fence the ENTIRE gate,
# including new fixtures whose authors might otherwise forget to select a home.
# Keep the explicit skip request, the in-turn deploy guard, this gate's own parallelism
# knob and the count that bounds this gate's own home; never inherit provider accounts, a real
# instance registry, a job auth token, or the user's runtime paths. The knobs are numbers, not
# runtime state.
while IFS= read -r variable; do
  case "$variable" in
    WASM_AGENT_SKIP_UI_TESTS|WASM_AGENT_IN_TURN|WA_GATE_JOBS|WA_GATE_HOME_KEEP|WA_CHECK_JOBS) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)

# Build/test parallelism is the repository's knob, not whatever cargo happens to do. With it
# unset - the default - every `cargo` below compiles one job per logical core (16 on the machine
# this was measured on), so two concurrent gate runs each claim the whole box and the second one
# only makes the first slower. WA_GATE_JOBS=<n> caps both cargo's build job count and the test
# harness's thread count; an explicit CARGO_BUILD_JOBS or RUST_TEST_THREADS still wins, because a
# request for one variable is more specific than one number for both. The measurement behind this,
# and why the default is still the uncapped one, are in docs/EVOLUTION.md ("Gate parallelism").
if [ -n "${WA_GATE_JOBS:-}" ]; then
  export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$WA_GATE_JOBS}"
  export RUST_TEST_THREADS="${RUST_TEST_THREADS:-$WA_GATE_JOBS}"
fi
# The run says what it ran with, so two gate times can be compared without guessing which
# parallelism produced them.
echo "gate parallelism: cargo jobs=${CARGO_BUILD_JOBS:-cargo default} test threads=${RUST_TEST_THREADS:-harness default} (WA_GATE_JOBS=${WA_GATE_JOBS:-unset})"
# ---- the gate's own temp, bounded -----------------------------------------------------------------
# This home is the whole gate's isolated WASM_AGENT_HOME, 22 MB measured, and until now every run kept
# it: 278 `wa-gate-home-*` directories were measured in this machine's temp root, beside the merge
# lane's 135 clones (the larger half of the same leak, bounded the same way in scripts/merge-lane.mjs).
# A day of gates therefore cost a day of temp, and the disk filled: the retained log of the run that
# died for it is `.wasm-agent/merge-lane-batch14.json.gate.log` - `There is not enough space on the
# disk. (os error 112)` at 1.9 GB free of 477 GB, ten seconds into a comment-only change's gate.
#
# THE POLICY. A passing run removes its home: a pass has nothing to diagnose, and its verdict line,
# exit status, skip count and sha256-pinned log are the record. A failing run keeps its own, because
# that is the state of the run that went red (profile, db, instance registry, whatever a test wrote
# into it) and it is 22 MB, not a gigabyte. A sweep of the family then keeps the newest
# WA_GATE_HOME_KEEP failures (default 1) and deletes the older ones, so a day of gates costs one home
# instead of one per run.
#
# LIVENESS DECIDES WHAT MAY BE PRUNED, NOT AGE, and where the name carries no pid the window is a
# fallback with its arithmetic stated rather than a claim about rollouts. The pid of the run is part of
# the directory name, so a sweep never touches a home whose process is still alive: on a machine running
# more than one gate - the plugin-staging note below is what deleting a live sibling's temp already cost
# this repository - that would turn a passing neighbour into an unattributed red gate. A home whose name
# carries no pid is from before this change: it is pruned only once it is an hour old, and that hour is
# the lane's own gate timeout (`--timeout-seconds`, 3600 s by default) and not comfortably more than it.
# Unlike the clone family, no queue arithmetic enters here: the lane waits for its slot BEFORE this block
# runs, so a home cannot be aged by a wait - but a gate started by hand, or by a lane whose timeout was
# raised, can still be running at that boundary and is then a candidate. Residual limits, named: the
# predicate here is Cygwin `kill -0`, which cannot see a native Windows pid; and a gate killed by a
# signal it does not trap leaves its home behind - the next gate's sweep is what removes it, and that
# sweep bounds the family.
#
# A PASSING RUN'S TRAP IS SILENT, and that is not a style choice: `scripts/merge-lane.mjs` reads this
# gate's LAST line as its verdict (`smoke ok`), so a notice printed after it - even on stderr, which the
# lane streams into the same log - would make the lane read its own pass as `gate_failed`. The failing
# path may speak, because a failing run has no verdict line to protect.
#
# THE KNOBS EXIST TO FALSIFY THE BOUND, not to tune it: WA_GATE_HOME_KEEP=all keeps every home forever
# (exactly the behaviour that filled the disk), WA_GATE_HOME_KEEP=0 keeps nothing (a failure with
# nothing left to diagnose).
GATE_HOME_KEEP="${WA_GATE_HOME_KEEP:-1}"
case "$GATE_HOME_KEEP" in
  all) ;;
  ''|*[!0-9]*) echo "gate home: WA_GATE_HOME_KEEP must be a non-negative whole number or 'all' (got '$GATE_HOME_KEEP')" >&2; exit 4 ;;
esac
GATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/wa-gate-home-$$-XXXXXX")"
if command -v cygpath >/dev/null 2>&1; then
  export WASM_AGENT_HOME="$(cygpath -w "$GATE_HOME")"
else
  export WASM_AGENT_HOME="$GATE_HOME"
fi
export WASM_AGENT_RENDEZVOUS="" WASM_AGENT_RELAY="" WASM_AGENT_MANAGED=0
export WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 WASM_AGENT_LLM_API_KEY=fixture-only
export HTTP_PROXY="" HTTPS_PROXY="" ALL_PROXY="" NO_PROXY=127.0.0.1,localhost,::1
echo "gate isolated home: $WASM_AGENT_HOME (a passing run removes it; a failing run keeps its own, newest $GATE_HOME_KEEP of this family kept: WA_GATE_HOME_KEEP)"

# Runs on every exit path, including the first `exit 1` of a failing section - which is the path that
# used to leave the home behind. It exits with the status it was given, so a bounded gate home can
# never change what the gate says about the tree; that is asserted by
# scripts/test-merge-lane-retention.mjs against a sliced copy of this very block.
gate_home_release() {
  local status=${1:-$?} home="$GATE_HOME" keep="$GATE_HOME_KEEP" root="${TMPDIR:-/tmp}"
  local ranked='' line='' path='' name='' pid='' index=0 own_kept=0 budget=0
  set +e
  # 1. This run's own home. A pass costs nothing; so does a failure when the bound is 0. `own_kept`
  #    is what the family budget below subtracts, because the budget counts this run's own home: it
  #    is the newest by construction, and a budget of 1 spent on somebody else's home keeps two.
  if [ "$keep" = "all" ]; then
    own_kept=1
  elif [ "$status" -eq 0 ] || [ "$keep" = "0" ]; then
    # Silent on purpose (see above); a home that survives this is one whose pid is already dead, so
    # the next sweep removes it.
    rm -rf "$home" 2>/dev/null
  else
    own_kept=1
    printf 'gate isolated home: %s (kept: this run exited %s, WA_GATE_HOME_KEEP=%s)\n' "$home" "$status" "$keep" >&2
  fi
  # 2. The family: the newest `keep` homes survive, and a home whose process is alive is not a
  #    candidate at all. Only a failing run narrates this - a pass has a verdict line to protect.
  if [ "$keep" != "all" ]; then
    budget=$((keep - own_kept))
    [ "$budget" -lt 0 ] && budget=0
    ranked="$(find "$root" -maxdepth 1 -name 'wa-gate-home-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      path="${line#* }"
      [ -d "$path" ] || continue
      [ "$path" = "$home" ] && continue
      name="${path##*/}"
      case "$name" in
        wa-gate-home-[0-9]*-??????)
          pid="${name#wa-gate-home-}"; pid="${pid%%-*}"
          kill -0 "$pid" 2>/dev/null && continue ;;              # a live sibling's home is never a candidate
        wa-gate-home-??????)
          [ -n "$(find "$path" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue ;;   # a pre-lease home
        *) continue ;;
      esac
      index=$((index + 1))
      [ "$index" -le "$budget" ] && continue
      if rm -rf "$path" 2>/dev/null; then
        [ "$status" -ne 0 ] && printf 'gate home: removed %s (only the newest %s home(s) of a run that failed are kept)\n' "$path" "$keep" >&2
      else
        [ "$status" -ne 0 ] && printf 'gate home: could not remove %s; the next sweep will see a dead pid\n' "$path" >&2
      fi
    done <<<"$ranked"
  fi
  exit "$status"
}
gate_exit() {
  local status=$?
  if declare -F gate_fixture_cleanup >/dev/null; then gate_fixture_cleanup; fi
  if declare -F gate_phase_summary >/dev/null; then gate_phase_summary; fi
  gate_home_release "$status"
}
trap gate_exit EXIT
# ---- end of the bounded gate-home block: scripts/test-merge-lane-retention.mjs slices this file at
# the line above and runs these exact bytes with its own body, so the policy is tested where it lives.

# Phase timing: instrumentation, not a redesign. Every phase marker below is a call between two
# existing commands, so no check is added, removed, reordered or skipped; the table is printed into
# this log before the verdict line (which must stay last) and written as JSON. scripts/lib/gate-phases.sh
. scripts/lib/gate-timing.sh
# carries the contract. Until this landed, a 21-minute gate log had no durations in it at all.
. scripts/lib/gate-phases.sh
. scripts/lib/gate-timing.sh
# gate_exit retains phase reporting and the original exit status on failure.
run_proof_fixture() {
  local kind="$1" minimum="$2" status=0 nested_skipped
  shift 2
  local log="${DB:-$GATE_HOME/proof}.$kind-proof.log"
  gate_run "$@" > "$log" 2>&1 || status=$?
  if ! nested_skipped="$(node scripts/lib/proof-verdict.cjs "$kind" "$status" "$minimum" < "$log")"; then
    echo "FAIL: $kind proof; retained output: $log" >&2
    tail -40 "$log" >&2
    exit 1
  fi
  SKIPPED=$((SKIPPED + nested_skipped))
  tail -4 "$log"
}

# BEGIN wave-owner safety proofs (required, not coverage discovery)
run_proof_fixture waveOwner 53 node scripts/test-wave-owner-refusal.mjs
run_proof_fixture waveOwnerMutations 3 node scripts/test-wave-owner-mutations.mjs
run_proof_fixture waveCorners 24 node scripts/test-wave-activity-corners.mjs
run_proof_fixture waveDerived 55 node scripts/test-wave-derived-state.mjs
gate_run node scripts/test-wave-withdrawal.mjs
run_proof_fixture waveActivityFix 62 node scripts/test-wave-activity-fix.mjs
# END wave-owner safety proofs

gate_phase_begin build
ACTUAL_RELEASE_BUILD_LOG="$(git rev-parse --git-path "wa-release-build-${GATE_HOME##*/}.log")"
echo "actual release build retained: $ACTUAL_RELEASE_BUILD_LOG"
gate_run cargo build --release --offline --manifest-path rust/Cargo.toml >"$ACTUAL_RELEASE_BUILD_LOG" 2>&1 \
  || { build_status=$?; cat "$ACTUAL_RELEASE_BUILD_LOG" >&2; exit "$build_status"; }

# BEGIN sentinel-intake required proofs
CARGO_BUILD_JOBS=2 gate_run cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml -- --test-threads=2
if [ "${OS:-}" = "Windows_NT" ]; then
CARGO_BUILD_JOBS=2 gate_run cargo build --offline --manifest-path rust/wa-sentinel/Cargo.toml
SERVICE_PROOF="$(git rev-parse --git-path "service-gate-$(date +%s)-$$")"
gate_run node scripts/test-sentinel-service.cjs "$PWD/rust/wa-sentinel/target/debug/wa-sentinel.exe" "$(cygpath -w "$SERVICE_PROOF/cli")"
gate_run powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$PWD/scripts/test-sentinel-service-installer.ps1")" -Scratch "$(cygpath -w "$SERVICE_PROOF/installer")"
INTAKE_PROOF="$(git rev-parse --git-path "intake-gate-$(date +%s)-$$")"
run_proof_fixture sentinelIntake 10 python scripts/test-sentinel-intake-cli.py --sentinel "$PWD/rust/wa-sentinel/target/debug/wa-sentinel.exe" --evidence "$INTAKE_PROOF/cli"
run_proof_fixture sentinelIntakeMutants 2 python scripts/test-sentinel-intake-mutants.py --repo "$PWD" --evidence "$INTAKE_PROOF/mutants"
else
  echo "SKIP: Windows service CLI/installer proofs (native SCM unavailable)"
  SKIPPED=$((SKIPPED + 1))
  echo "SKIP: Windows Job CLI proof (portable native intake tests above are required)"
  SKIPPED=$((SKIPPED + 1))
fi
# END sentinel-intake required proofs
gate_run node scripts/test-sentinel-service-deploy.cjs
if [ "${OS:-}" = "Windows_NT" ]; then
  gate_run node scripts/test-sentinel-reconcile.cjs "$PWD/rust/wa-sentinel/target/debug/wa-sentinel.exe" "$(cygpath -w "$GATE_HOME/rc")"
else
  echo "SKIP: native Windows reconciliation CLI fixture (1 skipped)"
  SKIPPED=$((SKIPPED + 1))
fi
gate_run node scripts/test-install-isolation.mjs
gate_run node scripts/test-gate-check.mjs
run_proof_fixture producer 16 node scripts/test-producer-admission.mjs
gate_run node scripts/test-full-gate-proof.mjs
gate_run node scripts/test-runtime-install-binding.mjs
gate_run node scripts/test-wave-ship.mjs
gate_run node scripts/test-wave-hot-guards.mjs
gate_run node scripts/test-wave-monitor-budget.mjs
gate_run node scripts/test-parallel-finish.mjs
# The execution and automation contracts have native, model-free adversarial tests.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-operation -p wa-jobs
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host file_search::tests
# The line boundaries `host.http_sse` hands to the subscription wire are half of that route's
# contract: this reader re-framing or dropping a line would mean the Lua parser is tested against a
# stream that never existed. It was written, reported passing by hand, and run by *no* `cargo test`
# line in this file - every filter above names its own module, and `sse_line_tests` was named by
# none, so four tests existed and the gate never executed one of them. The recorded fixtures under
# `tests/fixtures/subscription/` are what it reads, so it belongs here beside the other wa-host
# filters and not in a report.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host sse_line_tests
# The ticker's clock is the twin of `cli_view.duration` on the Lua side: the elapsed time of a
# call that has not finished can only be computed by the host, so both sides pin the same three
# values and a one-sided change fails here rather than on a screen.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host ticker_tests
# The console size is the one number the CLI cannot learn for itself, and the only thing standing
# between a detached console (which reports 0x0, not failure) and a screen wrapped to nothing.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host terminal_tests
# The native editor is the only side that can edit input while Lua is blocked. Its
# parser, history, multiline viewport and submit/clear behavior are not Lua tests.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host terminal_editor::tests
# The graph is a capability the agent navigates its own code with, so its extractor and
# incremental reindex are part of the contract, not a side project.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-graph
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host graph::tests
# Run the serve-level invariants, each a measured regression: routing by session (a wake carries its
# conversation in the body's `thread`, not the auth header) and the UI version tracking content rather
# than mtime (a `cp -f` of identical files must not force every open page to reload).
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host serve::
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host subagents::
# What an operation says about itself when its bound kills it: the measured phases, and never a
# cause it cannot know. A pure function of the operation record, so it is tested as one - the
# sentence it replaced was quoted onward as a diagnosis of a read-only `grep`.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-host deadline_note_tests
gate_run cargo test --release --offline --manifest-path rust/wa-sentinel/Cargo.toml
# The named-instance lifecycle, against two real co-located nodes: separate homes, keys, databases
# and ports; a refused wrong listener; and a stop/restart of one that cannot reach the other. No
# model and no network, so it belongs in the hermetic gate rather than the on-demand guest e2e.
gate_phase_begin instances
CARGO_BUILD_JOBS=2 cargo build --release --offline --manifest-path rust/wa-sentinel/Cargo.toml >/dev/null
gate_run node scripts/test-sentinel-ownership.cjs "rust/wa-sentinel/target/release/wa-sentinel"
gate_run node scripts/test-sentinel-task-launcher.mjs
gate_run node scripts/test-recovery-diagnosis.mjs
if command -v powershell.exe >/dev/null 2>&1; then
  gate_run powershell.exe -NoProfile -NonInteractive -File scripts/test-restore-sentinel-task.ps1
fi
if command -v cygpath >/dev/null 2>&1; then
  SENTINEL_DETACHED_BIN="$(cygpath -w "$(pwd)/rust/wa-sentinel/target/release/wa-sentinel.exe")"
  SENTINEL_DETACHED_EVIDENCE="$(cygpath -w "$GATE_HOME/sentinel-detached")"
  gate_run node scripts/test-sentinel-detached.cjs "$SENTINEL_DETACHED_BIN" "$SENTINEL_DETACHED_EVIDENCE"
fi
INSTANCE_VERDICT="$(mktemp)"
rm -f "$INSTANCE_VERDICT" # The child must produce NEW evidence, never a previous run's verdict.
INSTANCE_STATUS=0
WA_INSTANCE_VERDICT="$INSTANCE_VERDICT" bash scripts/test-node-instances.sh || INSTANCE_STATUS=$?
INSTANCE_SKIPPED=$(node scripts/lib/suite-verdict.cjs "$INSTANCE_VERDICT" test-node-instances "$INSTANCE_STATUS" 62)
SKIPPED=$((SKIPPED + INSTANCE_SKIPPED))
rm -f "$INSTANCE_VERDICT"
gate_phase_begin self-update
BIN=rust/target/release/wa
[ ! -f "$BIN.exe" ] || BIN="$BIN.exe"
# BEGIN native-target recovery required proofs
gate_run cargo test --offline --manifest-path rust/Cargo.toml -p wa-host resources::tests
run_proof_fixture nativeTarget 29 node scripts/test-native-target-resource.cjs "$BIN"
run_proof_fixture resourceClaims 47 node scripts/test-resource-claims.cjs "$BIN"
run_proof_fixture nativeAlias 12 node scripts/test-native-target-alias.cjs "$BIN"
run_proof_fixture nativeRecovery 66 node scripts/test-wave-native-recovery.mjs "$BIN" "$ACTUAL_RELEASE_BUILD_LOG" '--build-command=cargo build --release --offline --manifest-path rust/Cargo.toml'
# END native-target recovery required proofs
# Combined-tree wave fixtures are required when shipped; absence is explicit intermediate coverage.
for wave_spec in 'lifecycle mjs waveLifecycle 40 no' 'retire mjs waveRetire 20 no' 'executor cjs waveExecutor 11 yes' 'proof mjs waveProof 18 no' 'restart mjs waveRestart 9 no' 'public mjs wavePublic 20 yes'; do
  set -- $wave_spec
  wave_fixture="scripts/test-wave-$1.$2"
  if [ ! -f "$wave_fixture" ]; then
    echo "SKIP: wave $1 fixture absent from this intermediate source tree"
    SKIPPED=$((SKIPPED + 1))
  elif [ "$5" = yes ]; then
    run_proof_fixture "$3" "$4" node "$wave_fixture" "$BIN"
  else
    run_proof_fixture "$3" "$4" node "$wave_fixture"
  fi
done
# A turn cannot deploy the process serving that same turn. The marker crosses
# the Rust host's shell boundary; both entry points must refuse before waiting
# for idle or touching an installed binary.
GUARD_HOME="$(mktemp -d)"
mkdir -p "$GUARD_HOME/install"
if WASM_AGENT_IN_TURN=1 WA_INSTALL_DIR="$GUARD_HOME/install" bash scripts/deploy.sh --reason guard >"$GUARD_HOME/deploy.log" 2>&1; then
  echo "FAIL: deploy.sh accepted a running-turn invocation" >&2; exit 1
fi
grep -q 'cannot deploy from a running turn' "$GUARD_HOME/deploy.log"
if WASM_AGENT_IN_TURN=1 bash scripts/upgrade.sh "$BIN" >"$GUARD_HOME/upgrade.log" 2>&1; then
  echo "FAIL: upgrade.sh accepted a running-turn invocation" >&2; exit 1
fi
grep -q 'refused inside a running turn' "$GUARD_HOME/upgrade.log"
# `deploy.sh` now records a machine-readable result beside the install, so the temp home is not empty of
# files after the guard fires; remove the whole tree rather than a fixed list, or the smoke gate aborts
# here and never reaches the tests that matter.
rm -rf "$GUARD_HOME"
echo "self-update turn guard ok"
# The other half of the install gate: it must refuse to replace an install that is ahead of this tree. Its
# own file, because it asserts five cases (ahead, ancestor, no record, no commit=, an unresolvable commit)
# and both directions of the check - a gate that refuses everything is as wrong as one that refuses nothing.
# It stops at or before the build, so it costs about a second.
set +e
gate_run bash scripts/test-deploy-downgrade.sh
GATE_STATUS=$?
set -e
if [ "$GATE_STATUS" = "3" ]; then
  # Exit 3 is "this tree cannot reach the check": a clean tree that is not behind origin/main is required,
  # and the gate asks about the tree first. Counted, not hidden - a skipped check is not a passing check.
  SKIPPED=$((SKIPPED + 1))
elif [ "$GATE_STATUS" != "0" ]; then
  echo "FAIL: the deploy downgrade gate did not pass (exit $GATE_STATUS)" >&2
  exit 1
fi
# And the deploy's two other refusals, from the cloud node's own incident: it must refuse to install
# somewhere the service does not run - the unit ran a ten-day-old install while two other directories
# existed and the process exited 0 into 61,117 restarts - and refuse a port a stray process already
# holds. The fixture runs the real `scripts/deploy.sh` against a fake install, a fake unit and a listener
# of its own, all inside one temp directory: no build is reached (the scratch tree has no `rust/`) and no
# network, no model and no node binary are used. What makes it a check rather than a story is the
# falsification - the same cases are re-run against `scripts/deploy.sh` and `scripts/verify-install.sh`
# pinned by *blob sha* as they were before the check, and there they must proceed, so the file cannot pass
# by the check never firing. That pin is why it can be in the gate at all: its first version compared
# against `origin/main`, so the day the check landed on main the comparison went red on a clean tree and
# would have stayed red. The port is found free at run time rather than fixed, so it cannot collide with
# the two port suites above; the two pinned blobs have to be in this repository's object store, and a
# shallow checkout fails here by name instead of reading as a pass.
set +e
gate_run bash scripts/test-deploy-service-target.sh
SERVICE_TARGET_STATUS=$?
set -e
if [ "$SERVICE_TARGET_STATUS" = "3" ]; then
  # Exit 3 is "this tree cannot reach the check": the fixture needs `node` for the listener that stands in
  # for a stray. Counted, not hidden - a skipped check is not a passing check.
  SKIPPED=$((SKIPPED + 1))
elif [ "$SERVICE_TARGET_STATUS" != "0" ]; then
  echo "FAIL: the deploy service-target fixture did not pass (exit $SERVICE_TARGET_STATUS)" >&2
  exit 1
fi
# The suite must exercise the Lua in the working tree. cargo rebuilds the binary when a
# Lua file changes (they are include_str!-ed), so this is belt as well as braces - but it
# is the difference between testing the tree and testing a build artefact, and it went
# missing in a merge without anyone noticing.
export WASM_AGENT_LUA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
  export WASM_AGENT_LUA_ROOT="$(cygpath -w "$WASM_AGENT_LUA_ROOT")"
fi
# This is a fixture, not the operator's deployment configuration.
export WASM_AGENT_LLM_CONTEXT=128000
gate_phase_begin cli
DB="$(mktemp -u /tmp/wa-smoke-XXXXXX.db)"
# `wa status` reports *the current thread*, so it gets its own database: with the
# shared one, every earlier session in this run sits in the same second and the
# "latest session" assertion would be a coin flip.
SDB="$(mktemp -u /tmp/wa-status-XXXXXX.db)"
# Session recovery works on its own threads: which session is "the current
# thread" decides what `wa status` and `wa resume` report, so sharing the smoke
# database would make the assertions below depend on what ran before them.
RDB="$(mktemp -u /tmp/wa-resume-XXXXXX.db)"
QDB="$(mktemp -u /tmp/wa-resume-q-XXXXXX.db)"
PLUGINS="$(mktemp -d)"
gate_fixture_cleanup() { rm -f "$DB" "$DB"-wal "$DB"-shm "$SDB" "$SDB"-wal "$SDB"-shm "$RDB" "$RDB"-wal "$RDB"-shm "$QDB" "$QDB"-wal "$QDB"-shm "$DB.title" "$DB.title"-wal "$DB.title"-shm "$DB.exec" "$DB.exec"-wal "$DB.exec"-shm; rm -rf "$PLUGINS" "$DB.home"; }

# Fresh retained output + process status + terminal count evidence for every new
# integrated proof. A child that silently exits 0 or drops checks cannot pass.


"$BIN" --db "$DB" init >/dev/null

# A dev-mode node must not write the operator's ledger. The dangerous combination is on-disk Lua,
# the operator's home, and the default database; an explicit --db or any WASM_AGENT_HOME is a
# candidate node. Asserted by the message, not by the exit code, so this cannot pass vacuously -
# and both directions, because a guard that refuses everything is as wrong as one that refuses
# nothing. The refusal runs before memory.setup(), so the first invocation touches no database.
# Simulate an unscoped home, never the real operator home. Otherwise the gate's
# outer WASM_AGENT_HOME makes this negative case vacuous (and a broken guard could
# write to the operator's real ledger). Test --db independently of the home override.
GUARD_ENV=(env -u WASM_AGENT_HOME "HOME=$WASM_AGENT_HOME" "USERPROFILE=$WASM_AGENT_HOME"
  "LOCALAPPDATA=$WASM_AGENT_HOME/LocalAppData" "APPDATA=$WASM_AGENT_HOME/AppData")
guard_out="$("${GUARD_ENV[@]}" "$BIN" status 2>&1 || true)"
case "$guard_out" in
  *"refusing on-disk Lua"*) ;;
  *) echo "FAIL: on-disk Lua against the operator's database must be refused, got:" >&2
     printf '%s\n' "$guard_out" | tail -3 >&2; exit 1 ;;
esac
if "${GUARD_ENV[@]}" "$BIN" --db "$DB" status 2>&1 | grep -q "refusing on-disk Lua"; then
  echo "FAIL: a scratch ledger is a candidate node and must not be refused" >&2; exit 1
fi
mkdir -p "$DB.home"
if WASM_AGENT_HOME="$DB.home" WASM_AGENT_LUA_ROOT="$WASM_AGENT_LUA_ROOT" "$BIN" status >/dev/null 2>&1; then :; else
  echo "FAIL: a candidate home must not be refused" >&2; exit 1
fi
echo "dev home guard ok"
ID="$("$BIN" --db "$DB" remember "smoke fact about the rust lua core")"
"$BIN" --db "$DB" recall smoke | grep -q "smoke fact"
"$BIN" --db "$DB" memories | grep -q "$ID"
"$BIN" --db "$DB" forget "$ID" | grep -q '"forgotten":true'
"$BIN" --db "$DB" memories | grep -q "(empty)"
"$BIN" --db "$DB" stats | grep -q '"memories":0'

# The CLI's own surface. Resolving a merge once dropped an `else` and made
# `wa help` fall through to "unknown command" - valid Lua, so every Lua-level
# test passed while the command was broken.
HELP="$("$BIN" --db "$DB" help)"
case "$HELP" in
  *"unknown command"*) echo "FAIL: wa help falls through to the unknown-command branch" >&2; exit 1 ;;
esac
for entry in chat paths status skills sessions resume; do
  echo "$HELP" | grep -q "$entry" || { echo "FAIL: wa help must list '$entry'" >&2; exit 1; }
done
echo "cli ok"
# The REPL's `/` commands are the window's, and `/new` is the one that was missing: the window could
# start a thread and the CLI could not, and nothing in the repo said so. This drives it the way a
# reader does - typed into the real REPL - because a help line is not evidence that a command is
# handled, and asserts the two halves of the promise: the REPL moved to another session, and the
# session it left is still in the ledger (the ledger is append-only, so "unchanged" is a claim this
# can check). Which commands the two surfaces share is `scripts/test-command-parity.cjs`'s half.
"$BIN" --db "$DB" chat --help | grep -q '^  /new ' \
  || { echo "FAIL: /help must offer /new" >&2; exit 1; }
CLI_CMD_DB="$DB.cli-commands"
CLI_CMD_STATUS=0
CLI_CMD_OUT="$(printf '/new\n/session\n/exit\n' | "$BIN" --db "$CLI_CMD_DB" chat 2>&1 | tr -d '\r')" || CLI_CMD_STATUS=$?
if [ "$CLI_CMD_STATUS" != 0 ]; then
  echo "FAIL: wa chat exited $CLI_CMD_STATUS" >&2; printf '%s\n' "$CLI_CMD_OUT" >&2; exit 1
fi
printf '%s\n' "$CLI_CMD_OUT" | grep -q 'new session' \
  || { echo "FAIL: /new must say which session the REPL moved to" >&2; exit 1; }
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
# The banner's session id is the first id printed; `/session` answers on the line holding the prompt
# the command was typed at, and the first id on such a line is the session the REPL is in now (the
# `/new` notice names the same one). Both searches are for the full id, so a shortened one cannot pass.
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
BEFORE="$(printf '%s\n' "$CLI_CMD_OUT" | grep -oE "$UUID" | head -1)"
AFTER="$(printf '%s\n' "$CLI_CMD_OUT" | grep -E '^wa> ' | grep -oE "$UUID" | head -1)"
if [ -z "$BEFORE" ] || [ -z "$AFTER" ] || [ "$BEFORE" = "$AFTER" ]; then
  echo "FAIL: /new must move /session to a different session (before='$BEFORE' after='$AFTER')" >&2
  printf '%s\n' "$CLI_CMD_OUT" >&2
  exit 1
fi
printf '%s\n' "$CLI_CMD_OUT" | grep -q "$BEFORE" \
  || { echo "FAIL: /new must name the session it left" >&2; exit 1; }
"$BIN" --db "$CLI_CMD_DB" sessions | grep -q "$BEFORE" \
  || { echo "FAIL: /new must leave the session it left in the ledger" >&2; exit 1; }
rm -f "$CLI_CMD_DB"*
echo "cli /new ok"
# Actions that need the user's machine must fail immediately when nothing is
# polling the client bridge, instead of blocking for the call timeout: an agent
# spent rounds on a tool that looked half-working. There is never a client
# attached in this suite, so the failure is deterministic here.
#
# The failure must also say *which* failure it is. It used to say "start the
# desktop client with `wa ui`" for every case, including the one that actually
# happens - a wedged bridge with a perfectly healthy window - which sent the
# reader to fix the wrong thing.
cat > "$DB.client.lua" <<'LUA'
local json = dofile('lua/vendor/json.lua')
local started = host.now()
local raw = host.client('screenshot', '{}')
local elapsed = host.now() - started
local result = json.decode(raw)
assert(result.error == 'client_not_connected', 'expected client_not_connected, got ' .. tostring(result.error))
assert(result.next and #result.next > 10, 'the failure must say what to do')
assert(result.observed and #result.observed > 10, 'the failure must say what was seen, not just what to do')
-- The state fields are read flat, exactly as `status` returns them: an agent
-- follows `bridge.health`, so an error that nests it one level deeper is a trap.
assert(result.bridge and result.bridge.health, 'the bridge state must travel with the failure')
assert(result.connected == false, 'the failure must say whether a client is connected')
assert(not tostring(result.next):lower():find('restart'),
  'a wedged bridge must never be answered with "restart the window": two windows split one bridge')
assert(elapsed < 2, 'must fail fast, took ' .. string.format('%.2f', elapsed) .. 's')
-- `status` is the cheap question, and it is answerable with nothing attached:
-- that is the whole point of it.
local status = json.decode(host.client('status', '{}'))
assert(status.error == 'client_not_connected' and status.bridge and status.observed,
  'status must answer with the state and the diagnosis')
-- A result whose caller gave up is kept, and asking for one that is not kept is
-- an answer rather than a crash.
local late = json.decode(host.client('result', '{"id":"nothing"}'))
assert(late.error == 'result_not_kept' and late.next, 'asking for an unkept result must explain itself')
local link = json.decode(host.client_status())
assert(link.bridge and link.bridge.health ~= nil and link.results_kept ~= nil,
  'client_status must carry bridge/health/results_kept')
print('client fast-fail ok')
LUA
WA_SCRIPT="$DB.client.lua" "$BIN" --db "$DB" | grep "client fast-fail ok"
rm -f "$DB.client.lua"
# The three states a control failure can be in are three different sentences with
# three different remedies, and getting them the same way round is a unit test
# rather than a guess.
gate_run cargo test --release --offline --manifest-path rust/Cargo.toml --bin wa client_diagnosis >/dev/null
echo "client diagnosis ok"
# And what the agent is *told* about the tool, since that is what decides whether
# it reaches for `status` after a failure or guesses at `cdp` again.
cat > "$DB.clientschema.lua" <<'LUA'
local tools = dofile('lua/core/tools.lua')
local spec
for _, tool in ipairs(tools.all('master')) do
  if tool["function"] and tool["function"].name == 'client' then spec = tool["function"] end
end
assert(spec, 'the client tool must be in the schema')
local props = spec.parameters.properties
local actions = {}
for _, action in ipairs(props.action.enum) do actions[action] = true end
for _, action in ipairs({ 'status', 'browser', 'cdp', 'shell', 'screenshot' }) do
  assert(actions[action], 'the client action enum must offer ' .. action)
end
assert(props.timeout_ms and props.timeout_ms.description:find('waits', 1, true)
  and props.timeout_ms.description:find('result', 1, true),
  'the schema must say what a timeout means and how to collect the outcome')
assert(props.target and props.target.description:find('read', 1, true),
  'the browser targets must be named in the schema')
assert(spec.description:find('status', 1, true), 'the description must point at status when a call fails')
assert(not spec.description:find('default 9222', 1, true),
  'a port must not be advertised as the way in: it is discovered and reported')
print('client schema ok')
LUA
WA_SCRIPT="$DB.clientschema.lua" "$BIN" --db "$DB" | grep "client schema ok"
rm -f "$DB.clientschema.lua"
# The shell deadline is invisible to a model that only meets it by being killed. The
# description carries the number and the route for longer work, read from the host
# that enforces the number, so a long command is planned instead of lost.
cat > "$DB.bashschema.lua" <<'LUA'
local tools = dofile('lua/core/tools.lua')
local spec
for _, tool in ipairs(tools.all('master')) do
  if tool["function"] and tool["function"].name == 'bash' then spec = tool["function"] end
end
assert(spec, 'the bash tool must be in the schema')
local deadline = math.floor(host.exec_timeout())
assert(spec.description:find(deadline .. 's', 1, true),
  'the description must state the enforced foreground deadline in seconds, got: ' .. spec.description)
assert(spec.description:find('operation', 1, true) and spec.description:find('timeout_seconds', 1, true),
  'the description must name the operation escape hatch for work that outlives the deadline')
local timeout = spec.parameters.properties.timeout_seconds
assert(timeout and timeout.minimum == 1 and timeout.maximum == 86400,
  'the schema must offer a per-call timeout_seconds in the same 1-86400 range as operation')
local refused = tools.dispatch(nil, 'bash', { command = 'echo hi', timeout_seconds = 0 }, 'master')
assert(refused and refused.error == 'invalid_timeout_seconds',
  'an out-of-range per-call timeout must be refused before it reaches the shell')
print('bash schema ok')
LUA
WA_SCRIPT="$DB.bashschema.lua" "$BIN" --db "$DB" | grep "bash schema ok"
rm -f "$DB.bashschema.lua"
# `/update` decides whether there is anything to install and writes one request for the sentinel -
# it never installs anything itself (the node is the process being replaced). The decision is a pure
# function of the facts, so every case is checkable without a tree, a build or a sentinel; the one
# case that is *not* pure - the path a recorded worktree is handed to the shell in - is checked with
# a real file, because that is where a Windows backslash actually breaks.
cat > "$DB.update.lua" <<'LUA'
local update = dofile('lua/core/update.lua')
local json = dofile('lua/vendor/json.lua')
local function ok(condition, message) if not condition then error(message, 2) end end

-- Nothing to update from at all.
local v = update.verdict({ install = '/install' })
ok(v.ok == false and v.error == 'no_runtime_tree', 'no tree must be a refusal, got ' .. tostring(v.error))
ok(v.message and #v.message > 20, 'every answer must carry a sentence')
ok(v.next and #v.next > 20, 'a refusal must say where to go')

-- A tree with nothing built in it: a deploy *builds*, so this is no longer a reason to refuse.
v = update.verdict({ install = '/i', tree = '/tree', candidate = '/tree/rust/target/release/wa.exe',
  sentinel_present = true, sentinel_running = true })
ok(v.queued == true, 'an unbuilt tree must still queue - the gate builds it, got ' .. tostring(v.status))

-- Built, but the only process that could deploy it is not there.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10, sentinel_present = false })
ok(v.error == 'no_sentinel', 'a missing sentinel must be a refusal, got ' .. tostring(v.error))

-- The same commit still queues. The commit does not describe the install - measured on this
-- machine: `installed.txt` read commit=unknown while the shipped deploy.sh was ten lines behind the
-- tree - so "you already run that" would be a claim about scripts and a sentinel it never looked at.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10,
  sentinel_present = true, sentinel_running = true, tree_commit = 'abc1234', installed_commit = 'abc1234', dirty = 0 })
ok(v.queued == true and v.status == 'queue', 'the same commit must still deploy, got ' .. tostring(v.status))
ok(v.message:find('sentinel and scripts', 1, true),
  'the answer must say what a deploy installs: ' .. tostring(v.message))

-- A different commit queues, and says queued rather than done.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10,
  sentinel_present = true, sentinel_running = true, tree_commit = 'def5678', installed_commit = 'abc1234', dirty = 0 })
ok(v.queued == true and v.commit == 'def5678', 'a newer tree must queue')
ok(v.message:find('queued', 1, true) and v.message:find('not done yet', 1, true),
  'queued must not read as done: ' .. tostring(v.message))

-- Uncommitted work is refused here rather than queued: the gate refuses a dirty tree, so a request
-- would be written only to fail.
v = update.verdict({ install = '/i', tree = '/t', candidate = '/c', candidate_bytes = 10,
  sentinel_present = true, tree_commit = 'abc1234', installed_commit = 'abc1234', dirty = 3 })
ok(v.ok == false and v.error == 'tree_dirty', 'a dirty tree must be refused, got ' .. tostring(v.error))
ok(v.next:find('commit or stash', 1, true), 'the refusal must say what to do: ' .. tostring(v.next))

-- Nothing a watcher would perform, so nothing may be queued. This is the live shape the check
-- answers: a deploy request that sat in the sentinel's box for over an hour while the install stayed
-- on the old commit, reported as queued by a path that never asked whether a watcher was running.
-- The sentinel state is a directory of this test's own, so the machine's real pid file and request box
-- are neither read nor written here.
local sentinel = '/i/' .. update.sentinel_name()
v = update.verdict({ install = '/i', tree = '/t', sentinel = sentinel, sentinel_present = true, sentinel_running = false })
ok(v.ok == false and v.error == 'no_watcher', 'no watcher must be a refusal, got ' .. tostring(v.error))
ok(not v.queued, 'and it must not read as queued')
ok(v.next and v.next:find(sentinel .. ' start', 1, true), 'the refusal must name how to start one: ' .. tostring(v.next))
local windows = update.binary_name() == 'wa.exe'
ok((v.next:find('schtasks /Run /TN wasm-agent-sentinel', 1, true) ~= nil) == windows,
  'only Windows may suggest its registered task: ' .. tostring(v.next))
local stopped = update.verdict({ install = '/i', tree = '/t', sentinel_present = true, sentinel_running = false,
  sentinel_stopped = true, stop_file = '/state/stop' })
ok(stopped.error == 'sentinel_stopped', 'a stop file must be reported as the stop it is, got ' .. tostring(stopped.error))
local duplicate = update.verdict({ install = '/i', tree = '/t', sentinel_present = true, sentinel_running = true,
  pending_deploys = { 'requests/1-9.json' }, sentinel_dir = '/state' })
ok(duplicate.error == 'already_pending', 'a deploy already in the box must not be duplicated, got ' .. tostring(duplicate.error))

-- The path a recorded worktree comes back as is a Windows path with backslashes, which the shell
-- this node runs commands in cannot use: a backslash inside a single-quoted word reaches a native
-- git as an escape. It must be normalised before it is quoted.
local home = host.paths().temp .. '/wa-update-test'
host.write_file(home .. '/runtime-worktree.txt', 'C:\\work\\foundation\r\n')
local tree, source = update.runtime_tree(home)
ok(tree == 'C:/work/foundation', 'the recorded tree must be normalised, got ' .. tostring(tree))
ok(source == 'runtime-worktree.txt', 'the source of the tree must be named, got ' .. tostring(source))

-- The command that will be run, without running it. A reason with a quote in it must not be able to
-- end the quoting early: the sentinel would then read a different verb than the one intended.
local command = update.request_command(
  { sentinel = 'C:/install/wa-sentinel.exe', candidate = 'C:/tree/rust/target/release/wa.exe' },
  "/update: it's mine", { session_id = 'thread-123', prompt = 'verify and continue' })
ok(command:find("'C:/install/wa%-sentinel%.exe' request deploy"), 'the verb must be deploy, spelled out: ' .. command)
ok(not command:find('%-%-binary', 1), 'a deploy names no candidate binary: ' .. command)
ok(not command:find("it's", 1, true) and command:find("it'\\''s", 1, true),
  'a quote in the reason must be escaped, not left to end the word: ' .. command)
ok(command:find("--session 'thread-123' --prompt 'verify and continue'", 1, true),
  'the update must durably continue the session after replacement: ' .. command)

-- The whole path, through `run`, over a real tree and a real (empty) sentinel state: with no watcher
-- running, the refusal happens before anything is written. The fixture is a real file that is not a
-- program, reached through the same seam a node uses (WA_INSTALL_DIR), so nothing here touches the
-- machine's own install or its sentinel; the tree is a directory of this test's own, because the
-- candidate binary is derived from it (a fixture that put it anywhere else tested the wrong thing, and
-- did, once). A sentinel that refuses - and one that cannot be run - is covered by
-- scripts/test-update-watcher.lua, which scripts the sentinel's own answer.
local tree = host.paths().temp .. '/wa-update-tree'
local broken = host.paths().temp .. '/wa-update-broken'
local state = host.paths().temp .. '/wa-update-state'
host.exec("rm -rf '" .. state .. "' && mkdir -p '" .. tree .. "/rust/target/release' '" .. broken .. "' '" .. state .. "'", "")
host.write_file(tree .. '/rust/target/release/' .. update.binary_name(), 'placeholder\n')
host.write_file(broken .. '/runtime-worktree.txt', (tree:gsub('/', '\\')) .. "\r\n")
host.write_file(broken .. '/installed.txt', 'commit=0000000\nsource_commit_hint=0000000\n')
host.write_file(broken .. '/' .. update.sentinel_name(), 'not a program\n')
local report = update.run({ install = broken, reason = 'the update test', skip_source_sync = true, skip_backup = true,
  sentinel_dir = state })
ok(report.ok == false, 'a request no watcher can perform must not report success: ' .. tostring(report.message))
ok(report.error == 'no_watcher', 'the refusal must name the missing watcher, got ' .. tostring(report.error))
ok(not report.queued, 'a refused request must not claim to be queued')
ok(report.message:find('was not queued', 1, true), 'the answer must say the request was not queued')
ok(report.next and report.next:find(broken .. '/' .. update.sentinel_name() .. ' start', 1, true),
  'the refusal must carry the command that starts a watcher: ' .. tostring(report.next))
ok(report.observed and #report.observed > 10, 'the refusal must carry what was seen')

-- The path the new refusal must not have swallowed: a sentinel that exists and does not work is still
-- a refusal - never a crash, and never a claim of success. Reaching it needs a watcher the OS reports
-- alive, and a pid that was only *written* would prove nothing about a probe that asks the OS, so the
-- pid is real on both platforms: on Windows the System process (pid 4), which `tasklist` is asked
-- about first, and elsewhere the shell's own parent - the node running this script, which cannot be
-- gone while it runs.
local watcher = (function()
  local raw = host.exec(update.binary_name() == 'wa.exe'
    and 'MSYS_NO_PATHCONV=1 tasklist /FI "PID eq 4" /NH'
    or 'echo $PPID', "")
  local answer = raw and json.decode(raw) or nil
  return tostring(answer and answer.stdout or ''):match('(%d+)')
end)()
ok(watcher and watcher ~= '', 'the fixture needs a live watcher pid, got ' .. tostring(watcher))
host.write_file(state .. '/sentinel.pid', watcher .. '\n')
report = update.run({ install = broken, reason = 'the update test', skip_source_sync = true,
  sentinel_dir = state })
ok(report.ok == false, 'a sentinel that cannot run must not report success: ' .. tostring(report.message))
ok(report.error == 'no_watcher',
  'a live recycled pid cannot prove watcher ownership, got ' .. tostring(report.error) .. ' (' .. tostring(report.observed) .. ')')
ok(not report.queued, 'a refused request must not claim to be queued')
ok(report.observed and #report.observed > 10, 'the refusal must carry what was seen')
print('update decision ok')
LUA
gate_phase_begin memory-update
WA_SCRIPT="$DB.update.lua" "$BIN" --db "$DB" | grep "update decision ok"
rm -f "$DB.update.lua"
# The check that was missing from those decisions: no watcher running means no request is written, and
# the refusal names the command that starts one. It drives the real command path with a stub host, so it
# needs no node, no install and no request box of this machine's.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-update-watcher.lua" "$BIN" --db "$DB" | grep "update watcher decision ok"
# The same decisions through the route, on a node whose install dir is a fixture. Its sentinel is a
# stub: a live check that dropped a request into the operator's real request box could install a
# placeholder over the node that is running. It also asserts that it did not.
WA_BIN="$BIN" bash scripts/test-update.sh 8874 | grep "the real sentinel's request box is untouched"
# The idle wait before an upgrade is bounded by *lack of progress*, not wall time. A legitimate
# 40-minute turn must not make every queued upgrade wait, fail, and retry while the node stays busy.
gate_run bash scripts/test-upgrade-idle.sh | grep 'upgrade idle-wait ok'
# The ledger ingest path, on a scratch database. An observer (WhatsApp's own store, a mail sync, a
# bot) is exactly the caller that has a message with no reply target and sometimes no send time, and
# that caller used to crash inside the encoder: a nil in the SQL parameter list makes the JSON array
# sparse, and the encoder refuses holes outright rather than writing a NULL. The columns have a
# defined shape now; this is what keeps them that way.
cat > "$DB.ledger.lua" <<'LUA'
local memory = dofile('lua/core/memory.lua')
memory.setup()
memory.record_message({ conversation_id = 'c1', message_id = 'm1', body = 'hello' })
memory.record_message({ conversation_id = 'c1', message_id = 'm1', body = 'hello' })
memory.record_message({ conversation_id = 'c1', message_id = 'm1', body = 'hello again' })
memory.record_conversation({ id = 'c2', title = 'no messages yet', kind = 'direct' })
local rows = memory.conversation('c1', 10)
assert(#rows == 1, 'one message must be one row, got ' .. #rows)
assert(rows[1].body == 'hello again', 'a changed body must update in place, got ' .. tostring(rows[1].body))
assert(rows[1].sent_at and rows[1].sent_at > 0, 'an unknown send time must take a defined shape')
assert(rows[1].reply_to == '', 'a missing reply target must not be a hole in the parameters')
local conversations = memory.conversations(50)
local titles = {}
for _, row in ipairs(conversations) do titles[row.id] = row.title end
assert(titles['c2'] == 'no messages yet', 'a conversation with no messages must still be known')
memory.meta_set('test_cursor', 42)
assert(tonumber(memory.meta_get('test_cursor')) == 42, 'a cursor must round-trip through meta')
local hits = memory.search_ledger('again', nil, 5)
assert(#hits >= 1 and hits[1].conversation_id == 'c1', 'the ledger must be findable by its words')
print('ledger ingest ok')
LUA
WA_SCRIPT="$DB.ledger.lua" "$BIN" --db "$DB.ledger" | grep "ledger ingest ok"
rm -f "$DB.ledger.lua"
# Context budget is per model (provider.budget), and it is NOT the same thing as
# provider.limits, which fetches the account's rate limits for the UI. Confusing
# the two silently disabled compaction once: the window came back nil, so
# maybe_compact returned early and nothing ever compacted.
cat > "$DB.budget.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local windowlib = dofile("lua/core/model_window.lua")
local fallback = provider.budget("some-unknown-model")
assert(fallback.context == 128000, "the env window is the fallback, got " .. tostring(fallback.context))
assert(fallback.source == "env-WASM_AGENT_LLM_CONTEXT", "an unknown model must say the env was used, got " .. tostring(fallback.source))
local per_model = provider.budget("kimi-k2.6")
assert(per_model.context == 262144, "a per-model window must win, got " .. tostring(per_model.context))
assert(per_model.reserve == 32768, "a per-model reserve must win")
assert(provider.limits and provider.limits ~= provider.budget, "limits and budget are different things")

-- The window belongs to the model, not to the process. WASM_AGENT_LLM_CONTEXT is 128000
-- here, and deepseek-v4.1-flash has a 1000000-token window; the model's own number must
-- win, or compaction fires ~10x too early and nothing reports it because "compacted" is
-- not an error.
local deep = provider.budget("deepseek-v4.1-flash")
assert(deep.context == 1000000, "a known model keeps its own window, got " .. tostring(deep.context))
-- The source is now specific: pi's local store, the fetched catalogue, the shipped table
-- or the operator's override. Asserting the property (a real window, and a named source)
-- rather than one string keeps this true whichever source answers on the day.
assert(deep.context > 900000, "a known model must get its own window, got " .. tostring(deep.context))
assert(type(deep.source) == "string" and deep.source ~= "" and deep.source ~= "unknown",
  "and must say where the number came from, got " .. tostring(deep.source))
-- The trigger must scale with the window and keep real headroom below it. A large window
-- reserves proportionally (ten percent), because the catalogue's window is a *claim* and the
-- provider's real ceiling can sit below it - deepseek-v4.1-flash publishes 1,000,000 and
-- rejects near 950,000, so pi's fixed 16384 put the trigger (983,616) above the wall and
-- compaction never fired. A small window keeps the fixed reserve, which already exceeds ten
-- percent of it. Either way the trigger is near the window, not the old global's 96k.
assert(deep.context - deep.reserve > 850000, "a 1M window must not compact at 96k, trigger at " .. tostring(deep.context - deep.reserve))
local small = windowlib.policy(20000)
assert(small < 20000, "a small window must still reserve proportionally, got " .. tostring(small))
print("budget ok")
LUA
WASM_AGENT_MODEL_LIMITS='{"kimi-k2.6":{"context":262144,"reserve":32768}}' WA_SCRIPT="$DB.budget.lua" "$BIN" --db "$DB" | grep "budget ok"
rm -f "$DB.budget.lua"

# The request path must not fetch the catalogue. A scratch home has no cache and the catalogue URL
# cannot be reached, so a fetch would wait for the connect timeout - which is what used to happen:
# the first /models after a fresh install blocked the interpreter for as long as a 4.7MB download
# takes, and everything behind it queued, while /health kept answering as if all was well. A guest
# node with a fresh home is exactly that shape, which is where this was found. Immediate is the
# assertion; the value is not, because an unconfigured node legitimately knows nothing yet.
cat > "$DB.cold.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local started = host.now()
local answer = provider.budget("a-model-nobody-publishes")
local elapsed = host.now() - started
assert(elapsed < 2, "budget must not fetch the catalogue on the request path: took " .. elapsed .. "s")
assert(type(answer) == "table" and type(answer.source) == "string" and answer.source ~= "",
  "and it must still say where the answer came from")
print("cold budget ok")
LUA
WASM_AGENT_HOME="$DB.home" WASM_AGENT_MODELS_CATALOGUE='http://10.255.255.1/api.json' \
  WASM_AGENT_PI_MODELS_STORE="$DB.home/none.json" \
  WA_SCRIPT="$DB.cold.lua" "$BIN" --db "$DB" | grep "cold budget ok"
rm -f "$DB.cold.lua"
rm -f "$DB.budget.lua"

# What a provider's edge is told about the caller, and which conversation this is. OpenCode Go
# documents the requirement - "Send a stable session ID in x-opencode-session for each conversation
# so we can optimize routing and prompt caching" - and this node sent the constant "wasm-agent" for
# every conversation, so every conversation shared one cache shard. The assertion is the property,
# not a string: two conversations get different ids, each equal to its own, the id does not change
# between rounds, and a request that is not a conversation carries none. The catalogue is asserted
# too, so adding a provider forces a decision about its headers instead of silently defaulting.
# The base URL env vars are cleared because this asserts the *shipped* catalogue, not the shell's.
cat > "$DB.headers.lua" <<'LUA'
local provider = dofile("lua/core/provider.lua")
local json = dofile("lua/vendor/json.lua")

local gaps = provider.attribution_gaps()
assert(#gaps == 0, "no attribution rule for: " .. table.concat(gaps, ", ") ..
  " - decide what that host needs in ATTRIBUTION (lua/core/provider.lua)")

local opencode
for _, profile in ipairs(provider.providers()) do
  if profile.id == "opencode-go" then opencode = profile end
end
assert(opencode, "the opencode-go profile must exist")
local rule = provider.attribution_rule(opencode)
assert(rule and rule.session == "x-opencode-session",
  "opencode-go must route a conversation by x-opencode-session")

-- Drive the real request path with a stubbed transport and keep what it sent. Both
-- transports: the turn streams, the summariser does not, and the header must be on both.
local sent = {}
local real_http, real_stream = host.http, host.http_stream
host.http = function(_, _, headers)
  sent[#sent + 1] = json.decode(headers)
  return json.encode({ status = 200, body = json.encode({
    id = "fixture", model = "fixture",
    choices = { { message = { content = "ok" }, finish_reason = "stop" } },
    usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 },
  }) })
end
host.http_stream = function(_, _, headers)
  sent[#sent + 1] = json.decode(headers)
  return json.encode({ status = 200, content = "ok", finish_reason = "stop",
    stream_complete = true, tool_calls = {},
    usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 } })
end
local function ask(session_id, stream)
  return provider.complete_with("deepseek-v4.1-flash",
    { { role = "system", content = "s" }, { role = "user", content = "u" } },
    nil, stream, { session_id = session_id, round = 1 })
end
local first = ask("conversation-one", false)
ask("conversation-one", true)
ask("conversation-two", false)
provider.list_models("opencode-go")
host.http, host.http_stream = real_http, real_stream

assert(#sent == 4, "expected four captured requests, got " .. #sent)
local function session_header(i) return sent[i]["x-opencode-session"] end
assert(session_header(1) == "conversation-one",
  "the header must carry the conversation's own id, got " .. tostring(session_header(1)))
assert(session_header(1) == session_header(2), "the id must not change between rounds")
assert(session_header(1) ~= session_header(3), "two conversations must not share one routing id")
assert(session_header(3) == "conversation-two", "and each must carry its own id")
assert(session_header(4) == nil, "a model listing is not a conversation and must claim no id")
assert(session_header(1) ~= "wasm-agent", "the constant that caused this must not come back")

-- The routing used is recorded with the request, so a miss in the ledger can be read
-- against the instruction that produced it instead of being argued about later.
local meta = first.request_meta and first.request_meta.attribution
assert(meta, "the request must record its attribution")
assert(meta.host == "opencode.ai", "and the host it matched, got " .. tostring(meta.host))
assert(meta.session_header == "x-opencode-session", "and the header it applied")
assert(meta.session_id_present == true, "and whether the conversation id was sent")
print("provider headers ok")
LUA
env -u WASM_AGENT_LLM_BASE_URL -u WASM_AGENT_OPENAI_BASE_URL -u OPENAI_BASE_URL \
  WASM_AGENT_LLM_API_KEY=fixture-provider-headers \
  WA_SCRIPT="$DB.headers.lua" "$BIN" --db "$DB" | grep "provider headers ok"
rm -f "$DB.headers.lua"
# `wa status` must report whether the toolchains its tools need resolve - a
# service has no login PATH, which is how a remote build failed with
# "cargo: not found" while nothing else said a word.
cat > "$DB.tools.lua" <<'LUA'
local status = dofile("lua/core/status.lua")
local line = status.tools()
assert(line:find("git=", 1, true), "the tools line must report git: " .. line)
assert(line:find("cargo=", 1, true), "the tools line must report cargo: " .. line)
local lines = status.lines()
local found = false
for _, text in ipairs(lines) do if text:find("tools", 1, true) then found = true end end
assert(found, "status must print the tools line")
print("tools ok")
LUA
WA_SCRIPT="$DB.tools.lua" "$BIN" --db "$DB" | grep "tools ok"
rm -f "$DB.tools.lua"
# The shell the tools run in. The model speaks POSIX, so a cmd shell on Windows
# made `ls`, `pwd`, `tail` and `grep` fail with "is not recognized" - pi refuses
# to start without bash for exactly this reason, and this asserts ours found one.
cat > "$DB.shell.lua" <<'LUA'
local platform = dofile("lua/core/platform.lua")
local shell = platform.shell()
assert(shell:find("bash", 1, true) or shell:find("sh ", 1, true),
  "tools must run in a POSIX shell, got: " .. shell)
local raw = host.exec('echo "$0"', "")
local decoded = dofile("lua/vendor/json.lua").decode(raw)
assert(decoded and decoded.code == 0, "echo must succeed in the tool shell")
local name = tostring(decoded.stdout or ""):gsub("%s+$", "")
assert(name:find("bash", 1, true) or name:find("sh", 1, true),
  "$0 should name a POSIX shell, got: " .. name)
-- The commands the model reaches for by habit, which cmd cannot run.
for _, command in ipairs({ "pwd", "ls -a . | head -3", "echo hi | cat" }) do
  local result = dofile("lua/vendor/json.lua").decode(host.exec(command, ""))
  assert(result and result.code == 0, command .. " failed: " .. tostring(result and result.stderr))
end
print("posix shell ok")
LUA
WA_SCRIPT="$DB.shell.lua" "$BIN" --db "$DB" | grep "posix shell ok"
rm -f "$DB.shell.lua"
# Tool results are stored whole and budgeted only for the context, per tool. The
# old 600-character write-time cap made a 20 KB read a keyhole for every later
# turn - the reason 'read then edit' kept missing - and dropped a command's error
# with the tail of its output. pi keeps the tail and points at the full text.
cat > "$DB.evidence.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()
local sid = memory.start_session("", "evidence", { user_id = "master", node_id = "", title = "evidence" })
local big = string.rep("0123456789", 7000)
memory.append_turn(sid, { role = "user", content = "read it" })
-- A tool result whose call is not declared is dropped by the exchange repair,
-- correctly: the assistant message that asked for it has to be here too.
memory.append_turn(sid, { role = "assistant", content = "", tool_calls = {
  { id = "c1", type = "function", ["function"] = { name = "read", arguments = "{}" } },
  { id = "c2", type = "function", ["function"] = { name = "bash", arguments = "{}" } },
} })
memory.append_turn(sid, { role = "tool", tool_call_id = "c1", tool_name = "read", content = big })
memory.append_turn(sid, { role = "tool", tool_call_id = "c2", tool_name = "bash",
  content = string.rep("noise ", 2000) .. "FATAL: the error is at the end" })
local stored_read
for _, row in ipairs(memory.session_messages(sid, { limit = 10 })) do
  if row.tool_name == "read" then stored_read = row end
end
assert(stored_read, "the read result must be in the transcript")
assert(#stored_read.content > 20000, "the transcript must keep the whole result, got " .. #stored_read.content)
assert(stored_read.content == big, "and keep it verbatim")
local bot = agentlib.new(sid, function() end, "master", "master", "")
local read_view, bash_view
for _, message in ipairs(bot:build_context()) do
  if message.role == "tool" and message.name == "read" then read_view = message.content end
  if message.role == "tool" and message.name == "bash" then bash_view = message.content end
end
assert(#read_view > 600, "the read budget must be far larger than the old 600, got " .. #read_view)
-- The stored row keeps the whole result; only the *context* view is bounded, and an oversized
-- view keeps the head and points at the artifact that holds the rest. `big` is deliberately
-- larger than any budget the projector may be configured with, so this exercises the artifact
-- path whether the budget is at its 50 KiB default or moved by WASM_AGENT_TOOL_OUTPUT_BYTES.
assert(read_view:find(big:sub(1, 20), 1, true), "read keeps the head, which identifies the file")
assert(read_view:find("full_result", 1, true), "an oversized view must point at its artifact")
assert(bash_view:find("FATAL", 1, true), "bash keeps the tail, because the error lives there")
print("tool evidence ok")
LUA
gate_phase_begin tools
WA_SCRIPT="$DB.evidence.lua" "$BIN" --db "$DB" | grep "tool evidence ok"
rm -f "$DB.evidence.lua"
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-subscription-pending-output.lua" "$BIN" --db "$DB.pending-output" | grep 'subscription pending output ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-worker-integrate-refusals.lua" "$BIN" --db "$DB.integration-refusals" | grep 'worker integrate refusals ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-orchestration-mode.lua" "$BIN" --db "$DB.orchestration-mode" | grep 'orchestration mode ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-observability.lua" "$BIN" --db "$DB.observability" | grep 'observability ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-run-counts.lua" "$BIN" --db "$DB.run-counts" | grep 'run counts ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-context-growth.lua" "$BIN" --db "$DB.context-growth" | grep 'context growth ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-telemetry-incremental.lua" "$BIN" --db "$DB.telemetry-incremental" | grep 'telemetry incremental ok'
# The prompt index is an authored cue, not a slice of the schema description. Without this,
# the same text is sent twice and nothing in the suite notices when the slicing returns.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-tool-cues.lua" "$BIN" --db "$DB.tool-cues" | grep 'tool cues ok'
# Candidate batching is opt-in; exact evidence/order and response-group telemetry stay visible.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-batching-guidance.lua" "$BIN" --db "$DB.batching-guidance" | grep 'batching guidance ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-retry-context.lua" "$BIN" --db "$DB.retry-context" | grep 'retry context ok'
# A session can own a checkout so parallel sessions on one node do not overwrite each other. The
# default is the contract: a session with no worktree must resolve relative paths exactly as before,
# or this feature would silently relocate every existing session's files.
HISTORY_BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
HISTORY_EVIDENCE="$GATE_HOME/history-search"
if command -v cygpath >/dev/null 2>&1; then
  HISTORY_BIN="$(cygpath -w "$HISTORY_BIN")"
  HISTORY_EVIDENCE="$(cygpath -w "$HISTORY_EVIDENCE")"
fi
gate_run node scripts/test-history-search.cjs "$HISTORY_BIN" "$HISTORY_EVIDENCE"
HOOK_EVIDENCE="$GATE_HOME/hook-events"
if command -v cygpath >/dev/null 2>&1; then HOOK_EVIDENCE="$(cygpath -w "$HOOK_EVIDENCE")"; fi
gate_run node scripts/test-hook-events.cjs "$HISTORY_BIN" "$HOOK_EVIDENCE"
FINAL_EVALUATION="$GATE_HOME/before-final-evaluation"
if command -v cygpath >/dev/null 2>&1; then FINAL_EVALUATION="$(cygpath -w "$FINAL_EVALUATION")"; fi
gate_run node scripts/evaluate-before-final.cjs "$HISTORY_BIN" "$FINAL_EVALUATION"
IMPACT_EVIDENCE="$GATE_HOME/graph-impact-paging"
if command -v cygpath >/dev/null 2>&1; then IMPACT_EVIDENCE="$(cygpath -w "$IMPACT_EVIDENCE")"; fi
gate_run node scripts/test-graph-impact-paging.cjs "$HISTORY_BIN" "$IMPACT_EVIDENCE"
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-session-owner.lua" "$BIN" --db "$DB.session-owner" | grep 'session owner ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-session-worktree.lua" "$BIN" --db "$DB.session-worktree" | grep 'session worktree ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-session-fork.lua" "$BIN" --db "$DB.session-fork" | grep 'session fork ok'
gate_run node scripts/test-session-workspaces.cjs "$BIN"
gate_run node scripts/test-workspace-root-recovery.cjs "$BIN"
# A placed child arrives at a node that never saw its parent, so the source it forks from is the tree
# *that* node runs from - and a node with no usable checkout of its own must refuse by name rather
# than leave a session shell behind. Two disposable checkouts, no model.
gate_run node scripts/test-placed-child-workspace.cjs "$BIN"
gate_run node scripts/test-run-recovery.cjs "$BIN"
if [ -f scripts/test-selection-state.cjs ]; then
  run_proof_fixture selection 9 node scripts/test-selection-state.cjs "$BIN"
else
  echo "selection state proof SKIPPED - primary selection fixture absent from this producer tree"
  SKIPPED=$((SKIPPED + 1))
fi
gate_run node scripts/test-resource-claims.cjs "$BIN"
# The tool-choice experiment's verifier must reject a plausible-looking wrong answer, and
# its treatment must reach the child prompt the rig runs. Both are what make the arm's
# result mean anything, so they are tested without a model and before any paid run.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-experiment-verify.lua" "$BIN" --db "$DB.experiment-verify" | grep 'experiment verify ok'
# The paid edit-workflow experiment is never run by the gate, but its coordinator and
# independent verifier must at least remain executable JavaScript. Behavioral proof uses
# --provider mock explicitly; real inference requires --confirm-paid yes.
node --check "$WASM_AGENT_LUA_ROOT/scripts/experiment-edit-workflow.cjs"
node --check "$WASM_AGENT_LUA_ROOT/scripts/lib/experiment-edit-verify.cjs"
# The efficiency report is deterministic and spends no model call. It must price the
# provider's own cache categories, name a prefix break, and keep an unmeasured call
# unmeasured - the fields a reader would otherwise trust to be right.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-efficiency-report.lua" "$BIN" --db "$DB.efficiency-report" | grep 'efficiency report ok'
# A provider 400 on a too-large request must compact and retry once. Without it, one
# oversized turn makes every later turn of the session fail and the thread never answers.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-overflow-recovery.lua" "$BIN" --db "$DB.overflow" | grep 'overflow recovery ok'
# A provider edge can accept a model request and then send no response headers. Retrying is safe for
# tool effects only before a response exists, is bounded to one attempt, and remains operator-disableable
# because an upstream inference may still have been billed even though its response was lost.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-provider-timeout-recovery.lua" "$BIN" --db "$DB.provider-timeout" | grep 'provider timeout recovery ok'
# A route must refuse a model it cannot serve before the first provider request - and only that.
# A child with `gpt-6-luna` on the opencode-go route failed in 0.67s with zero tool calls on the
# edge's `Model does not support this protocol`, and 26 child runs of `deepseek-v4.1-flash` died
# on Pi's catalogue. The first version of this check refused five ids the subscription route
# serves, by deciding from a picker list, so this test ships a catalogue fixture and asserts the
# floor as well: an id the catalogue never mentions stays allowed. No network: HTTP is a counter.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-model-route-servability.lua" "$BIN" --db "$DB.model-route" | grep 'model route servability ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-graph-tool.lua" "$BIN" --db "$DB.graph-tool" | grep 'graph tool ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-graph-freshness.lua" "$BIN" --db "$DB.graph-freshness" | grep 'graph freshness ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-graph-workspace.lua" "$BIN" --db "$DB.graph-workspace" | grep 'graph workspace ok'
# Offline accounting must run even when UI tests are explicitly skipped.
gate_run node scripts/test-token-audit.cjs
WA_BIN="$BIN" node scripts/test-efficiency.cjs
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-patch-audit.lua" "$BIN" --db "$DB.patch-audit" | grep 'patch audit ok'
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-patch-audit-agent.lua" "$BIN" --db "$DB.patch-audit-agent" | grep 'patch audit agent ok'
# A module is one directory under `modules/`, so the route has to list what is on disk and a node
# with no modules has to be a normal state rather than an error. The harness pins that behaviour -
# off, on, granted, absent, path escapes, 404s - and the removal proof next to it deletes the
# directory and asserts the claim the design exists for: no file outside `modules/<id>/` names the
# module, before or after the deletion, so removing it needs no edit anywhere else.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-modules.lua" \
  WASM_AGENT_MODULES_DIR="$WASM_AGENT_LUA_ROOT/modules" "$BIN" --db "$DB.modules" | grep 'module route ok'
WA_BIN="$BIN" bash scripts/test-modules-removal.sh
# The same route over real HTTP, against scratch nodes. The Lua harness above pins the route's
# behaviour *inside* the interpreter; this is the only check that would notice the route not being
# registered or loaded at all, which is a 500/404 with every other check green.
WA_BIN="$BIN" bash scripts/test-modules-route.sh
# Real projector, isolated home, exact artifact recovery. No paid model or ignored A/B switch.
WA_BIN="$BIN" bash scripts/bench-tool-budget.sh
WA_BIN="$BIN" bash scripts/bench-tool-tail.sh
# Which conversation a turn lands in. The name a client sends is the only thing that
# lets a window start a thread or return to one: before this, `agent_for` always passed
# nil, so every turn from every window landed in the newest open session and that one
# thread grew without end. The *refusal* is asserted here too - the name is obeyed now,
# so a guest naming a master's thread must be refused rather than quietly served it.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-thread-selection.lua" "$BIN" --db "$DB.thread" | grep 'thread selection ok'
# Role gating: a guest must never see master tools, and a session must resolve
# to its own user. A regression here silently runs guests as master, which is
# exactly what happened when the session header stopped reaching dispatch.
cat > "$DB.gating.lua" <<'LUA'
local users = dofile("lua/core/users.lua")
local tools = dofile("lua/core/tools.lua")
local guest, master = tools.all("guest"), tools.all("master")
local seen = {}
for _, tool in ipairs(guest) do seen[tool["function"].name] = true end
for _, forbidden in ipairs({
  "bash", "write", "edit", "client", "shell", "remote",
  "spell_save", "session_debug", "session_fixture", "forget",
}) do
  assert(not seen[forbidden], "guest must not see " .. forbidden)
end
assert(#guest > 0 and #guest < #master, "guest gating looks wrong")
local session, user = users.login("guest")
assert(user and user.role == "guest", "login must return the guest role")
assert(users.current(session).id == "guest", "a valid session must resolve to its own user")

-- Role-scoped instructions. A guest must be given its own file and must never
-- fall back to the operator's: the operator file names internal paths and the
-- deploy shape, and a guest can ask the model to repeat its context.
local agent = dofile("lua/core/agent.lua")
local operator, operator_path = agent.agents_md("master")
local guest_md, guest_path = agent.agents_md("guest")
assert(operator and operator_path:match("AGENTS%.md$"), "master must read AGENTS.md")
assert(guest_md and guest_path:match("AGENTS%.guest%.md$"), "guest must read AGENTS.guest.md")
assert(guest_md ~= operator, "guest must not receive the operator instructions")
for _, leak in ipairs({ "openclaw", "git@github", "WORKSPACE", "cargo" }) do
  assert(not guest_md:lower():find(leak:lower(), 1, true),
    "guest instructions must not mention " .. leak)
end
print("gating ok")
LUA
WA_SCRIPT="$DB.gating.lua" "$BIN" --db "$DB" | grep "gating ok"
rm -f "$DB.gating.lua"
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-model-configuration-preview.lua" "$BIN" --db "$DB.preview" | grep 'model request preview ok'

# Every embedded Lua module must at least compile. Without this a typo in a
# file the test does not exercise (the chat REPL, a spell helper) ships and only
# fails at runtime in front of a user.
cat > "$DB.syntax.lua" <<'LUA'
local bad = 0
for path, source in pairs(EMBEDDED) do
  -- EMBEDDED also carries the SQL schema; only Lua can be compiled.
  if path:sub(-4) == ".lua" then
    local chunk, err = load(source, "@" .. path)
    if not chunk then
      bad = bad + 1
      print("  " .. path .. ": " .. tostring(err))
    end
  end
end
assert(bad == 0, bad .. " lua module(s) failed to compile")
print("lua syntax ok")
LUA
WA_SCRIPT="$DB.syntax.lua" "$BIN" --db "$DB" | grep "lua syntax ok"
rm -f "$DB.syntax.lua"

# A turn killed between recording its tool call and its result would otherwise
# make every later turn in that session fail with a provider 400 - a bricked
# thread. Build such a transcript on purpose and assert the context is repaired.
cat > "$DB.repair.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local agentlib = dofile("lua/core/agent.lua")
memory.setup()
local sid = memory.start_session("test", "repair", { user_id = "master", node_id = "", title = "repair" })
local call = { id = "call_1", type = "function", ["function"] = { name = "bash", arguments = "{}" } }
memory.append_turn(sid, { role = "user", content = "do it" })
memory.append_turn(sid, { role = "assistant", content = "", tool_calls = { call } })
-- no tool result follows: the turn died here
memory.append_turn(sid, { role = "user", content = "are you there?" })

local bot = agentlib.new(sid, function() end, "master", "master", "")
local messages = bot:build_context()
local calls, orphans = 0, 0
for _, m in ipairs(messages) do
  if m.role == "assistant" and m.tool_calls then calls = calls + 1 end
  if m.role == "tool" then orphans = orphans + 1 end
end
assert(calls == 0, "an unanswered tool call must not be sent (found " .. calls .. ")")
assert(orphans == 0, "an orphan tool result must not be sent (found " .. orphans .. ")")
assert(bot.repaired and bot.repaired > 0, "the repair must be recorded, not silent")

-- Positive control: a *complete* exchange must survive intact. Without this the
-- assertions above would also pass if the builder simply dropped every call.
local sid2 = memory.start_session("test", "repair", { user_id = "master", node_id = "", title = "repair" })
local call2 = { id = "call_2", type = "function", ["function"] = { name = "bash", arguments = "{}" } }
memory.append_turn(sid2, { role = "user", content = "do it" })
memory.append_turn(sid2, { role = "assistant", content = "", tool_calls = { call2 } })
memory.append_turn(sid2, { role = "tool", content = '{"stdout":"hi"}', tool_call_id = "call_2", tool_name = "bash" })
memory.append_turn(sid2, { role = "assistant", content = "done" })
local good = agentlib.new(sid2, function() end, "master", "master", "")
local kept_calls, kept_results = 0, 0
for _, m in ipairs(good:build_context()) do
  if m.role == "assistant" and m.tool_calls then kept_calls = kept_calls + 1 end
  if m.role == "tool" then kept_results = kept_results + 1 end
end
assert(kept_calls == 1, "a complete exchange must keep its call (found " .. kept_calls .. ")")
assert(kept_results == 1, "a complete exchange must keep its result (found " .. kept_results .. ")")
assert(not good.repaired, "a complete exchange must not be reported as repaired")
print("repair ok")
LUA
WA_SCRIPT="$DB.repair.lua" "$BIN" --db "$DB" | grep "repair ok"
rm -f "$DB.repair.lua"

# The transcript is ordered by arrival; the provider demands that a tool result follow its
# call immediately. A session whose stored rows were out of order answered every new turn
# with a 400 - "An assistant message with 'tool_calls' must be followed by tool messages
# responding to each 'tool_call_id'" - while the running turn's own rounds kept working,
# because only the round-1 rebuild sends the stored order. Each shape from that incident is
# in the file, with a healthy transcript as the control.
WA_SCRIPT=scripts/test-tool-adjacency.lua "$BIN" --db "$DB" | grep "tool adjacency ok"

# Secret redaction is a security boundary, so it gets a unit test with fake
# secrets: a value that survives redaction must fail the build, not reach a log.
cat > "$DB.redact.lua" <<'LUA'
local redact = dofile("lua/core/redact.lua")
local fake = "sk-FAKEtest1234567890abcdef"
local cases = {
  "OPENAI_API_KEY=" .. fake,
  "ANTHROPIC_API_KEY: " .. fake,
  "OPENROUTER_API_KEY='" .. fake .. "'",
  '{"opencode-go":{"type":"api_key","key":"' .. fake .. '"}}',
  "Authorization: Bearer " .. fake,
  "curl -H 'Authorization: Bearer " .. fake .. "' https://example.invalid",
  "WASM_AGENT_LLM_API_KEY=" .. fake .. " GITHUB_TOKEN=" .. fake,
  "ghp_FAKEgithubtoken1234567890",
  "nothing secret here",
}
for _, case in ipairs(cases) do
  local out = redact.text(case)
  assert(not out:find(fake, 1, true), "redaction leaked a secret: " .. out)
end
-- Masking must stay useful: which key, not what key. Plain find, not a
-- pattern: in Lua patterns '-' after a letter is a quantifier, so 'sk-%.%.%.'
-- silently never matches.
local masked = redact.text("OPENAI_API_KEY=" .. fake)
assert(masked:find("sk-...", 1, true) ~= nil, "expected a sk-...xxxx mask, got " .. masked)
assert(masked:find(fake:sub(-4), 1, true) ~= nil, "the mask should keep the last four")
-- Idempotent: redacting twice changes nothing.
assert(redact.text(masked) == masked, "redaction must be stable")
print("redact ok")
LUA
WA_SCRIPT="$DB.redact.lua" "$BIN" --db "$DB" | grep "redact ok"
rm -f "$DB.redact.lua"
# The node's own secret must not reach the transcript through a tool result. Measured on the
# live ledger: a bash call dumped the config file and its API key was stored and journalled.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-redact-secrets.lua" "$BIN" --db "$DB.redact-secrets" | grep 'redact secrets ok'

# Session selection: a new thread is the default, --continue finds the latest,
# --session must reject an unknown id instead of silently starting a new thread.
cat > "$DB.sessions.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
memory.setup()
local first = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "one" })
local second = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "two" })
assert(memory.session(first) and memory.session(second), "sessions must be readable")
local latest = memory.latest_session("master", "")
assert(latest and latest.id == second, "latest_session must return the newest thread")
assert(memory.session(second).id ~= first, "ids must differ")
assert(memory.session("no-such-session") == nil, "an unknown session must resolve to nil")
-- A finished session is still continuable: the process ends a session on exit,
-- so filtering to open ones would mean --continue never finds anything.
memory.finish_session(second)
local after = memory.latest_session("master", "")
assert(after and after.id == second, "a finished session must still be the latest")
-- Memory is independent of conversational history.
memory.remember("session test fact", "global", {})
local sid = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "three" })
assert(#memory.session_messages(sid, {}) == 0, "a new session must start empty")
assert(#memory.recall("session test fact", 5) > 0, "memory must not depend on the session")
print("sessions ok")
LUA
gate_phase_begin sessions
WA_SCRIPT="$DB.sessions.lua" "$BIN" --db "$DB" | grep "sessions ok"
# The ledger's order under concurrent writers: several processes appending to one session at once. A
# single-process test cannot catch a `MAX(seq)+1` race. The check is mutation-tested: removing the
# transaction in `append_turn` makes it fail with a duplicate seq.
WA_BIN="$BIN" bash scripts/test-append-race.sh | grep "append race ok"
rm -f "$DB.sessions.lua"
# The node database has several writers, and telemetry is the one write path that must never be able to
# fail a run: two runs tonight died on `lua/core/telemetry.lua:12: database is locked`, a child's run
# mid-edit and then the coordinator's message to that session. The contention here is real - a second OS
# process holds the database's write lock inside an open transaction before the subject starts - but the
# fixture owns its database and its home, and needs no model, no network, no port and no build, so it
# belongs in this gate rather than on the on-demand suite. Both halves of the retry budget are asserted,
# because either one alone is passable by the wrong code: with one attempt the record is lost *visibly*
# and the run survives, and with the lock released inside the budget the record is stored (a longer wait
# for death would satisfy the first half). Its output is retained rather than piped, so a failure here
# names this file instead of leaving one line with no author - the same reason the concurrency fixture
# below keeps its log.
WA_BIN="$BIN" bash scripts/test-telemetry-lock.sh > "$DB.telemetry-lock.log" 2>&1 || {
  echo "the telemetry lock fixture failed; its output:"; tail -30 "$DB.telemetry-lock.log"; exit 1; }
grep "telemetry lock ok" "$DB.telemetry-lock.log"

# Session recovery. The contract - what an unfinished thread is, what is recorded
# and what the agent is told - lives in scripts/test-recovery.lua, because the
# Windows suite runs the same file and two copies would drift. What is asserted
# here is the surface a user actually touches and the Lua test cannot see: the
# CLI's own words, its exit codes, and that reading a report changes nothing.
WA_SCRIPT=scripts/test-recovery.lua "$BIN" --db "$DB" | grep "recovery ok"
# The turn's file changes: recorded by write/edit, carried by the ledger, and reversible.
# Three files because they fail for three different reasons - the record's own logic, the
# ledger round trip (which was broken: the column existed and the INSERT dropped it), and
# the route the UI's toggle calls.
WA_SCRIPT=scripts/test-changeset.lua "$BIN" --db "$DB" | grep "changeset ok"
WA_SCRIPT=scripts/test-changes-roundtrip.lua "$BIN" --db "$DB" | grep "changes round trip ok"
WA_SCRIPT=scripts/test-diff-route.lua "$BIN" --db "$DB" | grep "diff route ok"
# The window's `/efficiency_report` reads this route; the UI test stubs it, so the route itself
# is proved here against a real session - otherwise the window could render a fixture forever.
WA_SCRIPT="$WASM_AGENT_LUA_ROOT/scripts/test-efficiency-route.lua" "$BIN" --db "$DB.efficiency-route" | grep "efficiency route ok"

# An empty assistant message is not an answer. A reasoning model that spends its
# whole output budget thinking returns content "", a reasoning field, and
# finish_reason=length; the loop used to record that as a finished turn. The same
# file runs in the Windows suite, for the same reason the recovery one does.
# The node's name: derived from the worktree it runs in, and validated when someone sets it.
# This deliberately writes nothing - it only exercises the derivation and the refusals - so it
# cannot disturb the name of the node running it.
cat > "$DB.node-name.lua" <<'LUA'
local nodes = dofile("lua/core/nodes.lua")
local dir = nodes.worktree()
assert(type(dir) == "string" and dir ~= "", "the worktree directory must be derivable from the cwd")
assert(nodes.node_name() ~= "", "the node must have a name")
local rejected, why = nodes.set_name("no" .. string.char(10) .. "newlines")
assert(rejected == nil and why == "node_name_invalid",
  "a control character must be refused, got " .. tostring(rejected) .. " / " .. tostring(why))
local long, why2 = nodes.set_name(string.rep("x", 41))
assert(long == nil and why2 == "node_name_too_long",
  "a 41-character name must be refused, got " .. tostring(long) .. " / " .. tostring(why2))
assert(nodes.set_name("") == nil, "an empty name must be refused")
print("node name ok (" .. nodes.node_name() .. " in " .. dir .. ")")
LUA
WA_SCRIPT="$DB.node-name.lua" "$BIN" --db "$DB" | grep "node name ok"
rm -f "$DB.node-name.lua"
WA_SCRIPT=scripts/test-empty-reply.lua "$BIN" --db "$DB" | grep "empty reply ok"

# Test the shipping registry, including missing/stale/invalid negative controls.
( export WA_EMBEDDED_SOURCE_ROOT="$WASM_AGENT_LUA_ROOT"; unset WASM_AGENT_LUA_ROOT
  WA_SCRIPT="$WA_EMBEDDED_SOURCE_ROOT/scripts/test-embedded-runtime.lua" "$BIN" --db "$DB" ) \
  | grep "embedded runtime regression ok"
# Which copy of the Lua a script run loaded has to be visible. With no WASM_AGENT_LUA_ROOT the
# `dofile` bootstrap resolves every module from the copy compiled into the binary, so a focused test
# whose subject is an edit under `lua/` can run green while never loading that edit: one worker lost
# a whole green run (28 checks) to the binary's own `update.lua`, and the only tell was a line
# number in a message. Real processes - the same fixture twice, and two unusable roots that must fail
# loudly instead of falling back.
WA_BIN="$BIN" node scripts/test-lua-root-notice.cjs
WA_BIN="$BIN" node scripts/test-json-parsing.cjs --embedded
WA_SCRIPT=scripts/test-recovery.lua "$BIN" --db "$DB" | grep "recovery ok"
cat > "$DB.seed.lua" <<'LUA'
-- Seed a thread cut off the way a killed process leaves it: a question, a decision
-- to run a tool, and no result. `question` seeds the other shape (nothing but an
-- unanswered question) - WA_SCRIPT runs before dispatch, so the extra word is free.
local memory = dofile("lua/core/memory.lua")
memory.setup()
local id = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "seed" })
memory.append_turn(id, { role = "user", content = "count the scripts in scripts/" })
if args[1] ~= "question" then
  memory.append_turn(id, { role = "assistant", content = "Listing them now.", tool_calls = {
    { id = "seed1", type = "function", ["function"] = { name = "bash", arguments = '{"command":"ls scripts"}' } },
  } })
end
print(id)
LUA
SID="$(WA_SCRIPT="$DB.seed.lua" "$BIN" --db "$RDB")"
[ -n "$SID" ] || { echo "FAIL: the seed produced no session id" >&2; exit 1; }
"$BIN" --db "$RDB" sessions | grep -q "unfinished"
# The unfinished call is named: "unfinished" alone would send the reader into the
# transcript to find out what is missing.
"$BIN" --db "$RDB" sessions | grep -q "1 tool call(s) with no recorded result: bash"
"$BIN" --db "$RDB" resume | grep -q "waiting: 1 thread"
"$BIN" --db "$RDB" resume | grep -q "wa resume --session"
"$BIN" --db "$RDB" status | grep -q "unfinished at seq 2"
"$BIN" --db "$RDB" resume --session "$SID" | grep -q "no recorded result"
# An unknown session must be refused, not silently reported as fine.
if "$BIN" --db "$RDB" resume --session no-such-session >/dev/null 2>&1; then
  echo "FAIL: wa resume --session <unknown> must exit non-zero" >&2; exit 1
fi
# Reporting is read-only. A report that repairs what it prints cannot be used to
# check whether anything is wrong, and the repair would destroy the evidence.
"$BIN" --db "$RDB" resume | grep -q "waiting: 1 thread"
# The other shape: asked and never answered.
QSID="$(WA_SCRIPT="$DB.seed.lua" "$BIN" --db "$QDB" question)"
[ -n "$QSID" ] || { echo "FAIL: the question seed produced no session id" >&2; exit 1; }
"$BIN" --db "$QDB" resume | grep -q "unanswered question"
"$BIN" --db "$QDB" resume | grep -q "count the scripts"
"$BIN" --db "$QDB" status | grep -q "unfinished at seq 1"
rm -f "$DB.seed.lua"

# Reading a session is a window, and the window is the newest turns. The old shape
# returned the oldest 200 of a long thread while saying nothing, so a reader looking
# for the end of a run got its opening moves. The tool that shows a session to the
# model must also say what it dropped.
# Its own database: it seeds a few hundred turns, and sharing them would put this
# file's fixtures in front of the recovery assertions above.
WA_SCRIPT=scripts/test-memory-window.lua "$BIN" --db "$DB.window" | grep "memory window ok"

# A thread is named after its first message, once. The name is what makes a list of threads usable,
# and it must not drift as the conversation moves - a name that follows the conversation is a name
# you cannot search for.
WA_SCRIPT=scripts/test-session-title.lua "$BIN" --db "$DB.title" | grep "session title ok"

# The CLI's answer is markdown: the renderer decides what a heading, a bullet, a fence, a
# link and a bare url become, and - the property that matters most - that nothing in the
# reply is dropped on the way through. It is asserted without a model and without a terminal:
# `paint` is passed in, so the test reads the roles the renderer chose.
WA_SCRIPT=scripts/test-markdown.lua "$BIN" --db "$DB.markdown" | grep "markdown ok"

# What a run looks like while it is running. The renderer is where the CLI's whole
# readable output is decided - a tool call's line, a failed call's line, and whether a
# captured transcript is free of escape sequences - so it is asserted without a model:
# the view is handed the events agent.lua emits, with a clock the test controls.
WA_SCRIPT=scripts/test-cli-view.lua "$BIN" --db "$DB.view" | grep "cli view ok"

# The status line must keep moving while the interpreter is blocked, and the timer therefore
# lives in the host. The evidence is the captured stdout of a child that does nothing but
# sleep: it cannot repaint anything itself, so every frame and every tenth of a second in that
# file is the host's own work. The clock reaching 0.5s or more is what proves a timer rather
# than one frame drawn at the start. Each frame is written in place (`\r`, the line, the cursor put
# back), so the frames are what a split on `\r` gives: the mark is counted from the start of its
# segment, and the clock from anywhere in it, because a frame ends with the cursor restore rather
# than with the clock.
TICKER_OUT="$DB.ticker.out"
WA_SCRIPT=scripts/test-cli-ticker.lua "$BIN" --db "$DB.ticker" > "$TICKER_OUT" 2>&1
ticker_frames=$(tr '\r' '\n' < "$TICKER_OUT" | grep -c "Thinking" || true)
ticker_clocks=$(tr '\r' '\n' < "$TICKER_OUT" | sed -n 's/.* \([0-9][0-9]*\.[0-9]s\).*/\1/p' | uniq | wc -l | tr -d ' ')
ticker_marks=$(node -e 'const fs=require("fs");const lines=fs.readFileSync(process.argv[1],"utf8").split(/[\r\n]/).filter(s=>s.includes("Thinking"));console.log(new Set(lines.map(s=>Array.from(s.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g,"").trim())[0])).size)' "$TICKER_OUT")
ticker_last=$(tr '\r' '\n' < "$TICKER_OUT" | sed -n 's/.* \([0-9][0-9]*\.[0-9]s\).*/\1/p' | tail -1 || true)
if [ "$ticker_frames" -ge 8 ] && [ "$ticker_clocks" -ge 8 ] && [ "$ticker_marks" -ge 3 ] \
  && [ "$ticker_last" != "0.0s" ] && [ -n "$ticker_last" ]; then
  echo "cli ticker ok ($ticker_frames frames, $ticker_marks marks, clock reached $ticker_last)"
else
  echo "cli ticker FAILED: $ticker_frames frames, $ticker_clocks clocks, $ticker_marks marks, last \"$ticker_last\""
  exit 1
fi

# Input typed while the interpreter is blocked must not be lost. It used to be broken by
# construction: the REPL read its line with `io.read` between turns, so nothing read stdin while a
# run was in flight and the reader's typing went nowhere. The evidence is a real child process
# whose stdin producer writes the second line *while the script sleeps* - which is the one
# arrangement that tells a reader thread apart from a read in the REPL, because with `io.read` that
# line would have arrived to nobody and no assertion in the script could have passed.
INPUT_OUT="$DB.input.out"
( printf 'first\n'; sleep 2; printf 'typed while blocked\n' ) \
  | WA_SCRIPT=scripts/test-cli-input.lua "$BIN" --db "$DB.input" > "$INPUT_OUT" 2>&1
if grep -q "cli input ok" "$INPUT_OUT"; then
  echo "cli input ok (a line typed during a blocked turn is not lost)"
else
  echo "cli input FAILED: $(tail -4 "$INPUT_OUT" | tr '\n' '|')"
  exit 1
fi

# A complete note typed while a tool runs must reach the next model round and the
# durable transcript. A local mock provider checks the actual agent loop without inference.
WA_SCRIPT=scripts/test-cli-steering.lua "$BIN" --db "$DB.cli-steering" | grep 'cli steering ok'

# A phase-aware HTTP stream sends commentary chunks live, then only associates the
# durable message id when the result settles. The transcript keeps commentary apart
# from the final answer, and ordinary unstreamed commentary still emits once.
WA_SCRIPT=scripts/test-commentary-stream.lua "$BIN" --db "$DB.commentary-stream" | grep 'commentary stream contract ok'

# A command must not be able to hold the interpreter forever: an agent curled the node's own port
# from inside a turn, the request queued behind the turn that made it, and the worker waited on
# itself. The deadline is set short here so the check takes seconds, not minutes.
WASM_AGENT_EXEC_TIMEOUT_SECONDS=2 WA_SCRIPT=scripts/test-exec-timeout.lua "$BIN" --db "$DB.exec" | grep "exec timeout ok"

# Raw expected state survives Lua's JSON null-to-nil behavior; exact comparison,
# live-owner refusal and original-byte preservation are tested in private processes.
gate_run node scripts/test-operation-reconcile-json.cjs "$BIN"

# A shell must not die on the way in because the directory it was told to start in is gone: a
# released worktree is the ordinary way that happens, and on unix the shell then splits on
# `shell-init: error retrieving current directory` with an empty stdout. This runs the real host,
# so the substitution has to reach the result the caller reads, and a directory that exists has to
# come through untouched.
WA_SCRIPT=scripts/test-start-directory.lua "$BIN" --db "$DB.startdir" | grep "start directory ok"

# Reasoning replay is prefix-stable, and that is the property under test: a thought sent in
# full during its turn must never be emptied later, or the provider recomputes the suffix at
# the full input rate (see provider.reasoning). The switch has to reach the request, so the
# same script runs both ways and asserts every request after the first is append-only.
WASM_AGENT_LLM_MODEL=deepseek-v4.1-flash WASM_AGENT_REASONING_REPLAY=1 \
  WA_SCRIPT=scripts/test-reasoning-replay.lua "$BIN" --db "$DB.replay1" | grep "reasoning replay ok"
WASM_AGENT_LLM_MODEL=deepseek-v4.1-flash WASM_AGENT_REASONING_REPLAY=0 \
  WA_SCRIPT=scripts/test-reasoning-replay.lua "$BIN" --db "$DB.replay0" | grep "reasoning replay ok"

# One file written twice in a turn is one change, and its patch is built from the blobs. Both halves
# matter to undo: a second entry carrying the intermediate text would restore a state the turn itself
# created. Sandboxed home, because the reversible text is stored as content-addressed blobs under it.
WASM_AGENT_HOME="$DB.home" WA_SCRIPT=scripts/test-changeset.lua "$BIN" --db "$DB.changeset" | grep "changeset ok"

# Unchanged instructions keep identical prefix bytes; edited instructions must take effect without
# a restart. The fixture mutates a scratch file so a stale per-process cache cannot pass vacuously.
# A legitimate authority change is allowed to invalidate provider caching.
SCRATCH_AGENTS_MD="$DB.agents.md"
printf 'ORIGINAL INSTRUCTIONS\n' > "$SCRATCH_AGENTS_MD"
WASM_AGENT_AGENTS_MD="$SCRATCH_AGENTS_MD" \
  WA_SCRIPT=scripts/test-prefix-stability.lua "$BIN" --db "$DB.prefix" | grep "prefix stability ok"
rm -f "$SCRATCH_AGENTS_MD"

# A guest is not a smaller master. A guest node owns no worktree - so it is not named after
# one and a rename does not move a branch on its behalf - and a master's call on a guest is
# filed under the master, not the guest. Sandboxed home: the node's stored name and role must
# be this test's, not the machine's, and the node's own last four lines write to them.
WASM_AGENT_HOME="$DB.home" WA_SCRIPT=scripts/test-guest.lua "$BIN" --db "$DB.guest" | grep "guest ok"

# A node that is healthy and wedged at the same time is not instrumented, it is quiet.
# The accept thread answers /health without the interpreter, so a stuck Lua worker used
# to report ok forever while every endpoint that needs Lua hung with zero bytes. This
# stalls the worker on purpose and requires the node to say so. No model needed, which
# is why it runs here and not in the concurrency test's model half.
# Preserve the whole sub-suite output: grep used to hide the actual failing
# pool/session assertion while leaving only an earlier passing wedge line.
CONCURRENCY_PORT=$(node scripts/free-test-port-block.cjs)
WEDGE_ONLY=1 WA_BIN="$BIN" bash scripts/test-serve-concurrency.sh "$CONCURRENCY_PORT" > "$DB.concurrency.log" 2>&1 || {
  echo "the concurrency fixture failed; its output:"; tail -30 "$DB.concurrency.log"; exit 1; }
# Both claims are read from one run: the pair costs one fixture, not two.
grep "a stalled worker is visible" "$DB.concurrency.log"
grep "the client bridge survived a connection that said nothing" "$DB.concurrency.log"
ISOLATION_PORT=$(node scripts/free-test-port-block.cjs)
WA_BIN="$BIN" bash scripts/test-run-isolation.sh "$ISOLATION_PORT" > "$DB.isolation.log" 2>&1 || {
  echo "the run-isolation fixture failed; its output:"; tail -40 "$DB.isolation.log"; exit 1; }
grep '^run isolation ok$' "$DB.isolation.log"
run_proof_fixture sqlite 6 node scripts/test-sqlite-isolation.cjs "$BIN"
run_proof_fixture peer 43 node scripts/test-peer-run-admission.cjs "$BIN"
gate_run node scripts/test-peer-sync.cjs "$BIN"
gate_run node scripts/test-quarantined-retirement.cjs "$BIN"
WA_SCRIPT=tests/peer-reply-verification.lua "$BIN" --db "$DB.peer-reply" | grep 'peer signed reply verification ok'
run_proof_fixture foreground 3 bash scripts/test-foreground-cancel.sh
rm -f "$DB.window"*
gate_phase_begin recovery-cli
echo "recovery cli ok"

# `wa status` is the command an operator runs when something is wrong, so every
# fact it prints is asserted here - including the one that has to leave the
# process (git). A health line that says "clean" because git was unreachable is
# worse than no line at all.
cat > "$DB.status.lua" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local provider = dofile("lua/core/provider.lua")
local paths = dofile("lua/core/paths.lua")
local status = dofile("lua/core/status.lua")
memory.setup()

-- Identity: the node id must be this node's real ed25519 id, not a placeholder.
local identity = json.decode(host.node_identity())
assert(status.node_id() == identity.node_id, "status must report this node's id")

-- The model line states the model *and* whether it can be reached: without the
-- second half a missing api key reads as a merely quiet model.
local model = status.model()
assert(model:find(provider.settings().model, 1, true) ~= nil,
  "the model line must name the model: " .. model)
local expected = provider.configured() and "configured=yes" or "configured=no"
assert(model:find(expected, 1, true) ~= nil, "the model line must say " .. expected)

-- The thread: exactly the session `wa chat --continue` would resume.
local sid = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "status" })
assert(status.session_id() == sid, "status must report the current thread")
assert(status.session():find(sid, 1, true) ~= nil, "the session line must carry the id")

-- The working tree: git must be reachable from the checkout under test, and the
-- answer must be a state, not an apology.
local tree = status.working_tree()
assert(tree == "clean" or tree:match("^%d+ changed$") ~= nil,
  "status must read the working tree, got: " .. tree)

-- paths.config() is the host's answer, not a path rebuilt from $HOME.
assert(status.config_path() == paths.config(), "config must come from paths.config()")
assert(status.config_path() ~= "", "the config path must not be empty")

-- Five facts, one line each, and each line names the fact it carries.
local lines = status.lines()
-- No count assertion: the labels below say which facts must be there, and a
-- count only breaks when a fact is added (adding `tools` turned 5 into 6).
for _, label in ipairs({ "node", "model", "session", "tools", "tree", "config" }) do
  local found = false
  for _, text in ipairs(lines) do
    if text:sub(1, #label) == label then found = true end
  end
  assert(found, "status is missing its " .. label .. " line")
end
print("status ok")
LUA
WA_SCRIPT="$DB.status.lua" "$BIN" --db "$SDB" | grep "status ok"
rm -f "$DB.status.lua"

# And the command itself must be wired to that report, and listed in help: a
# module nobody can reach is not a command.
"$BIN" --db "$SDB" status | grep -q "^node "
"$BIN" --db "$SDB" status | grep -q "^config "
"$BIN" --db "$SDB" help | grep -q "status"

# Host capabilities that keep the agent portable: it must be able to learn which
# shell dialect it is in (it guessed POSIX on Windows and lost a whole tool
# budget), and grep must not depend on a POSIX binary.
cat > "$DB.platform.lua" <<'LUA'
local platform = dofile("lua/core/platform.lua")
local info = platform.info()
assert(info.os and info.os ~= "unknown", "platform.os must be known")
assert(info.shell and info.shell ~= "", "platform.shell must be known")
local described = platform.describe()
assert(described:find("shell") or described:find("cmd"), "describe() must mention the shell")
local agentlib = dofile("lua/core/agent.lua")
local prompt = agentlib.system_prompt("master", nil)
assert(prompt:find("Running on:", 1, true), "the system prompt must state the environment")
local result = host.grep("wasm-agent", "lua/core", "{\"limit\":5}")
assert(result, "host.grep must return a result")
local decoded = dofile("lua/vendor/json.lua").decode(result)
assert(decoded.count > 0, "host.grep must find a pattern that is definitely present")
assert(decoded.matches[1].file and decoded.matches[1].line, "matches carry file and line")
local listing = host.list_dir("lua/core")
assert(listing, "host.list_dir must return a result")
local entries = dofile("lua/vendor/json.lua").decode(listing)
assert(entries.entries and #entries.entries > 0, "host.list_dir must list the Lua core")
local names = {}
for _, entry in ipairs(entries.entries) do names[entry.name] = entry.kind end
assert(names["agent.lua"] == "file", "listing must include files with a kind")
print("platform ok")
LUA
WA_SCRIPT="$DB.platform.lua" "$BIN" --db "$DB" | grep "platform ok"
rm -f "$DB.platform.lua"

# Memory has to be curatable and findable, or it misleads later: the agent could
# only accumulate (no delete tool), and a conversational question could never
# match a note because every term was ANDed.
cat > "$DB.memory.lua" <<'LUA'
local memory = dofile("lua/core/memory.lua")
local tools = dofile("lua/core/tools.lua")
memory.setup()
local id = memory.remember("The readiness probe runs on Tuesdays", "global", {})
-- The precise query finds it.
assert(#memory.recall("readiness probe") > 0, "an exact query must match")
-- A conversational question shares no complete term set with the note; it must
-- still find it, because returning nothing here made the agent report an empty
-- store while the fact was present.
local conversational = memory.recall("what did I ask you to remember about the probe?")
assert(#conversational > 0, "a conversational question must still find the memory")
-- The tool surface: listing and deleting, master only for the delete.
local master = {}
for _, tool in ipairs(tools.all("master")) do master[tool["function"].name] = true end
assert(master.memories and master.forget, "master must be able to list and delete memories")
local guest = {}
for _, tool in ipairs(tools.all("guest")) do guest[tool["function"].name] = true end
assert(not guest.forget, "a guest must not be able to erase stored facts")
assert(tools.dispatch(memory, "forget", { id = id }, "guest").error, "dispatching forget as a guest must fail")
local result = tools.dispatch(memory, "forget", { id = id }, "master")
assert(result.forgotten, "the master must be able to forget a memory")
assert(#memory.recall("readiness probe") == 0, "a forgotten memory must not be recalled")
print("memory curation ok")
LUA
WA_SCRIPT="$DB.memory.lua" "$BIN" --db "$DB" | grep "memory curation ok"
rm -f "$DB.memory.lua"

# Native Node test collection pins TAP, retains actual exit and reports skips.
gate_run node skills/parallel-evolution/scripts/test-node-tests.mjs "$WASM_AGENT_HOME"

# Read-only scoped file discovery: exact candidate pages, no hidden clipped tail.
gate_run node skills/code-graph/scripts/test-discover-files.mjs "$WASM_AGENT_HOME"
# Benchmark evidence metadata never recurses into retained solver repositories.
gate_run node skills/agent-benchmark/scripts/test-artifacts.mjs "$WASM_AGENT_HOME"

# Skills: on-demand instructions (the Agent Skills standard pi implements).
# Only name and description are always in context; the body loads when a task
# matches, which is the whole point - a technique needed occasionally must not
# cost context every turn, and must not have to be explained twice.
cat > "$DB.skills.lua" <<'LUA'
local skills = dofile("lua/core/skills.lua")
local tools = dofile("lua/core/tools.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local found = skills.list(true)
assert(#found > 0, "at least one skill must be discoverable")
local names = {}
for _, skill in ipairs(found) do
  names[skill.name] = true
  assert(skill.description ~= "", skill.name .. " must have a description")
end
assert(names["see-your-output"], "the repo's own skill must be found")
local block = skills.prompt_block()
assert(block and block:find("<available_skills>", 1, true),
  "the system prompt must advertise the skills")
assert(block:find("see-your-output", 1, true), "the advertised block must name the skill")
assert(block:find("crystallize repeatable deterministic sequences",1,true) and
  block:find("Compose consecutive spells",1,true) and block:find("inference by default",1,true),
  "every skill must receive the crystallization, composition and inference recovery rule")
local loaded = tools.dispatch(memory, "skill", { name = "see-your-output" }, "master")
assert(loaded.content and #loaded.content > 200, "loading a skill must return its instructions")
assert(loaded.path and loaded.path:find("SKILL.md", 1, true), "a loaded skill reports its file")
local missing = tools.dispatch(memory, "skill", { name = "no-such-skill" }, "master")
assert(missing.error == "unknown_skill", "an unknown skill must fail, not invent one")
assert(#missing.available > 0, "the failure must list what is available")
-- Guests get the same read-only knowledge; their tool envelope still gates actions.
assert(tools.dispatch(memory, "skill", { name = "see-your-output" }, "guest").content,
  "a guest must be able to read a skill")
-- Discovery must stop at the checkout root: this repo is nested inside
-- another one, and walking past the root made it advertise that project's
-- skills (airtable, productivity) to an agent working here.
local cwd = dofile("lua/core/platform.lua").cwd()
assert(block:find(cwd, 1, true) or true, "sanity")
for _, skill in ipairs(found) do
  assert(not skill.path:find("/local/skills/", 1, true),
    "must not adopt a parent project's skills: " .. skill.path)
end
print("skills ok")
LUA
WA_SCRIPT="$DB.skills.lua" "$BIN" --db "$DB" | grep "skills ok"
rm -f "$DB.skills.lua"

# The plugins are staged in a directory this section owns, and it owns it where it is *used*. The
# directory is created near the top of the run and used ~1300 lines later, and in between nothing
# keeps it: on a machine running more than one gate, an empty `mktemp -d` directory in the shared
# temp root can be gone by the time the first module is copied into it. Measured - candidate tree
# 55e04252, gate exit 1 after 763 s with no verdict line, its last line
# `cp: cannot create regular file '/tmp/tmp.PZulxpI9l4/echo.wasm': No such file or directory` - that
# is an unattributed red gate, which is what makes unattended landing unsafe. The copy is still the
# assertion: a module that cannot be written where the node reads it fails the gate, as it must.
stage_plugin() {  # stage_plugin <wasm-path> <name>
  if [ ! -d "$PLUGINS" ]; then
    echo "note: the plugin staging directory $PLUGINS was missing; re-creating it to stage $2" >&2
  fi
  mkdir -p "$PLUGINS"
  cp "$1" "$PLUGINS/$2.wasm"
}
# The staging contract is a test before it is a habit: a directory taken out from under this section
# must not become an unattributed red gate, and a staging that cannot write its module must still
# fail. That test reads the function above out of this file, so it cannot pass while the code here is
# wrong.
gate_phase_begin plugins
gate_run bash scripts/test-plugin-staging.sh
# Build every plugin and assert one round trip through the WASM host.
for crate in rust/plugins/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  cargo build --manifest-path "$crate/Cargo.toml" --target wasm32-unknown-unknown --release --offline >/dev/null
  wasm="$(ls "$crate"/target/wasm32-unknown-unknown/release/*.wasm | head -1)"
  stage_plugin "$wasm" "$name"
done
cat > "$DB.plugin.lua" <<'LUA'
local raw = host.invoke("echo", '{"text":"hi"}')
assert(raw and raw:find('"echo":"hi"'), "plugin round trip failed: " .. tostring(raw))
print("plugin ok")
LUA
WASM_AGENT_PLUGINS="$PLUGINS" WA_SCRIPT="$DB.plugin.lua" "$BIN" --db "$DB" | grep "plugin ok"
rm -f "$DB.plugin.lua"

# Line endings are an invariant, not a preference: these files run on a Linux
# host under sh and lua, where a CRLF script fails in confusing ways. Check the
# *stored* blobs (recoverable if a Windows working copy drifts) and skip
# binaries, which legitimately contain CR bytes. `-I` does that for us.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  # `git grep` exits 1 when it finds nothing, which is the good case here; with
  # `set -e` that would abort the run exactly when the invariant holds.
  crlf="$(git grep --cached -I -l "$(printf '\r')" || true)"
  if [ -n "$crlf" ]; then
    echo "FAIL: CRLF stored in the index:" >&2
    echo "$crlf" >&2
    echo "Fix with: git add --renormalize .   (and set core.autocrlf=false)" >&2
    exit 1
  fi
  echo "line endings ok"
fi

# No old name survives (ARCHITECTURE.md section 6). A rename that leaves both names in the tree is worse
# than not doing it, so it is a check rather than a convention - and it greps for the old *names*, not for
# the word "turn", which section 6 keeps for one speaker's contribution.
bash scripts/check-naming.sh
gate_run node scripts/test-naming-check.cjs
# A temporary family with no retention or cleanup path grows with every run of the suite, and no reviewer
# sees it in a diff: on 2026-09-30 the OS temp directory held 13079 stale entries from these scripts,
# 14 GB of them. The check fails a file that mints one and never bounds it; the 36 files that already do
# are printed on every run and are not fatal (`scripts/check-temp-retention.mjs` names each one).
node scripts/check-temp-retention.mjs
gate_run node scripts/test-temp-retention-check.cjs
# The reclaim pass's safety rule, on fixtures where the answer is known: an ended session's worktree is
# the only tree whose rust/target may be pruned, and a live session's, the canonical checkout's and a
# lane's are kept with the reason printed. Also the refusal that matters - a tree with no session row is
# refused, because ownership unproven is not permission.
gate_run node scripts/test-reclaim-disk.cjs
# The disk floor's refusal, the numbers it must name, the `--json` shape an alarm would read, and that
# the gate calls it before its first build rather than after one has failed.
gate_run node scripts/test-disk-floor.cjs
gate_run node scripts/test-execution-terminology.cjs
# Who may commit on `main` is decided by the host's answer about the process, not by a flag the
# committing process types: the orchestrator session is allowed, a child is refused even when it
# exports WASM_AGENT_ALLOW_MAIN=1, a person at a terminal keeps the visible override, and a merge is
# still the normal landing path. Run directly rather than piped, so a failing check prints its own
# name and what it saw instead of leaving one swallowed line. No build: its fixture is a throwaway
# repository on `main` (the host export itself is measured by the wa-host test named in that file).
gate_run bash scripts/test-main-guard.sh
# ... and its push half: the same repository declares origin main-only, so a push of any other ref is
# refused by name before the remote moves. `test-push-guard.sh` measures the three ways around it rather
# than asserting they do not exist - a client-side hook is convenience, not a boundary.
gate_run bash scripts/test-push-guard.sh
# The window and this CLI offer the same `/` commands, and `/new` was missing from the CLI for as long
# as nothing checked it. The rule is the window's list against the REPL's, plus the one sentence that
# is deliberately written twice (the `/merge` brief).
gate_run node scripts/test-command-parity.cjs
# Explicit two-sided binding proof; private registry/CLI, no live service or inference.
gate_run node scripts/test-binding.cjs "$BIN"
gate_run node scripts/test-binding-runtime.cjs "$BIN"
gate_run node scripts/test-verify-install.mjs
gate_run node scripts/test-merge-audit.mjs
# The boundary the audit's own verify verb answers, run at a wave's two entrypoints: a repository that
# declares `lane-policy.json` gets its declared checks enforced there, and one that does not gets nothing
# (proven, not asserted). This also pins that retirement stays one command.
gate_run node scripts/test-lane-boundary.mjs
# The factory's lanes, tested where their answers are known in advance. Each of these was written and
# then not run: scripts/test.sh discovers tests explicitly, so a delivery whose scope stopped short of
# this file shipped a check that no gate executes - a test nobody runs is a comment. All four are
# hermetic, model-free and need no build, and none of them runs a real gate: `test-gate-lane.cjs` stands
# a fake command in for it (what is under test is *when* a command runs, not what it is), and
# `test-merge-lane.mjs` takes its gate through `--gate-command`, so the lane's spine costs seconds and a
# real gate on real branches stays a merge-lane run. `test-delivery-admission.mjs` is the rule that
# decides what may reach the lane at all, on fixtures whose fixed author/committer dates make the
# recorded shas identical on a second run. `test-gate-lane-wiring.cjs` drives both of those consumers
# through the same stand-in gates, and it is handed a clean environment because that is one of the things
# it checks: its holder has to *ask* for the slot whose queue it then asserts, while a gate's own fence
# deliberately leaves the admission marker alone for the gates nested inside it - so this gate, which
# holds a slot and passes the marker on, has to say the marker is not there for this one file. Without
# `env -u GATE_LANE_HELD` the run inherits a slot and fails on its first check.
gate_run node scripts/test-gate-lane.cjs
gate_run node scripts/test-merge-lane.mjs
gate_run node scripts/test-merge-gate-source.mjs
gate_run node scripts/test-merge-lane-retention.mjs
gate_run node scripts/test-delivery-admission.mjs
gate_run node scripts/test-wave-release.mjs
gate_run bash scripts/test-deploy-gate-policy.sh
gate_run bash scripts/test-deploy-sentinel-sudo.sh
gate_run bash scripts/test-deploy-preconditions.sh
# The install record, and the self-ship that used to kill the deploy before it wrote one. Both read the real
# record step / ship helper out of deploy.sh and upgrade.sh and run them against a private install
# directory: the deploy's record must name the exact commit with `source_provenance=clean-built-by-deploy`
# and `record_role=final` over upgrade.sh's interim record, and a script that replaces itself while it runs
# must finish (the 2026-10-02 deploy died there and left `commit=unknown` while serving 2f02b4c).
gate_run bash scripts/test-deploy-record.sh
gate_run bash scripts/test-deploy-self-ship.sh
# The residue pass on the deploy record: the on-main rule may not be waived by WA_INSTALL_DIR (it was), the
# knob is read by value (0 used to be ON), and a killed run's staged copies are collected under a bound
# (a 248 MB sentinel image could sit there for ever). check-deploy-docs fails when the doc, the skill and the
# script stop saying the same thing about a deploy's release proof.
gate_run bash scripts/test-deploy-on-main.sh
gate_run bash scripts/test-deploy-staging-sweep.sh
gate_run node scripts/check-deploy-docs.mjs
gate_run node scripts/test-delivery-refresh.mjs
env -u GATE_LANE_HELD node scripts/test-gate-lane-wiring.cjs
gate_run node scripts/test-openai-sub.cjs "$BIN"
gate_run node scripts/test-subscription-transport.cjs "$WASM_AGENT_HOME" "$BIN"
EMPTY_START_BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
EMPTY_START_EVIDENCE="$GATE_HOME/subscription-empty-start"
if command -v cygpath >/dev/null 2>&1; then
  EMPTY_START_BIN="$(cygpath -w "$EMPTY_START_BIN")"
  EMPTY_START_EVIDENCE="$(cygpath -w "$EMPTY_START_EVIDENCE")"
fi
gate_run node scripts/test-subscription-empty-start.cjs "$EMPTY_START_BIN" "$EMPTY_START_EVIDENCE"
MIDSTREAM_EVIDENCE="$GATE_HOME/subscription-midstream"
if command -v cygpath >/dev/null 2>&1; then MIDSTREAM_EVIDENCE="$(cygpath -w "$MIDSTREAM_EVIDENCE")"; fi
gate_run node scripts/test-subscription-midstream.cjs "$EMPTY_START_BIN" "$MIDSTREAM_EVIDENCE"
# And the levels that route declares, read from the catalogue this repo owns
# (`lua/core/openai_sub_catalogue.lua`) rather than from a third-party store at request time: the
# fixture writes a *disagreeing* store where pi's store lives and none of it may reach the answer, so
# "the store is no longer consulted for this route" is a property and not a hope. A level the
# catalogue adds must be admissible - otherwise no child can be placed at all - and a level no source
# names must still be refused by name rather than silently replaced by a default.
WA_SCRIPT=scripts/test-openai-sub-levels.lua "$BIN" --db "$DB.sub-levels" | grep "openai-sub levels ok"
# The subscription wire itself, offline: SSE framing, the event mapping, the phase contract
# (`pending_delta` resolved to commentary or to the answer), the tool-decision telemetry, the usage
# mapping and the rule that a stream ending without a terminal event is an error - replayed from the
# two real streams recorded under `tests/fixtures/subscription/`. No network, no credential, no model
# and no Node; the bytes are the endpoint's, and re-recording them is what
# `scripts/check-subscription-wire-live.lua` does (it is not in this gate: it needs the network).
WA_SCRIPT=scripts/test-subscription-wire.lua "$BIN" --db "$DB.sub-wire" | grep "subscription wire ok"
# The credential half of the subscription route, which used to be Pi's: our own store, our own
# refresh, our own login, and the single-flight lock. Hermetic - a node fixture stands in for
# auth.openai.com on 127.0.0.1, so the two-process proof that one rotating token is spent once is
# measured rather than asserted, with no OpenAI account, no Pi package and no model. That fixture is
# a node server, so a machine without node skips it visibly instead of passing it silently.
if command -v node >/dev/null 2>&1; then
  SUB_AUTH_OUT="$(WA_SCRIPT=scripts/test-openai-sub-auth.lua "$BIN" --db "$DB.sub-auth" 2>&1)" || {
    echo "FAIL subscription credential tests"; printf '%s\n' "$SUB_AUTH_OUT" | tail -12; exit 1; }
  printf '%s\n' "$SUB_AUTH_OUT" | grep "openai-sub auth ok"
  # The same run prints its measured counts; keep them in the gate log beside the verdict.
  printf '%s\n' "$SUB_AUTH_OUT" | grep "openai-sub concurrency evidence"
else
  echo "subscription credential tests SKIPPED - node not on PATH (the concurrency fixture is a node server)"
  SKIPPED=$((SKIPPED + 1))
fi
# The mapping this binary loads Lua through: every literal `dofile` target reachable from an embedded
# `lua/` file must itself be in the binary's EMBEDDED registry. It is a static check with no binary,
# no network and no Node-in-the-loop, and it exists because the opposite is invisible here: a `dofile`
# of a `scripts/` path resolves in a checkout - which is what the rest of this file exports a Lua root
# for - and dies in an installed node with `embedded module missing`. `wa subscription login` shipped
# exactly that way. Falsified by adding one such `dofile` and watching it fail by name.
node scripts/check-embedded-lua-closure.mjs
# And the login door in the shape an installed node actually runs, since that is the shape the check
# above reasons about: every command is run twice, once with the Lua root deliberately removed (the
# shipped shape) and once with it set, and the two are compared rather than assumed equal. Both
# `wa subscription status` and `wa subscription login --browser` are exercised; the authorize URL is
# built locally, so this needs no network, no credential and no model.
env -u WASM_AGENT_LUA_ROOT bash scripts/test-subscription-login-door.sh "$BIN" "$DB.sub-login" | grep "subscription login door ok"
gate_run node scripts/test-auth-sessions.cjs "$BIN"
gate_run node scripts/test-fixture-verdict.cjs
gate_run node scripts/test-suite-verdict.cjs
gate_run node scripts/test-proof-verdict.cjs
gate_run node scripts/test-wave-gate-wiring.mjs

# The image-attachment tests, plus the helper tests that came with them. They were
# written, they passed when run by hand, and nothing ran them - which is how a test
# quietly stops being true. Each file is self-contained and prints its own verdict,
# so the gate is that verdict rather than a fixed string.
gate_phase_begin fixtures
for t in tests/*.lua; do
  fixture_status=0
  out=$(WA_SCRIPT="$t" "$BIN" --db "$DB.attach" 2>&1) || fixture_status=$?
  # Both pieces of evidence matter: a verdict printed before a crash is not success.
  if ! printf '%s' "$out" | node scripts/lib/test-verdict.cjs lua "$fixture_status"; then
    echo "FAIL $t (exit $fixture_status)"; printf '%s\n' "$out" | tail -6; exit 1
  fi
  rm -f "$DB.attach"*
done
echo "attach tests ok"

# A real long-running tool must remain observable/cancellable through another worker.
# Local mock provider only; no account, paid model or external browser required.
gate_run node scripts/test-operation-control.cjs "$BIN"
gate_run node scripts/test-operation-control.cjs "$BIN" --await

# Actual child runtime and real sentinel deliveries, never a /subagents route stub.
gate_phase_begin subagents
run_proof_fixture policy 62 node scripts/test-subagents-policy.cjs "$BIN"
run_proof_fixture children 18 node scripts/test-subagents.cjs "$BIN"
run_proof_fixture fleet 20 node scripts/test-orchestrator.cjs "$BIN"
gate_run node scripts/test-completion-wake.cjs "$BIN"
if [ "${OS:-}" = "Windows_NT" ]; then
  gate_run python scripts/test-sentinel-owned-job.py --repo "$PWD" --evidence "$(git rev-parse --git-path owned-return-gate-$$)"
  run_proof_fixture sentinelInstall 30 python scripts/test-sentinel-owned-job.py --repo "$PWD" --evidence "$(git rev-parse --git-path private-install-gate-$$)" --script "$PWD/scripts/test-sentinel-private-install.cjs" --deadline 1800
else
  echo "SKIP: Windows owned return Job proof"
  SKIPPED=$((SKIPPED + 1))
  echo "SKIP: Windows actual private installation proof"
  SKIPPED=$((SKIPPED + 1))
fi
for fixture in session-view durable-steering child-compaction child-budget-refusal completion-outbox orchestrator-defaults; do
  WA_SCRIPT="scripts/test-$fixture.lua" "$BIN" --db "$DB.$fixture"
done
# The settlement evaluation packet, against a real git worktree: the artifact facts a coordinator is
# woken with, who is woken at all (a self-reported profile is skipped with its reason recorded), and
# the wake that must never be replayed. Model-free: the scheduler seam is counted, not driven.
WA_SCRIPT="scripts/test-completion-packet.lua" "$BIN" --db "$DB.completion-packet"
run_proof_fixture jobs 37 node scripts/test-job-subagents.cjs
# The `onSubagentReturn` hook: every settled child, in every state, woken with a deterministically
# measured deploy verdict and its operating instruction. A real sentinel, real git checkouts, no model.
run_proof_fixture subagentReturn 206 node scripts/test-subagent-return-hook.cjs
# The shipped set the hook's verdict is read from, re-derived from the installers themselves: this fails
# when deploy.sh or upgrade.sh installs something scripts/deploy-shipped.json does not cover, when a copy
# names a path that is neither in the tree nor built by that installer, or when the derivation itself
# stops seeing a copy form it used to see. A proof fixture rather than a bare gate_run, so its 76 checks
# have a floor: a guard nobody counts is a guard that can lose checks silently.
run_proof_fixture deployShipped 92 node scripts/check-deploy-shipped.mjs
node scripts/test-sentinel-quarantine.mjs || exit 1
node scripts/test-sentinel-install-proof.mjs || exit 1
node scripts/test-install-speed.mjs || exit 1
run_proof_fixture orchestration 33 node scripts/test-orchestration-e2e.cjs "$BIN"
run_proof_fixture whatsapp 40 node scripts/test-whatsapp-subagent-e2e.cjs
# The reader's acted cursor: a message may be consumed only when a durable decision exists for it, the
# attempt count is bounded, and media is reported instead of handed to a child. Mock store, real ingest.
run_proof_fixture cursor 47 node scripts/test-whatsapp-cursor.cjs "$BIN"
# Local audio bytes, WASM formatting, durable reservation, and exactly-once
# verified sends. These use fake WhatsApp/STT adapters and no paid model.
gate_run node scripts/test-whatsapp-audio.mjs
# Staged here, at its use, for the same reason as the plugin loop above: this module is read about
# ninety sections after it was built, and the section does not assume the staging directory it
# created earlier is still there. The copy is still fatal if the module cannot be staged.
stage_plugin "$(ls rust/plugins/whatsapp-transcript/target/wasm32-unknown-unknown/release/*.wasm | head -1)" whatsapp-transcript
gate_run node scripts/test-whatsapp-transcribe.cjs "$BIN" "$PLUGINS/whatsapp-transcript.wasm"
# The silent skip: a voice note whose browser download fails must stay reachable, and a pass that loses one
# has to say so - with the id, the step and the underlying error - instead of {"ok":true,"pending":0,
# "refused":[]}. Fake media/STT/send adapters, real Lua, real ledger.
gate_run node scripts/test-whatsapp-audio-loss.cjs "$BIN" "$PLUGINS/whatsapp-transcript.wasm"
# The pipeline seam: a `returns` list reaches the foreach, a step that produced nothing fails the
# delivery, and a no-op run is distinguishable from a dropped result. Real sentinel, mock store, no model.
run_proof_fixture pipeline 19 node scripts/test-job-pipeline.cjs
# The source keeper's categorical refusals, hermetically: a port held by something that is not the agent
# browser is refused and left alone, and a missing logon task is named with the command that registers it.
gate_run node scripts/test-source-ensure.cjs
# The prevention: step 1 asks the preflight (which rebinds the document-start hook) instead of exiting on
# "DevTools answered", and a trigger pin that names a dead target is re-pinned rather than merely reported.
# A fake DevTools endpoint; the real adapter, trigger, preflight and sentinel CLI.
gate_run node scripts/test-whatsapp-hook-rebind.cjs
# be installed beside it, and both a missing module and an import this deploy cannot satisfy must be
# refused by name. The block under test is read out of deploy.sh, so this cannot pass while the real
# code is wrong - and it must not be a check that cannot fail (the live failure was a deploy that
# reported success over a reader whose import was absent).
gate_run bash scripts/test-deploy-ship.sh
gate_run node scripts/test-source-ensure.cjs

# The Android build itself needs Termux, but its installer and launcher contracts
# are hermetic: setup preserves an existing secret, keeps the env private, UI
# arguments reach the native runtime, and both shell entrypoints parse.
gate_run bash scripts/test-termux.sh
case "$(uname -o 2>/dev/null || true)" in
  Android) ;;
  *) SKIPPED=$((SKIPPED + 1)) ;;
esac

# The UI tests are JS and run outside the embedded interpreter, so they need node
# and they need the repo root as cwd (they read ui/app.js from disk). A test that does
# not run must not look like one that passed, so a skip is counted and asked for: if
# node is missing the suite says so and the verdict counts it.
gate_phase_begin ui-js
if [ "${WASM_AGENT_SKIP_UI_TESTS:-}" = "1" ]; then
  echo "ui tests skipped by request (WASM_AGENT_SKIP_UI_TESTS=1)"
  SKIPPED=$((SKIPPED + 1))
elif command -v node >/dev/null 2>&1; then
  CHECK_OUTPUT="$(git rev-parse --git-path wa-gate-ui-js)"
  command -v cygpath >/dev/null 2>&1 && CHECK_OUTPUT="$(cygpath -w "$CHECK_OUTPUT")"
  node scripts/gate-check.mjs run ui-js --jobs "${WA_CHECK_JOBS:-1}" --output "$CHECK_OUTPUT"
  echo "ui tests ok"
else
  echo "ui tests SKIPPED - node not on PATH"
  SKIPPED=$((SKIPPED + 1))
fi
# The window's own harness drives a real headless browser, so it needs PowerShell and Edge or
# Chrome. It is the only check that sees the page as rendered - and it used to sit outside this
# gate, so a green gate could say "ui tests ok" while it was failing. A machine that cannot run
# it says so and counts the skip, rather than reporting a pass it did not earn.
gate_phase_begin ui-browser
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [ -f scripts/test-recovery-two-window.cjs ]; then
      run_proof_fixture recoveryWindows 13 node scripts/test-recovery-two-window.cjs "$BIN"
      run_proof_fixture recoveryWindows 13 node scripts/test-recovery-two-window.cjs "$BIN" --embedded
      run_proof_fixture nativeChildBrowser 63 node scripts/test-native-child-browser.cjs "$BIN"
      run_proof_fixture nativeChildBrowser 63 node scripts/test-native-child-browser.cjs "$BIN" --embedded
    else
      echo "two-window recovery proof SKIPPED - primary recovery fixture absent from this producer tree"
      SKIPPED=$((SKIPPED + 1))
    fi ;;
  *) echo "two-window recovery proof SKIPPED - Windows Chromium integration fixture"; SKIPPED=$((SKIPPED + 1)) ;;
esac
if [ "${WASM_AGENT_SKIP_UI_BROWSER:-}" = "1" ]; then
  echo "ui browser harness skipped by request (WASM_AGENT_SKIP_UI_BROWSER=1)"
  SKIPPED=$((SKIPPED + 1))
elif command -v powershell >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  if ui_out=$(powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1 2>&1); then
    printf '%s\n' "$ui_out" | tail -1
    node scripts/test-coordinator-steps.cjs
  elif printf '%s' "$ui_out" | grep -q "no Edge or Chrome found"; then
    echo "ui browser harness SKIPPED - no Edge or Chrome on this machine"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "FAIL scripts/test-ui.ps1"
    printf '%s\n' "$ui_out" | tail -6
    exit 1
  fi
else
  echo "ui browser harness SKIPPED - powershell or node not on PATH"
  SKIPPED=$((SKIPPED + 1))
fi
gate_phase_summary
if [ "$SKIPPED" -gt 0 ]; then
  echo "smoke ok ($SKIPPED skipped)"
else
  echo "smoke ok"
fi
