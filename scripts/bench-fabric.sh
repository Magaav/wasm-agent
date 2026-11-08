#!/usr/bin/env bash
# The fabric's placement latency, measured, on this machine:
#
#   bash scripts/bench-fabric.sh [--rounds N] [--json]
#
# The measurement is the test `wa_fabric::tests::placement_latency_is_one_round_trip_plus_under_five_ms`:
# it binds a real loopback socket, answers `N` offers from a thread, and times two things per round:
#
#   * the **placement decision** — `placement::choose` over a live view (the part this crate owns);
#   * the **offer round trip** — encode, write, the peer's decode/accept/encode, read, decode.
#
# The brief's target is "one RTT + < 5 ms". The decision is the part the fabric adds to an RTT, so that
# is what is asserted (`p95 < 5 ms`) and what this script prints; the RTT is printed next to it so the
# two numbers are read together instead of one standing in for the other.
#
# No node, no network, no state: loopback only. A check that cannot run here (no cargo) is reported
# SKIPPED, never passed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT/rust" || exit 2

rounds=""
json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rounds) rounds=${2:?}; shift 2 ;;
    --json) json=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-fabric: unknown option $1" >&2; exit 2 ;;
  esac
done

if ! command -v cargo >/dev/null 2>&1; then
  echo "bench-fabric: SKIPPED (no cargo here)"
  exit 0
fi

flags=(--offline)
if ! cargo metadata "${flags[@]}" --no-deps --format-version 1 >/dev/null 2>&1; then
  flags=()
fi

# `--rounds` moves the sample count the test uses; the test's own default is 200.
if [ -n "$rounds" ]; then
  case "$rounds" in
    ''|*[!0-9]*) echo "bench-fabric: --rounds needs a number" >&2; exit 2 ;;
  esac
  export WA_FABRIC_ROUNDS="$rounds"
fi

out=$(cargo test -p wa-fabric "${flags[@]}" placement_latency -- --nocapture 2>&1)
status=$?
line=$(printf '%s\n' "$out" | grep -m1 '^fabric latency:' || true)

if [ -z "$line" ]; then
  printf '%s\n' "$out" | tail -20
  echo "bench-fabric: FAIL (the latency test did not report a measurement)"
  exit 1
fi

# The test's line is the only source of these numbers: "… decision p50=2us p95=5us; … p50=83us p95=210us (n=200)".
field() { printf '%s\n' "$line" | sed -n "$1"; }
decide_p50=$(field 's/.*decision p50=\([0-9]*\)us.*/\1/p')
decide_p95=$(field 's/.*decision p50=[0-9]*us p95=\([0-9]*\)us.*/\1/p')
rtt_p50=$(field 's/.*loopback p50=\([0-9]*\)us.*/\1/p')
rtt_p95=$(field 's/.*loopback p50=[0-9]*us p95=\([0-9]*\)us.*/\1/p')
samples=$(printf '%s\n' "$line" | sed -n 's/.*n=\([0-9]*\)).*/\1/p')
met=false
if [ -n "$decide_p95" ] && [ "$decide_p95" -lt 5000 ]; then met=true; fi

if [ "$json" = 1 ]; then
  printf '{"ok":%s,"placement_decision_us":{"p50":%s,"p95":%s},"offer_round_trip_us":{"p50":%s,"p95":%s},"samples":%s,"target":{"overhead_over_one_rtt_ms":5000,"met":%s},"source":"cargo test -p wa-fabric placement_latency -- --nocapture"}\n' \
    "$([ "$status" -eq 0 ] && echo true || echo false)" \
    "${decide_p50:-null}" "${decide_p95:-null}" "${rtt_p50:-null}" "${rtt_p95:-null}" "${samples:-null}" "$met"
else
  printf '%s\n' "$line"
  echo "bench-fabric: target is one round trip + < 5 ms; the decision (p95 ${decide_p95}us) is the part the fabric adds"
fi
exit "$status"
