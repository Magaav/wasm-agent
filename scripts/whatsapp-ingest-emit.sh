#!/usr/bin/env bash
# The ingest's job entry point, and the one place that says "emit".
#
# `whatsapp-ingest.sh` keeps emission behind `--emit-events` on purpose: a wake is a turn, and turning one
# on is the operator's decision rather than a side effect of reading the inbox. A job action carries no
# arguments (`{"kind":"run","script":…}`), so the decision is recorded here, in the script the job names -
# and a job that runs this file has made it. The topic it emits on must match the job that listens for it:
# `whatsapp.message` (jobs/whatsapp-message.json, docs/JOBS.md). The ingest emitted `app.message` until
# 2026-09-21, which is why the reply job had never once been woken.
set -uo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/whatsapp-ingest.sh" --emit-events "$@"
