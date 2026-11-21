#!/usr/bin/env bash
# The Lua scratch-home guard refuses the same things the shell guard does (item 3 of the node-ops round).
# It is one file (scripts/lib/scratch-home.lua) read by four rows, so it is judged on its own: the case
# that started this rule is WASM_AGENT_HOME=$HOME, which the old per-row guards PASSED and which writes
# the operator's real ~/.wasm-agent.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
WORK="${WA_TEST_ROOT:-$(dirname "$ROOT")}/.wa-test-scratch-home-lua-$$"
rm -rf "$WORK"; mkdir -p "$WORK/home" "$WORK/row-home/.wasm-agent" || exit 2
. "$ROOT/scripts/lib/scratch-home.sh"
wa_scratch_home_guard "$WORK/home" || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$(command -v wa || true)"
[ -x "$BIN" ] || { echo 'SKIP test-scratch-home-lua: no wa binary to run the guard with'; exit 0; }
cat > "$WORK/probe.lua" <<'LUA'
-- Every case is an explicit home, so one process proves the whole rule (scripts/lib/scratch-home.lua).
local guard = dofile('scripts/lib/scratch-home.lua')
-- THE OPERATOR HOME, AS THE NODE SAW IT BEFORE IT WAS OVERRIDDEN: wa sets HOME from WASM_AGENT_HOME at
-- startup, so a row that read HOME would be reading its own scratch home and every case below would be
-- about itself. WA_HOME_BEFORE_OVERRIDE is what the launcher recorded (rust/wa-host/src/main.rs).
local home = (host.getenv('WA_HOME_BEFORE_OVERRIDE') or ''):gsub('/+$', '')
assert(home ~= '', 'the node did not record the home it replaced (WA_HOME_BEFORE_OVERRIDE), so this probe would be comparing a home with itself')
local store = home .. '/.wasm-agent'
local above = home:match('^(.*)/[^/]+$') or '/'
local scratch_home = host.getenv('WASM_AGENT_HOME') or ''
local cases = {
  { name = 'the real HOME (the 19/11 defect)', home = home, want = 'refused' },
  { name = 'the real store', home = store, want = 'refused' },
  { name = 'inside the real store', home = store .. '/nested', want = 'refused' },
  { name = 'a home ABOVE the real store', home = above, want = 'refused' },
  { name = 'an empty home', home = '', want = 'refused' },
  { name = 'a relative home', home = 'relative/home', want = 'refused' },
  { name = 'this row own scratch home', home = scratch_home, want = 'accepted' },
}
local failed = 0
for _, case in ipairs(cases) do
  local why = guard.guard('probe', case.home)
  local got = why and 'refused' or 'accepted'
  if got ~= case.want then
    failed = failed + 1
    print(('FAIL %s: wanted %s, got %s (%s)'):format(case.name, case.want, got, tostring(why)))
  else
    print(('ok   %s: %s'):format(case.name, got))
  end
end
-- And the live path: with no explicit home the running node's own WASM_AGENT_HOME is judged, and the
-- runner always gives a row a scratch home, so that answer must be accepted.
local live = guard.guard('probe')
if live then
  failed = failed + 1
  print('FAIL the live WASM_AGENT_HOME of a scratch row was refused: ' .. tostring(live))
else
  print('ok   the live WASM_AGENT_HOME is accepted')
end
print(failed == 0 and 'scratch home lua: ok' or ('scratch home lua: FAILED (' .. failed .. ')'))
os.exit(failed == 0 and 0 or 1)
LUA
WASM_AGENT_HOME="$WORK/row-home" WASM_AGENT_LUA_ROOT="$ROOT" WASM_AGENT_MANAGED=0 WA_SCRIPT="$WORK/probe.lua" \
  "$BIN" --db "$WORK/row-home/.wasm-agent/ledger.db" > "$WORK/out" 2>&1
code=$?
cat "$WORK/out"
[ "$code" = 0 ] || { echo "test-scratch-home-lua: the probe exited $code"; exit 1; }
grep -q 'scratch home lua: ok' "$WORK/out" || { echo 'test-scratch-home-lua: the probe printed no verdict'; exit 1; }
echo 'test-scratch-home-lua: ok (the shared Lua guard accepts a scratch home and refuses the real HOME, the real store, anything inside or above it, an empty home and a relative one)'
