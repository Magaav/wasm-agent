#!/bin/bash
# reboot-snapshot.sh (Fable 24/11): the SNAPSHOT part of reboot-before.sh, safe to run any time: it pauses nothing,
# changes no max-workers, writes no marker. Run every 10 min by orch-snapshot.timer and at every launch/landing, so a
# POWER CUT (no "before") still leaves a state at most 10 min old. Writes atomically (tmp + mv).
M=$HOME/Work/missions; O=$M/_orch; C=$HOME/wasm-agent/checkout
exec 9>$O/.snapshot.lock; flock -n 9 || exit 0
S=$O/reboot-state.tsv; ST=$(mktemp $O/.reboot-state.XXXX)
printf 'mission\tstate\tbranch_tip\tsession\tdetail\n' > $ST
for d in $M/*/; do n=$(basename $d); [ -f $d/brief.md ] && [ -d $d/wt ] || continue
  tip=$(git -C $C rev-parse --short change/$n 2>/dev/null || echo -)
  sid=$(grep -oE 'wa: session [0-9a-f-]{36}' $d/err.log 2>/dev/null | tail -1 | awk '{print $3}')
  if git -C $C merge-base --is-ancestor change/$n origin/main 2>/dev/null; then st=landed
  elif systemctl --user is-active -q mission-$n || systemctl --user is-active -q orch-m-$n; then st=running
  elif [ -f $d/paused ]; then st=paused
  elif [ -f $d/done ]; then st=review
  elif [ -f $d/retired.txt ]; then st=retired
  else st=idle; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$st" "$tip" "${sid:--}" "$(head -c 80 $d/done 2>/dev/null | tr '\n\t' '  ')" >> $ST
done
mv -f $ST $S
U=$O/reboot-units.tsv; UT=$(mktemp $O/.reboot-units.XXXX)
for u in $(systemctl --user list-units --no-legend --state=active 'orch-*' | awk '{print $1}' | grep -v '^orch-snapshot'); do
  printf '%s\t%s\n' "${u%.service}" "$(systemctl --user show $u -p ExecStart --value | awk '{i=index($0,"argv[]="); s=substr($0,i+7); j=index(s," ; "); print substr(s,1,j-1)}')" >> $UT; done
mv -f $UT $U
date -u +%FT%TZ > $O/reboot-snapshot.at
