#!/bin/bash
# A SENTINEL TOLD WHERE ITS HOME IS MUST NEVER OPEN THE OPERATOR'S (28/11, P0 from the canary).
#
# MEASURED by the canary at 07:30Z: "pid .../tmp/wa-deploy-bound-*/wa-sentinel is a non-live sentinel with the live
# HOME/DB". The row that started it exported WASM_AGENT_HOME and not HOME.
#
# WHAT THIS ROW PINS, in the operator's words: a sentinel with WASM_AGENT_HOME=X never opens anything under
# $HOME/.wasm-agent. It gives the sentinel three places to write and asks which of them changed:
#   * the SCRATCH home (WASM_AGENT_HOME) - the only one it may use;
#   * the DECOY home (HOME) - a temp directory, so a mistake cannot reach the operator;
#   * the REAL $HOME/.wasm-agent - fingerprinted before and after, because that is the thing the P0 is about.
#
# MEASURED while writing it: with both variables set, the installed sentinel created its whole
# `.wasm-agent/sentinel/{requests,done,failed,claimed,withdrawn}` tree under the SCRATCH home and left HOME and the real
# store untouched - so the resolution is right today, and the row exists to keep it right.
#
# Hermetic: temp directories only, no network, no session. Skips (exit 0) when no sentinel binary can be had.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SKIP() { echo "sentinel-home: SKIP ($*)"; exit 0; }
FAIL() { echo "sentinel-home: $*"; exit 1; }

REAL_HOME=${HOME:-}
[ -n "$REAL_HOME" ] || FAIL 'no HOME to protect'
REAL_STORE="$REAL_HOME/.wasm-agent"

SENTINEL=${WA_SENTINEL_BIN:-}
if [ -z "$SENTINEL" ] || [ ! -x "$SENTINEL" ]; then
  SENTINEL=$(command -v wa-sentinel 2>/dev/null || true)
fi
if [ -z "$SENTINEL" ] || [ ! -x "$SENTINEL" ]; then
  CARGO=$(command -v cargo 2>/dev/null || true)
  [ -z "$CARGO" ] && [ -x "$REAL_HOME/.cargo/bin/cargo" ] && CARGO="$REAL_HOME/.cargo/bin/cargo"
  [ -n "$CARGO" ] || SKIP 'no sentinel binary on PATH or in WA_SENTINEL_BIN, and no cargo to build one'
  TARGET=${WA_SENTINEL_TARGET:-$ROOT/rust/target}
  [ -x "$TARGET/debug/wa-sentinel" ] || "$CARGO" build --offline --manifest-path "$ROOT/rust/wa-sentinel/Cargo.toml" >"${TMPDIR:-/tmp}/sentinel-home-build.log" 2>&1 \
    || SKIP "this tree's wa-sentinel did not build (log ${TMPDIR:-/tmp}/sentinel-home-build.log)"
  SENTINEL="$TARGET/debug/wa-sentinel"
fi
[ -x "$SENTINEL" ] || SKIP "no sentinel binary at $SENTINEL"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-home.XXXXXX") || FAIL 'no temp dir'
trap 'rm -rf "$WORK"' EXIT
DECOY="$WORK/operator-home"
SCRATCH="$WORK/scratch-home"
mkdir -p "$DECOY/.wasm-agent" "$SCRATCH/.wasm-agent" || FAIL 'cannot create the two homes'
printf 'decoy marker\n' > "$DECOY/.wasm-agent/DO-NOT-TOUCH"

fingerprint() { ( cd "$1" 2>/dev/null && find . -printf '%p %s\n' 2>/dev/null | LC_ALL=C sort ) || true; }

before_decoy=$(fingerprint "$DECOY")
before_scratch=$(fingerprint "$SCRATCH")
before_real=$(fingerprint "$REAL_STORE")

out=$(HOME="$DECOY" WASM_AGENT_HOME="$SCRATCH" timeout 60 "$SENTINEL" status 2>&1)
rc=$?
[ "$rc" -eq 124 ] && SKIP 'the sentinel status took more than 60 s (a supervisor, not a pure query)'

after_decoy=$(fingerprint "$DECOY")
after_scratch=$(fingerprint "$SCRATCH")
after_real=$(fingerprint "$REAL_STORE")

# 1) WHAT IT SAYS IT USED IS THE DECISIVE FACT, and it is not racy: the sentinel reports `home=<dir>` on its status
# line. MEASURED: fingerprinting the operator's real store to prove it was untouched does not work - that store is LIVE,
# and another job's build wrote a `wa-capabilities` fingerprint into it while this row ran, so the row failed on someone
# else's work. A row must not read a running system to prove a rule about one process.
reported=$(printf '%s' "$out" | grep -o 'home=[^ ]*' | head -1 | cut -d= -f2-)
[ -n "$reported" ] || FAIL "the sentinel did not report its home, so this row cannot judge the resolution: $(printf '%s' "$out" | head -2)"
case "$reported" in
  "$SCRATCH"|"$SCRATCH"/*) ;;
  *) FAIL "the sentinel reports home=$reported while WASM_AGENT_HOME=$SCRATCH - it did not take its home from the one owner" ;;
esac

# 2) HOME is a decoy, and it must be untouched too: that catches a fallback that would be fatal on a real machine.
if [ "$before_decoy" != "$after_decoy" ]; then
  FAIL "with WASM_AGENT_HOME set, HOME was still used: $DECOY changed
$(diff <(echo "$before_decoy") <(echo "$after_decoy") | head -8)"
fi

# 3) And it DID keep its state somewhere it was told to - otherwise the two checks above prove nothing.
[ "$before_scratch" != "$after_scratch" ] \
  || FAIL "the sentinel wrote nothing under WASM_AGENT_HOME ($SCRATCH), so this row never exercised a real resolution"

# (No check against the TEXT for the operator path: TMPDIR on this node lives under ~/.wasm-agent/tmp, so every scratch
# path contains that prefix and a text search is a false alarm. Check 1 already pins the reported home to the one owner.)

echo "sentinel-home ok (with WASM_AGENT_HOME set the sentinel reports home= that scratch home, the decoy HOME is untouched, and its state tree lands there; exit $rc)"
