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
  files = { { name = 'mcp-shared-fixture.mjs', content = other, sha256 = host.sha256(other) } } }, { node_id = 'p' }).error == 'share_file_in_use',
  'a script another registered connector runs is not taken over, not even by another connector id')
-- And replace is the receiving operator's decision, never a field a peer sets: with no operator on this
-- call, a replace is refused before any byte is written (18/11: a peer rewrote an enabled connector's
-- script this way).
local replaced = federation.import_here({ definition = base, replace = true,
  files = { { name = 'mcp-own-fixture.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'p' })
ok(replaced.error == 'share_replace_requires_operator', 'a peer replace is refused: ' .. json.encode(replaced))
ok(not host.read_file(dir .. '/mcp-own-fixture.mjs'), 'the refused replace wrote nothing')
-- The replace refusal is checked BEFORE any of these (round 3), so each one is asked without it:
-- what is being tested here is the rule itself, not which refusal wins.
ok(federation.import_here({ definition = base,
  files = { { name = 'mcp-client.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'p' }).error == 'share_file_is_built_in',
  'a built-in script is never replaced by a share')
ok(federation.import_here({ definition = base,
  files = { { name = 'a.mjs', content = script, sha256 = 'wrong' } } }, { node_id = 'p' }).error == 'share_file_unverified', 'a checksum mismatch is refused')
ok(federation.import_here({ definition = base,
  files = { { name = '../evil.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'p' }).error == 'share_file_name_invalid', 'a path in a file name is refused')
-- And with replace, the operator's decision is what refuses it first - built-in script or not.
ok(federation.import_here({ definition = base, replace = true,
  files = { { name = 'mcp-client.mjs', content = script, sha256 = host.sha256(script) } } }, { node_id = 'p' }).error == 'share_replace_requires_operator',
  'a peer replace is refused before the built-in rule is even reached')

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

-- 7. vault_env is the OPERATOR's: the kernel injects the value into whatever program the definition
-- names, so a model may not write such a definition, a peer's import of one lands inert, and neither can
-- be launched until the operator approves it at its own terminal (18/11).
local model = { role = 'master', session_id = 'model-session' }
local operator = { role = 'master', session_id = 'operator-session', operator = true }
local wanted = { id = 'vault-fixture', name = 'Vault fixture', transport = 'stdio', program = '/bin/sh',
  args = { '-c', 'echo $FIXTURE_TOKEN > /tmp/wasm-agent-vault-fixture' }, tools = { echo = 'read' },
  vault_env = { FIXTURE_TOKEN = 'fixture_token' } }
local put = mcp.control({ action = 'put', definition = wanted, expected_revision = mcp.inventory().revision }, model)
ok(put.ok == false and put.error == 'mcp_vault_env_requires_operator', 'a model put carrying vault_env is refused: ' .. json.encode(put))
ok(not host.read_file('/tmp/wasm-agent-vault-fixture'), 'the refused definition launched nothing')
local in_registry = function(id)
  for _, server in ipairs(mcp.inventory().servers) do if server.id == id then return server end end
  return nil
end
ok(in_registry('vault-fixture') == nil, 'the refused definition is not in the registry')
-- The same definition imported from a peer LANDS (a shared connector is meant to arrive names-only) but
-- disabled and unapproved.
local shared_vault = { id = 'vault-shared', name = 'Shared vault fixture', transport = 'stdio', program = '/usr/bin/node',
  args = { dir .. '/mcp-shared-fixture.mjs' }, tools = { echo = 'read' }, timeout_seconds = 5,
  vault_env = { FIXTURE_TOKEN = 'fixture_token' } }
local landed = federation.import_here({ definition = shared_vault, files = {} }, { node_id = 'peer-vault' })
ok(landed.ok == true and landed.disabled == true, 'a peer import carrying vault_env lands, disabled: ' .. json.encode(landed))
local shared_row = in_registry('vault-shared')
ok(shared_row and shared_row.enabled == false and not shared_row.vault_approved, 'the imported connector is inert, not approved')
local probe = mcp.control({ action = 'probe', id = 'vault-shared', expected_revision = mcp.inventory().revision }, model)
ok(probe.ok == false and probe.error == 'mcp_vault_env_requires_operator', 'its probe is refused until the operator approves: ' .. json.encode(probe))
local enable = mcp.control({ action = 'enable', id = 'vault-shared', expected_revision = mcp.inventory().revision }, model)
ok(enable.ok == false and enable.error == 'mcp_vault_env_requires_operator', 'so is a model enable: ' .. json.encode(enable))
-- The operator's own probe (the CLI's ctx, and nothing else sets ctx.operator) is what approves it. The
-- launch then fails for reasons of its own here - this test has no vault and no Node runtime - and that is
-- the point: the gate is gone, and the secret is still nowhere in the answer.
local approved = mcp.control({ action = 'probe', id = 'vault-shared', expected_revision = mcp.inventory().revision }, operator)
ok(approved.error ~= 'mcp_vault_env_requires_operator', 'the operator probe is not refused by the gate: '
  .. tostring(approved.error) .. ' ' .. tostring(approved.detail))
local after = in_registry('vault-shared')
ok(after and after.vault_approved == true, 'the operator probe is the approval')
ok(after and after.definition.vault_env and after.definition.vault_env.FIXTURE_TOKEN == 'fixture_token',
  'the entry stays a name on the row')
ok(not json.encode(after):find('secret', 1, true), 'no value reaches the registry')

-- ---- the replace bypass the review measured (18/11) --------------------------------------------
-- `replace` was checked INSIDE the per-file loop, so a peer sending `files: []` with `replace: true`
-- skipped the check entirely and reached the connector-id branch below it - overwriting this node's
-- definition of a connector that may be ENABLED, with no file to inspect and nobody's approval. The
-- check is now before the loop: one condition, whatever the file list holds.
local takeover = { id = 'shared-fixture', name = 'Taken over by the peer', transport = 'stdio',
  program = '/usr/bin/node', args = {}, tools = { a = 'read' } }
local empty_replace = federation.import_here({ definition = takeover, replace = true, files = {} }, { node_id = 'peer-evil' })
ok(empty_replace.error == 'share_replace_requires_operator',
  'a replace with no files at all is refused: ' .. json.encode(empty_replace))
local survivor = in_registry('shared-fixture')
ok(survivor and survivor.definition.name ~= 'Taken over by the peer',
  'and the connector this node already had keeps its definition: ' .. tostring(survivor and survivor.definition.name))
-- The same refusal with no replacement definition to hide behind: an empty file list and a new id.
local empty_new = federation.import_here({ definition = { id = 'other-id', name = 'O', transport = 'stdio',
  program = '/usr/bin/node', args = {}, tools = { a = 'read' } }, replace = true, files = {} }, { node_id = 'peer-evil' })
ok(empty_new.error == 'share_replace_requires_operator', 'and it is refused for a new id too: ' .. json.encode(empty_new))
ok(in_registry('other-id') == nil, 'nothing was registered by it')

if failed > 0 then print(string.format('mcp share: %d failed of %d checks', failed, checks)); os.exit(1) end
print(string.format('mcp share ok (%d checks)', checks))
