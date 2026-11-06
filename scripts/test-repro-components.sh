#!/usr/bin/env bash
# Prove that a component's bytes do not depend on WHERE the tree is checked out: the same commit,
# extracted into two differently named paths, built with scripts/build-components.sh, must produce the
# same sha256 (docs/COMPONENTS.md, "Reproducible builds: the checkout path is not an input").
#
#   bash scripts/test-repro-components.sh              # svc-echo and graph (one of each kind)
#   bash scripts/test-repro-components.sh svc-echo     # just one (fast, no C, no wasi-sdk needed)
#
# It is NOT in scripts/fast.sh on purpose: it needs what a component build needs (cargo, the wasm
# targets, wasi-sdk for a component with C inside) and two full component builds, which is minutes.
#
# What it does, in order: extract HEAD into <work>/clone-a and into
# <work>/clone-b-deeper-path/nested (a longer path is the point of the exercise), overlay this
# checkout's uncommitted and untracked files so the proof covers the working tree too, build the named
# components in each with an unshared CARGO_TARGET_DIR, then check every artifact twice: no checkout or
# CARGO_HOME path inside it, and the same sha256 from both paths.
#
# Today (06/11) the first check passes for every component and the second passes for a component
# without a path dependency (`svc-echo`) and fails for one with a path dependency (`graph`,
# `wa-whatsapp`). That is a measured gap in Cargo, not in the wrapper: Cargo's source identity for a
# path package is its canonical absolute path, that hash travels into the dependent's `-C metadata`,
# rustc combines `-C metadata` into symbol names, and a wrapper cannot override a value it did not
# compute. docs/COMPONENTS.md, "Reproducible builds: the checkout path is not an input", has the
# measurements and the three ways to close it.
#
# Exit: 0 identical and path-free; 1 a leaked path or different bytes (both sha256s are printed, with
# which of the two it was); 2 a tool or a build is missing.
# Env: WA_REPRO_DIR=<dir> keeps the two trees (a diagnosis aid: they are removed on exit by default);
#      WA_COMPONENTS_REPRO=0 builds without the path remapping, to show what the paths contribute.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
names=("$@"); [ "${#names[@]}" -gt 0 ] || names=(svc-echo graph)

fail() { printf 'repro: %s\n' "$*" >&2; exit "${2:-2}"; }
say() { printf 'repro: %s\n' "$*"; }

command -v cargo >/dev/null 2>&1 || fail 'cargo_missing'
command -v tar >/dev/null 2>&1 || fail 'tar_missing'
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'; else shasum -a 256 < "$1" | awk '{print $1}'; fi; }
# The two spellings a path has for the toolchain on this machine (see scripts/build-components.sh).
tree_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
win_path() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" | sed 's|/|\\|g' ;;
    *) printf '%s' "$1" ;;
  esac
}
# A path that should never be in a component: a leaked checkout, or a leaked CARGO_HOME.
leaks() { # <wasm> <tree>
  local wasm="$1" tree="$2" p
  for p in "$(tree_path "$tree")" "$(win_path "$tree")" \
           "$(tree_path "${CARGO_HOME:-$HOME/.cargo}")" "$(win_path "${CARGO_HOME:-$HOME/.cargo}")"; do
    [ -n "$p" ] || continue
    grep -a -q -F -- "$p" "$wasm" && printf '%s ' "$p"
  done
}

keep=0
if [ -n "${WA_REPRO_DIR:-}" ]; then work="$WA_REPRO_DIR"; keep=1; else work="$(mktemp -d "${TMPDIR:-/tmp}/wa-repro-XXXXXX")" || fail 'mktemp_failed'; fi
cleanup() { [ "$keep" = 1 ] || rm -rf "$work"; }
trap cleanup EXIT
rm -rf "$work/clone-a" "$work/clone-b-deeper-path"
say "work: $work"

# The same source in both trees: HEAD, plus whatever is uncommitted in this checkout (so a change that
# is not committed yet is still measured, instead of silently proving yesterday's tree). Untracked,
# non-ignored files count too - a new script is part of the build.
overlay() {
  local dst="$1" f
  { git -C "$ROOT" diff --name-only HEAD 2>/dev/null; git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null; } | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
    mkdir -p "$dst/$(dirname "$f")" && cp -p "$ROOT/$f" "$dst/$f" || exit 1
  done
}
extract() {
  local dst="$1"
  mkdir -p "$dst" || return 1
  git -C "$ROOT" archive HEAD | tar -x -C "$dst" || return 1
  overlay "$dst"
}
extract "$work/clone-a" || fail 'extract_failed: clone-a'
extract "$work/clone-b-deeper-path/nested" || fail 'extract_failed: clone-b'

for tree in clone-a clone-b-deeper-path/nested; do
  dir="$work/$tree"
  # `env -u CARGO_TARGET_DIR`: a shared target directory would let the second build reuse the first
  # one's artifacts, and the comparison would pass without building anything.
  say "building ${names[*]} in $dir"
  if ! env -u CARGO_TARGET_DIR WA_COMPONENTS_DIR="$dir/out" bash "$dir/scripts/build-components.sh" "${names[@]}"; then
    fail "build_failed: $dir (needs wasi-sdk for a component with C inside: WASI_SDK=<dir>)"
  fi
done

differ=0
code=0
for name in "${names[@]}"; do
  a="$work/clone-a/out/$name.wasm"
  b="$work/clone-b-deeper-path/nested/out/$name.wasm"
  for f in "$a" "$b"; do [ -f "$f" ] || fail "artifact_missing: $f"; done
  sha_a="$(sha "$a")"; sha_b="$(sha "$b")"
  bytes_a="$(wc -c < "$a" | tr -d '[:space:]')"; bytes_b="$(wc -c < "$b" | tr -d '[:space:]')"
  leak_a="$(leaks "$a" "$work/clone-a")"; leak_b="$(leaks "$b" "$work/clone-b-deeper-path/nested")"
  if [ -n "$leak_a$leak_b" ]; then
    differ=$((differ + 1))
    printf 'repro: PATH LEAK %s: %s%s\n' "$name" "$leak_a" "$leak_b" >&2
    code=1
  fi
  if [ "$sha_a" = "$sha_b" ]; then
    say "same  $name: sha256 $sha_a ($bytes_a bytes, two checkout paths, no path leaked)"
  else
    differ=$((differ + 1))
    printf 'repro: DIFFERENT %s: %s (%s bytes) vs %s (%s bytes)\n' "$name" "$sha_a" "$bytes_a" "$sha_b" "$bytes_b" >&2
    if [ -z "$leak_a$leak_b" ]; then
      printf 'repro: %s carries no leaked path in either build, so the difference is ordering: Cargo gives\n' "$name" >&2
      printf 'repro: a path dependency a metadata hash built from its absolute path, and rustc combines\n' >&2
      printf 'repro: -C metadata into symbol names, so an outside wrapper cannot override it. See\n' >&2
      printf 'repro: docs/COMPONENTS.md, "Reproducible builds", for the measurement and what closes it\n' >&2
    fi
    code=1
  fi
done
if [ "$differ" -gt 0 ]; then
  printf 'repro: %d of %d artifacts depend on the checkout path\n' "$differ" "${#names[@]}" >&2
  printf 'repro: keep both trees with WA_REPRO_DIR=%s and diff them; WA_COMPONENTS_REPRO=0 shows the\n' "$work" >&2
  printf 'repro: paths the remapping takes out (docs/COMPONENTS.md, "Reproducible builds")\n' >&2
  keep=1
  exit 1
fi
say "ok: ${#names[@]} component(s) reproduce byte for byte from two checkout paths"
exit "$code"
