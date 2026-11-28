#!/usr/bin/env bash
# THE SUPERVISOR IS IN THE MEMBER LIST, SPELLED ONCE (P0, 27/11).
#
# `wa` runs wa-operations-supervisor for every bash/operations call since 03579b19 and nothing shipped it. The names come
# from ONE list, WA_BUNDLE_MEMBERS; a first attempt held bare suffixes and prefixed them inside the loop, producing
# `wa-wa-sentinel-...` - assets no node can find. This row reads that list, builds the names the way every loop does, and
# asserts both the members and the spelling.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/lib/node-binaries.sh"
[ -r "$LIB" ] || { echo "SKIP supervisor-ships: $LIB missing"; exit 0; }
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }
# shellcheck disable=SC1090
. "$LIB"
[ -n "${WA_BUNDLE_MEMBERS:-}" ] || { bad 'WA_BUNDLE_MEMBERS is not defined in scripts/lib/node-binaries.sh'; printf 'supervisor ships: %d checks, %d failed\n' "$checks" "$failed"; exit 1; }
ok 'the member list is defined in the library every other file sources'
for want in wa-sentinel wa-term wa-operations-supervisor; do
  case " $WA_BUNDLE_MEMBERS " in *" $want "*) ok "the list names $want" ;; *) bad "the list does not name $want" ;; esac
done
TRIPLE=x86_64-unknown-linux-gnu; SHORT=0123456789ab; NAMES=""
for m in $WA_BUNDLE_MEMBERS; do NAMES="$NAMES $m-$TRIPLE-$SHORT"; done
case "$NAMES" in *wa-wa-*) bad 'a name is prefixed twice (wa-wa-...)' ;; *) ok 'no name is prefixed twice' ;; esac
case "$NAMES" in *" wa-operations-supervisor-$TRIPLE-$SHORT"*) ok 'the supervisor asset is produced with its full name' ;; *) bad "the supervisor asset is missing from: $NAMES" ;; esac
for f in scripts/publish-node-binaries.sh scripts/lib/node-binaries.sh scripts/deploy.sh scripts/upgrade.sh; do
  grep -q 'wa-operations-supervisor' "$ROOT/$f" && ok "$f carries the supervisor" || bad "$f does not mention it"
done
printf 'supervisor ships: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" -eq 0 ] && echo 'supervisor ships ok'
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
