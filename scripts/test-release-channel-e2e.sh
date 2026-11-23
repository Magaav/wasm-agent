#!/usr/bin/env bash
# THE CHANNEL STEP, END TO END: `wa release cut`'s `linux` step over the scripts and the build it really runs.
#
# WHY (Fable, 23/11). Every existing row replaced one half of this step with a stand-in: scripts/test-land-linux.lua
# ran the REAL step against a fixture publisher, and scripts/test-linux-channel.sh ran the REAL publisher against a
# fixture builder. `scripts/release-linux.sh` - the part that builds the bytes and stages the bundle from them -
# had therefore never run inside a test at all, and release F's public channel failed on its FIRST real run
# (release-20261123T082627Z-3fc25b76): the build wrote `wa` into the node's one build root, the bundle step looked
# for it in `rust/target/<triple>/release/wa`, and the step died with "no built binary at ...". Two releases in a
# row found this step's bugs only at the real cut.
#
# WHAT THIS WRAPPER OWNS, and nothing else: the scratch HOME (this row signs, commits and rewrites a git
# repository, so it must never be the operator's), the PATH the stand-ins live on, and the fake GitHub. The row
# itself is scripts/test-release-channel-e2e.lua; the stand-ins are named where they are written below.
#
# RUN: bash scripts/test-release-channel-e2e.sh        (prints "release-channel-e2e ok (<n> checks)")
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# NOT under $TMPDIR: a node sets TMPDIR inside its own store (<home>/.wasm-agent/tmp), and a scratch HOME there
# is inside the operator's store - which the row's guard refuses, correctly. /tmp is outside every home.
T=$(mktemp -d /tmp/wa-release-channel-e2e.XXXXXX) || { printf 'FAIL tmpdir_unavailable\n' >&2; exit 1; }
# WA_E2E_KEEP=1 keeps the work directory and prints it, so a failing row leaves its evidence behind.
if [ "${WA_E2E_KEEP:-0}" = 1 ]; then printf 'workdir %s\n' "$T" >&2; else trap 'rm -rf "$T"' EXIT; fi
# THE HOME THIS ROW WRITES IS ITS OWN, and it says so before it writes anything: this row runs the release step,
# which signs, commits and pushes into a git repository under the home it is given.
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
# The home this node had BEFORE WASM_AGENT_HOME replaced it: the launcher records it, the row's guard judges it
# (scripts/lib/scratch-home.lua says why: inside a node HOME == WASM_AGENT_HOME by construction).
export WA_HOME_BEFORE_OVERRIDE="$original_home"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || { printf 'no wa binary at %s (build it first, or set WA_BIN)\n' "$BIN" >&2; exit 2; }

mkdir -p "$T/bin" "$T/gh" "$T/cargo-target" "$HOME/.wasm-agent/build/target"
# THE FAKE GITHUB is the shared one (scripts/lib/fake-gh.sh), so this row and the publisher's own row are held to
# one fake instead of two that drift.
# shellcheck source=lib/fake-gh.sh
. "$ROOT/scripts/lib/fake-gh.sh"
wa_fake_gh_install "$T/bin" || { printf 'FAIL fake_gh_unavailable\n' >&2; exit 1; }
export FAKE_GH_STATE="$T/gh"

