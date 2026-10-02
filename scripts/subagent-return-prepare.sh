#!/usr/bin/env bash
# The `prepare` step of the `onSubagentReturn` job's wake action, and only that.
#
# The sentinel runs this before it submits the wake and injects what it prints into the wake message
# (`run_prepare` in rust/wa-sentinel/src/jobs.rs). It reads the delivery's own event from
# WA_JOB_EVENT_FILE - the file the sentinel writes for a deterministic step - and makes no network call:
# the child's facts were measured by the observe pass, and the deploy rule that reads them is this
# program's own constant.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$HERE/subagent-return-hook.mjs" --compose --event "${WA_JOB_EVENT_FILE:-}" "$@"
