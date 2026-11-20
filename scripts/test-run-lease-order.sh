#!/usr/bin/env bash
# The NEGATIVE CONTROL for scripts/test-run-lease-order.lua: it reverts the release order to the BASE
# behaviour (announce the failure, THEN release the lease) and requires the Lua test to FAIL. A test that
# passes both ways proves nothing, so this is what makes "release before announce" a measured fact.
#
#   1. the row passes with the tree as it is;
#   2. reverted to the base order, the row FAILS (by EXIT CODE, not by the word it prints - a failing row
#      still prints its "ok ... N checks, M failed" line, which is how a grep-based control would lie);
#   3. the file is restored byte for byte and the row passes again.
#
# Scratch node only, no network, no model: the whole thing is seconds.
set -u
WT=$(cd "$(dirname "$0")/.." && pwd)
cd "$WT" || exit 1
BACKUP=$(mktemp -t wa-agent-order.XXXXXX)
cp lua/core/agent.lua "$BACKUP" || exit 1
restore() { cp "$BACKUP" lua/core/agent.lua; rm -f "$BACKUP"; }
trap restore EXIT

# Run the row in its own scratch node. Answers the row's OWN exit status.
run_row() {
  local scratch out code
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/wa-lease-order.XXXXXX") || return 99
  mkdir -p "$scratch/home"
  out=$(WASM_AGENT_HOME="$scratch/home" WASM_AGENT_LUA_ROOT="$WT" \
    WA_SCRIPT=scripts/test-run-lease-order.lua timeout 300 "${WA_BIN:-wa}" --db "$scratch/x.db" 2>&1)
  code=$?
  rm -rf "$scratch"
  printf '%s\n' "$out"
  return $code
}

echo "lease-order: the row as the tree is"
if ! run_row | tail -3; then
  echo "lease-order: the row FAILED on the tree as it is - fix the row before trusting this control" >&2
  exit 1
fi
if ! run_row >/dev/null; then
  echo "lease-order: the row FAILED on the tree as it is - fix the row before trusting this control" >&2
  exit 1
fi

echo "lease-order: reverting to the base order (announce, then release)"
python3 - "$WT/lua/core/agent.lua" <<'PY' || exit 1
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

run_row | grep -E '^FAIL|^ok lease-order' | tail -3
if run_row >/dev/null; then
  echo "lease-order: the row PASSED with the base order - it does not discriminate, so it proves nothing" >&2
  exit 1
fi
echo "lease-order: the row fails with the base order, as it must"

restore
trap - EXIT
if ! run_row >/dev/null; then
  echo "lease-order: the row failed after restoring the tree - the restore is broken" >&2
  exit 1
fi
echo "lease-order ok: release-before-announce is measured, not assumed"
