-- Sharing a connector between nodes (operator 17/11, `/mcp <key> share <node>`) and its credential by vault
-- reference. In-process: the "peer" is this same node's import half, reached through `opts.call`, with its
-- script directory a temp directory (WA_MCP_SCRIPT_DIR). No network, no vault, no server spawned.
local json = dofile('lua/vendor/json.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok)
dofile('lua/core/memory.lua').setup()
local mcp = dofile('lua/core/mcp.lua')
local federation = dofile('lua/core/federation.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if not value then failed = failed + 1; print('FAIL ' .. label) end end

local dir = assert(host.getenv('WA_MCP_SCRIPT_DIR'), 'WA_MCP_SCRIPT_DIR')
local home = tostring(host.getenv('HOME'))

-- 1. paths move from the sender's home to this one, inside JSON strings too.
local moved = federation._moved({ args = { '/home/agent/x/a.mjs', '{"token_file":"/home/agent/k.key"}' }, n = 1 }, '/home/agent', '/home/victor')
ok(moved.args[1] == '/home/victor/x/a.mjs', 'a path argument moves home: ' .. tostring(moved.args[1]))
ok(moved.args[2] == '{"token_file":"/home/victor/k.key"}', 'a path inside a JSON argument moves home: ' .. tostring(moved.args[2]))

-- 2. vault_env: names only, stdio only; the launch gets a copy that references the names.
local base = { id = 'shared-fixture', name = 'Shared', transport = 'stdio', program = '/usr/bin/node',
  args = { '/home/sender/.wasm-agent/scripts/mcp-shared-fixture.mjs', '--config-json', '{"file":"/home/sender/a"}' },
  tools = { echo = 'read' }, vault_env = { FIXTURE_TOKEN = 'fixture_token' }, timeout_seconds = 5 }
ok(mcp.validate(base) == nil, 'a stdio definition naming a vault entry validates: ' .. tostring(mcp.validate(base)))
local http = { id = 'h', name = 'H', transport = 'http', url = 'https://example.invalid/mcp', tools = { a = 'read' }, vault_env = { T = 't' } }
ok(mcp.validate(http) == 'mcp_vault_env_requires_stdio', 'vault_env is stdio only')
local bad = { id = 'b', name = 'B', transport = 'stdio', program = '/usr/bin/node', args = {}, tools = { a = 'read' }, vault_env = { ['1X'] = 't' } }
ok(mcp.validate(bad) == 'invalid_mcp_vault_env', 'an invalid environment name is refused')
local launch, entries = mcp.vault_launch(base)
ok(launch ~= base and launch.env.FIXTURE_TOKEN == 'FIXTURE_TOKEN' and base.env == nil, 'the launch copy references the name; the row is untouched')
ok(entries and entries.FIXTURE_TOKEN == 'fixture_token', 'the kernel is handed the entry name, never a value')
local plain, none = mcp.vault_launch({ id = 'p' })
ok(plain and plain.id == 'p' and none == nil, 'a server naming no entry launches as it is')

-- 3. import: the custom script lands in this node's script directory, paths move, the row is disabled.
local script = 'export const fixture = 1;\n'
local answer = federation.import_here({ definition = base, from_home = '/home/sender',
  files = { { name = 'mcp-shared-fixture.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'peer-test' })
ok(answer.ok == true and answer.disabled == true, 'imported, disabled: ' .. json.encode(answer))
ok(host.read_file(dir .. '/mcp-shared-fixture.mjs') == script, 'the script is written into the script directory')
local row
for _, server in ipairs(mcp.inventory().servers) do if server.id == 'shared-fixture' then row = server end end
ok(row and row.enabled == false, 'the connector is registered disabled')
ok(row and row.definition.args[1] == dir .. '/mcp-shared-fixture.mjs', 'its script argument points at this node: ' .. tostring(row and row.definition.args[1]))
ok(row and row.definition.args[3] == '{"file":"' .. home .. '/a"}', 'its JSON argument moved home: ' .. tostring(row and row.definition.args[3]))
ok(row and row.definition.vault_env.FIXTURE_TOKEN == 'fixture_token', 'the vault entry travels by name')
ok(answer.vault_entries and answer.vault_entries[1] == 'fixture_token' and tostring(answer.note):find('wa vault set fixture_token', 1, true),
  'the answer says which entry to store there: ' .. tostring(answer.note))

-- 4. refusals: same id again, a built-in file, a bad checksum, a path in the name.
ok(federation.import_here({ definition = base, files = {} }, { node_id = 'peer-test' }).error == 'share_connector_exists', 'an existing id is not overwritten without replace')
local other = 'export const other = 2;\n'
ok(federation.import_here({ definition = { id = 'x2', name = 'X', transport = 'stdio', program = '/usr/bin/node', args = {}, tools = { a = 'read' } },
  files = { { name = 'mcp-shared-fixture.mjs', content = other, sha256 = host.sha256(other) } } }, { node_id = 'p' }).error == 'share_file_exists_differs',
  'a different file of the same name is not overwritten without replace')
ok(federation.import_here({ definition = base, replace = true,
  files = { { name = 'mcp-client.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'p' }).error == 'share_file_is_built_in',
  'a built-in script is never replaced by a share')
ok(federation.import_here({ definition = base, replace = true,
  files = { { name = 'a.mjs', content = script, sha256 = 'wrong' } } }, { node_id = 'p' }).error == 'share_file_unverified', 'a checksum mismatch is refused')
ok(federation.import_here({ definition = base, replace = true,
  files = { { name = '../evil.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'p' }).error == 'share_file_name_invalid', 'a path in a file name is refused')

-- 5. the sending half packs the custom script, not the built-in ones.
local sent
local real_cached = federation.cached
federation.cached = function() return { peers = { x = { name = 'peerx', node_id = 'node-x' } } } end
local shared = federation.share('peerx', 'shared-fixture', { call = function(node_id, capability, payload)
  sent = { node_id = node_id, capability = capability, payload = payload }
  return { ok = true, files = #payload.files, note = 'n' }
end })
federation.cached = real_cached
ok(shared.ok and sent and sent.node_id == 'node-x' and sent.capability == 'federation' and sent.payload.action == 'import', 'share calls the peer\'s import')
ok(sent and #sent.payload.files == 1 and sent.payload.files[1].name == 'mcp-shared-fixture.mjs' and sent.payload.files[1].content == script,
  'the custom script travels, with its checksum')
ok(sent and sent.payload.definition.vault_env and not json.encode(sent.payload):find('secret', 1, true), 'no value travels, only the entry name')
ok(federation.share('nobody', 'shared-fixture').error == 'unknown_peer', 'an unknown peer is refused')

-- 6. the tool and route paths cannot name a vault entry.
local tools_src = host.read_file('lua/core/tools.lua') or ''
ok(tools_src:find('args.vault_env = nil', 1, true) ~= nil, 'the operation tool strips vault_env')
ok((host.read_file('lua/core/server.lua') or ''):find('args.vault_env = nil', 1, true) ~= nil, 'the operation route strips vault_env')

if failed > 0 then print(string.format('mcp share: %d failed of %d checks', failed, checks)); os.exit(1) end
print(string.format('mcp share ok (%d checks)', checks))
