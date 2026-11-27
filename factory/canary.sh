#!/bin/bash
# canary.sh (orchestrator 25/11, Fable decision (e)): every minute, check the LIVE laptop install. Any change outside a
# landing writes ~/Work/missions/ATTENTION (wait-any wakes the orchestrator). Read-only; two reds in a row before alarm.
M=$HOME/Work/missions; O=$M/_orch; B=$HOME/.local/bin; S=$O/canary.state
# skip while a landing/deploy is legitimately changing the install
if [ -f $HOME/.wasm-agent/deploy-alive.json ] || systemctl --user list-units 'orch-land-*' --state=active --no-legend 2>/dev/null | grep -q . ; then echo "skip $(date -u +%T) landing" > $S; exit 0; fi
r=()
want=$(bash -c 'source $HOME/wasm-agent/checkout/scripts/lib/sentinel-unit.sh; wa_sentinel_unit_text $HOME/.local/bin $HOME/.wasm-agent/env 8799 8800 0 $HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin' 2>/dev/null)
[ "$want" = "$(cat $HOME/.config/systemd/user/wa-sentinel.service)" ] || r+=("unit file differs from the product text")
[ "$(cat $B/runtime-worktree.txt)" = "$(sed -n 's/^source_worktree=//p' $B/installed.txt)" ] || r+=("runtime-worktree.txt = $(cat $B/runtime-worktree.txt)")
[ "$(sha256sum < $B/wa | cut -d' ' -f1)" = "$(sed -n 's/^sha256=//p' $B/installed.txt)" ] || r+=("wa sha256 != installed.txt")
[ "$(sha256sum < $B/wa-sentinel | cut -d' ' -f1)" = "$(sed -n 's/^sentinel_sha256=//p' $B/installed.txt)" ] || r+=("wa-sentinel sha256 != installed.txt")
st=$(timeout 10 $B/wa-sentinel status 2>&1)
echo "$st" | grep -qE 'node: +up +port 8799' || r+=("node not up on 8799")
echo "$st" | grep -qE 'sentinel: +up +watching' || r+=("sentinel not watching")
p=$(systemctl --user show -p MainPID --value wa-sentinel); [ -n "$p" ] && [ "$p" != 0 ] && [ "$(readlink /proc/$p/exe 2>/dev/null)" = "$B/wa-sentinel" ] || r+=("wa-sentinel.service MainPID $p exe=$(readlink /proc/$p/exe 2>/dev/null)")
for q in $(pgrep -x wa-sentinel); do [ "$q" = "$p" ] && continue; e=$(tr '\0' '\n' < /proc/$q/environ 2>/dev/null)
  echo "$e" | grep -qxE 'WASM_AGENT_DB=/home/victor/.wasm-agent/memory.db|HOME=/home/victor' && r+=("pid $q $(readlink /proc/$q/exe) is a non-live sentinel with the live HOME/DB")
  echo "$e" | grep -q '^WASM_AGENT_PORT=' || r+=("pid $q $(readlink /proc/$q/exe) has no WASM_AGENT_PORT (watches 8799)"); done
if [ ${#r[@]} = 0 ]; then echo "green $(date -u +%T)" > $S; exit 0; fi
prev=$(cat $S 2>/dev/null); msg="$(date -u +%FT%TZ) CANARY RED: $(IFS='; '; echo "${r[*]}")"
echo "red $msg" > $S
case "$prev" in red*) echo "$msg" >> $M/ATTENTION; echo "$msg" >> $O/canary.log;; esac
