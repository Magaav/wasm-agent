#!/usr/bin/env bash
# The fabric's checks in one command: the rules (`wa-fabric`), the node half (`fabric_node`) and the
# first user (the speech queue's fabric seam). Minutes, no node, no network, no state:
#
#   bash scripts/test-fabric.sh [--jobs N]
#
# What it proves, and where the exact numbers come from:
#   * placement picks the idle capable node, and the score's terms say why (`wa-fabric` tests);
#   * a node killed mid-job loses its lease, the job is requeued and finished exactly once — the dead
#     node's late settle is refused by `wa-queue` (`a_node_killed_mid_job_loses_its_lease_...`);
#   * every peer gone runs locally without waiting, and a silent peer costs exactly the 200 ms window
#     (`all_peers_gone_...`, `a_silent_peer_costs_exactly_the_window_...`);
#   * the flag off is the pre-fabric path (`the_fabric_off_is_the_local_path`,
#     `without_a_placement_the_old_policy_decides`);
#   * the placement latency distribution (`placement_latency_is_one_round_trip_plus_under_five_ms`);
#   * the node half: presence, the offer pump, the lease and the admin view (`fabric_node` tests).
#
# A check that cannot run here (no cargo) is reported SKIPPED and counted, never passed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT/rust" || exit 2

jobs=$(nproc 2>/dev/null || echo 4)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) jobs=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-fabric: unknown option $1" >&2; exit 2 ;;
  esac
done

if ! command -v cargo >/dev/null 2>&1; then
  echo "test-fabric: SKIPPED (no cargo here)"
  exit 0
fi

# Offline first: the workspace's lockfile is the contract, and the fabric adds no dependency the graph
# did not already have (`wa-queue`, `serde_json`).
cargo_flags=(--offline)
if ! cargo metadata "${cargo_flags[@]}" --no-deps --format-version 1 >/dev/null 2>&1; then
  cargo_flags=()
fi

fails=0
run() {
  local label=$1; shift
  echo "== $label"
  if ! cargo test "$@" "${cargo_flags[@]}" -- --test-threads="$jobs" 2>&1 | tail -6; then
    fails=$((fails + 1))
    echo "FAIL $label"
  fi
}

run "wa-fabric: the rules" -p wa-fabric
run "wa-stt-remote: the speech queue, fabric seam included" -p wa-stt-remote
run "wa-kernel-runtime: the node half" -p wa-kernel-runtime fabric_node

if [ "$fails" -eq 0 ]; then
  echo "test-fabric: ok"
else
  echo "test-fabric: $fails check(s) failed"
fi
exit "$fails"
