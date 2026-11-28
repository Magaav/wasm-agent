#!/bin/bash
# TWO ROOTS NEVER SHARE ONE GRAPH STORE (`_queue/graph-one-store-per-root.md`, closed 28/11 as satisfied
# in code - and this is the row that keeps it satisfied).
#
# The property is a pair of library tests, and a test nobody runs is a comment. This row fails three
# ways: if either test is DELETED (it greps --list for the exact names), if either goes RED, or if the
# count changes so a rename cannot pass silently. The names are the contract:
#   two_roots_get_two_stores_and_never_the_shared_one
#   two_roots_alternating_never_claim_or_read_each_others_store
#
# Why a row and not just the cargo gate: `scripts/test.sh` runs the whole library suite, so deleting
# one test would still leave the gate green. This one names the property.
set -u
cd "$(dirname "$0")/.." || exit 1

CARGO=${CARGO:-cargo}
ONE=two_roots_get_two_stores_and_never_the_shared_one
TWO=two_roots_alternating_never_claim_or_read_each_others_store

# The list prints `graph::tests::<name>: test`, so the names are matched wherever they sit.
listed=$($CARGO test --offline -p wa-capabilities --lib --manifest-path rust/Cargo.toml -- --list 2>/dev/null | grep -cE "(^|::)${ONE}: test$|(^|::)${TWO}: test$")
if [ "${listed:-0}" -ne 2 ]; then
  echo "FAIL neither property test is present by name (found $listed of 2): a rename or a deletion is a lost rule"
  exit 1
fi

total=""
for name in "$ONE" "$TWO"; do
  out=$($CARGO test --offline -p wa-capabilities --lib --manifest-path rust/Cargo.toml "$name" 2>&1)
  case "$out" in
    *"1 passed"*) : ;;
    *) echo "FAIL $name did not pass:"; echo "$out" | tail -12; exit 1 ;;
  esac
  total="$total $name"
done

echo "graph one-store-per-root ok (2 properties: two roots get two stores; alternating calls share none)"
