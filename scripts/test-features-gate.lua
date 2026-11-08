-- The feature switches at the gate (docs/FEATURES.md), against the real resolver.
--
-- What this proves, in one process with no restart:
--   1. `features.<id>: false` is the live off switch: write it, wait one watch interval
--      (`WA_FEATURES_WATCH_MS`, one second by default), and the SAME module instance goes native;
--   2. switching it back on routes the same module to the component - the answer is asked per call,
--      not captured at load, which is the whole point of `lua/core/features.lua`;
--   3. a feature nobody turned off is ON (the 08/11 default) and its shipped component answers;
--   4. a feature that is on while its component is not installed reports `component_missing` (and
--      runs native) instead of looking like a working component;
--   5. the resolver's own env names and `features.status()` agree with this module's `env` table, so
--      the Lua fallback (a host with no `host.features`) cannot drift from the real switch.
--
-- Everything here goes through `host.features`, i.e. `rust/wa-features`: the policy file, the
-- component directory and the pin check are the node's own. What is stubbed is only what a stub can
-- honestly stand in for - the component call itself (`host.memory`), so "did the gate route to the
-- component" is observable without a real memory component in the test's home.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local features = dofile('lua/core/features.lua')

local checks, failures = 0, {}
local function check(ok, what)
  checks = checks + 1
  if not ok then failures[#failures + 1] = tostring(what) end
end
local function skip(what, why)
  print('SKIP features-gate ' .. what .. ': ' .. tostring(why))
end

if type(host.features) ~= 'function' then
  -- Without the capability there is no resolver to test: a node always has it (the Lua tree is pinned
  -- to the binary's capability digest), so this is a probe on an older binary, and it says so.
  skip('all', 'this binary has no host.features capability')
  return
end

local state = paths.config()
local components = state .. '/components'
local policy_path = state .. '/policy.json'
local function mkdir(path) host.exec("mkdir -p '" .. path .. "'", '', 20) end
mkdir(components)

-- A component whose pin matches its bytes: the resolver only asks "is it installed and is it these
-- bytes", so a stub module is the honest stand-in (the call itself is stubbed below).
local function install(name)
  local bytes = 'stub component ' .. name
  host.write_file(components .. '/' .. name .. '.wasm', bytes)
  host.write_file(components .. '/' .. name .. '.wasm.sha256', (host.sha256(bytes) or '') .. '\n')
  host.write_file(components .. '/' .. name .. '.json', '{"name":"' .. name .. '","kind":"test"}')
end
install('memory')

local function write_policy(features_list)
  local document = { version = 1, sensitive_capabilities = {}, features = features_list, components = {} }
  host.write_file(policy_path, json.encode(document))
end

-- One watch interval is a second; the resolver re-stats at most that often, and a test that flipped
-- the file twice inside one interval would be reading its own cache, not the node's behaviour.
local function after_watch()
  host.sleep(1200)
end

local real_memory, real_log = host.memory, host.log
local component_calls, log = 0, {}
host.log = function(line) log[#log + 1] = tostring(line) end
host.memory = function(request)
  component_calls = component_calls + 1
  local decoded = json.decode(request) or {}
  return json.encode({ ok = true, result = { id = 'component-' .. tostring(decoded.op or '') } })
end

------------------------------------------------------------------ 1. off by policy
write_policy({ memory = false })
after_watch()
local memory = dofile('lua/core/memory.lua')
memory.setup()
local active, reason = features.seam('memory')
check(active == false, 'a feature the policy turns off is not routed to the component')
check(reason == 'seam_disabled', 'off is reported as seam_disabled (nothing to log), got ' .. tostring(reason))
component_calls = 0
local id = memory.remember('the feature gate is off', 'global')
check(type(id) == 'string' and id ~= '', 'the native path still stores the fact')
check(component_calls == 0, 'no component call was made while the feature is off')
check(#log == 0, 'an off feature logs no fallback: ' .. tostring(log[1]))

------------------------------------------------------------------ 2. on by policy, same module, no reload
write_policy({ memory = true })
after_watch()
active, reason = features.seam('memory')
check(active == true, 'the policy turn-on reaches the same process, reason ' .. tostring(reason))
component_calls = 0
local switched = memory.remember('the feature gate is on', 'global')
check(component_calls == 1, 'the SAME module instance routed to the component without a reload (calls=' .. component_calls .. ')')
check(tostring(switched) == 'component-remember', 'the component answer is what remember returned, got ' .. tostring(switched))

------------------------------------------------------------------ 3. back off again, same module
write_policy({ memory = false })
after_watch()
component_calls = 0
local back = memory.remember('the feature gate is off again', 'global')
check(component_calls == 0, 'turning it back off returns the same instance to the native path')
check(type(back) == 'string', 'the native path answered after the switch back')

-------------------------------------------------- 3b. nobody said anything: ON by default (08/11)
-- The default is enabled, not off (Victor, 08/11: every feature on by default, each with a live
-- per-feature off switch). A policy file whose `features` section names nothing is a node running its
-- shipped components, and `default_on` says why nobody is to blame for it.
write_policy(nil)
after_watch()
active, reason = features.seam('memory')
check(active == true, 'a feature nobody turned off is on by default, reason ' .. tostring(reason))
check(reason == 'default_on', 'and the reason says the default did it, got ' .. tostring(reason))
component_calls = 0
memory.remember('on by default', 'global')
check(component_calls == 1, 'the component answers by default (calls=' .. component_calls .. ')')

------------------------------------------------------------------ 4. on with no component: component_missing
write_policy({ hooks = true, memory = false })
after_watch()
active, reason = features.seam('hooks')
check(active == false, 'a feature whose component is not installed is not routed to it')
check(reason == 'component_missing', 'that case is reported by name, got ' .. tostring(reason))
local attribution = features.resolve('hooks')
check(type(attribution) == 'table' and attribution.enabled == true,
  'the operator asked for it: enabled stays true while the path is native')

------------------------------------------------------------------ 5. the two tables agree
local table_answer = features.status()
check(type(table_answer) == 'table' and type(table_answer.features) == 'table', 'the resolver answers the whole table')
check(#(table_answer and table_answer.features or {}) == 8, 'eight features, got ' .. tostring(table_answer and #table_answer.features))
for _, entry in ipairs((table_answer and table_answer.features) or {}) do
  check(entry.env == features.env[entry.feature],
    'env name for ' .. tostring(entry.feature) .. ': resolver ' .. tostring(entry.env) .. ' vs lua ' .. tostring(features.env[entry.feature]))
  check(entry.reason ~= nil and entry.reason ~= '', 'every feature carries a reason (' .. tostring(entry.feature) .. ')')
end
check(type(table_answer.policy) == 'string' and table_answer.policy ~= '', 'the answer names the policy file it read')

host.memory, host.log = real_memory, real_log

if #failures > 0 then
  for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
  error(('features gate: %d failed of %d checks'):format(#failures, checks))
end
print(('features gate: %d checks passed (policy switch live, env names agree, missing component reported)'):format(checks))
