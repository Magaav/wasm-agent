#!/usr/bin/env bash
# The whatsapp ingest, as a job runs it: no model, one line of output.
#
#   bash scripts/whatsapp-ingest.sh            # the job's `run` action calls this
#
# A job's `run` action is a script and nothing else: the sentinel executes it from a directory the
# operator allowed through WA_SENTINEL_SCRIPTS, and the ledger is written by the Lua beside this file
# (which uses the same ingest path as every other observer). It is deliberately not a `wake`: reading
# the inbox and diffing it needs no judgement, and a job that spends a model turn on it is paying for
# an opinion nobody asked for.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The installed node first (that is what a job should use), the checkout's build second, so the same
# script works while it is being developed and after it is installed.
for candidate in \
  "${WA_BIN:-}" \
  "$LOCALAPPDATA/wasm-agent/wa.exe" \
  "$HOME/.local/bin/wa" \
  "$ROOT/rust/target/release/wa" \
  "$ROOT/rust/target/release/wa.exe"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && WA="$candidate" && break
done
if [ -z "${WA:-}" ]; then
  echo "whatsapp ingest unavailable reason=no_binary"
  exit 0
fi

# WA_SCRIPT makes the binary run the Lua instead of a REPL; no port, no HTTP, no interpreter of the
# running node's - so this cannot queue behind a turn that is already in flight.
#
# `cygpath -m` because the binary is native and a POSIX path is not a path to it: `/c/...` is
# unusable as an argument, and the same rule applies to an environment variable read by the host.
lua_script="$ROOT/scripts/whatsapp-ingest.lua"
if command -v cygpath >/dev/null 2>&1; then
  lua_script="$(cygpath -m "$lua_script")"
fi
# `--emit-events` asks for the deterministic emission of the messages that are *new* (see the Lua):
# one `app.message` event per new incoming message, whose id is the message id, so a re-run cannot
# wake anyone twice for the same message. Off by default - a wake is a turn, and turning one on is a
# decision the operator makes, not a side effect of reading the inbox.
if [ "${1:-}" = "--emit-events" ]; then
  export WA_WHATSAPP_EMIT=1
  shift
fi

WA_SCRIPT="$lua_script" "$WA" "$@"
