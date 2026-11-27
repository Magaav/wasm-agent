#!/usr/bin/env bash
# Carry exactly the ffmpeg one configured build compiled, plus everything those files include, so a component
# can build it hermetically (no network, a verifiable pin). The work is in vendor-ffmpeg-source.py: the
# include closure is a breadth-first walk, and doing it in bash cost minutes per run and five patches.
#
#   bash scripts/vendor-ffmpeg-source.sh <built-ffmpeg-tree> <destination>
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/vendor-ffmpeg-source.py" "$@"
