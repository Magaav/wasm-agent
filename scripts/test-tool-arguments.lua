-- The unknown-argument check is REPORT-ONLY (STEP 1, 23/11, Fable).
--
-- The finding it answers is unchanged: `tools.remote({capability:"bash", stdin:"hello"})` wrote an empty file
-- and answered code 0 - an argument the tool did not know was silently dropped. The first fix refused such a
-- field by name, and on main that refusal turned out to be too sharp: real call sites send fields their
-- schemas never declared (the pending path, the wake tool, the managed-list gate), so a dozen rows went red.
-- So the check MEASURES instead of refusing: the call runs exactly as it did before the validator existed,
-- and ONE telemetry event per distinct tool+field records {tool, field, fields, caller} - names only, never a
-- value. Enforcement comes back in STEP 2, for model-sent calls first.
--
-- What this row pins:
--   * an undeclared field no longer refuses, and the call really runs;
--   * one event per distinct tool+field, for the life of the process: a second identical call adds nothing;
--   * the caller is classified peer / internal / model from the CONTEXT, never from the arguments;
--   * the runtime's own fields and the file tools' synonyms are not recorded at all;
--   * an open schema, a tool that declares nothing, and a schema this node cannot read each answer correctly.
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
local telemetry = dofile('lua/core/telemetry.lua')
local home = host.paths().home
local sid = memory.start_session('', 'tool arguments report', { user_id = 'master' })
local ctx = { user_id = 'master', session_id = sid }
local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end
local function dispatch(name, args, given) return tools.dispatch(memory, name, args, 'master', given or ctx) end

-- The events this session recorded, as {tool, field, fields, caller} rows.
local function recorded()
  local rows = {}
  local ok, page = pcall(telemetry.events, sid, 0, 500)
  if not ok or type(page) ~= 'table' then return rows end
  for _, event in ipairs(page.events or page or {}) do
    if type(event) == 'table' and event.kind == 'tool_arguments' then
      local payload = event.payload or {}
      if type(payload) == 'string' then
        local decoded_ok, decoded = pcall(json.decode, payload)
        payload = decoded_ok and type(decoded) == 'table' and decoded or {}
      end
      rows[#rows + 1] = { tool = payload.tool, field = payload.field, fields = payload.fields, caller = payload.caller }
    end
  end
  return rows
end
local function count_of(tool, field)
  local n = 0
  for _, row in ipairs(recorded()) do if row.tool == tool and row.field == field then n = n + 1 end end
  return n
end
local function payload_of(tool, field)
  for _, row in ipairs(recorded()) do if row.tool == tool and row.field == field then return row end end
  return nil
end

-- 1. An undeclared field no longer refuses: the call runs, exactly as it did before the check existed.
local ran = dispatch('bash', { command = 'printf hi', nope = 1 })
check(ran.error == nil and tonumber(ran.code) == 0, 'an undeclared field does not refuse the call: ' .. json.encode(ran):sub(1, 200))
check(tostring(ran.stdout) == 'hi', 'and the command really ran: ' .. tostring(ran.stdout):sub(1, 80))
local none = dispatch('nodes', { probe = true })
check(none.error ~= 'unknown_argument:probe', 'a no-argument tool is not refused for a field either: ' .. json.encode(none):sub(1, 160))

-- 2. One event per distinct tool+field, with names only.
local first = payload_of('bash', 'nope')
check(first ~= nil, 'the undeclared field is recorded: ' .. json.encode(recorded()):sub(1, 300))
check(first and first.caller == 'model', 'and the caller is the model: ' .. tostring(first and first.caller))
check(first and type(first.fields) == 'table' and first.fields[1] == 'nope', 'the payload names the fields: ' .. json.encode(first and first.fields))
local before = count_of('bash', 'nope')
dispatch('bash', { command = 'printf hi', nope = 1 })
dispatch('bash', { command = 'printf hi', nope = 1 })
check(count_of('bash', 'nope') == before, 'a repeated call adds no event: ' .. (before .. ' then ' .. count_of('bash', 'nope')))
check(before == 1, 'the first call recorded it once: ' .. before)

-- 3. The caller is classified from the context, never from the arguments.
dispatch('bash', { command = 'printf hi', peer_only = 1 }, { user_id = 'master', session_id = sid, peer_call = true })
local peer_row = payload_of('bash', 'peer_only')
check(peer_row ~= nil and peer_row.caller == 'peer', 'a peer call is recorded as peer: ' .. json.encode(peer_row or {}))
dispatch('bash', { command = 'printf hi', nested_only = 1 }, { user_id = 'master', session_id = sid, codemode_nested = true })
local nested_row = payload_of('bash', 'nested_only')
check(nested_row ~= nil and nested_row.caller == 'internal', 'a nested call is recorded as internal: ' .. json.encode(nested_row or {}))

-- 4. The runtime's own fields and the file tools' synonyms are never recorded.
for field in pairs(validator.INTERNAL) do
  check(validator.INTERNAL[field] ~= nil and validator.INTERNAL[field] ~= '', 'the internal field ' .. field .. ' says why it exists')
end
dispatch('bash', { command = 'printf hi', budget_ms = 5000 })
check(count_of('bash', 'budget_ms') == 0, 'budget_ms is the runtime\'s word, not a field to report')
check(dispatch('write', { file_path = home .. '/alias.txt', content = 'x' }).ok == true, 'file_path still writes')
check(count_of('write', 'file_path') == 0, 'and the synonym is not reported')
check(dispatch('edit', { path = home .. '/alias.txt', old_string = 'x', new_string = 'y' }).error == nil, 'old_string still edits')

-- 5. The rule itself, without a dispatch: an open schema declares every name, a no-argument tool declares
--    none, and a schema this node cannot read is not a verdict.
check(validator.undeclared('mcp_nowhere_anything', { whatever = 1 }, nil) == nil, 'no schema means no verdict')
check(validator.undeclared('open_tool', { anything = 1 }, { type = 'object', additionalProperties = true,
  properties = { known = { type = 'string' } } }) == nil, 'an open schema declares every name')
local nothing = validator.undeclared('nodes', { probe = true }, tools.parameters('nodes', 'master'))
check(type(nothing) == 'table' and nothing[1] == 'probe', 'a no-argument tool reports every field it is sent')
local both = validator.undeclared('read', { path = '/x', zzz = 1, aaa = 2 }, tools.parameters('read', 'master'))
check(type(both) == 'table' and table.concat(both, ',') == 'aaa,zzz', 'every undeclared name, sorted: ' .. json.encode(both))
local bash_fields = tools.parameters('bash', 'master') or {}
check((bash_fields.properties or {}).stdin ~= nil, 'bash declares stdin, so it is never reported')

print(('tool arguments: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
