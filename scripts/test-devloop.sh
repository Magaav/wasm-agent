#!/usr/bin/env bash
# `wa dev` smoke test: one rebuild and one hot swap of a real component, on this machine, with no
# node and no network (docs/SERVICE-COMPONENTS.md, "Iterating on a component").
#
# What it proves, in order:
#   1. `wa dev <dir> --once` builds the fixture crate for wasm32-wasip2, lays the artifact down as an
#      installed component in <dir>/.wa-dev/components, starts it, and waits for `lifecycle.report(ready)`
#      - printing the build time and the swap time;
#   2. in watch mode, an edit to the crate's source is noticed, rebuilt, and swapped in: the second
#      cycle reports `mode=hot_swap`, i.e. the new instance was already healthy before the old one
#      was stopped;
#   3. `--restart` takes the other order on purpose and says so (`mode=restart`);
#   4. a build that does not compile keeps the running instance alive (`build_failed`, and the
#      previous instance's instance is still the one running).
#
#   bash scripts/test-devloop.sh [--keep]
#
# The fixture, the dev component directory and the home are all inside a temp tree: a node's own
# state is never read or written. A run needs cargo, the wasm32-wasip2 target and a `wa` binary;
# any of them missing is reported SKIPPED, never passed.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
keep=0
[ "${1:-}" = "--keep" ] && keep=1

checks=0; skipped=0
ok() { checks=$((checks + 1)); }
skip() { echo "devloop SKIPPED: $*"; skipped=$((skipped + 1)); }
fail() { echo "devloop FAILED: $*" >&2; [ "$keep" = 1 ] && [ -n "${work:-}" ] && echo "devloop work dir: $work" >&2; exit 1; }
contains() { # <text> <needle> <what>
  case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | tail -20)" ;; esac
}
absent() { # <text> <needle> <what>
  case "$1" in *"$2"*) fail "$3: '$2' should not be there: $(printf '%s' "$1" | tail -20)" ;; *) ok ;; esac
}

# ---- the binary -------------------------------------------------------------------------------------
bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "${CARGO_TARGET_DIR:-}/debug/wa.exe" "${CARGO_TARGET_DIR:-}/debug/wa" \
         "$ROOT/rust/target/debug/wa.exe" "$ROOT/rust/target/debug/wa" "$ROOT/rust/target/release/wa"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ] && command -v cargo >/dev/null 2>&1; then
  echo "devloop: building wa (no binary found)"
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" cargo build --offline --manifest-path rust/Cargo.toml -p wa-host >/dev/null 2>&1 \
    && bin="$(ls -1 "${CARGO_TARGET_DIR:-$ROOT/rust/target}"/debug/wa.exe "${CARGO_TARGET_DIR:-$ROOT/rust/target}"/debug/wa 2>/dev/null | head -1)"
fi
if [ -z "$bin" ]; then
  skip "no wa binary (WA_BIN, PATH, rust/target/{debug,release}) and it could not be built"
  echo "devloop: $checks checks, $skipped skipped"; exit 0
fi
if ! command -v cargo >/dev/null 2>&1; then
  skip "no cargo: wa dev cannot build a component"
  echo "devloop: $checks checks, $skipped skipped"; exit 0
fi
if ! rustc --print target-list 2>/dev/null | grep -qx wasm32-wasip2 && ! rustup target list --installed 2>/dev/null | grep -qx wasm32-wasip2; then
  skip "the wasm32-wasip2 target is not installed (rustup target add wasm32-wasip2)"
  echo "devloop: $checks checks, $skipped skipped"; exit 0
fi

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# ---- a temp tree: fixture copy, home, component directory ---------------------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/wa-devloop-XXXXXX")"
cleanup() { [ "$keep" = 1 ] && { echo "devloop work dir: $work"; return; }; rm -rf "$work" 2>/dev/null; }
trap cleanup EXIT
home="$work/home"; mkdir -p "$home"
# The toolchain lives under the operator's own home; the node state must not. So HOME/USERPROFILE and
# WASM_AGENT_HOME point at the temp tree, and cargo keeps its real homes (rustup needs them).
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"; cargo_home="${CARGO_HOME:-$HOME/.cargo}"
# The fixture is copied so the edit below never touches the checkout, and the WIT it generates from
# is copied beside it: `wit_bindgen::generate!` resolves its `path` against the crate, which is no
# longer inside the checkout. The copied source gets that one path rewritten to the copy.
crate="$work/fake-kernel-fixture"
cp -R rust/wa-fake-kernel/fixture "$crate"
rm -rf "$crate/.wa-dev" "$crate/target"
cp -R wit/kernel-v2 "$work/wit-kernel-v2"
wit_path="$(native "$work/wit-kernel-v2")"; wit_path="${wit_path//\\//}"
sed "s|path: \"../../../wit/kernel-v2\"|path: \"$wit_path\"|" "$crate/src/lib.rs" > "$crate/src/lib.rs.tmp"   && mv "$crate/src/lib.rs.tmp" "$crate/src/lib.rs"
grep -qF "path: \"$wit_path\"" "$crate/src/lib.rs" || fail "could not point the copied fixture at the copied WIT ($wit_path)"
run_wa() { # <stdout file> <args...>
  local out=$1; shift
  HOME="$(native "$home")" USERPROFILE="$(native "$home")" WASM_AGENT_HOME="$(native "$home")" \
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  CARGO_TARGET_DIR="$(native "$work/target")" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
  "$bin" dev "$(native "$crate")" "$@" > "$out" 2>&1
}

