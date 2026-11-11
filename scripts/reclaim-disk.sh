#!/usr/bin/env bash
# The job's `run` step, and only that.
#
# A sentinel `run` step executes the script it names through a shell (`shell_for` in
# rust/wa-sentinel/src/main.rs hands it to Git Bash on Windows), so the file a job points at has to be a
# shell script that starts the program - which is also how this repository's other jobs do it
# (`scripts/delivery-trigger.sh` and friends). The pass itself is
# Node, where the walks, the session store and the JSON live.
#
# ACTIVE BY DEFAULT (2026-11-11). This script removed nothing on its first scheduled tick when it was
# written (wave 5): the only way to reclaim was `WA_RECLAIM_MODE=apply`, which nothing set, so the job
# reported a plan every hour while the disk filled. Disk-full then froze this node twice in one night
# (00:47 and ~01:18 on 11/11) and killed it for ~1h44. The operator approved active reclaim for the
# named safe categories, so the job is the pass and the pass removes - see
# `scripts/reclaim-disk.mjs` for the never-touch list and each category's rule.
#
#   bash scripts/reclaim-disk.sh              # the job: active, on the safe categories
#   bash scripts/reclaim-disk.sh --dry-run    # the operator: the plan, nothing removed
#   WA_RECLAIM_MODE=report bash scripts/...   # the same dry run, for a caller that sets the variable
#
# Nothing here decides a category: the categories, their keep rules and the never-touch list live in one
# place (`NEVER_TOUCH` and the `*Pass` functions in reclaim-disk.mjs), so a reading of this file cannot
# disagree with what the pass does.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${WA_RECLAIM_MODE:-apply}"
case "$MODE" in
  apply)  node "$HERE/reclaim-disk.mjs" --apply "$@" ;;
  report|dry-run|dry) node "$HERE/reclaim-disk.mjs" --dry-run "$@" ;;
  *)
    # An unrecognised mode is refused, not defaulted: a typo must not silently turn the active pass
    # back into a report (the failure this file exists to stop) or into an unexpected removal.
    printf 'disk-reclaim: WA_RECLAIM_MODE=%s is not one of apply, report, dry-run\n' "$MODE" >&2
    exit 2
    ;;
esac
rc=$?

# The same measurement the gate and the deploy refuse on, not a second opinion.
FLOOR_CHECK="$HERE/check-disk-floor.sh"
if [ -f "$FLOOR_CHECK" ]; then
  floor_out="$(bash "$FLOOR_CHECK" 2>&1)"; floor_rc=$?
  printf '%s\n' "$floor_out" | sed 's/^/disk-reclaim: /'
  case "$floor_rc" in
    0) printf 'disk-reclaim: thresholds ok (>= 3.71 GiB free; 7.4 GiB is the one-gate-away warning, 1 GiB the running node floor)\n' ;;
    1) printf 'disk-reclaim: ALERT below the 3.71 GiB build floor - a build and a publish-less deploy will refuse; the pass above freed what the safe categories hold\n' ;;
    *) printf 'disk-reclaim: ALERT the free space could not be measured (exit %s) - an unmeasurable disk is not a healthy one\n' "$floor_rc" ;;
  esac
fi
exit "$rc"