# THE BUILD STAND-IN. `node scripts/codemode-build.mjs build <tree> --target <triple>` is the ONE call this row
# answers itself: the real shipping build compiles the whole node for two triples and downloads nothing here, so
# the stand-in writes a RECEIPT of the real shape (scripts/codemode-build.mjs) and a real executable at the path
# that receipt names - which is the point of the row, because the real build writes into the node's one build root
# (`<home>/.wasm-agent/build/target/<tree>/<triple>/release/wa`, docs/ONEROOT.md) and NOT into `rust/target`.
# Every other `node` call in the tree (the receipt reader, the index writer) is passed to the real node.
WA_REAL_NODE="$(command -v node)" || { printf 'FAIL node_missing\n' >&2; exit 1; }
export WA_REAL_NODE WA_FAKE_BUILD_ROOT="$HOME/.wasm-agent/build/target"
cat > "$T/bin/node" <<'NODE'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  */codemode-build.mjs)
    action=${2:-}; root=${3:-}; [ "$#" -ge 3 ] && shift 3
    target=; while [ "$#" -gt 0 ]; do case "$1" in --target) target=${2:-}; shift 2 ;; *) shift ;; esac; done
    [ "$action" = build ] || { printf 'stand-in: codemode-build.mjs only answers build\n' >&2; exit 1; }
    [ "${WA_FAKE_BUILD_FAIL:-0}" = 1 ] && { printf 'stand-in: the build refused\n' >&2; exit 9; }
    sha=$(git -C "$root" rev-parse HEAD) || exit 1
    tree=$(git -C "$root" rev-parse 'HEAD^{tree}') || exit 1
    sha=${WA_FAKE_BUILD_COMMIT:-$sha}; tree=${WA_FAKE_BUILD_TREE:-$tree}
    dir="$WA_FAKE_BUILD_ROOT/tree-0123456789ab"; [ -n "$target" ] && dir="$dir/$target"
    mkdir -p "$dir/release"
    bin="$dir/release/wa"
    printf '#!/bin/sh\n# the fixture wa, built from %s\n[ "$1" = --version ] && { echo "wa 0.1.0 (%s)"; exit 0; }\nexit 0\n' \
      "$sha" "${sha:0:8}" > "$bin" || exit 1
    chmod +x "$bin"
    [ "${WA_FAKE_BUILD_NO_BINARY:-0}" = 1 ] && rm -f "$bin"
    bin_sha=$(sha256sum "$bin" 2>/dev/null | cut -d' ' -f1)
    target_json=null; [ -n "$target" ] && target_json="\"$target\""
    printf '{"build_schema":1,"kind":"codemode-offline-build","ok":true,"target":%s,"binary":"%s","binary_sha256":"%s","source_commit":"%s","source_tree":"%s","source_dirty":false,"root":"%s"}\n' \
      "$target_json" "$bin" "$bin_sha" "$sha" "$tree" "$(CDPATH= cd -- "$root" && pwd -P)"
    exit 0 ;;
esac
exec "$WA_REAL_NODE" "$@"
NODE
chmod +x "$T/bin/node"
# THE CARGO STAND-IN: answers the calls scripts/release-linux.sh makes and, for the sentinel build, prints the
# `compiler-artifact` message that NAMES the executable - cargo's own answer, which the script now reads instead
# of guessing `rust/wa-sentinel/target/<triple>/release/wa-sentinel`. `zig` is not installed on a test machine.
export WA_FAKE_CARGO_DIR="$T/cargo-target"
cat > "$T/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  --version) echo 'cargo 1.89.0 (fixture)'; exit 0 ;;
  fetch) exit 0 ;;
  build|zigbuild)
    dir="$WA_FAKE_CARGO_DIR/release"; mkdir -p "$dir" || exit 1
    printf '#!/bin/sh\necho "wa-sentinel 0.1.0 (fixture)"\n' > "$dir/wa-sentinel" || exit 1
    chmod +x "$dir/wa-sentinel"
    if [ "${WA_FAKE_CARGO_SILENT:-0}" != 1 ]; then
      printf '{"reason":"compiler-artifact","target":{"kind":["bin"],"name":"wa-sentinel","crate_types":["bin"]},"executable":"%s"}\n' "$dir/wa-sentinel"
    fi
    printf '{"reason":"build-finished","success":true}\n'
    printf '    Finished `release` profile [optimized] target(s) (fixture)\n' >&2
    exit 0 ;;
esac
printf 'stand-in cargo: unsupported %s\n' "$*" >&2; exit 1
CARGO
chmod +x "$T/bin/cargo"
ln -sf "$T/bin/cargo" "$T/bin/cargo-zigbuild"
printf '#!/bin/sh\nprintf "rustc 1.89.0 (fixture %%s)\\n" "$*"\n' > "$T/bin/rustc"
chmod +x "$T/bin/rustc"
export PATH="$T/bin:$PATH"

log="$T/row.log"
WASM_AGENT_MANAGED=0 WA_SCRIPT="$ROOT/scripts/test-release-channel-e2e.lua" "$BIN" --db "$T/db.sqlite" >"$log" 2>&1
rc=$?
tail -40 "$log"
if [ "$rc" = 0 ] && grep -q 'release-channel-e2e ok' "$log"; then exit 0; fi
printf 'release-channel-e2e FAILED (exit %s)\n' "$rc" >&2
exit 1
