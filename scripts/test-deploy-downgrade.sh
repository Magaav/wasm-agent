#!/usr/bin/env bash
# The downgrade rule, tested once: this file now hands over to the test that owns it.
#
# WHY THIS IS A SHIM. Until 18/11 the rule was decided from installed.txt - the record the installing party wrote,
# which on that day said commit=14963b6f for a binary built from 8 commits that were on no landed branch. The
# guard compared this tree against that record, saw an ancestor, and let a deploy replace work that was running.
# The rule is the same rule (a deploy may not replace a commit the target does not contain) and it is now decided
# from the RUNNING BINARY's own answer, with the record as a named fallback.
#
# Two tests for one rule drift apart, and the one that is not maintained is the one that lies. So the cases this
# file used to drive - a newer install refused, an ancestor accepted, and the three "cannot tell" shapes (no
# record, a record naming no commit, a commit this tree does not have) - live in
# scripts/test-deploy-ancestry.sh, which drives them through the same deploy.sh. The name stays because
# docs/TORUS.md and the gate measurement list it, and a pointer is cheaper than a stale assertion.
#
# Usage:  bash scripts/test-deploy-downgrade.sh [--help]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  ''|--run) ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "test-deploy-downgrade: unknown argument $1" >&2; exit 2 ;;
esac
echo "test-deploy-downgrade: the rule moved; running the test that owns it (scripts/test-deploy-ancestry.sh)"
exec bash "$ROOT/scripts/test-deploy-ancestry.sh"
