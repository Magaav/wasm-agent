#!/usr/bin/env bash
# A LANDING THAT TOUCHES A COMPONENT'S INPUTS MUST PROVE ITS PIN REBUILDS.
#
# WHY (27/11). `components.lock` pinned wa-whatsapp at bytes built with `WA_COMPONENT_TOOLCHAIN=1.100.0` -
# the diagnosis override the build script itself says is "a build whose bytes are not the pinned ones" -
# while the tree's own compiler builds something else. Every publish after that landing was refused
# `artifact_not_pinned`, for hours, and every check that ran at landing time was green: `test-components-
# lock-follows-source.lua` compares the lock to the SOURCES, and the sources never moved. Nothing compared
# "what this tree builds" with "what this tree pins".
#
# WHAT IT DOES. Takes the two commits a landing is about to merge, lists the files between them, and asks
# each pin's own closure (`scripts/lib/components_sources.lua`, the same one the `# SOURCES` line hashes)
# whether any of those files reach its bytes. For every component whose inputs moved it rebuilds with the
# shipped pipeline and refuses when the artifact is not the line in components.lock.
#
#   bash scripts/landing-component-gate.sh <base> <head>
#
# Exit: 0 nothing touched, or every touched component rebuilds to its own pin
#       1 a touched component does not rebuild to its pin (the landing must refuse, with this line)
#       2 the arguments, the tree or a tool are wrong (unknown, never a pass)
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2

base="${1:-}"
head="${2:-}"
if [ -z "$base" ] || [ -z "$head" ]; then
  echo "usage: bash scripts/landing-component-gate.sh <base> <head>" >&2
  exit 2
fi
if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null || ! git rev-parse --verify --quiet "$head^{commit}" >/dev/null; then
  echo "landing-component-gate: unknown commit ($base, $head)" >&2
  exit 2
fi

# The branch's own tree, because the pin being judged is the branch's:
# a temp worktree at $head so the lock and the Cargo.tomls are the ones that would land.
# The throw-away tree lives under the agent home, never /tmp: the node resolves a script path
# against its own root and a /tmp tree is unreachable from it (measured 27/11).
mkdir -p "$HOME/.wasm-agent/tmp" || exit 2
tree="$(mktemp -d -p "$HOME/.wasm-agent/tmp" gate-XXXXXX)"
cleanup() {
  git worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
}
trap cleanup EXIT
if ! git worktree add --detach "$tree" "$head" >/dev/null 2>&1; then
  echo "landing-component-gate: cannot check out $head in a throw-away worktree" >&2
  exit 2
fi

# The closure row and the library it reads travel WITH the gate: the tree being judged may predate them
# (a historical commit), and what must be read there is that tree's lock and Cargo.tomls, not its helpers.
mkdir -p "$tree/scripts/lib" || exit 2
cp -f "$ROOT/scripts/lib/component-closures.lua" "$tree/scripts/lib/component-closures.lua" || exit 2
cp -f "$ROOT/scripts/lib/components_sources.lua" "$tree/scripts/lib/components_sources.lua" || exit 2

changed="$(git diff --name-only "$base...$head" || true)"
if [ -z "$changed" ]; then
  echo "landing-component-gate: ${base:0:12}...${head:0:12} changes nothing"
  exit 0
fi

wa="$(command -v wa || true)"
if [ -z "$wa" ]; then
  echo "landing-component-gate: no wa binary on PATH, so the closures cannot be read (unknown, not a pass)" >&2
  exit 2
fi
home="$(mktemp -d -p "$HOME/.wasm-agent/tmp" gatehome-XXXXXX)"
closures="$(cd "$tree" && WASM_AGENT_HOME="$home" WASM_AGENT_LUA_ROOT="$tree" WASM_AGENT_MANAGED=0 \
  WA_SCRIPT="$tree/scripts/lib/component-closures.lua" "$wa" --db "$home/t.db" 2>&1)"
status=$?
rm -rf "$home"
if [ $status -ne 0 ]; then
  echo "landing-component-gate: the closures could not be read: $closures" >&2
  exit 2
fi

touched=""
while IFS=$'\t' read -r name dirs; do
  [ -n "${name:-}" ] || continue
  IFS=$'\t' read -r -a list <<< "$dirs"
  for dir in "${list[@]}"; do
    if printf '%s\n' "$changed" | grep -q "^${dir%/}/"; then
      touched="$touched $name"
      break
    fi
  done
done <<< "$closures"

touched="$(printf '%s\n' $touched | sort -u | tr '\n' ' ' | sed 's/ *$//')"
if [ -z "$touched" ]; then
  echo "landing-component-gate: no pinned component's inputs moved in ${base:0:12}...${head:0:12}"
  exit 0
fi
echo "landing-component-gate: inputs of $touched moved - rebuilding each against its own pin"

# The rebuild is the one script that must come from the tree being judged: it builds THAT tree. A tree
# without it cannot answer, and an unanswerable gate is exit 2, never a pass.
if [ ! -f "$tree/scripts/test-component-lock-rebuild.sh" ]; then
  echo "landing-component-gate: ${head:0:12} has no scripts/test-component-lock-rebuild.sh, so its pin cannot be rebuilt (unknown, not a pass)" >&2
  exit 2
fi

if ! bash "$tree/scripts/test-component-lock-rebuild.sh" $touched; then
  echo "component_not_reproducible: the tree at ${head:0:12} does not build $touched to the line components.lock pins (see the build above); commit the pin with the change, built with the tree's own toolchain"
  exit 1
fi
echo "landing-component-gate: $touched rebuild to their own pins"
exit 0
