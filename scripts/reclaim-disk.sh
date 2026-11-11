#!/usr/bin/env bash
# The job's `run` step, and only that.
#
# A sentinel `run` step executes the script it names through a shell (`shell_for` in
# rust/wa-sentinel/src/main.rs hands it to Git Bash on Windows), so the file a job points at has to be a
# shell script that starts the program - which is also how this repository's other jobs do it
# (`scripts/delivery-trigger.sh` and friends). The pass itself is
# Node, where the walks, the session store and the JSON live.
#
# No arguments are needed: a job's run step has no argument list, and none is wanted. `--apply` is *not*
# passed from here: the job's script is the report, and the removal is a decision a runner makes with
# `--apply` in front of it. (A reclaim that quietly deletes on its first scheduled tick is how a tree
# somebody still wanted disappears.) The free space and the armed mode are named on every run.
#
# THE THRESHOLDS ARE THE CLEAN-DISK SKILL'S (skills/clean-disk/SKILL.md §6), and they are printed on every
# run because a report whose reader has to compare numbers by hand is a report nobody acts on:
#
#   * 3.71 GiB (3,987,386,368 B) is what one gate needs; below it a build refuses (scripts/test.sh), and a
#     deploy with no published binary refuses too (`refused(no_prebuilt_binary_and_disk_floor)`);
#   * 7.4 GiB free is "one gate away": the device is at 95 %+ used, and the next build/deploy is the one
#     that will fail;
#   * 1 GiB is the running node's own floor (`WASM_AGENT_DISK_FLOOR_BYTES`), where a session says so.
#
# Measured 2026-11-11: openclaw at 2.10 GiB free of 96 GiB was already below the build floor. Nothing here
# deletes anything: WA_RECLAIM_MODE=apply is the only switch, it is not set by the job, and the operator
# makes that decision.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${WA_RECLAIM_MODE:-report}"
if [ "$MODE" = "apply" ]; then
  node "$HERE/reclaim-disk.mjs" --apply "$@"
else
  node "$HERE/reclaim-disk.mjs" "$@"
fi
rc=$?

# The same measurement the gate and the deploy refuse on, not a second opinion.
FLOOR_CHECK="$HERE/check-disk-floor.sh"
if [ -f "$FLOOR_CHECK" ]; then
  floor_out="$(bash "$FLOOR_CHECK" 2>&1)"; floor_rc=$?
  printf '%s\n' "$floor_out" | sed 's/^/disk-reclaim: /'
  case "$floor_rc" in
    0) printf 'disk-reclaim: thresholds ok (>= 3.71 GiB free; 7.4 GiB is the one-gate-away warning, 1 GiB the running node floor)\n' ;;
    1) printf 'disk-reclaim: ALERT below the 3.71 GiB build floor - a build and a publish-less deploy will refuse; the report above is what can be freed, and removal is the operator decision (WA_RECLAIM_MODE=apply)\n' ;;
    *) printf 'disk-reclaim: ALERT the free space could not be measured (exit %s) - an unmeasurable disk is not a healthy one\n' "$floor_rc" ;;
  esac
fi
exit "$rc"
