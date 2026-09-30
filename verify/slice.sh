#!/usr/bin/env bash
# Smoke test for the Rust+Lua wasm-agent: build, then exercise memory and a WASM plugin.
set -euo pipefail
# A skipped test must be visible in the verdict, not only in the middle of the log:
# "smoke ok" over a run that skipped the UI tests claims more than it did.
SKIPPED=0
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

# A scratch DB does not isolate profile/config/effect files. Fence the ENTIRE gate,
# including new fixtures whose authors might otherwise forget to select a home.
# Keep the explicit skip request, the in-turn deploy guard, this gate's own parallelism
# knob and the count that bounds this gate's own home; never inherit provider accounts, a real
# instance registry, a job auth token, or the user's runtime paths. The knobs are numbers, not
# runtime state.
while IFS= read -r variable; do
  case "$variable" in
    WASM_AGENT_SKIP_UI_TESTS|WASM_AGENT_IN_TURN|WA_GATE_JOBS|WA_GATE_HOME_KEEP) ;;
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
# LIVENESS DECIDES WHAT MAY BE PRUNED, NOT AGE. The pid of the run is part of the directory name, so a
# sweep never touches a home whose process is still alive: on a machine running more than one gate - the
# plugin-staging note below is what deleting a live sibling's temp already cost this repository - that
# would turn a passing neighbour into an unattributed red gate. A home whose name carries no pid is from
# before this change: it is pruned only once it is an hour old, so a rollout cannot delete the home of a
# gate the previous script started. Residual limit, named: a gate killed by a signal it does not trap
# leaves its home behind - the next gate's sweep is what removes it, and that sweep bounds the family.
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
  local status=$? home="$GATE_HOME" keep="$GATE_HOME_KEEP" root="${TMPDIR:-/tmp}"
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
trap gate_home_release EXIT
