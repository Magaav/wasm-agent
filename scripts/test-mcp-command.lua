-- `/mcp`: one list of this node's connectors and its peers', the exact names each gives the model, and a
-- toggle that goes through the path that owns the connector.
--
-- Hermetic on purpose, and in the fast path: nothing here spawns an MCP server or reaches a node. The
-- registry and the federation cache are seeded with the durable state a probe and a refresh leave behind
-- (`mcp.extensions.v1` and `federation.catalog.v2`), and the peer half runs the *peer's own* code
-- (`federation.serve`) through a stand-in transport, so both sides of a peer toggle are exercised without
-- a network. `scripts/test-mcp.lua` remains the one that proves a real stdio handshake.
local json = dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok,
  'private registry table setup failed')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local mcp = dofile('lua/core/mcp.lua')
local federation = dofile('lua/core/federation.lua')
local command = dofile('lua/core/mcp_command.lua')
local tools = dofile('lua/core/tools.lua')
local prompt_cache = dofile('lua/core/prompt_cache.lua')

local checks = 0
local function check(value, label) checks = checks + 1; if not value then error('MCP /mcp CHECK FAILED: ' .. label) end end
local function meta_set(key, value)
  assert(json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key, value }))).ok,
    'meta write failed for ' .. key)
end
local function contains(haystack, needle) return tostring(haystack or ''):find(needle, 1, true) ~= nil end

-- ---------------------------------------------------------------- the state a probe leaves
local SCHEMA_READ_NEWEST = '{"type":"object","properties":{"conversation_id":{"type":"string"},"n":{"type":"integer"}},"required":["conversation_id"]}'
local SCHEMA_INSPECT = '{"type":"object","properties":{"conversation_id":{"type":"string"},"limit":{"type":"integer"}},"required":["conversation_id"]}'
local SCHEMA_LOOKUP = '{"type":"object","properties":{}}'
local SCHEMA_SEARCH = '{"type":"object","properties":{"conversation_id":{"type":"string"},"query":{"type":"string"}}}'
local registry = { schema = 1, revision = 7, servers = {
  native_reads = {
    enabled = false, revision = 1,
    definition = { id = 'native_reads', name = 'Native reads', transport = 'native',
      native = { read_newest = 'whatsapp_read', inspect_chat = 'whatsapp_read',
        read_snapshot = 'whatsapp_search', lookup_self = 'identity' },
      tools = { read_newest = 'read', inspect_chat = 'read', read_snapshot = 'read', lookup_self = 'read' } },
    probe = { ok = true, schema_hash = 'probe-hash-whatsapp', tools = {
      { name = 'read_newest', description = 'Read one WhatsApp chat newest-first', input_schema_json = SCHEMA_READ_NEWEST },
      { name = 'inspect_chat', description = 'Inspect one WhatsApp chat', input_schema_json = SCHEMA_INSPECT },
      { name = 'read_snapshot', description = 'Search the message index', input_schema_json = SCHEMA_SEARCH },
      { name = 'lookup_self', description = 'The paired account', input_schema_json = SCHEMA_LOOKUP },
    } },
  },
  broken = {
    enabled = false, revision = 1,
    definition = { id = 'broken', name = 'Broken connector', transport = 'stdio', program = 'missing', args = { 'x' }, tools = {} },
    probe = { ok = false, error = 'mcp_operation_failed' },
  },
} }
meta_set('mcp.extensions.v1', json.encode(registry))

-- A peer's answer, as `federation catalog` carries it: the flattened tools AND the connectors that export
-- them. The connector is enabled there and publishes one tool of the four it discovered. `revision` is the
-- peer's registry revision at the time of the answer, so this is written again after a local change moved
-- the seeded registry: a catalog is a snapshot, and the peer's own CAS is what refuses a stale one.
local peer_tool = mcp.namespace('native_reads', 'read_newest')
local function seed_peer_cache()
  local revision = mcp.inventory().revision
  local peer_connectors = { {
    key = 'native_reads', id = 'native_reads', name = 'Native reads', where = 'this node',
    scope = 'local', transport = 'native', state = 'enabled', enabled = true,
    tool_count = 1, approved = 4, discovered = 4, revision = revision,
    tools = { { name = peer_tool, tool = 'read_newest', description = 'MCP native_reads / read_newest: Read one chat',
      schema = SCHEMA_READ_NEWEST, approval = 'read', published = true } },
    policy = { tier = 'mcp', approval = 'each tool is approved locally as read or write' },
  } }
  meta_set('federation.catalog.v2', json.encode({ at = host.now(), peers = {
    ['peer-openclaw'] = { name = 'openclaw', node_id = 'peer-openclaw', at = host.now(),
      tools = { { name = peer_tool, description = '[on peer openclaw] Read one chat', effect = 'read',
        parameters = json.decode(SCHEMA_READ_NEWEST) } },
      connectors = peer_connectors },
  } }))
  return revision
