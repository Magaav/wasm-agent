#!/usr/bin/env bash
# The deterministic `run` step of the job `subagent-return-observe`, and only that.
#
# A sentinel `run` step executes the file it names through a shell (`shell_for` in
# rust/wa-sentinel/src/main.rs hands it to Git Bash on Windows), so the file a job points at has to be a
# shell script that starts the program - the same shape `scripts/delivery-trigger.sh` and
# `scripts/whatsapp-copilot-read.sh` already use.
#
# No arguments are needed: a job's run step has no argument list, and none is wanted. The node's port comes
# from WASM_AGENT_PORT, the authentication session from WA_SENTINEL_AUTH_SESSION, the sentinel binary used
# to emit from WA_SENTINEL_BIN (else `wa-sentinel` on PATH), and the durable "already reported" cursor from
# WA_SENTINEL_RETURN_STATE (else <config>/sentinel/subagent-return-reported.json) - all of them
# machine-local, none of them typed into a job definition.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$HERE/subagent-return-hook.mjs" --observe "$@"