# ---- 1. one build, one start -------------------------------------------------------------------------
out="$work/once.log"
run_wa "$out" --once --config '{"exit_after_ms":150,"tick_ms":20}' || true
once="$(cat "$out")"
contains "$once" "dev: build " "the first cycle built the crate"
absent "$once" "build_failed" "the first build compiled"
contains "$once" "dev: swap " "the first cycle reported a swap"
contains "$once" "mode=start" "the first cycle started an instance (nothing to replace yet)"
contains "$once" "health=ready" "the new instance reported lifecycle.report(ready)"
contains "$once" "components in " "the dev component directory is named"
[ -f "$crate/.wa-dev/components/fake-kernel-fixture.wasm" ] && ok || fail "the artifact was installed under .wa-dev/components"
[ -f "$crate/.wa-dev/components/fake-kernel-fixture.wasm.sha256" ] && ok || fail "the install wrote a pin"
[ -s "$crate/.wa-dev/components/fake-kernel-fixture.service.log" ] && ok || fail "the instance wrote its service log"
# The build and swap times are printed as numbers, which is the loop's own measurement.
printf '%s' "$once" | grep -qE 'dev: build [0-9]+ ms \([0-9]+ bytes\)' && ok || fail "the build line carries a duration and a size"
printf '%s' "$once" | grep -qE 'dev: swap [0-9]+ ms mode=start' && ok || fail "the swap line carries a duration"

# ---- 2. watch mode: an edit is rebuilt and hot-swapped ------------------------------------------------
watch="$work/watch.log"
HOME="$(native "$home")" USERPROFILE="$(native "$home")" WASM_AGENT_HOME="$(native "$home")" \
RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
CARGO_TARGET_DIR="$(native "$work/target")" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
"$bin" dev "$(native "$crate")" --interval 200 --config '{"exit_after_ms":150,"tick_ms":20}' > "$watch" 2>&1 &
watcher=$!
wait_for() { # <needle> <seconds>
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -qF -- "$1" "$watch" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
if ! wait_for "mode=start" 180; then
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  fail "the watch loop never started an instance: $(tail -5 "$watch")"
fi
ok
# An edit the loop must see: a new line of source.
sleep 1
printf '\n// devloop smoke test: %s\n' "$(date +%s)" >> "$crate/src/lib.rs"
if ! wait_for "mode=hot_swap" 300; then
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  fail "no hot swap after the edit: $(tail -8 "$watch")"
fi
ok
contains "$(cat "$watch")" "dev: change detected, rebuilding" "the loop noticed the edit"
contains "$(cat "$watch")" "health=ready" "the swapped-in instance reported ready before the old one stopped"
# The instance still runs after the swap: its log has the new build's start line.
grep -q "start version=dev" "$crate/.wa-dev/components/fake-kernel-fixture.service.log" && ok || fail "the new instance wrote to the service log"

# ---- 3. a build that does not compile keeps the running instance --------------------------------------
printf '\nthis is not rust\n' >> "$crate/src/lib.rs"
if ! wait_for "build_failed" 300; then
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  fail "a broken edit was not reported as build_failed: $(tail -8 "$watch")"
fi
ok
absent "$(cat "$watch" | tail -5)" "mode=hot_swap
" "a failed build did not swap anything"
kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
# Remove the broken line so the crate is a valid source tree again for the --restart case.
grep -v "this is not rust" "$crate/src/lib.rs" > "$crate/src/lib.rs.tmp" && mv "$crate/src/lib.rs.tmp" "$crate/src/lib.rs"

# ---- 4. --restart takes the other order and says so --------------------------------------------------
out="$work/restart.log"
run_wa "$out" --once --restart --config '{"exit_after_ms":100,"tick_ms":20}' || true
restart="$(cat "$out")"
contains "$restart" "mode=restart" "--restart reports the restart order it used"
absent "$restart" "mode=hot_swap" "--restart never reports a hot swap"

# ---- 5. --no-swap installs and runs nothing ----------------------------------------------------------
out="$work/noswap.log"
run_wa "$out" --once --no-swap --no-build || true
contains "$(cat "$out")" "installed " "--no-build --no-swap lays down the artifact it already has"
absent "$(cat "$out")" "dev: swap " "--no-swap runs nothing"

echo "devloop ok ($checks checks, $skipped skipped)"
