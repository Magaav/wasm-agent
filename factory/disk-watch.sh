#!/bin/bash
# disk-watch (Fable 25/11): warn at 70% of / (the node's disk_cap refuses work at 85%).
M=$HOME/Work/missions; p=$(df --output=pcent / | tail -1 | tr -dc 0-9)
echo "$(date -u +%TZ) $p%" > $M/_orch/disk.state
if [ "$p" -ge 70 ]; then
  last=$(cat $M/_orch/disk.warned 2>/dev/null); now=$(date +%s)
  if [ -z "$last" ] || [ $((now - last)) -ge 3600 ]; then echo "$(date -u +%H:%MZ) DISK: / is at $p% (warn 70%, node disk_cap 85%): prune ended missions' target/m-* (>24 h), tell Fable" >> $M/ATTENTION; echo $now > $M/_orch/disk.warned; fi
fi
