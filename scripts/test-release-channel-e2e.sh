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
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
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
# NOTHING LIVE IS INHERITED (Fable, 25/11 decision: every scratch run gets a scratch install, unit dir, DB
# and config home, and this row is no exception - it runs scripts/release-linux.sh, which builds a bundle and
# shells out to cargo, node and git). Each name below is one way a child could reach the operator's own
# install, systemd unit, database or vault; they are dropped HERE, before anything runs, rather than trusted
# to the caller. The row itself never installs anything (install.sh and bootstrap.sh travel INSIDE the bundle
# this row checks, and the sentinel is a stand-in), so this is defence in depth, and it is checkable: run
# scripts/_orch/scratch-guard.sh against "$T" with this environment and it answers ISOLATED.
# THE GUARD'S OWN VARIABLES ARE NEVER STRIPPED (Fable, 25/11, rule 1). WASM_AGENT_IN_TURN is what makes
# deploy.sh / upgrade.sh refuse to run inside a turn, and WASM_AGENT_PROVENANCE=child is what makes "wa update"
# answer update_coordinator_only (lua/core/update.lua:824): a child that loses them can do exactly what the
# guard exists to refuse, which is how the live unit was rewritten tonight. So they are carried through
# UNTOUCHED and only a LIVE POINTER is dropped. This is the repository's own fence in verify/slice.sh:14-22 -
# a keep-list, never a blanket clear - and this row follows it instead of inventing one.
while IFS= read -r variable; do
  case "$variable" in
    # the caller's one input to this row; HOME, WASM_AGENT_HOME and WASM_AGENT_LUA_ROOT are set BELOW from
    # this run's own scratch root, so a caller's values are dropped like any other live pointer
    WA_BIN) continue ;;
    # the guards': never ours to clear
    WASM_AGENT_IN_TURN|WASM_AGENT_PROVENANCE|WASM_AGENT_SKIP_UI_TESTS) continue ;;
    # ONLY the runtime families are dropped - never PATH, HOME, TERM or anything the shell itself needs. The
    # first shape of this fence said "unset everything else" and took PATH with it (measured: "git: No such
    # file or directory", "HOME: unbound variable", rm missing) - a fence that strips too much is the same
    # failure it exists to prevent. verify/slice.sh:14-22 names the same three families.
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)
mkdir -p "$T/config" "$T/units" "$T/install" "$T/bin"
export XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state"
export WA_INSTALL_DIR="$T/install" WA_SENTINEL_UNIT_DIR="$T/units"
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
