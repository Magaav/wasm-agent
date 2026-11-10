#!/usr/bin/env bash
# `/mcp` checks, scoped to what this branch changes.
#
# `bash scripts/fast.sh` does not pass on this machine and does not pass on clean origin/main either:
# measured 11/11 on 927ba4d9, each run alone, the same ten Lua tests fail on the branch as on the base
# (test-cli-view, test-codemode-boundary, test-codemode-component, test-experiment-verify,
# test-graph-freshness, test-graph-impact-paging, test-graph-automatic, test-graph-workspace,
# test-features-gate, test-patch-audit) - 141/151 passed on the branch against 140/150 on the base, the
# extra test being scripts/test-mcp-command.lua. This runs the suites this branch actually moves.
set -euo pipefail
cd "$(dirname "$0")/.."
WA_BIN="${WA_BIN:-$(command -v wa)}"
NATIVE_NODE="$(command -v node)"; command -v cygpath >/dev/null && NATIVE_NODE="$(cygpath -m "$NATIVE_NODE")"
ROOT="$PWD"
export WASM_AGENT_LUA_ROOT="$ROOT"
H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
export WASM_AGENT_HOME="$(command -v cygpath >/dev/null && cygpath -w "$H" || echo "$H")"
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0

echo '== the command itself: local + peer connectors, verbatim names, both toggles, guest, session update'
WA_SCRIPT="$ROOT/scripts/test-mcp-command.lua" "$WA_BIN" --db "$H/command.db" | grep 'mcp command ok'

echo '== the registry it reads, over a real stdio handshake (probe, enable, call, disable)'
MCP_TEST_SOURCE="$ROOT" WA_NODE="$NATIVE_NODE" WA_MCP_SCRIPT_DIR="$ROOT/scripts" \
  WA_SCRIPT="$ROOT/scripts/test-mcp.lua" "$WA_BIN" --db "$H/mcp.db" | grep 'mcp native ok'

echo '== the federation it reads and writes (catalog, local names, call, control)'
WA_SCRIPT="$ROOT/scripts/test-federation.lua" "$WA_BIN" --db "$H/federation.db" | tail -1

echo '== the prefix rule the change is announced through'
WA_SCRIPT="$ROOT/scripts/test-prompt-cache.lua" "$WA_BIN" --db "$H/prompt-cache.db" | tail -1

echo '== the native connector contract it lists'
WA_SCRIPT="$ROOT/scripts/test-mcp-native.lua" "$WA_BIN" --db "$H/native.db" | tail -1

echo '== one command list in two surfaces: every row armed, no window-only command, usage inside the column'
node scripts/test-command-parity.cjs | tail -1
node --check ui/app.js
node --check ui/components.js
echo '== the panel and the command are wired to the same endpoint'
node --test --test-reporter=tap scripts/test-mcp.mjs scripts/test-mcp-runtime-closure.mjs | tail -4

echo 'mcp-command checks: PASS'
