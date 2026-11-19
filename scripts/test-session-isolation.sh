#!/usr/bin/env bash
# The session-isolation suite, with the canaries its two environment sections exist to withhold.
#
#   scripts/test-session-isolation.sh [path/to/wa]
#
# The .lua row is hermetic already; what it cannot invent is a node that HOLDS a secret. This wrapper
# exports canaries shaped like the real names (a token, an LLM key, a vault admin token, a GH token) and
# one plainly-visible control, on a scratch HOME and database and this tree Lua, then runs the row. The
# values are this run own, never a real credential, and the row prints a named SKIP for either section
# when they are absent - so a bare bash scripts/test-session-isolation.lua never passes by omission.
set -u
BIN="${1:-${WA_BIN:-rust/target/release/wa}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wa-session-isolation-XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/home"
export HOME="$SCRATCH/home" WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$ROOT"
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0
export WA_SCRIPT="$ROOT/scripts/test-session-isolation.lua"
export OPENAI_API_KEY="sk-...0001" WASM_AGENT_LLM_API_KEY="llm-canary-not-a-real-key-0002"
export WA_VAULT_ADMIN_TOKEN="vault-admin-canary-not-a-real-0003" GH_TOKEN="gh-canary-not-a-real-0004"
export WA_TEST_CANARY_VISIBLE="visible-to-children"
export ISOLATION_TEST_TOKEN="token-canary-not-a-real-0005" ISOLATION_TEST_SECRET="secret-canary-not-a-real-0006"
export ISOLATION_TEST_PASSWORD="password-canary-not-a-real-0007" ANTHROPIC_AUTH_TOKEN="anthropic-canary-not-a-real-0008"
export ISOLATION_TEST_PLAIN="plain-value-that-arrives"
exec "$BIN" --db "$SCRATCH/t.db"
