-- Every feature ON by default, and each one with a live off switch (docs/FEATURES.md, 08/11).
--
-- What this proves, in one process with no restart:
--   1. with no `policy.json` and no environment statement, every feature in the resolver's table is
--      `enabled` with `source: default` and `reason: default_on` - the 08/11 default ("every new feature
--      ON by default"). Nothing about which components happen to be installed decides that;
--   2. a feature whose component is installed with a verified pin is `active: component`, and one whose
--      component is not there is `active: native` with `reason: component_missing` - reported, never a
--      crash and never a silent fallback (item 5 of the job);
--   3. the *whole table* turns off with one policy write (`"<id>": false` for each) and back on with
--      another, in the same process, one watch interval later: the off switch is live, and there are
--      eight of them;
--   4. one feature turned off does not touch the others (the switch is per feature, not a mode);
--   5. the mesh's own switch is in the same answer (docs/MESH.md) so an operator can see whether the
--      mesh is in use, not just which code would decide a call.
--
-- Hermetic: the components it installs are stub modules whose pins are their own bytes (the resolver only
-- asks "is it installed and is it these bytes"), and it only writes into `WA_COMPONENTS_DIR` when that
-- variable names a directory - a test must never touch a node's real `~/.wasm-agent/components`.
-- The call itself is not made here: `scripts/test-{memory,selfloop,hooks,codemode}-component.lua` are the
-- parity suites that route a real seam through a component.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local features = dofile('lua/core/features.lua')

local checks, failures = 0, {}
local function check(ok, what)
  checks = checks + 1
  if not ok then failures[#failures + 1] = tostring(what) end
end
local function skip(what, why)
  print('SKIP features-defaults ' .. what .. ': ' .. tostring(why))
end

if type(host.features) ~= 'function' then
  -- No capability, no resolver to ask: a node always has it (the Lua tree is pinned to the binary's
  -- capability digest), so this is an older binary and it says so instead of passing.
  skip('all', 'this binary has no host.features capability')
  return
end

local state = paths.config()
local policy_path = state .. '/policy.json'
local function mkdir(path) host.exec("mkdir -p '" .. path .. "'", '', 20) end
mkdir(state)
-- No policy file: the default is the whole statement. A stale one from a previous run would be a test
-- passing on its own leftovers.
pcall(os.remove, policy_path)

local components = host.getenv('WA_COMPONENTS_DIR')
local test_home = host.getenv('WASM_AGENT_HOME') or ''
local function inside_home(path)
  if type(path) ~= 'string' or path == '' or test_home == '' then return false end
  local normal = path:gsub('\\', '/'):gsub('/$', '')
  local prefix = test_home:gsub('\\', '/'):gsub('/$', '')
  return normal:sub(1, #prefix) == prefix
end
-- Only a component directory inside this test's own home: a test never writes into a node's real
-- `~/.wasm-agent/components` (which is also where the resolver would look if `WA_COMPONENTS_DIR` were
-- unset - the process HOME, not the guest's).
if not inside_home(components) then components = nil end

local function install(name)
  if not components then return false end
  mkdir(components)
  local bytes = 'stub default component ' .. name
  host.write_file(components .. '/' .. name .. '.wasm', bytes)
  host.write_file(components .. '/' .. name .. '.wasm.sha256', (host.sha256(bytes) or '') .. '\n')
  host.write_file(components .. '/' .. name .. '.json', '{"name":"' .. name .. '","kind":"test"}')
  return true
end

-- `memory` is deliberately NOT installed at first: one feature must answer `component_missing` while
-- every other one answers `component`.
for _, name in ipairs({ 'selfloop', 'codemode', 'hooks', 'model-gateway', 'mesh', 'agent-core', 'telemetry-sink' }) do
  install(name)
end
pcall(function() os.remove(components .. '/memory.wasm') end)
pcall(function() os.remove(components .. '/memory.wasm.sha256') end)

-- One watch interval is a second and the resolver re-stats at most that often (WA_FEATURES_WATCH_MS).
local function after_watch() host.sleep(1200) end

local function write_policy(features_list)
  local document = { version = 1, sensitive_capabilities = {}, features = features_list, components = {} }
  host.write_file(policy_path, json.encode(document))
end

local function entry(id)
  local answer = features.status()
  for _, row in ipairs((answer and answer.features) or {}) do
    if row.feature == id then return row end
  end
  return nil
end

------------------------------------------------------ 1. nobody said anything: every feature is on
local table_answer = features.status()
check(type(table_answer) == 'table', 'the resolver answers without a policy file')
local rows = (table_answer and table_answer.features) or {}
check(#rows == 8, 'the resolver lists eight features, got ' .. tostring(#rows))
for _, row in ipairs(rows) do
  check(row.enabled == true, tostring(row.feature) .. ' is enabled by default')
  check(row.source == 'default', tostring(row.feature) .. ' says the default did it, got ' .. tostring(row.source))
  if row.feature == 'memory' then
    check(row.active == 'native', 'a feature whose component is absent runs native')
    check(row.reason == 'component_missing',
      'and is reported by name, got ' .. tostring(row.reason))
    check(row.installed == nil or row.installed == json.null, 'an absent component has no installed sha')
  elseif components then
    check(row.active == 'component',
      tostring(row.feature) .. ' routes to its installed component, got ' .. tostring(row.active))
    check(row.reason == 'default_on', tostring(row.feature) .. ' keeps saying why, got ' .. tostring(row.reason))
    check(type(row.installed) == 'string' and #row.installed == 64,
      tostring(row.feature) .. ' reports the verified pin it checked')
  end
end
check(type(table_answer.mesh) == 'table', 'the answer carries the mesh switch beside the table')
if type(table_answer.mesh) == 'table' then
  check(type(table_answer.mesh.enabled) == 'boolean', 'the mesh switch is an answer, not absent')
  check(type(table_answer.mesh.source) == 'string' and table_answer.mesh.source ~= '',
    'the mesh switch names its source, got ' .. tostring(table_answer.mesh.source))
end

-------------------------------------------------- 2. the install lands: memory stops being missing
if components then
  install('memory')
  after_watch()
  local row = entry('memory')
  check(row and row.active == 'component', 'installing the component makes it the active path (no restart)')
  check(row and row.reason == 'default_on', 'still on by default, got ' .. tostring(row and row.reason))
else
  skip('the installed-component half', 'WA_COMPONENTS_DIR is not a directory inside this test\'s own home (a test never touches a node\'s component directory)')
end

-------------------------------------------------- 3. one off switch, and it is one feature only
write_policy({ memory = false })
after_watch()
local memory_row = entry('memory')
check(memory_row and memory_row.enabled == false, 'features.memory: false turns memory off')
check(memory_row and memory_row.source == 'policy', 'and attributes it to the policy file, got ' .. tostring(memory_row and memory_row.source))
check(memory_row and memory_row.active == 'native', 'the native path is live for it')
check(memory_row and memory_row.reason == 'feature_off', 'the reason is feature_off, got ' .. tostring(memory_row and memory_row.reason))
for _, id in ipairs({ 'selfloop', 'codemode', 'hooks', 'gateway', 'mesh_component', 'agent_core', 'telemetry_sink' }) do
  local row = entry(id)
  check(row and row.enabled == true, 'one switch does not turn ' .. id .. ' off')
end

-------------------------------------------------- 4. the eighth switch works the same way
write_policy({ memory = false, selfloop = false, codemode = false, hooks = false, gateway = false,
  mesh_component = false, agent_core = false, telemetry_sink = false })
after_watch()
local all_off = true
for _, row in ipairs((features.status() or {}).features or {}) do
  if row.enabled ~= false or row.active ~= 'native' or row.reason ~= 'feature_off' then
    all_off = false
    failures[#failures + 1] = 'turning ' .. tostring(row.feature) .. ' off left ' ..
      tostring(row.enabled) .. '/' .. tostring(row.active) .. '/' .. tostring(row.reason)
    checks = checks + 1
  end
end
check(all_off, 'every one of the eight switches is live in the same process')

-------------------------------------------------- 5. and back on, same process, no restart
write_policy({ memory = true, selfloop = true, codemode = true, hooks = true, gateway = true,
  mesh_component = true, agent_core = true, telemetry_sink = true })
after_watch()
local all_on = true
for _, row in ipairs((features.status() or {}).features or {}) do
  if row.enabled ~= true then
    all_on = false
    failures[#failures + 1] = tostring(row.feature) .. ' did not come back on: ' .. tostring(row.reason)
    checks = checks + 1
  end
end
check(all_on, 'all eight come back on from the policy file alone')

if #failures > 0 then
  for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
  error(('features defaults: %d failed of %d checks'):format(#failures, checks))
end
print(('features defaults: %d checks passed (every feature on by default, all eight switches live, component_missing reported, the mesh switch answered)'):format(checks))
