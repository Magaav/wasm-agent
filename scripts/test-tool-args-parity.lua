-- Parity by construction: a field a tool DECLARES must reach the executor on the peer path too
-- (mission tool-args-honest-and-same-on-peers, item 3).
--
-- A peer call is mostly the local call already: `wa_peer_dispatch` (lua/core/server.lua) ends in
-- `toolslib.dispatch`, the same function a local call reaches, so there is nothing to keep in step. The one
-- exception was bash with `budget_ms` (adoption), a second implementation that forwarded command, cwd and
-- timeout_seconds and DROPPED every other field - the class of bug this mission was opened for. The fix
-- forwards the caller's arguments through the operation start schema instead of re-picking them, so a field
-- added later either travels or the call is refused by name.
--
-- This row enumerates the WHOLE catalogue, so a field added to ANY tool later is covered without editing it:
--   1. every catalogued tool, every declared property: the peer path delivers it to a dispatch (the same
--      capability for an ordinary call, `operation start` for adopted bash) and answers no field refusal;
--   2. the values arrive unchanged, so it is the same executor with the same arguments;
--   3. a positive control that the guard can FAIL: the operation schema is asked without `stdin` and adopted
--      bash with stdin must then be refused by name rather than run without its input.
--
-- Hermetic: own scratch home, and the dispatch it measures is a stub, so nothing it enumerates runs.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
-- The peer side must load THE SAME module table this row patched: `dofile` runs a file again, so the stub is
-- installed before lua/core/server.lua reads its own copy of tools.lua.
local real_dofile = dofile
local real_dispatch = tools.dispatch
local seen = {}
tools.dispatch = function(_memory, name, args)
  seen[#seen + 1] = { name = name, args = args }
  return { error = 'parity_probe_stop', effect = 'none' }
end
dofile = function(path) if path == 'lua/core/tools.lua' then return tools end return real_dofile(path) end
local ok_server, server = pcall(real_dofile, 'lua/core/server.lua')
dofile = real_dofile
if not ok_server then error('lua/core/server.lua did not load: ' .. tostring(server)) end
-- The stub STAYS in place: the table lua/core/server.lua holds is this one, so putting the real dispatch
-- back here would make every measurement below run the real tool (and some of them would have effects).
local function restore_dispatch() tools.dispatch = real_dispatch end

local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end
local caller, author = { node_id = 'peer-parity-probe', role = 'master' }, 'master'

-- One probe value per declared field, by the type the schema declares: a value the schema itself would name.
local function probe(property)
  property = type(property) == 'table' and property or {}
  if property.type == 'integer' or property.type == 'number' then return 1 end
  if property.type == 'boolean' then return true end
  if property.type == 'array' then return {} end
  if property.type == 'object' then return {} end
  if type(property.enum) == 'table' and property.enum[1] ~= nil then return property.enum[1] end
  return 'probe'
end

local catalogue = tools.catalog('master')
check(type(catalogue) == 'table' and #catalogue > 20, 'the catalogue is enumerable (' .. tostring(type(catalogue) == 'table' and #catalogue or 0) .. ' tools)')

local tools_seen, fields_seen, refused_fields = 0, 0, {}
for _, item in ipairs(catalogue) do
  local fn = item['function'] or {}
  local name = fn.name
  local properties = type(fn.parameters) == 'table' and type(fn.parameters.properties) == 'table' and fn.parameters.properties or {}
  if type(name) == 'string' and name ~= '' then
    tools_seen = tools_seen + 1
    for field, property in pairs(properties) do
      fields_seen = fields_seen + 1
      local value = probe(property)
      seen = {}
      local answer = wa_peer_dispatch(name, { [field] = value }, caller, author)
      local delivered = seen[1] and seen[1].args and seen[1].args[field]
      -- A declared field is either DELIVERED to the executor, or the call is REFUSED BY NAME with no effect.
      -- The one legitimate refusal before the executor is the mesh's own node-scope rule: a peer asking for
      -- node-wide scope over another node's operations is refused there (lua/core/server.lua), which is a
      -- boundary, not a dropped field.
      local refused_by_name = type(answer) == 'table' and answer.error == 'peer_node_scope_not_granted'
        and answer.effect == 'none'
      if refused_by_name then
        refused_fields[#refused_fields + 1] = name .. '.' .. field
      end
      check(delivered ~= nil or refused_by_name,
        'the peer path delivers ' .. name .. '.' .. field .. ' (recorded: ' .. json.encode(seen[1] or {}):sub(1, 160) .. ')')
      if delivered ~= nil then
        check(json.encode(delivered) == json.encode(value),
          'and delivers it unchanged: ' .. name .. '.' .. field .. ' -> ' .. json.encode(delivered):sub(1, 80))
        check(seen[1].name == name,
          'the peer path runs the same capability ' .. name .. ' (recorded: ' .. tostring(seen[1] and seen[1].name) .. ')')
      end
    end
  end
end
check(tools_seen > 20 and fields_seen > 50, 'the enumeration covers the catalogue (' .. tools_seen .. ' tools, ' .. fields_seen .. ' declared fields)')
if #refused_fields > 0 then
  print('note: refused before the executor at the mesh boundary (a boundary, not a dropped field): ' .. table.concat(refused_fields, ', '))
end

-- 2. ADOPTED bash (budget_ms): every declared field of bash must reach the supervised operation.
local bash_fields = {}
for field in pairs((tools.parameters('bash', 'master') or {}).properties or {}) do bash_fields[#bash_fields + 1] = field end
table.sort(bash_fields)
check(#bash_fields >= 4, 'bash declares its fields: ' .. table.concat(bash_fields, ','))
for _, field in ipairs(bash_fields) do
  seen = {}
  local args = { command = 'printf parity', budget_ms = 5000 }
  if field == 'timeout_seconds' then args[field] = 30
  elseif field == 'cwd' then args[field] = 'probe-cwd'
  elseif field == 'stdin' then args[field] = 'hello'
  elseif field ~= 'command' then args[field] = 'probe' end
  local answer = wa_peer_dispatch('bash', args, caller, author)
  local start = seen[1] or {}
  check(start.name == 'operation' and type(start.args) == 'table' and start.args.action == 'start',
    'adopted bash starts one supervised operation: ' .. json.encode(start):sub(1, 200))
  check(start.args and start.args[field] ~= nil,
    'adopted bash carries ' .. field .. ' into the operation start: ' .. json.encode(start.args or {}):sub(1, 200))
  check(tostring(type(answer) == 'table' and answer.error or ''):find('not_adoptable', 1, true) == nil,
    'adopted bash accepts ' .. field .. ': ' .. json.encode(answer):sub(1, 160))
end
-- budget_ms itself is the caller's word and never becomes a field of the operation.
local budget_start
do
  seen = {}
  wa_peer_dispatch('bash', { command = 'printf parity', budget_ms = 5000 }, caller, author)
  budget_start = seen[1] and seen[1].args or {}
end
check(budget_start.budget_ms == nil, 'budget_ms is consumed by adoption, not forwarded as an operation field')

-- 3. The guard can fail (proves the checks above are not vacuous): an operation schema without `stdin`, and
--    adopted bash with stdin, must be REFUSED by name - never run without the input it was given.
local real_parameters = tools.parameters
tools.parameters = function(name, role)
  local parameters = real_parameters(name, role)
  if name ~= 'operation' or type(parameters) ~= 'table' or type(parameters.properties) ~= 'table' then return parameters end
  local copy = { type = 'object', properties = {} }
  for key, value in pairs(parameters.properties) do if key ~= 'stdin' then copy.properties[key] = value end end
  return copy
end
seen = {}
local refused = wa_peer_dispatch('bash', { command = 'cat', stdin = 'hello', budget_ms = 5000 }, caller, author)
tools.parameters = real_parameters
check(type(refused) == 'table' and refused.error == 'peer_bash_field_not_adoptable' and refused.field == 'stdin',
  'a field adoption cannot carry is refused by name: ' .. json.encode(refused):sub(1, 240))
check(#seen == 0, 'and nothing was started for it (no dispatch was made)')

print(('tool args parity: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
