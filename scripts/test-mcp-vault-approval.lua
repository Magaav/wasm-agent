-- A connector that names a vault entry is approved by the OPERATOR, and the approval is a digest over what
-- its launch IS (docs/VAULT.md, 18/11): the program, its arguments, every script file it runs and the
-- vault names it asks for. The kernel recomputes that digest from the bytes on disk before it reads a
-- value, so editing a script or an argument AFTER the approval voids it. This is the adversarial half:
-- the review measured that an approved connector's script could be rewritten (the script directory was
-- writable by the agent's own tools) and the value handed to the new code.
--
-- In-process: no vault, no server spawned. `host.operation` is stubbed so the launch is captured and
-- refused before anything runs; the store is seeded directly, the way an approval row already exists.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok)
dofile('lua/core/memory.lua').setup()
local mcp = dofile('lua/core/mcp.lua')
local checks, failed = 0, 0
local function ok(value, label) checks = checks + 1; if not value then failed = failed + 1; print('FAIL ' .. label) end end
local function eq(actual, wanted, label)
  ok(actual == wanted, label .. ' (got ' .. tostring(actual) .. ', wanted ' .. tostring(wanted) .. ')')
end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

-- ---- 1. the canonical text is the Rust side's, byte for byte --------------------------------
-- The same fixture the Rust test pins (rust/wa-capabilities/src/operations.rs,
-- `the_canonical_text_escapes_fields_and_matches_the_lua_side`). One form, two implementations, and
-- one digest: if either side changes its escaping, one of the two tests fails.
local fixture = {
  program = '/usr/bin/node',
  args = { '/home/agent/scripts/fixture.mjs', '--token', 'a b' },
  files = { { path = '/home/agent/scripts/fixture.mjs', sha256 = string.rep('aa', 32) },
            { path = '/home/agent/scripts/lib/other.mjs', sha256 = string.rep('bb', 32) } },
  vault = { 'FIXTURE_TOKEN', 'SECOND_ONE' },
}
local text = mcp.vault_approval_text(fixture)
ok(has(text, 'mcp-vault-approval/v1\nprogram /usr/bin/node\n'), 'the canonical text names its version and program')
ok(has(text, '\narg a%20b\n'), 'a space inside an argument is escaped, not a separator: ' .. text)
eq(host.sha256(text), '0423d0cb712e6441592ef2a8d04f8179ba03d7d797bfb233b3f07939ae450da8',
  'the digest the Rust side pins for the same fixture')
-- A newline (or a tab) in a field cannot forge a line of the digest.
ok(not has(mcp.vault_approval_text({ program = '/bin/sh', args = { 'a\nb' }, files = {}, vault = {} }),
  '\narg a\nb\n'), 'a newline in an argument is escaped rather than forging a line')

-- ---- 2. the digest covers every script the connector runs ------------------------------------
-- A directory this test owns, made the runtime the node resolves (WA_MCP_SCRIPT_DIR), so nothing here
-- writes into the node's install or into this checkout.
local real_getenv = host.getenv
local dir = paths.data() .. '/mcp/vault-approval-' .. tostring(host.uuid()):sub(1, 8)
host.getenv = function(name) if name == 'WA_MCP_SCRIPT_DIR' then return dir end return real_getenv(name) end
for _, name in ipairs(mcp.RUNTIME) do
  assert(host.write_file(dir .. '/' .. name, '// runtime stub: ' .. name .. '\n'), 'a runtime stub: ' .. name)
end
local connector = dir .. '/connector.mjs'
assert(host.write_file(connector, 'export const run = 1;\n'), 'the connector script')
eq(mcp.script_dir(), dir, 'the script directory this test owns is the runtime the node resolves')

local definition = { id = 'vault-fixture', name = 'Vault fixture', transport = 'stdio',
  program = '/usr/bin/node', args = { connector, '--mode', 'stdio' }, tools = { echo = 'write' },
  vault_env = { FIXTURE_TOKEN = 'fixture_token' }, timeout_seconds = 5 }
eq(mcp.validate(definition), nil, 'a stdio definition naming a vault entry validates')
local manifest = mcp.vault_manifest(definition, mcp.script_dir())
ok(#manifest.files >= #mcp.RUNTIME + 1, 'the digest covers the runtime and the connector script: ' .. #manifest.files .. ' files')
local covered = {}
for _, file in ipairs(manifest.files) do covered[file.path] = true end
ok(covered[dir .. '/mcp-client.mjs'] and covered[connector], 'the client that runs and the connector it runs are both in it')
eq(#manifest.vault, 1, 'and the vault name it asks for')

-- ---- 3. the operator's "on" records the digest, and a call carries it to the kernel ----------
local probe = { ok = true, schema_hash = 'fixture-hash',
  tools = { { name = 'echo', description = 'echo', input_schema_json = '{"type":"object"}' } } }
local STORE = 'mcp.extensions.v1'
local function seed(row)
  local store = { schema = 1, revision = 1, servers = { ['vault-fixture'] = row } }
  assert(json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
    json.encode({ STORE, json.encode(store) }))).ok, 'the registry row is written')
