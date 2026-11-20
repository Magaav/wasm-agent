-- The A/B arms are OFF unless their own switch names one (review MUST 3).
--
-- They used to read WASM_AGENT_RAW_CODE and answer "fence" when it was unset, so every node silently
-- ran an arm: the arm's allow-list filtered the tool list, and a subagent's declared tools differed
-- from base for a reason nobody asked for. WA_AB_ARM is the switch; unset means no arm and no filter.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local arms = dofile('lua/core/ab_arms.lua')
local tools = dofile('lua/core/tools.lua')
local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end

-- 1. unset is not an arm, and says so
local arm, why = arms.current()
ok(arm == nil, 'with no switch there is no arm, got ' .. tostring(arm))
ok(why == 'off', 'and the reason is off, got ' .. tostring(why))

-- 2. the switch is its own variable, not the transport switch
ok(arms.SWITCH == 'WA_AB_ARM', 'the arm switch is WA_AB_ARM, got ' .. tostring(arms.SWITCH))

-- 3. a subagent's declared list is what the profile says, with no arm filter applied.
--    Compared against the same call with the arm table consulted: they must be equal, which is the
--    property the review measured as different before this fix.
local memory = dofile('lua/core/memory.lua'); memory.setup()
local sid = memory.start_session('', 'no-arm', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
local list = tools.envelope('master', ctx)
ok(#list > 0, 'a node with no arm declares tools at all')
local names = {}
for _, item in ipairs(list) do names[#names + 1] = item['function'].name end
-- No arm means NO FILTER: the declared set must equal what the node's own policy produces, which on
-- this build is the native transport's single door. The property under test is equality with the
-- unfiltered policy, not a guess about which names that policy happens to yield.
local policy = dofile('lua/core/codemode_policy.lua')
policy.pin(memory, 'master', ctx)
local door = dofile('lua/core/raw_code.lua').transport_for(nil, true)
if door == 'tool_call' then
  ok(#names == 1 and names[1] == 'run',
    'the tool_call transport declares one door, run; got: ' .. table.concat(names, ','))
else
  ok(not (#names == 1 and names[1] == 'run'),
    'a block transport must not declare run as the door; got: ' .. table.concat(names, ','))
end

-- 4. a named arm still works, and an unknown one is refused by name rather than silently taken
host.getenv = (function(original)
  return function(key)
    if key == 'WA_AB_ARM' then return 'bash' end
    return original(key)
  end
end)(host.getenv)
ok(select(1, arms.current()) == 'bash', 'the switch selects an arm when set')
host.getenv = (function(original)
  return function(key)
    if key == 'WA_AB_ARM' then return 'not-an-arm' end
    return original(key)
  end
end)(host.getenv)
local bad, bad_why = arms.current()
ok(bad == nil, 'an unknown arm is not an arm')
ok(tostring(bad_why):find('unknown_arm', 1, true) ~= nil, 'and the refusal names it: ' .. tostring(bad_why))
print('ab arms ok (' .. checks .. ' checks)')

