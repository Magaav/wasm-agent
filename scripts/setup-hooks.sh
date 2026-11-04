#!/usr/bin/env bash
# Arm this checkout's git hooks (.githooks: CRLF + main guard + generated prompt docs, commit-msg,
# pre-push). One command for a fresh clone:   bash scripts/setup-hooks.sh
# deploy.sh runs it on the tree it deploys from, so a node's runtime checkout is armed by default.
#
# Idempotent. An explicit core.hooksPath that points elsewhere (including the empty value
# scripts/merge-lane.mjs uses to disarm a scratch clone on purpose) is respected and reported.
set -uo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "setup-hooks: $root is not a git checkout" >&2; exit 1; }
for hook in "$root"/.githooks/*; do [ -f "$hook" ] && [ ! -x "$hook" ] && chmod +x "$hook"; done
if current="$(git -C "$root" config --local --get core.hooksPath)"; then
  if [ "$current" = ".githooks" ] || [ "$current" = "$root/.githooks" ]; then
    echo "setup-hooks: already armed ($current)"
  else
    echo "setup-hooks: core.hooksPath is '$current', set explicitly; left as is (git config core.hooksPath .githooks to arm)" >&2
  fi
  exit 0
fi
git -C "$root" config --local core.hooksPath .githooks && echo "setup-hooks: armed core.hooksPath=.githooks in $root"
