-- Every connector tool's declared schema reaches the model, everywhere it is offered.
--
-- The finding (13/11, session eb848985): `searchTools("select:mcp_whatsapp_contacts")` answered the tool
-- with `parameters = { properties = {} }`, so the model had no argument names to read. It guessed
-- `query`, got `schema_extra:arguments.query`, guessed `name`, got it again, and only then found `q` -
-- three calls for one question, on a name the operator's own phone had saved. An empty `properties` on a
-- tool whose server declares four arguments is never a rendering detail: it is the difference between a
-- call that can be made and a call that must be guessed.
--
-- So this file is a GATE, not a snapshot. It builds the catalogue from every source that contributes one
-- - a registry MCP server's probe, a peer's exported tools (both shapes a peer publishes them in), the
-- one WhatsApp surface, and a wasm plugin - and then holds three lines:
--
--   1. every catalogued tool whose server DECLARES properties is catalogued with those properties, with
--      the same names and the same keywords (`$schema`, `$defs`, `additionalProperties` included);
--   2. `searchTools("select:...")` and `describeTool(name)` - through the real lookup both code-mode
--      loops build - answer the same parameters, because that is the surface the model reads;
--   3. a tool that declares no arguments is allowed an empty `properties` and is not a failure, and a
--      cached schema that is not a JSON object is refused BY NAME instead of published empty.
--
-- Hermetic: no server is spawned, no peer is contacted, no node is running. The registry and the
-- federation cache are seeded with the durable state a probe and a refresh leave behind, and the plugin
-- list is a fixture through `host.plugins` (the same door `lua/core/tools.lua` reads).
local json = dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok,
  'private registry table setup failed')

local checks, failed = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then failed = failed + 1; print('FAIL ' .. label) end
end
local function eq(actual, expected, label)
  check(actual == expected, label .. ' (got ' .. tostring(actual) .. ', wanted ' .. tostring(expected) .. ')')
end
local function has(text, needle) return tostring(text or ''):find(needle, 1, true) ~= nil end
local function meta_set(key, value)
  assert(json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key, value }))).ok,
    'meta write failed for ' .. key)
end

