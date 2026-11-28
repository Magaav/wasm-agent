#!/usr/bin/env bash
# The node's zone is answered by the `tz` COMPONENT, and by nothing left in the host binary.
#
# WHY THIS ROW EXISTS. `rust/wa-local-tz` used to be linked into `wa`, so `host.local_tz` could be answered
# without any component at all and a change to how the OS zone is read rebuilt the node
# (everything-is-a-component, first move). A row that only runs `scripts/test-local-tz.lua` would stay
# green with the old code back in the binary, because the native path answers the same values. So this row
# asserts the two things that are only true after the move:
#
#   1. WITH the tz component installed, the Lua core running inside the agent-core component gets the zone
#      from it and `scripts/test-local-tz.lua` passes (`node local time zone ok`).
#   2. WITHOUT it, the same run says `zone_source=tz_component_absent`. If the host still carried the
#      library it would answer a zone here instead - this is the assertion that the host no longer links
#      `wa-local-tz`.
#
# Inputs, all optional and defaulted: WA_BIN (the node built from this tree), WA_CORE (agent-core.wasm),
# WA_TZ (tz.wasm). Built by `cargo build --release -p wa-host` and `bash scripts/build-agent-core.sh` /
# `bash scripts/build-components.sh tz`.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
bin=${WA_BIN:-$ROOT/rust/target/release/wa}
core=${WA_CORE:-$ROOT/rust/components/agent-core/target/wasm32-wasip2/release/agent_core.wasm}
tz=${WA_TZ:-$HOME/.wasm-agent/components/tz.wasm}
fail=0
say() { printf '%s\n' "$*"; }
[ -x "$bin" ] || { say "tz-component: no wa at $bin (set WA_BIN)"; exit 1; }
[ -f "$core" ] || { say "tz-component: no agent-core at $core (run bash scripts/build-agent-core.sh)"; exit 1; }
[ -f "$tz" ] || { say "tz-component: no tz.wasm at $tz (run bash scripts/build-components.sh tz)"; exit 1; }
# The core component refuses a home that is not under the node's own scratch root, so the scratch lives
# there - the same rule scripts/test-core-parity.sh obeys.
root=$HOME/.wasm-agent/tmp/tz-component-$$
mkdir -p "$root" || exit 1
# STOP WHAT THIS ROW STARTS (orchestrator, 28/11: 388 orphaned wa-operations-supervisor processes came from a
# worker's test runs). A node with no rendezvous spawns a supervisor of its own per home, and that supervisor
# outlives the node by design - it is a service. A row that makes homes must therefore take their supervisors
# with them, or every run leaves a process behind for ever.
reap() {
  for pid in $(ps -eo pid,cmd 2>/dev/null | grep 'wa-operations-supervisor' | grep -F -- "--rendezvous $root" \
      | grep -v grep | awk '{print $1}'); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$root"
}
trap reap EXIT
run() { # run <home> <out>
  WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_HOME="$1" WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
    timeout 300 "$bin" --db "$1/t.db" --core-component "$core" "$ROOT/scripts/test-local-tz.lua" >"$2" 2>&1
  echo $?
}

with=$root/with; mkdir -p "$with/.wasm-agent/components"
cp "$tz" "$with/.wasm-agent/components/tz.wasm"
# The pin and the manifest are what the loader checks before it will run a component at all.
sha256sum "$tz" | awk '{print $1}' > "$with/.wasm-agent/components/tz.wasm.sha256"
cp "$ROOT/rust/components/tz/manifest.json" "$with/.wasm-agent/components/tz.json"
code=$(run "$with" "$root/with.out")
if [ "$code" = 0 ] && grep -q 'node local time zone ok' "$root/with.out"; then
  say "ok - with the tz component, the guest's host.local_tz is answered by it (test-local-tz green)"
else
  say "FAIL - the guest could not get its zone from the tz component (exit $code):"
  sed -e 's/^/     /' "$root/with.out" | head -8
  fail=1
fi

without=$root/without; mkdir -p "$without"
code=$(run "$without" "$root/without.out")
if grep -q 'zone_source=tz_component_absent' "$root/without.out"; then
  say "ok - without the component the node says tz_component_absent: nothing in the host answers it"
else
  say "FAIL - a node with no tz component answered a zone anyway (exit $code):"
  sed -e 's/^/     /' "$root/without.out" | head -8
  fail=1
fi
[ "$fail" = 0 ] && say "tz component: 2 checks, 0 failed"
exit "$fail"
