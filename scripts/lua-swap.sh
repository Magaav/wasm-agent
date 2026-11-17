#!/usr/bin/env bash
# Put a Lua tree in charge of an installed node in ~30 s - no cargo, no new binary - and never leave the
# node worse than it was.
#
#   bash scripts/lua-swap.sh --tree <checkout> [--bin ~/.local/bin/wa] [--probe file.lua] [--no-restart]
#   bash scripts/lua-swap.sh --rollback [--bin ~/.local/bin/wa]
#   --detach     run in its own systemd user scope (when started through the node it restarts)
#   --label NAME names the tree in its manifest when it is not a git checkout (a synced copy)
#
# WHY (operator 17/11, "can we make the evolution faster? hotswap fail fallback?"). A core Lua change (the
# agent loop, the tools, the provider) is not hot-reloadable (docs/HOTRELOAD.md), and a full build is ~3
# minutes plus an install. The binary already runs `<install>/lua-core/` in place of its compiled-in Lua when
# the tree's manifest verifies (rust/wa-host/src/main.rs, "An installed Lua tree"); this script is that
# install, from a working tree, with the same guards fleet-install.sh has for a binary:
#
#   1. stage   <install>/lua-core.next: the shipped file set (scripts/lib/lua-tree.sh, the one definition
#              deploy.sh stages from), each file pinned, and the capability digest of the INSTALLED binary -
#              a tree that needs a host capability this binary lacks is refused by the binary itself;
#   2. verify  the binary reads the staged tree back (`--lua-tree`) and names its commit;
#   3. probe   BEFORE anything is replaced, the staged tree loads the agent, the tools, the codemode loop, the
#              view and the raw-code parser, and raw_code.mode() agrees with the node's env (the signature of
#              the 17/11 stale-tree bug); plus --probe, your own check, when given;
#   4. swap    lua-core -> lua-core.prev, lua-core.next -> lua-core (the way back is one mv);
#   5. prove   restart, /health 200 within 30 s, and the probe again on what the node now loads;
#              any failure puts lua-core.prev back, restarts, and exits non-zero with the reason.
#
# A binary install (fleet-install.sh step 4b) moves an installed tree aside, so a tree never outlives the
# binary it was verified against.
set -uo pipefail
TREE=; BIN=${BIN:-$HOME/.local/bin/wa}; PROBE=; RESTART=1; ROLLBACK=0; LABEL=; DETACH=0
ORIG_ARGS=("$@")
HEALTH=${HEALTH:-http://127.0.0.1:8799/health}
while [ $# -gt 0 ]; do
  case $1 in
    --tree) TREE=${2:?}; shift 2 ;;
    --bin) BIN=${2:?}; shift 2 ;;
    --probe) PROBE=${2:?}; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --label) LABEL=${2:?}; shift 2 ;;
    --detach) DETACH=1; shift ;;
    *) echo "lua-swap: unknown_option $1" >&2; exit 2 ;;
  esac
done
say() { printf 'lua-swap: %s\n' "$*"; }
# --detach: run in a scope of its own and log to ~/lua-swap.log. Needed when this script is started THROUGH the
# node it restarts (a remote `wa call <node> bash`): 17/11 on openclaw the restart killed the script after the
# swap and before its after-swap probe, so nothing could have rolled back. setsid was not enough there.
if [ "$DETACH" = 1 ] && [ -z "${LUA_SWAP_DETACHED:-}" ]; then
  args=(); for a in "${ORIG_ARGS[@]}"; do [ "$a" = --detach ] || args+=("$a"); done
  if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --quiet --collect --unit "lua-swap-$$" \
      --setenv=LUA_SWAP_DETACHED=1 --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
      bash -c "exec bash '$0' $(printf '%q ' "${args[@]}") >> '$HOME/lua-swap.log' 2>&1"; then
    echo "lua-swap: detached as user unit lua-swap-$$; log: ~/lua-swap.log"; exit 0
  fi
  echo "lua-swap: systemd-run unavailable; running attached" >&2
fi
die() { printf 'lua-swap: %s\n' "$*" >&2; exit 1; }
INSTALL=$(dirname "$BIN")
LIVE=$INSTALL/lua-core; NEXT=$INSTALL/lua-core.next; PREV=$INSTALL/lua-core.prev
[ -x "$BIN" ] || die "no_binary $BIN"

restart() {
  [ "$RESTART" = 1 ] || return 0
  if [ -n "${UNIT:-}" ]; then systemctl --user restart "$UNIT" 2>/dev/null || sudo -n systemctl restart "$UNIT" 2>/dev/null; fi
  if command -v pkill >/dev/null 2>&1; then pkill -f "wa serve --port 8799" 2>/dev/null; fi
}
healthy() {
  [ "$RESTART" = 1 ] || return 0
  local code=000
  for _ in $(seq 1 "${HEALTH_WAIT:-150}"); do
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$HEALTH" 2>/dev/null || echo 000)
    [ "$code" = 200 ] && return 0
    sleep 1
  done
  say "health=$code"; return 1
}
put_back() {
  rm -rf "$LIVE"
  if [ -d "$PREV" ]; then mv "$PREV" "$LIVE" && say "restored the previous tree ($(sed -n 's/^commit //p' "$LIVE/manifest.txt" | head -1))"
  else say "no previous tree: the binary's compiled-in Lua is in charge"; fi
  restart; healthy || die "rolled_back_still_unhealthy: look at the node by hand"
}

if [ "$ROLLBACK" = 1 ]; then
  [ -d "$PREV" ] || [ -d "$LIVE" ] || die "nothing_to_roll_back"
  put_back; say "rolled back"; exit 0
