-- One validator for tool arguments, at the dispatch a local call and a peer call share (mission
-- tool-args-honest-and-same-on-peers, item 2).
--
-- The finding it closes: `tools.remote({capability:"bash", stdin:"hello"})` wrote an empty file and answered
-- code 0 with empty stdout. Nothing refused the field, so the call ran as a DIFFERENT call and its answer
-- read like success - one run and one re-verify lost to it. The refusal is now one sentence, worded the same
-- whichever route the call took, because every route (a model's direct call, a script's `tools.<name>`, a
-- `tool_call` batch, a peer's capability) reaches `tools.dispatch`, where it is asked.
--
-- What this row also pins, because each one would be collateral damage:
--   * a declared field is still accepted (the same names the schema prints);
--   * the synonyms the file tools already map (`file_path`, `old_string`, `new_string`) keep working;
--   * the fields the RUNTIME stamps on its own calls (`budget_ms`, `tool`, `background`, `image_bytes`)
--     are not the model's words and are not refused;
--   * a tool the node has no schema for is judged by nobody: unknown is not yes, so nothing is refused on a
--     schema that could not be read;
--   * the report mode measures instead of refusing, so a new refusal can be counted against real traffic.
--
-- Hermetic: its own scratch home, and it refuses to run against a live one.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local validator = dofile('lua/core/tool_arguments.lua')
local home = host.paths().home
local ctx = { user_id = 'master' }
local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end
local function dispatch(name, args) return tools.dispatch(memory, name, args, 'master', ctx) end
local function contains(list, needle)
  for _, value in ipairs(list or {}) do if value == needle then return true end end
  return false
end

-- 1. An undeclared field is refused BY NAME, with the declared fields in the fix line.
local refused = dispatch('bash', { command = 'echo hi', stdin = 'x', nope = 1 })
check(refused.error == 'unknown_argument:nope', 'an undeclared field is refused by name: ' .. json.encode(refused):sub(1, 300))
check(refused.tool == 'bash', 'the refusal names the tool')
check(refused.effect == 'none', 'the refusal has no effect')
check(refused.message and refused.message:find('command', 1, true) ~= nil, 'the sentence lists the declared fields: ' .. tostring(refused.message))
check(refused.fix and refused.fix:find('stdin', 1, true) ~= nil, 'and so does the fix line: ' .. tostring(refused.fix))
check(contains(refused.accepted, 'stdin') and contains(refused.accepted, 'command'), 'the accepted list is the schema\'s own')

-- 2. Nothing ran: the refusal comes before the shell, so a command that would leave a file leaves none.
local marker = home .. '/never-created'
local refused_effect = dispatch('bash', { command = 'printf x > ' .. marker, bogus = 1 })
check(refused_effect.error == 'unknown_argument:bogus', 'a call with an undeclared field is refused: ' .. json.encode(refused_effect):sub(1, 200))
check(host.read_file(marker) == nil, 'the refused command never ran (no file was created)')

-- 3. Every DECLARED field is accepted: the same names the catalogue prints, one at a time. A wrong VALUE is
--    a different refusal and is not this test's subject; what is checked is that no declared name is unknown.
local function declared_names(name)
  local parameters = tools.parameters(name, 'master') or {}
  local names = {}
  for key in pairs(parameters.properties or {}) do names[#names + 1] = key end
  table.sort(names)
  return names
end
local bash_fields = declared_names('bash')
check(#bash_fields >= 4, 'bash declares its fields: ' .. table.concat(bash_fields, ','))
local probes = { command = 'true', cwd = home, timeout_seconds = 5, stdin = 'hello' }
for _, field in ipairs(bash_fields) do
  local args = { command = 'true' }
  if field ~= 'command' then args[field] = probes[field] end
  local answer = dispatch('bash', args)
  check(tostring(answer.error or ''):find('unknown_argument', 1, true) == nil,
    'the declared field ' .. field .. ' is not an unknown argument: ' .. json.encode(answer):sub(1, 200))
end

-- 4. Two undeclared fields are both named, in one deterministic order.
local two = dispatch('read', { path = home .. '/nothing-here', zzz = 1, aaa = 2 })
check(two.error == 'unknown_argument:aaa,zzz', 'every undeclared field is named, sorted: ' .. tostring(two.error))

-- 5. The synonyms the file tools already map are not unknown arguments (file_tools.ALIASES).
local alias_write = dispatch('write', { file_path = home .. '/alias.txt', content = 'x' })
check(alias_write.ok == true and alias_write.error == nil, 'file_path still writes: ' .. json.encode(alias_write):sub(1, 200))
local alias_read = dispatch('read', { file_path = home .. '/alias.txt' })
check(alias_read.error == nil and alias_read.path ~= nil, 'file_path still reads: ' .. json.encode(alias_read):sub(1, 200))
local edit_refused = validator.refusal('edit', { path = 'p', old_string = 'a', new_string = 'b' }, tools.parameters('edit', 'master'))
check(edit_refused == nil, 'old_string/new_string are the edit synonyms, not unknown arguments')

-- 6. The runtime's own fields are not the model's words, and are not refused (one table, each entry says why).
for key in pairs(validator.INTERNAL) do
  check(validator.INTERNAL[key] ~= nil and validator.INTERNAL[key] ~= '', 'the internal field ' .. key .. ' says why it exists')
end
check(validator.refusal('bash', { command = 'true', budget_ms = 5000 }, tools.parameters('bash', 'master')) == nil,
  'budget_ms (adoption) is not an unknown argument')
check(validator.refusal('operation', { action = 'start', command = 'true', background = true, tool = 'operation' },
  tools.parameters('operation', 'master')) == nil, 'operation start\'s own runtime fields are not unknown arguments')
check(validator.refusal('read', { path = '/x', image_bytes = true }, tools.parameters('read', 'master')) == nil,
  'a peer picture request is not an unknown argument')

-- 7. A tool that declares no arguments refuses any field by name, and says that it declares none.
local none = dispatch('nodes', { probe = true })
check(none.error == 'unknown_argument:probe', 'a no-argument tool refuses a field by name: ' .. json.encode(none):sub(1, 200))
check(tostring(none.message or ''):find('no arguments', 1, true) ~= nil, 'and says it declares no arguments: ' .. tostring(none.message))

-- 8. Unknown is not yes: a schema this node cannot read refuses nothing (the tool\'s own path answers it).
check(validator.refusal('mcp_nowhere_anything', { whatever = 1 }, nil) == nil,
  'no schema means no verdict, not a refusal')
check(validator.refusal('open_tool', { anything = 1 }, { type = 'object', additionalProperties = true,
  properties = { known = { type = 'string' } } }) == nil, 'a schema that declares additionalProperties=true declares every name')

-- 9. The report mode measures instead of refusing: the call proceeds, and the would-be refusal is a line.
local log = home .. '/tool-arguments-report.log'
local real_getenv = host.getenv
host.getenv = function(name)
  if name == 'WASM_AGENT_TOOL_ARGUMENTS' then return 'report' end
  if name == 'WASM_AGENT_TOOL_ARGUMENTS_LOG' then return log end
  return real_getenv(name)
end
local reported = dispatch('bash', { command = 'printf reported', nope = 1 })
host.getenv = real_getenv
check(reported.code == 0 and tostring(reported.stdout or ''):find('reported', 1, true) ~= nil,
  'in report mode the call runs as it did before: ' .. json.encode(reported):sub(1, 200))
local recorded = host.read_file(log) or ''
check(recorded:find('nope', 1, true) ~= nil and recorded:find('bash', 1, true) ~= nil,
  'in report mode the would-be refusal is recorded: ' .. recorded:sub(1, 200))
local after_report = dispatch('bash', { command = 'true', nope = 1 })
check(after_report.error == 'unknown_argument:nope', 'with the mode off again the refusal is back')

print(('tool arguments: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
