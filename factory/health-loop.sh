#!/bin/bash
# health-loop (Fable 27/11; the binary rule Victor 27/11): fast.sh on main's tip, continuously, BESIDE the
# train. A new red is rerun alone once (green -> flaky.tsv); still red -> the landings since the last green
# tip are named in _orch/REVERT-PROPOSAL-<sha>.txt for the orchestrator. It never stops the train and never
# reverts by itself.
#
# THE ONE CHANGE FROM THE RUNNING COPY: the rows are given MAIN'S OWN BINARY. They used to get
# `~/.local/bin/wa`, the laptop's installed build - and since a landing no longer installs by default, that
# binary lags main, so a row that needs the new code went red for the wrong reason. `wa_main_binary` (this
# directory's lib/) names the published bundle for the tip, or the tree's own build of it, or builds one in
# its own target dir; it never returns the installed binary, and when it can name none the loop SAYS SO and
# does not grade.
set -uo pipefail
M=$HOME/Work/missions; H=$M/HANDOVER.md; C=$HOME/wasm-agent/checkout
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/main-binary.sh"
G="env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C $C"
GREEN=$(cat $M/_orch/health-green 2>/dev/null); KNOWN=" $(cat $M/_orch/health-known 2>/dev/null) "
while true; do
  $G fetch -q origin; N=$($G rev-parse origin/main)
  if [ "$N" = "$(cat $M/_orch/health-last 2>/dev/null)" ]; then sleep 300; continue; fi
  if ! WA_BIN=$(wa_main_binary "$N"); then
    echo "$(date -u +%H:%MZ) orch(health): NOT GRADED for ${N:0:8}: no binary of main's own (the installed one is not used)" >> $H
    # A WATCHDOG THAT NEVER BARKS IS WORSE THAN NONE: one ungraded tip can be a release still publishing, two in
    # a row is a resolver that cannot see anything, and that must reach the operator instead of scrolling by in
    # HANDOVER (27/11: every tip from 18:23 to 18:34 was NOT GRADED and nothing said so).
    if ! n=$(wa_note_ungraded "$N" $M/_orch); then
      m="$(date -u +%H:%MZ) WATCHDOG: health has not graded the last $n tips (newest ${N:0:8}) - the loop is blind, not idle"
      echo "$m" >> $M/ATTENTION; echo "$m" >> $H
    fi
    sleep 300; continue
  fi
  wa_note_graded $M/_orch
  export WA_BIN
  bash $C/scripts/main-health.sh > $M/_orch/health-loop-run.out 2>&1
  S=$(jq -r .sha $M/main-health.json); echo $S > $M/_orch/health-last
  R=$(jq -r '.failed[]?.row' $M/main-health.json | sort -u)
  STILL=""; for r in $R; do
    case "$KNOWN" in *" $r "*) continue;; esac
    L=$(cut -d' ' -f1 /proc/loadavg)
    if WA_BIN="$WA_BIN" bash $M/_orch/rerun-row.sh $r $S > $M/_orch/health-rerun-$r.log 2>&1; then
      printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%H:%MZ)" "$r" "hl-${S:0:8}" "load $L" >> $M/_orch/flaky.tsv
    else STILL="$STILL$r "; fi
  done
  if [ -z "$STILL" ]; then echo $S > $M/_orch/health-green; GREEN=$S
    echo "$(date -u +%H:%MZ) orch(health): ${S:0:8} $(jq -r '"\(.counts.passed)/\(.counts.checks)"' $M/main-health.json) green (reds rerun green: $(echo $R))" >> $H
  else
    P=$M/_orch/REVERT-PROPOSAL-${S:0:8}.txt
    { echo "new red on ${S:0:8} (still red alone): $STILL"; echo "last green: ${GREEN:0:8}"; echo "landings since:"; $G log --first-parent --format='%h %s' ${GREEN:-$S~1}..$S; } > $P
    echo "$(date -u +%H:%MZ) orch(health): NEW RED on ${S:0:8}: $STILL -> $P (attribute + propose revert)" >> $H
  fi
  sleep 60
done
