#!/usr/bin/env bash
# The job's `run` step, and only that.
#
# A sentinel `run` step executes the script it names through a shell (`shell_for` in
# rust/wa-sentinel/src/main.rs hands it to Git Bash on Windows), so the file a job points at has to be
# a shell script that starts the program - which is also how this repository's other jobs do it
# (`scripts/whatsapp-copilot-read.sh` and friends). The program itself is Node, where the reading, the
# git calls and the JSON live.
#
# No arguments are needed: a job's run step has no argument list, and none is wanted. Every path the
# program uses comes from the record (`repository`), from `WA_DELIVERY_STORE`, or from the sentinel's
# own store root - all of them machine-local, none of them typed into a job definition.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$HERE/delivery-trigger.mjs" "$@"
