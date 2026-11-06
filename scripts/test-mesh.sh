#!/usr/bin/env bash
# The mesh (docs/MESH.md) test run: the crate's own tests, loopback only.
#
#   bash scripts/test-mesh.sh [--offline]
#
# What it runs: `cargo test -p wa-mesh` and `cargo clippy -p wa-mesh --all-targets`, which are the
# three-node end-to-end file (levels 0/1/1, a test rendezvous that is killed after bootstrap, the
# hierarchy on both ends, a tampered roster) plus the unit tests of the roster, the policy section,
# the peer cache, the wire envelopes, the audit lines and the tiny HTTP dialect.
#
# What it deliberately does NOT do: start a `wa serve`, contact a rendezvous, join the fabric, or read
# a node home. Every listener in the tests binds 127.0.0.1:0 and every identity lives in the system
# temp directory, so this cannot meet `~/.wasm-agent`, port 8799/8800/8890, or another node.
#
# `--offline` is passed through when the machine has no registry access; `cargo fetch` once is enough
# to make it work, because the crate adds no external dependency of its own (ring, serde, serde_json
# and wa-grant-policy are all already in the workspace lock).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT/rust" || exit 2
offline=""
[ "${1:-}" = "--offline" ] && offline="--offline"
status=0
echo "== cargo test -p wa-mesh"
cargo test -p wa-mesh $offline || status=1
echo "== cargo clippy -p wa-mesh --all-targets"
cargo clippy -p wa-mesh --all-targets $offline || status=1
exit $status
