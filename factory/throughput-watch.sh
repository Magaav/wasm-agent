#!/bin/bash
# throughput-watch.sh (orch-throughput.timer, every 10 min; Fable 27/11). Raises, at most once an hour each:
#  - fewer than 1 landing in the last hour while a READY branch waits in train.list -> ATTENTION (oldest, its age)
#  - an item waiting on Fable's read > 60 min (_orch/awaiting-fable.tsv: when<TAB>item<TAB>open|done) -> _orch/FABLE-NUDGE
#    (the orchestrator's next round sends it; a script cannot message a session)
#  - the health loop not running, or the train not running while READY branches wait -> ATTENTION
M=$HOME/Work/missions; H=$M/HANDOVER.md; now=$(date +%s)
G="env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C $HOME/wasm-agent/checkout"
alarm(){ k=$1; shift; s=$M/_orch/.alarm-$k; [ $(( now - $(stat -c %Y $s 2>/dev/null || echo 0) )) -ge 3600 ] || return 0; touch $s
  m="$(date -u +%H:%MZ) WATCHDOG: $*"; echo "$m" >> $M/ATTENTION; echo "$m" >> $H; notify-send -u critical "wa factory" "$*" 2>/dev/null || true; }
$G fetch -q origin 2>/dev/null
landed=$($G log --first-parent --since="1 hour ago" --format=%s origin/main | grep -cE '^(land-quick: merge|Merge|batch )')
oldest=""; oage=0
while read BR MIS SHA WHY; do
  $G merge-base --is-ancestor $SHA origin/main 2>/dev/null && continue
  r=$(ls -t $M/$MIS/ready*.md 2>/dev/null | head -1); [ -n "$r" ] || continue
  a=$(( (now - $(stat -c %Y $r)) / 60 )); [ $a -gt $oage ] && { oage=$a; oldest=$BR; }
done < <(grep -vE '^#|^$' $M/_orch/train.list)
[ -n "$oldest" ] && [ "$landed" -lt 1 ] && alarm throughput "0 landings in the last hour while READY branches wait; oldest: $oldest (ready file ${oage} min old)"
[ -n "$oldest" ] && ! systemctl --user is-active -q orch-q-runner && alarm train "READY branches wait ($oldest, ${oage} min) and no train is running"
systemctl --user is-active -q orch-health-loop || alarm health "the health loop (orch-health-loop) is not running"
if [ -f $M/_orch/awaiting-fable.tsv ]; then
  awk -F'\t' -v now=$now '$3=="open" { cmd="date -d "$1" +%s"; cmd | getline t; close(cmd); if (now-t > 3600) print int((now-t)/60)" min: "$2 }' $M/_orch/awaiting-fable.tsv > $M/_orch/FABLE-NUDGE.new
  if [ -s $M/_orch/FABLE-NUDGE.new ]; then mv $M/_orch/FABLE-NUDGE.new $M/_orch/FABLE-NUDGE; else rm -f $M/_orch/FABLE-NUDGE.new $M/_orch/FABLE-NUDGE; fi
fi
printf '%s\t%s\t%s\n' "$(date -u +%FT%H:%MZ)" "$landed" "$(wc -l < $M/_orch/IDLE 2>/dev/null || echo 0)" >> $M/_orch/throughput-samples.tsv
