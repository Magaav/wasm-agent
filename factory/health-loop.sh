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

# WHICH COPY OF THE FACTORY IS RUNNING (28/11). MEASURED: every tip printed "NOT GRADED" for hours after the fix had
# LANDED, because this loop runs from a copy under _orch that is swapped by hand between landings (factory/MAP.md) and
# a running shell loop sources its lib once, at start. The lib in use had no release-resolution bound, no sidecar build
# and no step name - the fix was in the repo and nothing on the running node could have read it. A worker reading the
# HANDOVER had no way to tell. So the loop now says which copies it is running, and how far behind the landed ones they
# are, on every start and once per grading: a swap that was forgotten is a line, not an afternoon.
wa_factory_selfcheck() {
  local mine_lib=$HERE/lib/main-binary.sh note="" landed_sha landed_date running_sha running_mtime
  [ -r "$mine_lib" ] || { printf '%s\n' ""; return 0; }
  # COMPARED WITH origin/main, NOT WITH THE CHECKOUT'S WORKING TREE (28/11). The first version of this check read
  # $C/factory/lib/main-binary.sh, and on the first real swap it accused a copy that was NEWER than the thing it
  # compared to: _orch was swapped at 21:53 while the checkout sat commits behind main at 16:32, so the loop wrote
  # "the running lib differs - swap _orch" about work somebody had just done. Truth comes from the landed blob.
  landed_sha=$(git -C "$C" show origin/main:factory/lib/main-binary.sh 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')
  [ -n "$landed_sha" ] || { printf '%s\n' ""; return 0; }
  running_sha=$(sha256sum "$mine_lib" 2>/dev/null | awk '{print $1}')
  [ "$running_sha" = "$landed_sha" ] && { printf '%s\n' ""; return 0; }
  # They differ: the USEFUL fact is which one is behind, so compute it instead of guessing from two mtimes.
  landed_date=$(git -C "$C" log -1 --format=%ct origin/main -- factory/lib/main-binary.sh 2>/dev/null)
  running_mtime=$(stat -c %Y "$mine_lib" 2>/dev/null)
  case "$landed_date" in ''|*[!0-9]*) landed_date=0 ;; esac
  case "$running_mtime" in ''|*[!0-9]*) running_mtime=0 ;; esac
  if [ "$landed_date" -gt "$running_mtime" ]; then
    note="the running lib is STALE: main changed it $(date -u -d "@$landed_date" +%Y-%m-%dT%H:%MZ) and this copy is $(date -u -d "@$running_mtime" +%Y-%m-%dT%H:%MZ); swap _orch per factory/MAP.md and restart"
  else
    note="the running lib is AHEAD of origin/main ($(date -u -d "@$running_mtime" +%Y-%m-%dT%H:%MZ) vs $(date -u -d "@$landed_date" +%Y-%m-%dT%H:%MZ)) - nothing to swap; check the checkout is on main before swapping anything"
  fi
  printf '%s\n' "$note"
}
FACTORY_NOTE=$(wa_factory_selfcheck)
if [ -n "$FACTORY_NOTE" ]; then
  m="$(date -u +%H:%MZ) WATCHDOG: health runs a factory copy that is not the landed one - $FACTORY_NOTE"
  echo "$m" >> $M/ATTENTION; echo "$m" >> $H
fi
G="env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C $C"
GREEN=$(cat $M/_orch/health-green 2>/dev/null); KNOWN=" $(cat $M/_orch/health-known 2>/dev/null) "
while true; do
  $G fetch -q origin; N=$($G rev-parse origin/main)
  if [ "$N" = "$(cat $M/_orch/health-last 2>/dev/null)" ]; then sleep 300; continue; fi
  # A COLD STAGE NEEDS MORE THAN THE DEFAULT BOUND (28/11: every tip NOT GRADED while c1fcda27 WAS published).
  # MEASURED: the release resolver, asked for a tip whose bundle is on GitHub, stops its digest scan at
  # WA_NODE_RELEASE_DIGEST_SECONDS and answers "no release" - and the default is 20 s. The SAME call with 60 s
  # resolved the published bundle in 76 s, no build. This loop's fallback is a fifteen-minute cargo build, so a
  # longer scan is the cheap answer; a warm stage is unaffected because it answers before the scan runs.
  export WA_NODE_RELEASE_DIGEST_SECONDS=${WA_NODE_RELEASE_DIGEST_SECONDS:-120}
  # NOT IN A COMMAND SUBSTITUTION (28/11). wa_main_binary names the step it used by EXPORTING WA_MAIN_BINARY_STEP,
  # and `WA_BIN=$(wa_main_binary ...)` runs it in a subshell, so the export died and every graded line read
  # "with unknown" - measured 00:53Z on a tip that WAS graded: "grading 242e69c4 with unknown (pinned/.../wa)".
  # The binary goes to a file and is read back, so the step survives in this shell, where the line is written.
  WA_BIN=""
  if ! wa_main_binary "$N" > "$M/_orch/health-binary.out" 2> "$M/_orch/health-binary.err"; then
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
  # READ BACK HERE, in the shell that writes the line, so WA_MAIN_BINARY_STEP (exported by the lib) is still set.
  WA_BIN=$(head -1 "$M/_orch/health-binary.out" 2>/dev/null)
  wa_note_graded $M/_orch
  # WHICH STEP GAVE THE BINARY, on the line that records the grading, so "graded" is never mistaken for "built".
  echo "$(date -u +%H:%MZ) orch(health): grading ${N:0:8} with ${WA_MAIN_BINARY_STEP:-unknown} (${WA_BIN})" >> $H
  # The lib that produced that binary, named: a grading line is evidence only if a reader can tell WHICH factory said it.
  echo "$(date -u +%H:%MZ) orch(health): factory lib $(stat -c %y "$HERE/lib/main-binary.sh" 2>/dev/null | cut -d. -f1)${FACTORY_NOTE:+  [$FACTORY_NOTE]}" >> $H
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