end
local function row()
  local rows = json.decode(host.sql_query('SELECT value FROM meta WHERE key=?', json.encode({ STORE })))
  local store = json.decode(rows[1].value)
  return store.servers['vault-fixture'], store
end
seed({ definition = definition, enabled = false, vault_approved = false, revision = 1, probe = probe })
local switched = mcp.control({ action = 'enable', id = 'vault-fixture', expected_revision = 1 },
  { role = 'master', operator = true, session_id = 'op' })
ok(switched.ok == true, 'the operator turns it on: ' .. json.encode(switched))
local approved = row()
eq(approved.vault_approved, true, 'the row records the approval')
ok(type(approved.vault_approval) == 'table' and type(approved.vault_approval.sha256) == 'string',
  'and WHAT it approves, which is new (a boolean cannot say what it covered)')
eq(approved.vault_approval.sha256, manifest.sha256, 'the recorded digest is the launch this definition makes')

-- The launch: captured, never started. What reaches the kernel is the digest, the vault names and the
-- script list - and the value is not here (only the entry's name is).
local real_operation = host.operation
local starts = {}
host.operation = function(action, payload)
  if action == 'start' then
    local decoded = json.decode(payload)
    starts[#starts + 1] = decoded
    return json.encode({ error = 'fixture_no_launch' })
  end
  return real_operation(action, payload)
end
local name = mcp.namespace('vault-fixture', 'echo')
local answer = mcp.call(name, {}, { session_id = 'model' })
eq(answer.error, 'mcp_operation_not_started', 'the call reaches the launch (the stub refuses it): ' .. json.encode(answer))
local sent = starts[#starts]
ok(sent ~= nil, 'a launch was attempted')
eq(sent and sent.vault_env and sent.vault_env.FIXTURE_TOKEN, 'fixture_token', 'the kernel is handed the entry NAME')
ok(sent and sent.vault_approval and sent.vault_approval.sha256 == manifest.sha256,
  'and the approval the operator gave, as a digest')
ok(sent and type(sent.vault_approval.files) == 'table' and #sent.vault_approval.files >= 1,
  'with the script list the kernel re-reads')

-- ---- 4. the attack: the script is rewritten after the approval -------------------------------
local before = #starts
assert(host.write_file(connector, 'export const run = 1; // replaced after the approval\n'), 'rewrite the script')
local stale = mcp.call(name, {}, { session_id = 'model' })
eq(stale.error, 'mcp_vault_approval_stale', 'an edited script voids the approval: ' .. json.encode(stale))
eq(stale.tool_call_issued, false, 'and nothing was issued')
eq(stale.outcome, 'not_submitted', 'nor submitted')
eq(#starts, before, 'no process was started')
ok(has(stale.note, '/mcp vault-fixture probe'), 'the refusal says how to approve it again: ' .. tostring(stale.note))
ok(type(stale.approved) == 'string' and type(stale.now) == 'string' and stale.approved ~= stale.now,
  'and names both digests, so the change is a fact rather than a claim')

-- The approved bytes coming back restores the approval: nothing was re-recorded, the digest is the same.
assert(host.write_file(connector, 'export const run = 1;\n'), 'restore the script')
local again = mcp.call(name, {}, { session_id = 'model' })
eq(again.error, 'mcp_operation_not_started', 'the approved bytes launch again: ' .. json.encode(again))

-- An ARGUMENT is covered the same way: changing it makes the stored digest stale.
local moved = mcp.vault_manifest({ program = definition.program, args = { connector, '--mode', 'http' },
  vault_env = definition.vault_env, tools = definition.tools }, mcp.script_dir())
ok(moved.sha256 ~= manifest.sha256, 'a changed argument is a changed digest')

-- ---- 5. an approval from before the digest existed, and a model's own put --------------------
seed({ definition = definition, enabled = true, vault_approved = true, revision = 1, probe = probe })
local legacy = mcp.call(name, {}, { session_id = 'model' })
eq(legacy.error, 'mcp_vault_approval_missing', 'an approval that cannot say what it covers launches nothing: ' .. json.encode(legacy))
eq(legacy.tool_call_issued, false, 'and issues nothing')
-- A definition that names a vault entry is still never a model's to write, and the put that writes one
-- carries no approval: the operator's own act is the only approval there is.
seed({ definition = definition, enabled = true, vault_approved = true, revision = 1, probe = probe })
local put = mcp.control({ action = 'put', definition = definition, expected_revision = 1 },
  { role = 'master', session_id = 'model' })
eq(put.error, 'mcp_vault_env_requires_operator', 'a model still cannot write a vault definition')
host.getenv = real_getenv
host.operation = real_operation

if failed > 0 then print(string.format('mcp vault approval: %d failed of %d checks', failed, checks)) os.exit(1) end
print(string.format('mcp vault approval ok (%d checks)', checks))
