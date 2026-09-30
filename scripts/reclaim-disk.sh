#!/usr/bin/env bash
# The job's `run` step, and only that.
#
# A sentinel `run` step executes the script it names through a shell (`shell_for` in
# rust/wa-sentinel/src/main.rs hands it to Git Bash on Windows), so the file a job points at has to be a
# shell script that starts the program - which is also how this repository's other jobs do it
# (`scripts/delivery-trigger.sh`, `scripts/whatsapp-copilot-read.sh` and friends). The pass itself is
# Node, where the walks, the session store and the JSON live.
#
# No arguments are needed: a job's run step has no argument list, and none is wanted. `--apply` is *not*
# passed from here: the job's script is the report, and the removal is a decision a runner makes with
# `--apply` in front of it. (A reclaim that quietly deletes on its first scheduled tick is how a tree
# somebody still wanted disappears.) The free space and the armed mode are named on every run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${WA_RECLAIM_MODE:-report}"
if [ "$MODE" = "apply" ]; then
  exec node "$HERE/reclaim-disk.mjs" --apply "$@"
fi
exec node "$HERE/reclaim-disk.mjs" "$@"
