#!/usr/bin/env bash
# Phase 1 checks, scoped to what this branch changes.
#
# `bash scripts/fast.sh` cannot pass on this machine and does not pass on clean origin/main either:
# test-codemode-boundary.lua, test-cli-view.lua, test-whatsapp-send.lua and
# test-tool-search-names-codemode.lua fail identically on f2af9c67 (measured 10/11, each run alone),
# and every fast.sh run loses 2-3 more Lua tests to `fork: Input/output error` (exit 125/126) under
# xargs -P. This runs the suites that this branch actually moves, and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
WA_BIN="${WA_BIN:-$(command -v wa)}"
NATIVE_NODE="$(command -v node)"; command -v cygpath >/dev/null && NATIVE_NODE="$(cygpath -m "$NATIVE_NODE")"
ROOT="$PWD"
export WASM_AGENT_LUA_ROOT="$ROOT"
H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
export WASM_AGENT_HOME="$(command -v cygpath >/dev/null && cygpath -w "$H" || echo "$H")"
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0

echo '== mcp node suite (incl. runtime closure: lua list == install.sh == deploy.sh == import graph)'
node --test --test-reporter=tap scripts/test-mcp.mjs scripts/test-mcp-session.mjs scripts/test-web.mjs \
  scripts/test-mcp-runtime-closure.mjs scripts/test-whatsapp-connector-http.mjs | tail -6

echo '== lua: the mcp surface this branch edits'
MCP_TEST_SOURCE="$ROOT" WA_NODE="$NATIVE_NODE" WA_MCP_SCRIPT_DIR="$ROOT/scripts" \
  WA_SCRIPT="$ROOT/scripts/test-mcp.lua" "$WA_BIN" --db "$H/mcp.db" | grep 'mcp native ok'

echo '== lua: the explicit send (component outbox producer) and the codemode refusal shape'
WA_SCRIPT="$ROOT/scripts/test-whatsapp-send.lua" "$WA_BIN" --db "$H/send.db" | grep 'whatsapp send ok'
WA_SCRIPT="$ROOT/scripts/test-tool-search-names-codemode.lua" "$WA_BIN" --db "$H/cm.db" | grep 'tool_search names codemode ok'

echo '== deploy ships whatsapp-operator.mjs and its connector client, import-closed'
bash scripts/test-deploy-ship.sh | tail -1

echo '== the operator CLI against a real unpaired connector binary (never pairs, never sends)'
( cd connectors/whatsapp && GOTOOLCHAIN=local go build -o "$H/connector.exe" . )
BIN="$H/connector.exe"; command -v cygpath >/dev/null && BIN="$(cygpath -m "$BIN")"
node scripts/test-whatsapp-operator-process.mjs "$BIN"

echo 'phase1 checks: PASS'
