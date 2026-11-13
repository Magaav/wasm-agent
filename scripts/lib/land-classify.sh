#!/usr/bin/env bash
# Which path is which KIND of change - the classification `wa land` plans a round with.
#
# WHY. A landing round cost ~40 minutes every time (measured by hand, 13/11): merge, a code-mode build, the
# fast gate, a cross-build of BOTH Linux targets (even when no compiled input changed), sign+publish, and four
# deploys in series. Most of that day's branches were Lua-only, so most of the round was spent paying for work
# the round did not need. The planner needs one answer per changed path, and the answer has to be the SAME
# classifier every other part of this tree already uses - otherwise "this change needs no new binary" (the
# deploy's Lua fast path), "that release IS this commit's binary" (the release digest fallback) and "this round
# needs no cross-build" could disagree about the same file, and a node would install something the planner
# said could not exist.
#
# WHAT IS NOT SPELLED HERE: what "compiled" means. `wa_compiled_input` (scripts/lib/node-binaries.sh) is the
# one definition - rust/, wit/, Cargo files, the code-mode build inputs, config, lock files - and this script
# only adds the two categories the planner needs on top of it:
#
#   component   a path that compiles into the shipped WASI component bundle and NOT into the node binary:
#               `rust/components/**` (each component is its own cargo workspace, built to wasm) and
#               `components.lock` (the pins a deploy installs). A change here needs the bundle rebuilt and
#               repinned, and no new node binary.
#   lua         everything a node LOADS from its installed tree or only reloads: lua/, ui/, modules/, jobs/,
#               scripts/, tests/, fixtures/, vault/ - not compiled (wa_compiled_input says so), but a node
#               must be given the bytes.
#   docs        a markdown document or a review artefact: no build, no release, no deploy.
#
# A shared crate is NOT `component` even though a component uses it: `rust/wa-whatsapp-outbox` is also a
# member of the node's own workspace, so changing it changes the binary and takes the full path. A component
# whose own crate changed gets `component`, and the pins it ships are `components.lock` - which this
# classification puts in the same category, so the repin check runs in the same round as the change.
#
# Usage:
#   bash scripts/lib/land-classify.sh --repo <dir> --paths <file>   one "<class>\t<path>" line per path
#   bash scripts/lib/land-classify.sh --repo <dir> <path>...        the same, paths as arguments
#   bash scripts/lib/land-classify.sh --category --repo <dir> --paths <file>
#                                                                  one word: docs-only | lua-scripts-only |
#                                                                  components | compiled (the strongest wins)
#
# Exit codes: 0 classified; 2 a missing argument, a missing path list or a missing classifier library.
set -uo pipefail

REPO=""
PATHS_FILE=""
CATEGORY=0
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || { printf 'land-classify: repo_value_required\n' >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --paths) [ "$#" -ge 2 ] || { printf 'land-classify: paths_value_required\n' >&2; exit 2; }; PATHS_FILE="$2"; shift 2 ;;
    --category) CATEGORY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'land-classify: unknown_option: %s\n' "$1" >&2; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ -n "$REPO" ] || REPO="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LIB="$REPO/scripts/lib/node-binaries.sh"
[ -f "$LIB" ] || LIB="$SELF_DIR/node-binaries.sh"
[ -f "$LIB" ] || { printf 'land-classify: classifier_missing: %s (scripts/lib/node-binaries.sh, the one definition of a compiled input)\n' "$LIB" >&2; exit 2; }
# shellcheck source=lib/node-binaries.sh
. "$LIB"

wa_land_class() { # <path> -> one word on stdout
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    rust/components/*|components.lock)
      # A component's own source, or the pins that name the bundle a deploy installs.
      printf 'component\n'; return 0 ;;
  esac
  if wa_compiled_input "$path"; then printf 'compiled\n'; return 0; fi
  case "$path" in
    docs/*|review/*|reviews/*|review-evidence/*|benchmarks/*|skills/*) printf 'docs\n'; return 0 ;;
    *.md) printf 'docs\n'; return 0 ;;
  esac
  printf 'lua\n'
}

wa_land_category() { # reads "<class> <path>" lines on stdin -> the strongest category
  local class strongest=docs
  # Every line is read, even once `compiled` is seen: returning early closes the pipe under the caller's
  # `emit` and the writer dies on SIGPIPE (measured: exit 141 on a 7-path list that contained rust/).
  while IFS=$' \t' read -r class _; do
    case "$class" in
      compiled) strongest=compiled ;;
      component) [ "$strongest" = compiled ] || strongest=components ;;
      lua) case "$strongest" in compiled|components) : ;; *) strongest=lua ;; esac ;;
      docs) : ;;
    esac
  done
  case "$strongest" in
    compiled) printf 'compiled\n' ;;
    components) printf 'components\n' ;;
    lua) printf 'lua-scripts-only\n' ;;
    *) printf 'docs-only\n' ;;
  esac
}

emit() {
  local path
  if [ -n "$PATHS_FILE" ]; then
    [ -f "$PATHS_FILE" ] || { printf 'land-classify: paths_unreadable: %s\n' "$PATHS_FILE" >&2; exit 2; }
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf '%s\t%s\n' "$(wa_land_class "$path")" "$path"
    done < "$PATHS_FILE"
  else
    local item
    for item in ${ARGS+"${ARGS[@]}"}; do
      [ -n "$item" ] || continue
      printf '%s\t%s\n' "$(wa_land_class "$item")" "$item"
    done
  fi
}

if [ "$CATEGORY" = 1 ]; then
  emit | wa_land_category
else
  emit
fi
