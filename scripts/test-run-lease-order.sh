#!/usr/bin/env bash
# The NEGATIVE CONTROL for scripts/test-run-lease-order.lua: it reverts the release order to the BASE
# behaviour (announce the failure, THEN release the lease) and requires the Lua test to FAIL. A test that
# passes both ways proves nothing, so this is what makes "release before announce" a measured fact.
#
# IT NEVER WRITES THE TREE (review r2, item 4). The earlier version patched lua/core/agent.lua in place
# and restored it afterwards; a run interrupted between those two steps left the checkout modified, which
# is how a control script becomes the incident. This copies the Lua root to a scratch directory, patches
# the COPY, and points WASM_AGENT_LUA_ROOT at it. Nothing outside ${TMPDIR:-/tmp} is ever written.
#
#   1. the row passes against this tree;
#   2. against a scratch copy with the base order, the row FAILS (by EXIT CODE - a failing row still
#      prints its "ok ... N failed" line, which a grep-based control would read as a pass);
#   3. the row passes again against this tree.
#
# Scratch node only, no network, no model.
set -u
# python3 edits the scratch COPY of agent.lua that carries the base order. Without it this control
# cannot build its negative case, so it says so and exits 77 - the gate's own skip code - rather than
# passing vacuously.
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP test-run-lease-order: no python3 to build the scratch base-order copy"
  exit 77
fi
WT=$(cd "$(dirname "$0")/.." && pwd)
cd "$WT" || exit 1
SCRATCH_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wa-lease-control.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH_ROOT"' EXIT

# Run the row against a given Lua root. Answers the row's OWN exit status.
run_row() {
  local root=$1 scratch out code
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/wa-lease-node.XXXXXX") || return 99
  mkdir -p "$scratch/home"
  out=$(WASM_AGENT_HOME="$scratch/home" WASM_AGENT_LUA_ROOT="$root" \
    LEASE_PROBE_BIN="${WA_BIN:-wa}" \
    WA_SCRIPT=scripts/test-run-lease-order.lua timeout 300 "${WA_BIN:-wa}" --db "$scratch/x.db" 2>&1)
  code=$?
  rm -rf "$scratch"
  printf '%s\n' "$out"
  return $code
}

echo "lease-order: the row against this tree"
if ! run_row "$WT" | tail -2; then
  echo "lease-order: the row FAILED on this tree - fix it before trusting this control" >&2
  exit 1
fi
if ! run_row "$WT" >/dev/null; then
  echo "lease-order: the row FAILED on this tree - fix it before trusting this control" >&2
  exit 1
fi

echo "lease-order: building a scratch Lua root with the base order (announce, then release)"
COPY="$SCRATCH_ROOT/tree"
mkdir -p "$COPY"
cp -a "$WT/lua" "$COPY/lua" || exit 1
python3 - "$COPY/lua/core/agent.lua" <<'PY' || exit 1
import sys
p = sys.argv[1]
t = open(p).read()
a = t.index('  -- THE RUN LEASE IS RELEASED BEFORE THE FAILURE IS SIGNALLED')
b = t.index('  telemetry.finish(span,{ok=ok,error=not ok and tostring(result) or nil})', a)
base = '''  if not ok then
    local failure=self.pending_failure or {}
    local ending=run_failure.handle(tostring(result), {
      session_id=self.session_id,user_id=self.user,run_id=self.run_id,
      trace=failure.trace,round=failure.round,attempts=failure.attempts,
      debug=self.debug,subagent=self.subagent and true or false,
      self_wake=self.self_wake and true or false,
      last_user=self.last_user_text,
      record=function(turn) return record_turn(self, turn) end,
      ms=math.max(0,math.floor((host.now()-(self.run_counts.started_at or host.now()))*1000)),
      emit=function(event) pcall(self.emit,event) end,
    })
    self.failure=ending.info
  end
  local released=resources.finish(resource_ctx)
  if not released.ok then
    released.uncertain=not ok and resources.uncertain(resource_ctx) or nil
    self.emit({type="error",error="resource_release_failed: "..json.encode(released)})
    ok,result=false,"resource_release_failed: "..json.encode(released)
  end
'''
t = t[:a] + base + t[b:]
open(p, 'w').write(t)
PY

run_row "$COPY" | grep -E '^FAIL|^ok lease-order' | tail -3
if run_row "$COPY" >/dev/null; then
  echo "lease-order: the row PASSED with the base order - it does not discriminate, so it proves nothing" >&2
  exit 1
fi
echo "lease-order: the row fails with the base order, as it must"

if ! run_row "$WT" >/dev/null; then
  echo "lease-order: the row failed on the real tree - something outside this control changed it" >&2
  exit 1
fi
echo "lease-order ok: release-before-announce is measured, and this script never writes the tree"
