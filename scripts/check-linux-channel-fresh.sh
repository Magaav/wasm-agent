#!/usr/bin/env bash
# Is the PUBLIC Linux bundle channel as new as the newest node release this project cut?
#
# WHY (measured by Fable, 22/11 ~17:30Z). The fresh-install proof failed: the public installer
# (`scripts/install.sh` -> `scripts/linux/bootstrap.sh` -> `releases/index-linux.json`) is a channel of its
# own, and nothing in `wa release cut` had ever written to it. Six `node-<sha12>` releases were cut on 22/11
# alone and the channel's newest x86_64 entry was still `v0.1.0-alpha.13` at `d80d86bd` (30/10): 23 days old.
# The install did not fail on the day the channel went stale - it failed when a file that entry fetches moved
# (`core_lib_unreachable`: 404 on `scripts/lib/release-signing.sh` at d80d86bd) - so the lag is silent until it
# is a broken install. That is why the comparison is a check with a verdict instead of a habit.
#
# WHAT IT COMPARES, and why those two facts. The index is newest-first: its contract, and what
# `scripts/linux/bootstrap.sh` installs from (the first entry for this machine's target), so the newest
# PUBLISHED bundle is `releases[0]` and no timestamp parsing is needed. The newest release this project cut is
# the `node-<sha12>` tag whose commit is newest. A channel whose newest entry is older than that skipped a cut.
#
# THREE ANSWERS, never two: 0 `fresh`, 1 `stale`, 2 `unknown`. 1 is a verdict about the channel; 2 is a check
# that cannot tell - no index, an unparseable one, a commit this repository does not have, no python3 to read
# it. A check that cannot tell must never answer 0, because 0 is what a green gate reads as.
#
# Usage: bash scripts/check-linux-channel-fresh.sh [--index FILE] [--repo DIR]
#   --index FILE   the channel index (default: <repo>/releases/index-linux.json)
#   --repo DIR     the checkout the node-<sha12> releases are read from (default: this script's repository)
#
# Exit: 0 fresh | 1 stale (a first line naming `stale:`) | 2 unknown (a first line naming `unknown:`)
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
index="$ROOT/releases/index-linux.json"
repo="$ROOT"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --index) [ "$#" -ge 2 ] || { echo 'stale-check: index_value_required' >&2; exit 2; }; index=$2; shift 2 ;;
    --repo)  [ "$#" -ge 2 ] || { echo 'stale-check: repo_value_required' >&2; exit 2; }; repo=$2; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "stale-check: unknown_option: $1" >&2; exit 2 ;;
  esac
done

unknown() { printf 'unknown: %s\n' "$*"; echo "next: nothing was decided here; a channel that cannot be read must not read as a published one"; exit 2; }
stale()   { printf 'stale: %s\n' "$*"; echo 'next: publish the channel for the newest release - the linux step of "wa release cut" does it (scripts/publish-linux-channel.sh --commit <sha>); the lag stays silent until an install fetches a file the old entry names and that file has moved'; exit 1; }
fresh()   { printf 'fresh: %s\n' "$*"; exit 0; }

[ -f "$index" ] || unknown "index_missing: $index does not exist, so this machine cannot read the channel at all"
command -v python3 >/dev/null 2>&1 || unknown "python3_missing: the index is JSON and this check reads it with python3 (scripts/linux/bootstrap.sh requires python3 too)"
command -v git >/dev/null 2>&1 || unknown "git_missing: the node-<sha12> releases are read with git"

# The newest published entry: the first one. commit, commit_short, built_utc, tag and target come back
# tab-separated, and a file that is not the schema the installer accepts is a check that cannot tell - not an
# empty channel.
entry=$(python3 - "$index" <<'PY'
import json, re, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception as problem:
    print("ERR unparseable: %s (%s)" % (sys.argv[1], problem)); sys.exit()
if doc.get("schema") != "wasm-agent-linux-release-index" or doc.get("schema_version") != 1:
    print("ERR foreign_schema: %r v%r" % (doc.get("schema"), doc.get("schema_version"))); sys.exit()
rows = doc.get("releases") or []
if not rows:
    print("EMPTY"); sys.exit()
first = rows[0]
commit = first.get("commit") or ""
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    print("ERR commit_malformed: %r" % commit); sys.exit()
print("\t".join([commit, str(first.get("commit_short") or ""), str(first.get("built_utc") or ""),
                 str(first.get("tag") or ""), str(first.get("target") or "")]))
PY
) || unknown "index_unreadable: python3 could not read $index"
case "$entry" in
  ERR*) unknown "${entry#ERR }" ;;
  EMPTY) stale "index_empty: $index publishes no Linux bundle at all, so a fresh machine has nothing to install" ;;
  '') unknown "index_unreadable: python3 answered nothing for $index" ;;
esac
IFS=$'\t' read -r entry_commit entry_short entry_built entry_tag entry_target <<< "$entry"

# The newest node release: the node-<sha12> tag whose COMMIT is newest (a lightweight tag's creatordate is its
# commit's, and every node tag this project makes is lightweight - publish-node-binaries.sh creates them with
# gh, which tags the commit itself).
node_row=$(git -C "$repo" for-each-ref --sort=-creatordate --format='%(objectname) %(creatordate:unix) %(refname:short)' 'refs/tags/node-*' 2>/dev/null | head -1)
if [ -z "$node_row" ]; then
  fresh "no node-<sha12> release in $repo: there is no release for the channel to keep up with (newest entry $entry_short, built $entry_built)"
fi
node_commit=${node_row%% *}
node_rest=${node_row#* }
node_time=${node_rest%% *}
node_tag=${node_rest#* }

if [ "$entry_commit" = "$node_commit" ]; then
  fresh "the newest published entry ($entry_short, $entry_target, built $entry_built) IS the newest node release $node_tag"
fi
entry_time=$(git -C "$repo" log -1 --format=%ct "$entry_commit" 2>/dev/null)
case "$entry_time" in ''|*[!0-9]*) unknown "commit_unknown: $repo has no commit for the channel's newest entry $entry_commit (git answered '$entry_time')" ;; esac
case "$node_time" in ''|*[!0-9]*) unknown "tag_time_unreadable: git answered '$node_time' for $node_tag" ;; esac

if [ "$entry_time" -lt "$node_time" ]; then
  stale "the newest published entry ($entry_short, $entry_target, commit time $(date -u -d "@$entry_time" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$entry_time")) is older than the newest node release $node_tag (commit time $(date -u -d "@$node_time" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$node_time")): the channel skipped a cut"
fi
fresh "the newest published entry ($entry_short, $entry_target, built $entry_built) is not older than the newest node release $node_tag"
