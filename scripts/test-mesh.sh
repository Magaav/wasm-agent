#!/usr/bin/env bash
# The mesh (docs/MESH.md) test run: the crate's own tests and the Lua admission, loopback only.
#
#   bash scripts/test-mesh.sh [--offline]
#
# What it runs:
#   * `cargo test -p wa-mesh` and `cargo clippy -p wa-mesh --all-targets` — the three-node end-to-end
#     file (levels 0/1/1, a test rendezvous killed after bootstrap, the hierarchy on both ends, a
#     tampered roster) and `tests_relay.rs`, the four-node case the fleet actually has: A(0), B(1),
#     T(1) and R with no address at all, T pinning [B] the way `nextcloud` pins its operators. Before
#     the push A is refused through the relay (T has no roster, so its pins decide); B pushes the
#     roster; after it A is allowed through the same relay, T->A is denied by the hierarchy, a tampered
#     relayed body and a replayed one are refused, and a target pinning another fleet key refuses the
#     push. Plus the unit tests of the roster, the policy section, the peer cache, the wire envelopes,
#     the audit lines and the tiny HTTP dialect.
#   * three Lua tests against the real `lua/` tree, each in its own scratch home:
#       - `scripts/test-mesh-admission.lua` — the real `lua/core/binding.lua`: a caller absent from
#         the operator pins is refused, a `roster` push from a pinned operator installs the roster
#         (policy merge + backup + roster file + env), and a relayed mesh call is admitted by the
#         roster for exactly one call;
#       - `scripts/test-mesh-verb-admission.lua` — the managed node's admission by the mesh's verb
#         (`read`/`control`/`call`), with the legacy name list unchanged and every forged, stale or
#         differently-bound attestation refused;
#       - `scripts/test-mesh-attest.lua` — the same rule, with the attestation produced by the **Rust**
#         mount (`host.mesh_call`'s `{attest: …}`, `wa_mesh::attest::sign`) and verified by the real
#         `wa_node_call`: a roster-authorized `bash`/`sessions` call is admitted by its verb.
#     Skipped, never silently passed, when there is no `wa` binary to run them.
#   * `scripts/test-mesh-live.sh` is separate on purpose (it starts a `wa serve`, in a scratch home,
#     on a fresh port, and kills it by its own pid): `bash scripts/test-mesh-live.sh` measures the
#     operator's keygen/sign/show round trip and three live enable/disable cycles on a running node.
#
# What the Lua tests deliberately do NOT do: start a `wa serve`, contact a rendezvous, join the
# fabric, or read a node home. Every listener in the tests binds 127.0.0.1:0 and every identity lives
# in the system temp directory, so this cannot meet `~/.wasm-agent`, port 8799/8800/8890, or another
# node. Each Lua test gets a scratch `WASM_AGENT_HOME` and an empty rendezvous/relay, the same way
# `scripts/fast.sh` runs every Lua test.
#
# `--offline` is passed through when the machine has no registry access; `cargo fetch` once is enough
# to make it work, because the crate adds no external dependency of its own (ring, serde, serde_json
# and wa-grant-policy are all already in the workspace lock).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
offline=""
[ "${1:-}" = "--offline" ] && offline="--offline"
status=0
cd "$ROOT/rust" || exit 2
echo "== cargo test -p wa-mesh"
cargo test -p wa-mesh $offline || status=1
echo "== cargo clippy -p wa-mesh --all-targets"
cargo clippy -p wa-mesh --all-targets $offline || status=1

bin="${WA_BIN:-}"
for c in "$(command -v wa 2>/dev/null)" "$HOME/.local/bin/wa" "$ROOT/rust/target/release/wa"          "$ROOT/rust/target/release/wa.exe" "$ROOT/rust/target/debug/wa" "$ROOT/rust/target/debug/wa.exe"; do
  [ -n "$bin" ] && break; [ -n "$c" ] && [ -x "$c" ] && bin="$c"
done
if [ -z "$bin" ]; then
  echo "mesh: the Lua admission tests SKIPPED (no wa binary: set WA_BIN or build rust/wa-host)"
  exit $status
fi
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
# The tests that need the feature gate answer it from `policy.json` themselves where they can; this
# flag is the same one a fleet node would have, and it is the operator's process switch.
for test in test-mesh-admission.lua test-mesh-verb-admission.lua test-mesh-attest.lua; do
  echo "== scripts/$test"
  home=$(mktemp -d "${TMPDIR:-/tmp}/wa-mesh-lua-XXXXXX")
  WASM_AGENT_LUA_ROOT="$(native "$ROOT")" WASM_AGENT_HOME="$(native "$home")"     WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 WA_MESH=1     WA_SCRIPT="$(native "$ROOT/scripts/$test")" timeout 120 "$bin" --db "$(native "$home/t.db")"     || status=1
  rm -rf "$home"
done
exit $status
