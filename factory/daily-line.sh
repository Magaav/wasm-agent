#!/bin/bash
# daily-line.sh (orch-daily.timer, 08:00 local; Fable/Victor 27/11): ONE line about yesterday (local day), no prose,
# into HANDOVER.md and to the screen. DAY=YYYY-MM-DD overrides the day (by hand).
M=$HOME/Work/missions; G="env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C $HOME/wasm-agent/checkout"
D=${DAY:-$(date -d yesterday +%F)}; S="$D 00:00"; E="$(date -d "$D +1 day" +%F) 00:00"
$G fetch -q origin 2>/dev/null
subj=$($G log --first-parent --since="$S" --until="$E" --format=%s origin/main)
land=$(echo "$subj" | grep -cE '^(land-quick: merge|batch )')
rev=$(echo "$subj" | grep -cE '^Revert')
med(){ sort -n | awk '{a[NR]=$1} END{if(NR==0){print "-"} else {m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "%.1f", m/60}}'; }
su=$(date -u -d @$(date -d "$S" +%s) +%FT%H:%M); eu=$(date -u -d @$(date -d "$E" +%s) +%FT%H:%M)
inday(){ awk -F'\t' -v s=$su -v e=$eu '$1>=s && $1<e'; }
mc=$(inday 2>/dev/null < $M/_orch/landing-times.tsv | awk -F'\t' '$3=="compiled"{print $7}' | med)
ml=$(inday 2>/dev/null < $M/_orch/landing-times.tsv | awk -F'\t' '$3!="compiled"{print $7}' | med)
fl=$(inday 2>/dev/null < $M/_orch/flaky.tsv | wc -l)
idle=$(inday 2>/dev/null < $M/_orch/throughput-samples.tsv | awk -F'\t' '{s+=$3} END{printf "%.1f", s*10/60}')
now=$(date +%s)
fw=$(awk -F'\t' '$3=="open"{print $1"\t"$2}' $M/_orch/awaiting-fable.tsv 2>/dev/null | while IFS=$'\t' read w i; do echo "$i $(( (now-$(date -d "$w" +%s))/60 ))m"; done | paste -sd, -)
vw=$(awk -F'\t' '$3=="open"{print $1}' $M/_orch/awaiting-victor.tsv 2>/dev/null | sort | head -1); vn=$(awk -F'\t' '$3=="open"' $M/_orch/awaiting-victor.tsv 2>/dev/null | wc -l)
vo=""; [ -n "$vw" ] && vo=" (oldest $(( (now-$(date -d "$vw" +%s))/3600 ))h)"
line="DAILY $D: landings $land (baseline 30) | median min compiled $mc / not $ml | reverts $rev | flakes $fl | idle worker-h $idle | waiting on Fable: ${fw:-none} | waiting on Victor: $vn$vo"
echo "$(date -u +%H:%MZ) $line" >> $M/HANDOVER.md
notify-send "wa factory" "$line" 2>/dev/null || true
echo "$line"
