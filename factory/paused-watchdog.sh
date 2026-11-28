#!/bin/bash
# paused-watchdog.sh: every 5 min, a mission whose 'paused' marker is older than 15 min, with no deploy waiting and its
# session quiet 10 min with a pause notice as its last word, is resumed by hand (the node's own resume did not come).
. "$(cd "$(dirname "$0")" && pwd)/lib/refresh-self.sh"   # refresh the clone between iterations (factory/lib/refresh-self.sh)
M=$HOME/Work/missions
while :; do
  wa_factory_refresh_self "$0" "$@"
  if ! wa-sentinel status 2>&1 | grep -qE 'requests: +[1-9][0-9]* waiting'; then
    for p in $M/*/paused; do [ -f "$p" ] || continue
      d=$(dirname $p); n=$(basename $d)
      [ $(( $(date +%s) - $(stat -c %Y $p) )) -ge 900 ] || continue
      # a resume unit younger than 40 min owns it; an older one is hung (24/11: worker-write-guard sat 2 h behind one)
      busy=0; for u in orch-c-$n orch-pw-$n; do systemctl --user is-active -q $u || continue
        st=$(systemctl --user show $u -p ActiveEnterTimestamp --value); [ $(( $(date +%s) - $(date -d "$st" +%s) )) -lt 2400 ] && busy=1 || systemctl --user stop $u; done
      [ $busy = 1 ] && continue
      SID=$(grep -oE 'wa: session [0-9a-f-]{36} (failed|ok)' $d/err.log | tail -1 | awk '{print $3}'); [ -n "$SID" ] || continue
      q=$(sqlite3 "file:$HOME/.wasm-agent/memory.db?mode=ro" "select cast(strftime('%s','now')-max(created_at) as int) from messages where session_id='$SID'" 2>/dev/null)
      lp=$(sqlite3 "file:$HOME/.wasm-agent/memory.db?mode=ro" "select (content like '%deploy pending:%' or content like '%deploy waiting:%') from messages where session_id='$SID' order by seq desc limit 1" 2>/dev/null)
      [ "${q:-0}" -ge 600 ] && [ "$lp" = 1 ] || continue
      printf '[orchestrator, automatic] Your turn was paused by an install and the node did not resume it. Nothing was lost. Continue exactly where you stopped: check git status in your worktree first, finish what you were doing, commit, and finish.\n' > $d/continue-auto.txt
      sat=$(( $(date +%s) - $(stat -c %Y $p) ))
      E=$M/deploy-hold-never-fails-our-load/paused-evidence.log
      { echo "== $(date -u +%FT%TZ) $n session $SID: paused marker $(cat $p) ; sat ${sat}s; session quiet ${q}s; last word = pause notice"
        journalctl --user -u wa-serve -u wa-sentinel --since "@$(stat -c %Y $p)" --no-pager -o short-iso 2>/dev/null | grep -iE "release_due|deploy_pause|resume|${SID:0:8}" | tail -15
        sqlite3 "file:$HOME/.wasm-agent/memory.db?mode=ro" "select seq,role,substr(replace(content,char(10),' '),1,160) from messages where session_id='$SID' order by seq desc limit 3" 2>/dev/null
      } >> $E
      [ -f $M/deploy-hold-never-fails-our-load/landed-resume-fix ] && echo "$(date -u +%H:%MZ) **RED (Fable): watchdog fired AFTER the resume fix landed: $n session ${SID:0:8} sat ${sat}s; evidence in deploy-hold-never-fails-our-load/paused-evidence.log**" >> $M/HANDOVER.md
      rm -f $p; echo "$(date -u +%H:%MZ) orch(watchdog): $n paused ${sat}s, node did not resume; resumed by hand; evidence -> deploy-hold paused-evidence.log." >> $M/HANDOVER.md
      systemd-run --user --unit=orch-pw-$n --collect -p WorkingDirectory=$M bash $M/_orch/resume-when-idle.sh $n $d/continue-auto.txt
    done
  fi
  sleep 300
done
