#!/usr/bin/env bash
# A FRESH BUILD OF THIS TREE MUST BE THE BYTES components.lock PINS.
#
# WHY. Two checks judged pins and neither rebuilt one: `scripts/test-component-pins.sh` half 1 compares
# the lock to the SOURCE (a component's tree changed while its line stood still) and half 2 compares the
# lock to a COPY of bytes somebody built. So on 13/11, and again on 23/11, lines sat at artifacts no
# build of main produced - on 23/11 ten of eleven, because the pins had been made on another machine
# with another rustc and, for the five components with a `path =` dependency, in another checkout path.
# A pin nobody can rebuild is a pin nobody can verify, and the deploy's whole claim is that it installs
# exactly these bytes on every node.
#
# WHAT IT DOES. Builds the named components with the shipped pipeline (`scripts/build-components.sh`,
# overriding nothing - not the toolchain, not the build root) into a scratch directory, and compares
# each artifact's sha256 AND size to its own line in components.lock. It greps each artifact for the two
# paths that must never be in it (this checkout, the constant build root), and then builds one component
# WITHOUT the constant root (WA_COMPONENT_STABLE_ROOT=0) and requires the same sha256: that is the check
# that the copy is not itself an input, which is what the whole scheme rests on.
#
#   bash scripts/test-component-lock-rebuild.sh                 # agent-core, hooks, mesh, graph
#   bash scripts/test-component-lock-rebuild.sh --all           # all eleven pinned names
#   bash scripts/test-component-lock-rebuild.sh hooks memory    # named ones
#
# Exit: 0 every measured component is its pin; 1 drift; 2 a tool, the lock or the arguments are wrong.
#
# WHERE IT RUNS: scripts/test.sh (the gate), after the shipped-set row. It needs what a component build
# needs - cargo, the wasm targets, wasi-sdk for `graph` - and minutes, so it is not in scripts/fast.sh.
# Env: WA_LOCK_REBUILD_NO_PARITY=1 skips the no-constant-root comparison (a diagnosis aid).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
cfail() { printf 'lock-rebuild: %s\n' "$*" >&2; exit 2; }
say() { printf 'lock-rebuild: %s\n' "$*" >&2; }

names=()
all=0
for arg in "$@"; do
  case "$arg" in
    --all) all=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) cfail "unknown_option: $arg" ;;
    *) names+=("$arg") ;;
  esac
done
if [ "$all" = 1 ]; then
  names=($(awk '/^[[:space:]]*(#|$)/ {next} $1 != "" && $2 ~ /^[0-9a-f]+$/ {print $1}' components.lock))
fi
[ "${#names[@]}" -gt 0 ] || names=(agent-core hooks mesh graph)

[ -f components.lock ] || cfail 'components_lock_missing'
command -v cargo >/dev/null 2>&1 || cfail 'cargo_missing: this check builds the components; without a toolchain it can only say it did not run'
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'; else shasum -a 256 < "$1" | awk '{print $1}'; fi; }
pin_of() { awk -v n="$1" '$1 == n && $2 ~ /^[0-9a-f]+$/ {print $2 " " $3}' components.lock; }