--- The property names an object schema declares, sorted and joined: the comparison that matters.
local function keyset(parameters)
  if type(parameters) ~= 'table' then return '<no parameters>' end
  local names = {}
  for name in pairs(parameters.properties or {}) do names[#names + 1] = tostring(name) end
  table.sort(names)
  return table.concat(names, ',')
end
local function properties(parameters)
  return type(parameters) == 'table' and type(parameters.properties) == 'table' and next(parameters.properties) ~= nil
end

-- ---------------------------------------------------------------- the fixtures
-- A pydantic-shaped declaration (mail-mcp 0.6.1 stamps `$schema`/`$defs`/`$ref` inside every
-- `inputSchema`), the plain shape, and a tool that genuinely takes no arguments.
local PINNED = '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object",'
  .. '"$defs":{"Mailbox":{"type":"string","enum":["inbox","sent"]}},'
  .. '"properties":{"mailbox":{"$ref":"#/$defs/Mailbox"},"limit":{"type":"integer","minimum":1},'
  .. '"unread_only":{"type":"boolean"}},"required":["mailbox"],"additionalProperties":false}'
local PLAIN = '{"type":"object","properties":{"q":{"type":"string","maxLength":80},'
  .. '"since":{"type":"number"}},"required":["q"]}'
local NOARGS = '{"type":"object"}'
local BROKEN = '[]'

meta_set('mcp.extensions.v1', json.encode({ schema = 1, revision = 3, servers = {
  mailroom = {
    enabled = true, revision = 1,
    definition = { id = 'mailroom', name = 'Mailroom', transport = 'stdio', program = 'mail-mcp',
      tools = { list_mail = 'read', search_mail = 'read', whoami = 'read' } },
    probe = { ok = true, schema_hash = 'probe-hash-mailroom', tools = {
      { name = 'list_mail', description = 'List the mailboxes of one account', input_schema_json = PINNED },
      { name = 'search_mail', description = 'Search one mailbox', input_schema_json = PLAIN },
      { name = 'whoami', description = 'The bound account', input_schema_json = NOARGS },
    } },
  },
  -- A cached probe whose schema cannot be read: it must refuse by name, never publish `properties: {}`.
  ghost = {
    enabled = true, revision = 1,
    definition = { id = 'ghost', name = 'Ghost', transport = 'stdio', program = 'ghost-mcp',
      tools = { broken_tool = 'read' } },
    probe = { ok = true, schema_hash = 'probe-hash-ghost', tools = {
      { name = 'broken_tool', description = 'A schema nobody can read', input_schema_json = BROKEN },
    } },
  },
} }))

-- A peer publishes the catalogue shape (`parameters`) and its `/mcp` view the same declaration as JSON
-- text (`schema`); both are the server's own word, and a peer tool with neither takes no arguments.
local peer_parameters = json.decode(PLAIN)
meta_set('federation.catalog.v2', json.encode({ at = host.now(), peers = {
  ['peer-openclaw'] = { name = 'openclaw', node_id = 'peer-openclaw', at = host.now(), tools = {
    { name = 'peer_search', description = 'Search a peer', effect = 'read', parameters = peer_parameters },
    { name = 'peer_text_only', description = 'A peer that published its schema as text', effect = 'read',
      schema = PINNED },
    { name = 'peer_noargs', description = 'A peer tool with no arguments', effect = 'read' },
  } },
} }))

-- A declarative plugin: `additionalProperties` is part of its contract and used to be dropped by being
-- rebuilt from `properties`+`required` alone.
local PLUGIN_PARAMETERS = { type = 'object', additionalProperties = false, required = { 'value' },
  properties = { value = { type = 'string' }, scale = { type = 'integer', minimum = 1 } } }
local real_plugins = host.plugins
host.plugins = function()
  return json.encode({
    { name = 'demo_plugin', description = 'A plugin that declares its own schema', parameters = PLUGIN_PARAMETERS },
    { name = 'demo_noargs', description = 'A plugin with no arguments', parameters = { type = 'object', properties = {} } },
  })
end

local tools = dofile('lua/core/tools.lua')
local mcp = dofile('lua/core/mcp.lua')
local federation = dofile('lua/core/federation.lua')
local whatsapp = dofile('lua/core/whatsapp.lua')
local codemode = dofile('lua/core/codemode.lua')
local contract = dofile('lua/core/json_contract.lua')

-- ---------------------------------------------------------------- 1. each source keeps its declaration
local function named(list, name)
  for _, entry in ipairs(list) do
    local fn = entry['function'] or entry
    if fn.name == name then return fn end
  end
  return nil
end

local mailroom = mcp.schemas()
local list_mail = named(mailroom, mcp.namespace('mailroom', 'list_mail'))
check(list_mail ~= nil, 'the enabled connector publishes its tool')
eq(keyset(list_mail and list_mail.parameters), 'limit,mailbox,unread_only', 'MCP tool: the declared properties arrive')
check(list_mail and list_mail.parameters.additionalProperties == false, 'MCP tool: additionalProperties is kept')
check(list_mail and list_mail.parameters.required and list_mail.parameters.required[1] == 'mailbox', 'MCP tool: required is kept')
-- The pydantic keywords ride the raw schema: a model that reads `$defs` learns the enum.
check(has(json.encode(list_mail and list_mail.parameters), '$defs'), 'MCP tool: $defs is kept, not stripped as unsupported')
check(has(json.encode(list_mail and list_mail.parameters), 'draft/2020-12/schema'), 'MCP tool: $schema is kept')

local whoami = named(mailroom, mcp.namespace('mailroom', 'whoami'))
check(whoami ~= nil and not properties(whoami.parameters), 'MCP tool: a no-argument tool keeps an empty properties and is not a loss')

-- A schema that cannot be read is withheld and NAMED, never published empty - and it does not take the
-- rest of the catalogue down with it: one connector's bad cache is not the node's tool list.
local ghost = named(mailroom, mcp.namespace('ghost', 'broken_tool'))
check(ghost == nil, 'a tool whose cached schema cannot be read is not offered at all')
local faults = mcp.schema_faults()
local fault
for _, entry in ipairs(faults) do
  if entry.name == mcp.namespace('ghost', 'broken_tool') then fault = entry end
end
check(fault ~= nil, 'the withheld tool is named as a fault')
eq(fault and fault.error, 'mcp_cached_schema_invalid', 'the fault names the reason')
eq(fault and fault.connector, 'ghost', 'the fault names the connector to re-probe')
check(named(mailroom, mcp.namespace('mailroom', 'list_mail')) ~= nil, 'the readable connector is still offered')
check(named(mcp.inventory().schema_faults or {}, mcp.namespace('ghost', 'broken_tool')) ~= nil,
  'the inventory carries the fault, so /mcp can say which connector to re-probe')

local peers = federation.schemas()
local peer_search = named(peers, federation.local_name('openclaw', 'peer_search'))
eq(keyset(peer_search and peer_search.parameters), 'q,since', 'peer tool: the catalogue shape arrives')
local peer_text = named(peers, federation.local_name('openclaw', 'peer_text_only'))
eq(keyset(peer_text and peer_text.parameters), 'limit,mailbox,unread_only', 'peer tool: a schema published as JSON text arrives')
local peer_noargs = named(peers, federation.local_name('openclaw', 'peer_noargs'))
check(peer_noargs ~= nil and not properties(peer_noargs.parameters), 'peer tool: no declaration means no properties, and says so honestly')

-- ---------------------------------------------------------------- 2. the catalogue the model is offered
local catalog = tools.catalog('master')
local function catalogued(name)
  local fn = named(catalog, name)
  return fn and fn.parameters or nil
end

-- The gate: every declaration with properties is catalogued with exactly those properties.
local declared = {}
for _, entry in ipairs(mailroom) do declared[entry['function'].name] = entry['function'].parameters end
for _, entry in ipairs(peers) do declared[entry['function'].name] = entry['function'].parameters end
for _, entry in ipairs(whatsapp.schemas()) do declared[entry['function'].name] = entry['function'].parameters end
for _, entry in ipairs({ { name = 'demo_plugin', parameters = PLUGIN_PARAMETERS } }) do declared[entry.name] = entry.parameters end

local lost, declared_count = {}, 0
for name, parameters in pairs(declared) do
  if properties(parameters) then
    declared_count = declared_count + 1
    local offered = catalogued(name)
    if offered == nil then
      lost[#lost + 1] = name .. ' (not catalogued at all)'
    elseif keyset(offered) ~= keyset(parameters) then
      lost[#lost + 1] = name .. ' (offered ' .. keyset(offered) .. ', declared ' .. keyset(parameters) .. ')'
    end
  end
end
check(declared_count >= 8, 'the gate saw every connector family, not one: ' .. declared_count .. ' tool(s) declared properties')
check(#lost == 0, 'no catalogued tool exposes empty properties while its server declares some: ' .. table.concat(lost, '; '))

-- The WhatsApp surface is the one the finding named: every tool it offers carries its arguments.
for _, entry in ipairs(whatsapp.schemas()) do
  local fn = entry['function']
  check(properties(fn.parameters), 'whatsapp tool ' .. fn.name .. ' is offered with its properties')
  check(keyset(catalogued(fn.name)) == keyset(fn.parameters), 'whatsapp tool ' .. fn.name .. ' is catalogued with them')
end

-- A plugin's own keywords are passed through, not rebuilt.
local plugin = catalogued('demo_plugin')
check(plugin ~= nil and plugin.additionalProperties == false, 'plugin: additionalProperties survives the catalogue')
eq(keyset(plugin), 'scale,value', 'plugin: the declared properties arrive')

-- ---------------------------------------------------------------- 3. what the model actually reads
-- `searchTools("select:...")` and `describeTool(name)` are the same object through the same lookup both
-- code-mode loops build, so this is the surface the model guesses from - or reads.
local lookup = codemode.lookup(catalog, function() return { status = 'not_blocked' } end, function() return { error = 'not_invoked' } end)
local names = {}
for name in pairs(declared) do names[#names + 1] = name end
table.sort(names)
local selected = {}
for index = 1, math.min(#names, 8) do selected[#selected + 1] = names[index] end
local entries = lookup.discover({ 'select:' .. table.concat(selected, ',') })
check(type(entries) == 'table' and #entries == #selected, 'searchTools("select:...") answers one entry per name')
for _, entry in ipairs(entries) do
  check(entry.found ~= false, 'searchTools knows ' .. tostring(entry.name))
  check(keyset(entry.parameters) == keyset(declared[entry.name]),
    'searchTools answers the declared arguments for ' .. tostring(entry.name) .. ': got ' .. keyset(entry.parameters))
  local described = lookup.describe(entry.name)
  eq(keyset(described.parameters), keyset(entry.parameters), 'describeTool(' .. entry.name .. ') answers the same parameters')
end

-- ---------------------------------------------------------------- 4. a wrong argument name teaches the right one
-- A model that guesses `query` for a tool whose parameter is `q` gets one refusal that names every
-- accepted argument, so its next call is the one that works (13/11: three calls, three refusals).
local schema = { type = 'object', additionalProperties = false, properties = {
  q = { type = 'string' }, since = { type = 'number' }, before = { type = 'number' }, limit = { type = 'integer' } } }
local _, refusal = contract.validate(schema, '{"query":"laura"}')
check(has(refusal, 'schema_extra:arguments.query'), 'the refusal names the argument that does not exist: ' .. tostring(refusal))
check(has(refusal, 'accepted:'), 'the refusal names the arguments that do: ' .. tostring(refusal))
for _, accepted in ipairs({ 'before', 'limit', 'q', 'since' }) do
  check(has(refusal, accepted), 'the refusal lists ' .. accepted .. ': ' .. tostring(refusal))
end
-- A tool that takes no arguments says that instead of listing nothing.
local _, empty_refusal = contract.validate({ type = 'object', additionalProperties = false, properties = {} }, '{"q":"x"}')
check(has(empty_refusal, 'this object takes no arguments'), 'a no-argument tool says so: ' .. tostring(empty_refusal))
-- An argument the schema does not police is still accepted (the guard is a guard, not a rubber stamp).
local valid = contract.validate({ type = 'object', properties = { q = { type = 'string' } } }, '{"anything":1}')
check(valid ~= nil, 'an open schema accepts what it does not name')

host.plugins = real_plugins

print(('tool schema fidelity: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then error(('tool schema fidelity: %d check(s) failed'):format(failed)) end
