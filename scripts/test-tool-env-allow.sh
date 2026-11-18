#!/usr/bin/env bash
# Both halves of the tool-environment rule (session isolation, finding 5 round 2): a secret is withheld by
# SHAPE, and a name the node's policy lists under tool_env_allow is handed over.
#
#   scripts/test-tool-env-allow.sh [path/to/wa]
#
# A scratch HOME and database; the canaries are this run's own, never a real credential.
set -u
BIN="${1:-${WA_BIN:-rust/target/release/wa}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/wa-tool-env-XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/home"
export HOME="$SCRATCH/home" WASM_AGENT_HOME="$SCRATCH/home" WASM_AGENT_LUA_ROOT="$ROOT"
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0
export WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 WASM_AGENT_LLM_API_KEY="llm-canary-not-a-real-key"
export GH_TOKEN="gh-canary-not-a-real-token"
export ISOLATION_TEST_TOKEN="token-canary" ISOLATION_TEST_SECRET="secret-canary"
export ISOLATION_TEST_PASSWORD="password-canary" ANTHROPIC_AUTH_TOKEN="anthropic-canary"
export ISOLATION_TEST_PLAIN="plain-value-that-arrives"
status=0
run_mode() {
  local mode="$1"; shift
  WA_SCRIPT="$ROOT/scripts/test-tool-env-allow.lua" WA_TEST_ENV_ALLOW="$mode" "$@" \
    "$BIN" --db "$SCRATCH/$mode.db" || status=1
}
run_mode withheld env -u WA_GRANT_POLICY
printf '%s\n' '{"version":1,"tool_env_allow":["GH_TOKEN"]}' > "$SCRATCH/policy.json"
run_mode granted env WA_GRANT_POLICY="$SCRATCH/policy.json"
exit "$status"

