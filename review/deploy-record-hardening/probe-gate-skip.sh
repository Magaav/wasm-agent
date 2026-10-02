#!/usr/bin/env bash
# Runs the GATE'S OWN skip-handling bytes (scripts/test.sh 280-291 and 1966-1970) around the real suite.
set -uo pipefail
TREE="$1"; SUBJ="$2"
cd "$TREE"
SKIPPED=0
export GATE_TIMINGS_TSV="$(mktemp)"
. scripts/lib/gate-timing.sh
gate_phase_summary() { :; }
echo "----- subject: $SUBJ   (cwd $TREE) -----"
OUT="$(mktemp)"
set +e
eval "$(sed -n '280,291p' scripts/test.sh | sed "s|bash scripts/test-deploy-downgrade.sh|$SUBJ|")" > "$OUT" 2>&1
BLOCK_EXIT=$?
echo "suite output (last 2 lines):"; tail -2 "$OUT" | sed 's/^/    /'
echo "the gate's block left GATE_STATUS=$GATE_STATUS and SKIPPED=$SKIPPED"
echo "the gate's own verdict line would be:"
eval "$(sed -n '1966,1970p' scripts/test.sh)"
echo "harness exit so far: $BLOCK_EXIT (the gate would exit $BLOCK_EXIT on this suite)"
