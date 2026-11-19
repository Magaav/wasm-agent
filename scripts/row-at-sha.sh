#!/usr/bin/env bash
# One fast row at a base commit and at this tree, and what changed between them (item 5/8, #46).
#
#   bash scripts/row-at-sha.sh <sha> <row> [repo-root]
#
# The worker is scripts/lib/row-at-sha.sh; this file exists so the command in that library's own header is
# a command that runs (item 8 of the node-ops round: the header named a script that did not exist, so the
# documented way to establish "fails before, passes after" was a file name). `wa test --at <sha> <row>` is
# the node verb, and it runs this same worker - one implementation, two faces.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
[ -f "$ROOT/scripts/lib/row-at-sha.sh" ] || { echo 'row-at-sha: refused(row_at_sha_lib_missing): scripts/lib/row-at-sha.sh is not beside this script' >&2; exit 2; }
. "$ROOT/scripts/lib/row-at-sha.sh"
sha="${1-}"; row="${2-}"; repo="${3:-$ROOT}"
[ -n "$sha" ] && [ -n "$row" ] || { echo 'usage: row-at-sha.sh <sha> <row> [repo-root]' >&2; exit 2; }
wa_row_at_sha "$sha" "$row" "$repo"
