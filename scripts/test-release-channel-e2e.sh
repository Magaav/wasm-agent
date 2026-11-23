#!/usr/bin/env bash
# THE CHANNEL STEP, END TO END: `wa release cut`'s `linux` step over the scripts and the build it really runs.
#
# WHY (Fable, 23/11). Every earlier row replaced one half of this step with a stand-in: scripts/test-land-linux.lua
# ran the REAL step against a fixture publisher, and scripts/test-linux-channel.sh ran the REAL publisher against a
# fixture builder. `scripts/release-linux.sh` - the part that builds the bytes and stages the bundle from them -
# had never run inside a test, and release F's public channel failed on its FIRST real run
# (release-20261123T082627Z-3fc25b76): the build wrote `wa` into the node's one build root, the bundle step looked
# for it in `rust/target/<triple>/release/wa`, and the step died with "no built binary at ...".
#
# WHAT THIS WRAPPER IS, AND IS NOT. It is a convenience for a human: a scratch HOME (the row signs, commits and
# rewrites a git repository) that refuses to be the operator's, and the call. It owns NO part of the test any
# more: the stand-ins (the build, cargo, the fake GitHub) and their PATH live IN THE ROW
# (scripts/test-release-channel-e2e.lua, "the stand-ins, IN THE ROW"), because the LANDING runs a branch's own
# row as `WA_SCRIPT=<row> wa` - with no wrapper at all. Round 1 of this branch's gate measured exactly that: the
# row was red under the landing and green by hand, which is a row that depends on the shell that ran it.
#
# RUN: bash scripts/test-release-channel-e2e.sh      (prints "release-channel-e2e ok (<n> checks)")
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/wa-release-channel-e2e.XXXXXX") || { printf 'FAIL tmpdir_unavailable\n' >&2; exit 1; }
# WA_E2E_KEEP=1 keeps the work directory and prints it, so a failing run leaves its evidence behind.
if [ "${WA_E2E_KEEP:-0}" = 1 ]; then printf 'workdir %s\n' "$T" >&2; else trap 'rm -rf "$T"' EXIT; fi
# THE HOME THIS ROW WRITES IS ITS OWN, and it says so before it writes anything.
original_home="${WA_HOME_BEFORE_OVERRIDE:-${HOME:-}}"
unset WASM_AGENT_HOME
export HOME="$T/home"
mkdir -p "$HOME"
if [ -n "$original_home" ] && [ "$(cd "$HOME" && pwd -P)" = "$(cd "$original_home" 2>/dev/null && pwd -P)" ]; then
  printf 'REFUSED scratch_home_is_real: refusing to run in %s\n' "$HOME" >&2; exit 2
fi
export XDG_CACHE_HOME="$T/cache" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email fixture@example.invalid
git config --global user.name "Release channel fixture"
git config --global init.defaultBranch main
# The node's store hangs off WASM_AGENT_HOME, and the row's own guard (scripts/lib/scratch-home.lua) proves it is
# not the operator's: the launcher sets HOME from this, so both must name the scratch home.
export WASM_AGENT_HOME="$HOME" WASM_AGENT_LUA_ROOT="$ROOT"
export WA_HOME_BEFORE_OVERRIDE="$original_home"
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || { printf 'no wa binary at %s (build it first, or set WA_BIN)\n' "$BIN" >&2; exit 2; }

log="$T/row.log"
WA_SCRIPT="$ROOT/scripts/test-release-channel-e2e.lua" "$BIN" --db "$T/db.sqlite" >"$log" 2>&1
rc=$?
tail -40 "$log"
if [ "$rc" = 0 ] && grep -q 'release-channel-e2e ok' "$log"; then exit 0; fi
printf 'release-channel-e2e FAILED (exit %s)\n' "$rc" >&2
exit 1
