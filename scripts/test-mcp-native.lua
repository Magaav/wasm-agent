-- Why this exists (2026-11-10): the native connector took four deploy-sized rounds to work because
-- nothing checked its contract locally. The probe first published the capability's fields instead of
-- the tool's, then a bare property map, then `required` nested inside `properties`. Each is a
-- three-line check here, and a deploy is a six-minute way to discover it.
--
-- The contract has two halves and both are asserted without a node, a queue or a component:
--   1. what the connector publishes is a schema the node's own contract validator accepts;
--   2. what the caller says lands on the capability's own field names.
local json = dofile('lua/vendor/json.lua')
local jc = dofile('lua/core/json_contract.lua')
local mcp = dofile('lua/core/mcp.lua')
local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end

local def = {
  id = 'whatsapp_native', name = 'WhatsApp (native)', transport = 'native',
  tools = { read_newest = 'read', inspect_chat = 'read', read_snapshot = 'read', lookup_self = 'read' },
  native = { read_newest = 'whatsapp_read', inspect_chat = 'whatsapp_read',
             read_snapshot = 'whatsapp_search', lookup_self = 'identity' },
  config = { account = '5519994939204@s.whatsapp.net', generation = 2 },
  timeout_seconds = 60,
}

-- 1. the definition validates, and a tool with no published schema is refused here, not at call time
ok(mcp.validate(def) == nil, 'a native connector validates')
local unpublished = { id = 'x', transport = 'native', tools = { frobnicate = 'read' },
                       native = { frobnicate = 'whatsapp_read' } }
ok(mcp.validate(unpublished) == 'invalid_mcp_native_map', 'a tool with no published schema is refused')

-- 2. the probe publishes every mapped tool, each schema a real object schema
local probe = mcp.invoke({ action = 'probe', server = def }, {})
ok(probe.ok == true and #(probe.tools or {}) == 4, 'the probe publishes every mapped tool')
ok(type(probe.schema_hash) == 'string' and #probe.schema_hash == 64, 'the probe carries a schema hash')
local published = {}
for _, tool in ipairs(probe.tools) do
  local schema, err = json.decode(tool.input_schema_json)
  ok(schema ~= nil, 'the published schema is JSON: ' .. tool.name .. ' ' .. tostring(err))
  ok(schema.type == 'object', 'the published schema is an object schema: ' .. tool.name)
  ok(schema.properties ~= nil, 'the published schema has properties: ' .. tool.name)
  published[tool.name] = schema
end

-- 3. the published schema speaks the caller's vocabulary, not the capability's
local _, missing = jc.validate(published.read_newest, '{}')
ok(missing ~= nil and missing:find('conversation_id', 1, true) ~= nil,
  'a missing conversation_id is refused by name')
local _, extra = jc.validate(published.read_newest, '{"conversation_id":"x@lid","chat":"x@lid"}')
ok(extra ~= nil and extra:find('chat', 1, true) ~= nil, 'the capability field is not accepted from the caller')
ok(jc.validate(published.read_newest, '{"conversation_id":"x@lid","n":2}') ~= nil,
  'the documented arguments validate')
ok(jc.validate(published.lookup_self, '{}') ~= nil, 'lookup_self takes no arguments')

-- 4. the other half: every published field lands on the capability's own name
local mapped = mcp.native_arguments('read_newest', { conversation_id = 'x@lid', n = 2 })
ok(mapped.chat == 'x@lid' and mapped.limit == 2, 'conversation_id/n map onto chat/limit')
ok(mcp.native_arguments('inspect_chat', { conversation_id = 'x@lid' }).limit == 1,
  'inspect_chat reads one message by default')
ok(mcp.native_arguments('read_snapshot', { query = 'fica' }).q == 'fica', 'query maps onto q')
for name in pairs(published) do
  ok(mcp.native_arguments(name, {}) ~= nil, 'a published tool has an argument mapping: ' .. name)
end

-- 5. identity and refusals need no component
local identity = mcp.invoke({ action = 'call', server = def, tool = 'lookup_self', arguments = {} }, {})
local body = (identity.result and identity.result.structuredContent) or {}
ok(identity.ok == true and body.account == '5519994939204@s.whatsapp.net',
  'lookup_self answers from the connector binding')
ok(mcp.invoke({ action = 'call', server = def, tool = 'nope', arguments = {} }, {}).error == 'mcp_tool_not_approved',
  'an unmapped tool is refused')

print('mcp native connector: ' .. checks .. ' checks passed')