end
seed_peer_cache()

local ctx = { role = 'master', user_id = 'master', session_id = 'mcp-command-fixture' }

-- ---------------------------------------------------------------- 1. the list, both sources
local view = command.list(ctx)
check(view.ok == true, 'list answers')
check(view.read_only == false, 'a master may change connectors')
check(view.counts.here == 2, 'two connectors registered on this node, found ' .. tostring(view.counts.here))
check(view.counts.from_peers == 1, 'one connector federated from a peer, found ' .. tostring(view.counts.from_peers))
local native = command.find(view, 'native_reads')
check(native and native.where == 'this node' and native.scope == 'local', 'the local connector says where it runs')
check(native.transport == 'native', 'the local connector reports its transport')
check(native.state == 'disabled' and native.error == nil, 'a probed but disabled connector is disabled, not failing')
check(native.tool_count == 0, 'a disabled connector gives the model no tool')
check(native.approved == 4 and native.discovered == 4, 'approved and discovered counts are the registry\'s')
local broken = command.find(view, 'broken')
check(broken and broken.state == 'failing', 'a failed probe is failing, not merely disabled')
check(broken.error == 'mcp_operation_failed', 'the failure carries its last error')
local peer = command.find(view, 'openclaw:native_reads')
check(peer and peer.scope == 'peer' and peer.where == 'openclaw', 'the peer connector says which node runs it')
check(peer.transport == 'native', 'the peer connector reports its transport')
check(peer.state == 'enabled' and peer.tool_count == 1, 'the peer connector reports its state and tool count')

-- ---------------------------------------------------------------- 2. one connector, verbatim
local detail = command.inspect(ctx, 'native_reads')
check(detail.ok, 'a connector opens by its key')
local names = {}
for _, tool in ipairs(detail.connector.tools) do names[tool.name] = tool end
local verbatim = mcp.namespace('native_reads', 'read_newest')
check(names[verbatim] ~= nil, 'the detail lists the exact model-visible name ' .. verbatim)
check(verbatim:match('^mcp_native_reads_read_newest_%x+$') ~= nil,
  'the name is the registry\'s own namespace, underscores intact: ' .. verbatim)
check(names[verbatim].schema == SCHEMA_READ_NEWEST, 'the input schema is the exact probed JSON')
check(contains(names[verbatim].description, 'Read one WhatsApp chat newest-first'), 'the tool keeps its description')
check(names[verbatim].approval == 'read', 'the approval tier is the local one')
check(names[verbatim].published == false, 'a disabled connector publishes nothing')
check(detail.connector.policy and detail.connector.policy.tier == 'mcp', 'the policy tier is reported')
local peer_detail = command.inspect(ctx, 'openclaw:native_reads')
local peer_name = federation.local_name('openclaw', peer_tool)
check(peer_name == 'peer_openclaw__' .. peer_tool, 'a peer tool is named peer_<peer>__<tool>')
check(peer_detail.connector.tools[1].name == peer_name, 'the detail lists the peer name verbatim')
check(peer_detail.connector.tools[1].schema == SCHEMA_READ_NEWEST, 'the peer schema travels unchanged')
check(peer_detail.connector.tools[1].published == true, 'a published peer tool is callable now')

-- The text the terminal prints: the list and the detail carry the same names.
local text = command.text(view)
check(contains(text, '3 connectors'), 'the list says how many connectors there are')
check(contains(text, 'openclaw:native_reads'), 'the list prints the key to open')
check(contains(text, 'connected'), 'the list names the state in one word a reader scans for')
check(not contains(text, 'schema'), 'the list is one screen, not a wall of JSON')
-- The detail: the names verbatim, and the tool's input is its FIELDS, not the raw schema JSON - the
-- schema used to be pasted whole, which is what made `/mcp` unreadable at 80 columns.
local pages = command.views(view).views
local detail_text = command.detail_text(detail.connector)
check(contains(detail_text, verbatim), 'the detail text carries the verbatim name')
local seen_tool, seen_input = false, false
for _, page in ipairs(pages) do
  if page.title == verbatim then
    seen_tool = true
    for _, line in ipairs(page.lines) do
      -- Fields, or "none": never the schema JSON (no brace can appear on this line).
      if line:find('^input: ') and not line:find('[{}]') then seen_input = true end
    end
  end
