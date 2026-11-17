#!/usr/bin/env bash
# The fast loop: put this checkout's Lua where a node can run it, in about a second, and say which of the
# three speeds the change needs (operator 17/11, "make the evolution faster").
#
#   bash scripts/dev-sync.sh --docker <container>[:<dir>]      # default dir: ~/wa-dev in the container
#   bash scripts/dev-sync.sh --ssh <host>[:<dir>]              # default dir: ~/wa-dev on the host
#   bash scripts/dev-sync.sh --dir <dir>                       # a local directory
#   ... [--swap]   also run scripts/lua-swap.sh there: the node runs this Lua as its core (~15-90 s,
#                  probed before and after, rolled back on any failure)
#
# The three speeds, by what changed (docs/HOTRELOAD.md):
#   ui    (cli_view, codemode_block, the commands, /mcp ...)  `wa chat --dev <dir>`: live, next frame
#   pure  (raw_code, codemode_harness, tool_output)            `wa chat --dev <dir>`: at the next turn
#   core  (the agent, the tools, the provider, the ledger)     `--swap`: lua-core beside the binary
#   rust  (the transcript, the host)                          a build (ship.sh), ~3 min
# A screen check needs no model call at all: scripts/replay-events.lua draws a recorded turn in ~0.1 s.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODE=; TARGET=; SWAP=0
while [ $# -gt 0 ]; do
  case $1 in
    --docker) MODE=docker; TARGET=${2:?}; shift 2 ;;
    --ssh) MODE=ssh; TARGET=${2:?}; shift 2 ;;
    --dir) MODE=dir; TARGET=${2:?}; shift 2 ;;
    --swap) SWAP=1; shift ;;
    *) echo "dev-sync: unknown_option $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,20p' "$0"; exit 2; }
LABEL="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo tree)"
[ -z "$(git -C "$ROOT" status --porcelain -- lua 2>/dev/null)" ] || LABEL="$LABEL-dirty"
pack() { tar -C "$ROOT" -cf - lua scripts/lib scripts/lua-swap.sh scripts/replay-events.lua fixtures/events-codeact-turn.json \
  AGENTS.orchestrator.md AGENTS.subagents.md 2>/dev/null; }
case $MODE in
  docker)
    name=${TARGET%%:*}; dir=${TARGET#*:}; [ "$dir" = "$TARGET" ] && dir='$HOME/wa-dev'
    pack | docker exec -i "$name" bash -c "rm -rf $dir.new && mkdir -p $dir.new && tar xf - -C $dir.new && rm -rf $dir && mv $dir.new $dir && echo synced: $dir" || exit 1
    run() { docker exec "$name" bash -lc "$1"; } ;;
  ssh)
    host=${TARGET%%:*}; dir=${TARGET#*:}; [ "$dir" = "$TARGET" ] && dir='$HOME/wa-dev'
    pack | ssh "$host" "rm -rf $dir.new && mkdir -p $dir.new && tar xf - -C $dir.new && rm -rf $dir && mv $dir.new $dir && echo synced: $dir" || exit 1
    run() { ssh "$host" "bash -lc '$1'"; } ;;
  dir)
    dir=$TARGET; mkdir -p "$dir.new" && pack | tar xf - -C "$dir.new" && rm -rf "$dir" && mv "$dir.new" "$dir" && echo "synced: $dir" || exit 1
    run() { bash -lc "$1"; } ;;
esac
if [ "$SWAP" = 1 ]; then
  run "bash $dir/scripts/lua-swap.sh --tree $dir --label $LABEL" || exit 1
fi
echo "ui + pure: wa chat --dev $dir   (core: --swap; rust: a build)"