fi

[ -n "$TREE" ] && [ -d "$TREE/lua/core" ] || die "--tree must be a checkout root holding lua/core"
TREE=$(cd "$TREE" && pwd)
LIB="$TREE/scripts/lib/lua-tree.sh"; [ -f "$LIB" ] || LIB="$(dirname "$0")/lib/lua-tree.sh"
. "$LIB" 2>/dev/null || die "cannot read scripts/lib/lua-tree.sh"
DIGEST=$("$BIN" --capability-digest 2>/dev/null | tr -d '[:space:]')
printf '%s' "$DIGEST" | grep -qE '^[0-9a-f]{64}$' || die "the installed binary cannot state its capability digest"
COMMIT=${LABEL:-$(git -C "$TREE" rev-parse --short=12 HEAD 2>/dev/null || echo nogit)}
if [ -n "$(git -C "$TREE" status --porcelain -- lua 2>/dev/null)" ]; then
  COMMIT="$COMMIT-dirty-$(wa_lua_tree_files "$TREE" | (cd "$TREE" && xargs sha256sum) | sha256sum | cut -c1-8)"
fi

# 1. stage
rm -rf "$NEXT" && mkdir -p "$NEXT" || die "cannot_stage $NEXT"
{
  echo "capabilities $DIGEST"
  echo "commit $COMMIT"
  wa_lua_tree_files "$TREE" | while read -r f; do
    [ -f "$TREE/$f" ] || continue
    mkdir -p "$NEXT/$(dirname "$f")" && cp "$TREE/$f" "$NEXT/$f" || exit 1
    printf '%s  %s\n' "$(sha256sum < "$TREE/$f" | awk '{print $1}')" "$f"
  done
} > "$NEXT/manifest.txt" || die "cannot_write_tree"
# 2. verify
check=$(WA_LUA_TREE="$NEXT" "$BIN" --lua-tree 2>&1)
case "$check" in "installed lua tree: commit $COMMIT"*) say "staged $COMMIT ($(grep -c '  ' "$NEXT/manifest.txt") files)" ;;
  *) rm -rf "$NEXT"; die "the binary refuses the staged tree: $check" ;; esac
# 3. probe (before the swap)
scratch=$(mktemp -d "$INSTALL/.lua-swap.XXXXXX") || die "no_scratch"
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/probe.lua" <<'LUA'
-- Load what a run loads, and make the parser do its job: "it parsed" is not "it runs".
for _, path in ipairs({ 'lua/core/agent.lua', 'lua/core/tools.lua', 'lua/core/codemode.lua',
    'lua/core/provider.lua', 'lua/core/cli_view.lua', 'lua/core/reload.lua', 'lua/core/chat.lua' }) do
  local ok, problem = pcall(dofile, path)
  if not ok then print('load_failed ' .. path .. ': ' .. tostring(problem):sub(1, 200)) return end
end
local raw = dofile('lua/core/raw_code.lua')
-- The markup parser exists from change/codeact on; a tree without it (main before that) is not refused for it.
if raw.native_calls then
  local found = raw.native_calls('<tool_call>{"name":"js","arguments":{"code":"return 1;"}}</tool_call>')
  if not (found and found.calls[1] and found.calls[1].code == 'return 1;') then print('raw_code_parser_broken') return end
end
local want = tostring(host.getenv('WASM_AGENT_RAW_CODE') or ''):lower()
if want == '1' or want == 'true' then want = 'on' end
if want ~= '' and tostring(raw.mode()) ~= want then print('mode_mismatch env=' .. want .. ' lua=' .. tostring(raw.mode())) return end
print('probe ok')
LUA
run_probe() { # $1 = tree dir or "" for what the node loads now
  local verdict
  if [ -n "$1" ]; then verdict=$(WA_LUA_TREE="$1" WA_SCRIPT="$scratch/probe.lua" "$BIN" --db "$scratch/p.db" 2>/dev/null | tail -1)
  else verdict=$(WA_SCRIPT="$scratch/probe.lua" "$BIN" --db "$scratch/p.db" 2>/dev/null | tail -1); fi
  [ "$verdict" = "probe ok" ] || { echo "$verdict"; return 1; }
  if [ -n "$PROBE" ]; then
    if [ -n "$1" ]; then verdict=$(WA_LUA_TREE="$1" WA_SCRIPT="$PROBE" "$BIN" --db "$scratch/q.db" 2>&1 | tail -1)
    else verdict=$(WA_SCRIPT="$PROBE" "$BIN" --db "$scratch/q.db" 2>&1 | tail -1); fi
    case "$verdict" in *ok*) ;; *) echo "your probe: $verdict"; return 1 ;; esac
  fi
  return 0
}
if ! why=$(run_probe "$NEXT"); then rm -rf "$NEXT"; die "probe refused the staged tree, nothing replaced: $why"; fi
say "probe ok on the staged tree"
# 4. swap
rm -rf "$PREV"
{ [ ! -d "$LIVE" ] || mv "$LIVE" "$PREV"; } && mv "$NEXT" "$LIVE" || die "cannot_swap"
# 5. prove, or put back
restart
if ! healthy; then say "UNHEALTHY after the swap - rolling back"; put_back; die "rolled_back_unhealthy"; fi
if ! why=$(run_probe ""); then say "the node does not run the new tree ($why) - rolling back"; put_back; die "rolled_back_probe: $why"; fi
say "in charge: $COMMIT (previous kept as lua-core.prev; undo: lua-swap.sh --rollback)"
