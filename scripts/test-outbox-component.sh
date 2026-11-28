#!/usr/bin/env bash
# The explicit-send contract is answered by the `outbox` COMPONENT, and by nothing left in the node.
#
# WHY THIS ROW EXISTS. `rust/wa-whatsapp-outbox` was linked into `wa` for the exact-JID rule, the payload,
# the dedupe key and the limits (everything-is-a-component, move 2). A row that only ran
# scripts/test-whatsapp-send.lua would stay green with the crate back in the binary, because the send path
# would answer the same words either way. So this row asserts the two facts that are only true after the
# move:
#
#   1. WITH the component installed, a send is accepted (a valid JID validates and is queued as before) and
#      a bare number is refused with the tool's own word, `whatsapp_send_bad_chat`.
#   2. WITHOUT it, the same send says `outbox_component_absent`. A node that still carried the library
#      would answer a zone here instead - this is the assertion that the crate left the binary.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
bin=${WA_BIN:-$ROOT/rust/target/release/wa}
comp=${WA_OUTBOX:-$HOME/.wasm-agent/components/outbox.wasm}
fail=0
say() { printf '%s\n' "$*"; }
[ -x "$bin" ] || { say "outbox-component: no wa at $bin (set WA_BIN)"; exit 1; }
[ -f "$comp" ] || { say "outbox-component: no outbox.wasm at $comp (run bash scripts/build-components.sh outbox)"; exit 1; }
root=$HOME/.wasm-agent/tmp/outbox-component-$$
mkdir -p "$root" || exit 1
# STOP WHAT THIS ROW STARTS: a node with no rendezvous spawns a wa-operations-supervisor per home, and that
# supervisor outlives the node by design.
reap() {
  for pid in $(ps -eo pid,cmd 2>/dev/null | grep 'wa-operations-supervisor' | grep -v grep \
      | grep -F -- "--rendezvous $root" | awk '{print $1}'); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$root"
}
trap reap EXIT
script=$root/probe.lua
cat > "$script" <<'LUA'
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua"); memory.setup()
local tools = dofile("lua/core/tools.lua")
local ctx = { user_id = "master", role = "master", codemode_nested = true }
local function call(name, args) return tools.dispatch(memory, name, args, "master", ctx) end
print("good=" .. json.encode(call("mcp_whatsapp_send", { chat = "5511999999999@lid", text = "hello" })))
print("bad=" .. json.encode(call("mcp_whatsapp_send", { chat = "5511999999999", text = "hello" })))
LUA
run() { # run <home> <out>
  WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_HOME="$1" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    WA_SCRIPT="$script" timeout 300 "$bin" --db "$1/t.db" >"$2" 2>&1
}

with=$root/with; mkdir -p "$with/.wasm-agent/components"
cp "$comp" "$with/.wasm-agent/components/outbox.wasm"
sha256sum "$comp" | awk '{print $1}' > "$with/.wasm-agent/components/outbox.wasm.sha256"
cp "$ROOT/rust/components/outbox/manifest.json" "$with/.wasm-agent/components/outbox.json"
run "$with" "$root/with.out"
if grep -q 'bad={.*whatsapp_send_bad_chat' "$root/with.out" && grep -q 'good={.*"ok":true' "$root/with.out"; then
  say "ok - with the outbox component a valid JID is accepted and a bare number is refused by the contract"
else
  say "FAIL - the send path did not answer as the contract says:"
  sed -e 's/^/     /' "$root/with.out" | head -6
  fail=1
fi

without=$root/without; mkdir -p "$without"
run "$without" "$root/without.out"
if grep -q 'outbox_component_absent' "$root/without.out"; then
  say "ok - without the component the node says outbox_component_absent: nothing in the host answers it"
else
  say "FAIL - a node with no outbox component validated a send anyway:"
  sed -e 's/^/     /' "$root/without.out" | head -6
  fail=1
fi
[ "$fail" = 0 ] && say "outbox component: 2 checks, 0 failed"
exit "$fail"
