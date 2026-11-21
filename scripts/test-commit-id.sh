#!/usr/bin/env bash
# wa_same_commit: a short and a long spelling of one commit are the same commit; anything else is not.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/commit-id.sh
n=0; fail() { echo "FAIL test-commit-id: $*" >&2; exit 1; }
wa_same_commit bcacbf38 bcacbf38eb3b || fail "short and long spelling of one commit (the 21/11 deploy refusal)"; n=$((n+1))
wa_same_commit bcacbf38eb3b bcacbf38eb3b3f0397011abef9c14689bc37d169 || fail "12 hex and 40 hex of one commit"; n=$((n+1))
wa_same_commit bcacbf38 bcacbf39eb3b && fail "two different commits are not the same"; n=$((n+1))
wa_same_commit bcacbf bcacbf38eb3b && fail "6 hex is too short to tell"; n=$((n+1))
wa_same_commit "" bcacbf38eb3b && fail "an empty id is never the same commit"; n=$((n+1))
wa_same_commit unknown unknown && fail "a non-hex id is never the same commit"; n=$((n+1))
grep -q 'wa_same_commit "\$record_commit" "\$record_expected"' scripts/deploy.sh || fail "deploy.sh compares the installed commit with wa_same_commit"; n=$((n+1))
echo "commit id ok ($n checks)"