# Nothing here writes to a node's component directory: the artifacts go to a private directory, and this
# refuses (rather than assumes) if that ever resolves under the real ~/.wasm-agent.
OUT="$(mktemp -d "${TMPDIR:-/tmp}/wa-lock-rebuild-out-XXXXXX")" || cfail 'mktemp_failed: out'
# The node's own component directory, and the agent home itself - not $(TMPDIR), which on this node IS
# a part of the agent home and is where a scratch directory belongs.
real_home="${WASM_AGENT_HOME:-$HOME/.wasm-agent}"
case "$OUT" in
  "$real_home"|"$real_home"/*) case "$OUT" in
    "$real_home"/components|"$real_home"/components/*) cfail "refusing_to_write_the_real_component_directory: $OUT" ;;
  esac ;;
esac
trap 'rm -rf "$OUT"' EXIT
say "out: $OUT (private; the node's own component directory is never written)"
say "components: ${names[*]}"

# THE GUARD THAT SAYS WHY A DIFFERENCE IS NOT A BUILD FAULT: the root and the compiler are recorded in
# components.lock, and a run that would build elsewhere cannot be the pins - refused by name, not
# reported as a drift. The library that knows them is not a test file, so it is absent when this test is
# run against an older tree; then the byte comparison below still does the real job and this line says
# the guard did not run (never that it passed).
if [ -f scripts/lib/component-build-root.sh ]; then
  . scripts/lib/component-build-root.sh
  wa_component_build_inputs_match_lock "$ROOT" ||     cfail 'build_inputs_differ_from_the_lock: this run would not build where, or with what, components.lock records (the line above says which); nothing was rebuilt, so nothing was judged'
else
  say 'build-root guard NOT CHECKED: scripts/lib/component-build-root.sh is missing, so this run cannot say its build root and compiler are the ones components.lock records'
fi

# THE BUILD, through the shipped pipeline and nothing else: the same script a deploy falls back to and a
# publish uses, so what is measured is what ships - not a build with this test's own flags.
WA_COMPONENTS_DIR="$OUT/shipped" bash scripts/build-components.sh "${names[@]}" || \
  cfail "build_failed: scripts/build-components.sh ${names[*]} (needs wasi-sdk for a component with C inside: WASI_SDK=<dir>)"

drift=0
measured=0
for name in "${names[@]}"; do
  wasm="$OUT/shipped/$name.wasm"
  [ -f "$wasm" ] || cfail "artifact_missing: $wasm (the build said it installed nothing for $name)"
  pin="$(pin_of "$name")"
  [ -n "$pin" ] || cfail "component_not_pinned: $name is not in components.lock, so there is nothing to compare it to"
  pin_sha="${pin%% *}"; pin_bytes="${pin##* }"
  got_sha="$(sha "$wasm")"; got_bytes="$(wc -c < "$wasm" | tr -d '[:space:]')"
  measured=$((measured + 1))
  if [ "$got_sha" != "$pin_sha" ] || { [ "$pin_bytes" != - ] && [ "$got_bytes" != "$pin_bytes" ]; }; then
    printf 'lock-rebuild: DRIFT %s: built %s (%s bytes); components.lock pins %s (%s bytes)\n' \
      "$name" "$got_sha" "$got_bytes" "$pin_sha" "$pin_bytes" >&2
    drift=$((drift + 1))
    continue
  fi
  # A leaked path is its own finding even when the sha matches: it is the seed of the next drift, and a
  # copy that carries its own path would make this check pass on this machine and fail on the next.
  for p in "$ROOT" "${WA_COMPONENT_BUILD_ROOT:-${TMPDIR:-/tmp}/wa-component-build}"; do
    if grep -a -q -F -- "$p" "$wasm"; then
      printf 'lock-rebuild: PATH LEAK %s: %s is inside the artifact\n' "$name" "$p" >&2
      drift=$((drift + 1))
    fi
  done
  say "match $name: $got_sha ($got_bytes bytes)"
done

# THE COPY IS NOT AN INPUT (only where the shipped path used one at all). One small component built
# without the constant build root must be the same bytes as the same component built with it - if it is
# not, the copy has become part of the answer and every "same from two checkouts" measurement above is
# about the copy rather than about the tree.
parity=hooks
if [ "${WA_LOCK_REBUILD_NO_PARITY:-}" != 1 ] && [ "${WA_COMPONENT_STABLE_ROOT:-1}" != 0 ]; then
  if WA_COMPONENTS_DIR="$OUT/in-tree" WA_COMPONENT_STABLE_ROOT=0 bash scripts/build-components.sh "$parity" >&2; then
    a="$OUT/shipped/$parity.wasm"; b="$OUT/in-tree/$parity.wasm"
    if [ -f "$a" ] && [ -f "$b" ]; then
      sha_a="$(sha "$a")"; sha_b="$(sha "$b")"
      if [ "$sha_a" = "$sha_b" ]; then
        say "parity $parity: the constant build root changes nothing ($sha_a)"
      else
        printf 'lock-rebuild: PARITY %s: with the constant build root %s, built in the checkout %s - the copy is an input, not a location\n' \
          "$parity" "$sha_a" "$sha_b" >&2
        drift=$((drift + 1))
      fi
    else
      cfail "parity_artifact_missing: $a or $b (one of the two builds installed nothing)"
    fi
  else
    # Not a pass: a check that cannot run is not a check that passed.
    printf 'lock-rebuild: PARITY %s NOT MEASURED: WA_COMPONENT_STABLE_ROOT=0 build failed - the copy-is-not-an-input property is unproven on this run\n' "$parity" >&2
    drift=$((drift + 1))
  fi
fi

if [ "$drift" -gt 0 ]; then
  printf 'lock-rebuild: %d problem(s) over %d measured component(s). A drifted line is either a source change\n' "$drift" "$measured" >&2
  printf 'lock-rebuild: (the pin is stale: repin it from this build with scripts/publish-components.sh), a compiler\n' >&2
  printf 'lock-rebuild: that is not the pinned one (components.lock, "HOW THESE LINES ARE REPRODUCED"), or a path\n' >&2
  printf 'lock-rebuild: that reached the bytes. Never edit the line to match: find out which of the three it is.\n' >&2
  exit 1
fi
say "ok: $measured of ${#names[@]} pinned component(s) build to their own line in components.lock"
exit 0

