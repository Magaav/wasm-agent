-- What one connector call may change in the registry (10/11).
--
-- `lua/core/mcp.lua` used to treat `mcp_tool_schemas_changed` as a reason to turn the connector OFF: it set
-- `enabled=false` and threw the cached probe away. The connector then came back DISABLED with its tools gone
-- from the catalogue, and only a manual probe could bring it back - the state a reader reported as "the
-- connectors came back disabled after a deploy", where a cached probe no longer matched the running runtime.
--
-- A call is evidence about a connector, never a reason to reverse the operator's decision: the refusal
-- itself is unchanged and stays safe (`mcp_tool_schemas_changed` is answered before dispatch, so nothing is
-- issued against a catalogue nobody approved), but the enable decision and the cached probe survive, and the
-- staleness is recorded so the list can say "re-probe" instead of "disabled".
--
-- Hermetic and in the fast path: a real SQLite registry, the module's own CAS, and `M.invoke` stood in for -
-- no connector is spawned and no node is reached. `scripts/test-mcp.lua` remains the one that proves a real
-- stdio handshake.
local json = dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok,
  'private registry table setup failed')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local mcp = dofile('lua/core/mcp.lua')

local checks = 0
local function check(value, label) checks = checks + 1; if not value then error('MCP REGISTRY CHECK FAILED: ' .. label) end end
local function eq(got, want, label)
  assert(got == want, (label or '') .. ': got ' .. tostring(got) .. ', want ' .. tostring(want)); checks = checks + 1
end
local KEY = 'mcp.extensions.v1'
local TOOL = 'imap_list_mailboxes'
local SCHEMA = '{"type":"object","properties":{"account_id":{"type":"string"}}}'
local NAME = mcp.namespace('google', TOOL)

-- The registry a passing probe leaves behind: enabled, one approved read tool, the catalogue it read.
local function seed()
  local registry = { schema = 1, revision = 4, servers = { google = {
    enabled = true, revision = 2,
    definition = { id = 'google', name = 'Gmail', transport = 'stdio', program = 'node',
      args = { 'mcp-mail.mjs' }, tools = { [TOOL] = 'read' } },
    probe = { ok = true, schema_hash = 'hash-1', tools = {
      { name = TOOL, description = 'List the mailboxes of one account', input_schema_json = SCHEMA },
    } },
  } } }
  assert(json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
    json.encode({ KEY, json.encode(registry) }))).ok, 'registry seed failed')
end
local function stored()
  local rows = json.decode(host.sql_query('SELECT value FROM meta WHERE key=?', json.encode({ KEY })))
  return json.decode(rows[1].value)
end
seed()

-- ---- a refused call leaves the operator's decision alone -----------------------------------------
local refused = { ok = false, error = 'mcp_tool_schemas_changed', outcome = 'not_submitted', tool_call_issued = false }
mcp.invoke = function() return refused end
local answer = mcp.call(NAME, {}, { user_id = 'master', role = 'master', session_id = 'registry-state' })
eq(answer.error, 'mcp_tool_schemas_changed', 'the refusal still reaches the caller')
eq(answer.probe_stale and answer.probe_stale.error, 'mcp_tool_schemas_changed', 'the answer names the staleness')
local after = stored().servers.google
eq(after.enabled, true, 'a refused call does not disable the connector')
check(type(after.probe) == 'table' and after.probe.ok == true, 'and does not throw the cached probe away')
eq(after.probe.schema_hash, 'hash-1', 'the approved catalogue is still the one on record')
eq(after.probe_stale and after.probe_stale.error, 'mcp_tool_schemas_changed', 'the staleness is durable')
eq(after.last_call and after.last_call.error, 'mcp_tool_schemas_changed', 'and the call is recorded as it was')

-- the connector is still offered: this is what used to vanish from the catalogue
local id = mcp.resolve_tool(NAME)
eq(id, 'google', 'the tool still resolves, so the catalogue still publishes it')
local inventory = mcp.inventory()
local entry = inventory.servers[1]
eq(entry.enabled, true, 'the inventory still says enabled')
check(tostring(entry.observed_status):find('re%-probe') ~= nil, 'and says re-probe, not disabled')

-- a fresh module load is what a restart has of this state: the store is the only memory
local restarted = dofile('lua/core/mcp.lua')
eq(restarted.inventory().servers[1].enabled, true, 'a restart keeps the connector enabled')
eq(restarted.resolve_tool(NAME), 'google', 'and keeps its tools published')

-- ---- a call that works proves the catalogue matches again ----------------------------------------
mcp.invoke = function() return { ok = true, result_json = '{"mailboxes":["INBOX"]}', outcome = 'settled', tool_call_issued = true } end
local good = mcp.call(NAME, {}, { user_id = 'master', role = 'master', session_id = 'registry-state' })
check(good.ok == true, 'the passing call answers')
eq(stored().servers.google.probe_stale, nil, 'a passing call clears the staleness note')
eq(stored().servers.google.enabled, true, 'and leaves the connector on')

-- ---- a definite server error is a call result, not a reason to disable ---------------------------
mcp.invoke = function()
  return { ok = false, error = "mcp_rpc_error:-32002:IMAP account 'default' is not configured", outcome = 'error', tool_call_issued = true }
end
mcp.call(NAME, {}, { user_id = 'master', role = 'master', session_id = 'registry-state' })
local errored = stored().servers.google
eq(errored.enabled, true, 'a server error does not disable the connector either')
eq(errored.probe_stale, nil, 'and it is not a schema staleness')

-- ---- probe and enable are what refresh or clear it ----------------------------------------------
local mutation = stored()
mutation.servers.google.probe_stale = { at = host.now(), error = 'mcp_tool_schemas_changed' }
assert(json.decode(host.sql_exec('UPDATE meta SET value=? WHERE key=?', json.encode({ json.encode(mutation), KEY }))).ok,
  'staleness seed failed')
local revision = stored().revision
local enabled = mcp.control({ action = 'enable', id = 'google', expected_revision = revision },
  { role = 'master', user_id = 'master', session_id = 'registry-state' })
eq(enabled.ok, true, 'enable still works with a recorded staleness')
eq(enabled.enabled, true, 'and reports the connector on')
eq(stored().servers.google.probe_stale, nil, 'enable clears the note it just answered')

mutation = stored()
mutation.servers.google.probe_stale = { at = host.now(), error = 'mcp_tool_schemas_changed' }
assert(json.decode(host.sql_exec('UPDATE meta SET value=? WHERE key=?', json.encode({ json.encode(mutation), KEY }))).ok,
  'staleness seed failed')
mcp.invoke = function() return { ok = true, schema_hash = 'hash-2', tool_call_issued = false, tools = {
  { name = TOOL, description = 'List the mailboxes of one account', input_schema_json = SCHEMA } } } end
local probed = mcp.control({ action = 'probe', id = 'google', expected_revision = stored().revision },
  { role = 'master', user_id = 'master', session_id = 'registry-state' })
eq(probed.ok, true, 'the probe answers')
local probed_entry = stored().servers.google
eq(probed_entry.probe_stale, nil, 'a fresh probe clears the staleness note')
eq(probed_entry.enabled, false, 'and still leaves the connector to be enabled explicitly, as before')
eq(probed_entry.probe.schema_hash, 'hash-2', 'with the catalogue it just read')

print('test-mcp-registry-state: ' .. checks .. ' checks passed')
