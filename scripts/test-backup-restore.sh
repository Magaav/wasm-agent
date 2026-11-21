#!/usr/bin/env bash
# wa backup / wa restore against a REAL SQLite ledger, in a scratch home this script owns.
#
#   bash scripts/test-backup-restore.sh
#
# The Lua half is scripts/test-backup-restore.lua: it takes a snapshot, restores it, and holds five
# refusals. This wrapper exists for two reasons, and both are the harness's, not the test's:
#   * the row needs a real binary and a real ledger (`wa --db`), which a Lua row inside the node cannot
#     open a second time;
#   * the scratch home has to be proven NOT to be the operator's before anything runs (the test asserts
#     it again from inside, because a wrapper that stops doing it must not turn into a test that writes
#     the real ~/.wasm-agent).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$(command -v wa || true)"
[ -x "$BIN" ] || { echo 'SKIP test-backup-restore: no wa binary to run the row with'; exit 0; }
# A scratch root under the caller's TMPDIR, on the same filesystem as the repo when that is possible:
# /tmp is a tmpfs on this node and it ran out of space mid-test (measured 19/11: "disk I/O error" from
# SQLite at 80% full, which looked like a restore defect and was the filesystem). WA_TEST_ROOT lets a
# caller put it somewhere with room; the default is a directory BESIDE the repo, never under it.
SCRATCH="${WA_TEST_ROOT:-$(dirname "$ROOT")/.wa-test-backup-restore-$$}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/home" || exit 2
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
home="$SCRATCH/home"
# The rule, checked here as well: the home this run gives the test is never the operator's own.
# The scratch home is compared against the RIGHT side (item 4 of the node-ops round):
# WASM_AGENT_HOME is the USER home (rust/wa-host-support/src/paths.rs:12), and the node store
# hangs off it as <home>/.wasm-agent. The guard refuses the real $HOME, the real store, anything
# inside it and anything above it - the measurements are in scripts/lib/scratch-home.sh.
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$home" || exit 2
out="$(WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$ROOT" WA_SCRIPT=scripts/test-backup-restore.lua \
  "$BIN" --db "$SCRATCH/ledger.db" 2>&1)"
code=$?
printf '%s\n' "$out" | tail -5
[ "$code" = 0 ] || exit "$code"
printf '%s\n' "$out" | grep -q 'backup restore ok' || { echo 'test-backup-restore: the row exited 0 without its verdict line' >&2; exit 1; }
