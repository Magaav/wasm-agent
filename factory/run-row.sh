#!/bin/bash
# run-row.sh <row> [args...]  - the ONLY supported way to run one row BY HAND (29/11 rule from the incident):
# a row runs through the runner, or with HOME and WASM_AGENT_HOME pointing at a scratch dir that was created for
# it - never against ~/.wasm-agent.
#
# Why it exists: on 27/11 a row (test-features-defaults) was run straight at the binaries instead of through
# fast.sh. It wrote a 98-byte test policy over ~/.wasm-agent/policy.json, deleting the mesh section, so the node
# could not reach its peers and WhatsApp reads failed. fast.sh already refuses an operator-store WASM_AGENT_HOME
# (scripts/fast.sh, the wa_tmp_floor_check call); nothing refused when the row was started WITHOUT fast.sh.
#
# This runner hands the row a fresh scratch home (lib/scratch-home.sh) and REFUSES BY NAME when the caller is
# trying to smuggle the real store in through WASM_AGENT_HOME. A real HOME or a TMPDIR under the real home is
# fine: they are replaced here, which is exactly the fix.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$HERE/lib/scratch-home.sh"

row=${1:?usage: run-row.sh <row-name> [args...]}; shift
case "$row" in */*|.*) echo "REFUSED (run-row): $row is not a row name (a row is a file directly under scripts/)" >&2; exit 3;; esac

# The one thing a caller may not bring: the operator's store. Everything else is simply replaced.
real=$(wa_real_home)
if [ -n "${WASM_AGENT_HOME:-}" ]; then
  case "$WASM_AGENT_HOME" in
    "$real"|"$real"/*) wa_require_scratch_home "$row"; exit 3;;
  esac
fi

[ -f "$TOP/scripts/$row" ] || { echo "REFUSED (run-row): no row named $row under $TOP/scripts/" >&2; exit 3; }

wa_scratch_home "$row" || { echo "REFUSED (run-row): could not create a scratch home for $row" >&2; exit 3; }
wa_require_scratch_home "$row" || exit 3

cd "$TOP" && exec bash "scripts/$row" "$@"