end
check(seen_tool and seen_input, 'a tool page carries its fields, summarised from the schema')
check(not contains(table.concat((function()
  local all = {}
  for _, page in ipairs(pages) do for _, line in ipairs(page.lines) do all[#all + 1] = line end end
  return all
end)(), '\n'), SCHEMA_READ_NEWEST), 'no page pastes the raw schema')

-- ---------------------------------------------------------------- 3. toggle a local connector
local enabled = command.toggle(ctx, 'native_reads', true)
check(enabled.ok, 'enabling a probed connector succeeds: ' .. tostring(enabled.error))
check(enabled.enabled == true and enabled.where == 'this node', 'the answer says what changed')
check(#mcp.schemas() == 4, 'the four approved tools are in the catalogue now')
check(command.find(command.list(ctx), 'native_reads').tool_count == 4, 'the list counts them')
local disabled = command.toggle(ctx, 'native_reads', false)
check(disabled.ok and disabled.enabled == false, 'disabling it succeeds')
check(#mcp.schemas() == 0, 'and the catalogue is empty again')
check(command.toggle(ctx, 'nope', true).error == 'unknown_connector', 'an unknown key refuses')
check(command.toggle(ctx, 'broken', true).error == 'mcp_probe_required', 'a connector whose probe failed cannot be enabled')
local audit = json.decode(host.sql_query("SELECT count(*) AS n FROM harness_events WHERE kind='mcp_control'", '[]'))
check(audit[1] and tonumber(audit[1].n) >= 2, 'each change is recorded on the node that owns the registry')

-- ---------------------------------------------------------------- 4. toggle a peer connector, as master
command.toggle(ctx, 'native_reads', true) -- the peer's registry must hold something to turn off
seed_peer_cache() -- the peer's answer after that change: a catalog is a snapshot, not a live view
local served = {}
local function peer_transport(node_id, capability, payload)
  served[#served + 1] = { node_id = node_id, capability = capability }
  -- The peer's own code, with the caller a verified master - exactly what server.lua hands `federation`.
  return federation.serve(payload, { role = 'master', node_id = 'master-node' },
    function(name) return { ok = false, error = 'not_dispatchable_here', name = name } end)
end
local stale = command.toggle(ctx, 'openclaw:native_reads', false, {
  call = function(node_id, capability, payload)
    payload.control.expected_revision = 999
    return peer_transport(node_id, capability, payload)
  end })
check(stale.ok == false and stale.error == 'mcp_store_revision_changed', 'a stale revision refuses on the peer')
check(command.find(command.list(ctx), 'openclaw:native_reads').state == 'enabled', 'and nothing changed')
local peer_off = command.toggle(ctx, 'openclaw:native_reads', false, { call = peer_transport })
check(peer_off.ok, 'a master turns a peer connector off: ' .. tostring(peer_off.error))
check(peer_off.where == 'openclaw' and peer_off.enabled == false, 'the answer names the peer and the new state')
check(#served == 2 and served[2].capability == 'federation', 'the change went through the federation capability')
local function federated(name)
  for _, item in ipairs(federation.schemas()) do if item['function'].name == name then return true end end
  return false
end
local after = command.find(command.list(ctx), 'openclaw:native_reads')
check(after.state == 'disabled' and after.tool_count == 0, 'this node\'s view of the peer changed at once')
check(federated(peer_name) == false, 'and the peer connector\'s tool left this node\'s catalogue')
check(command.toggle(ctx, 'openclaw:native_reads', true, { call = peer_transport }).ok, 'and back on again')
check(federated(peer_name) == true, 'the peer tool is callable here again')

-- ---------------------------------------------------------------- 5. a guest, and a child
local guest_view = command.list({ role = 'guest' })
check(guest_view.read_only == true, 'a guest sees the list read-only')
check(guest_view.counts.connectors == command.list(ctx).counts.connectors, 'a guest sees the same connectors')
check(contains(command.text(guest_view), 'read-only'), 'and the list says so')
check(command.toggle({ role = 'guest' }, 'native_reads', false).error == 'forbidden', 'a guest cannot change one')
check(command.toggle({ role = 'master', subagent = {} }, 'native_reads', false).error
  == 'mcp_management_forbidden_for_subagent', 'a child cannot change one')

-- ---------------------------------------------------------------- 5b. a peer on an older build
-- A peer that answers with tools and no registry is grouped by its own descriptions, and nothing there can
-- be toggled: the group says so rather than offering a control the peer cannot honour.
meta_set('federation.catalog.v2', json.encode({ at = host.now(), peers = {
  ['peer-legacy'] = { name = 'legacy', node_id = 'peer-legacy', at = host.now(),
    tools = {
      { name = 'mcp_mail_read_messages_cafebabe', effect = 'read',
        description = 'MCP mail / read_messages: Read one mailbox' },
      { name = 'mcp_mail_send_message_deadbeef', effect = 'write',
        description = 'MCP mail / send_message: Send one message' },
      { name = 'whatsapp_read', effect = 'read', description = '[native] Read one chat newest-first' },
      { name = 'whatsapp_operator', effect = 'write', description = 'Operator-directed WhatsApp text' },
    } },
} }))
local legacy = command.list(ctx)
local mail = command.find(legacy, 'legacy:mail')
check(mail ~= nil, "an older peer's tools are grouped into the connector its own descriptions name")
check(mail.tool_count == 2 and mail.state == 'enabled', 'with the tool count it exports')
check(mail.tools[1].name == federation.local_name('legacy', 'mcp_mail_read_messages_cafebabe'),
  'and the exact peer name per tool')
check(command.find(legacy, 'legacy:native') ~= nil, 'its native path is its own connector too')
check(command.find(legacy, 'legacy:*') ~= nil, 'and a tool matching neither keeps an other-tools group')
check(command.toggle(ctx, 'legacy:mail', false, { call = peer_transport }).error == 'connector_registry_not_reported',
  'a group inferred from an older peer cannot be toggled')
seed_peer_cache() -- back to the peer that does report its registry, for the sections below

-- ---------------------------------------------------------------- 6. a running session is told
-- A session freezes its prefix (system prompt + tool list) on its first turn, so a catalogue change is
-- delivered as the existing `[session update]` note rather than by editing the prefix. This proves a
-- connector change takes that path: the note is owed, appended once, and names the tool that appeared.
command.toggle(ctx, 'native_reads', false)
local session = memory.start_session('fixture', 'chat', { user_id = 'master', node_id = '', title = 'mcp' })
local session_ctx = { session_id = session, user_id = 'master', role = 'master' }
local function catalogue()
  local out = {}
  for _, item in ipairs(tools.all('master')) do out[#out + 1] = item end
  return out
end
local frozen, report = prompt_cache.enforce(session_ctx, { system = 'frozen system', tools = catalogue(), parts = {} })
check(report and report.created, 'the session freezes its prefix')
local baseline = #catalogue()
check(command.toggle(session_ctx, 'native_reads', true).ok, 'a master enables the connector mid-session')
check(#catalogue() == baseline + 4, 'the catalogue gained the connector\'s four tools')
local frozen2, report2 = prompt_cache.enforce(session_ctx, { system = 'frozen system', tools = catalogue(), parts = {} })
check(report2.changed == true, 'the running session sees a different catalogue')
check(report2.note_required == true, 'and owes it a note')
local added = (report2.detail or {}).tools_added or {}
local saw_name = false
for _, name in ipairs(added) do if name == mcp.namespace('native_reads', 'read_newest') then saw_name = true end end
check(saw_name, 'the added tool is the connector\'s own verbatim name')
local notes = prompt_cache.notes(session_ctx, frozen2, report2, {})
check(#notes == 1, 'the note is appended once')
check(contains(notes[1], '[session update]'), 'it is the existing session update')
check(contains(notes[1], mcp.namespace('native_reads', 'read_newest')), 'and it names the tool that appeared')
check(contains(notes[1], 'added:'), 'the note says what was added, not that everything was removed')
local _, report2b = prompt_cache.enforce(session_ctx, { system = 'frozen system', tools = catalogue(), parts = {} })
check(report2b.note_required == false, 'the session is not owed the note again')
check(#prompt_cache.notes(session_ctx, frozen2, report2b, {}) == 0, 'and it is not repeated')
check(frozen2 ~= nil, 'the frozen prefix is kept')
-- Turning it back off returns the catalogue to the bytes the session froze in: not `changed`, but the
-- last note in the transcript says the tools are there, so a note is still owed.
command.toggle(session_ctx, 'native_reads', false)
local frozen3, report3 = prompt_cache.enforce(session_ctx, { system = 'frozen system', tools = catalogue(), parts = {} })
check(report3.changed == false, 'the catalogue is back to the frozen bytes')
check(report3.note_required == true, 'and the session is still owed the note that says so')
check(#prompt_cache.notes(session_ctx, frozen3, report3, {}) == 1, 'which is delivered')


print(string.format('mcp command ok (%d checks, 0 skipped; no server spawned, no peer called)', checks))
