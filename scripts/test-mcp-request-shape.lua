-- The two halves of round 5's first fix are tested separately: lua/core/mcp.lua BUILDS the request file
-- (server.program/args/cwd/env, and the vault values by name only) and
-- rust/wa-capabilities/src/operations.rs CHECKS it against the operator's approval before the child may
-- spawn. This test is the seam between them: it asks the real console to build a request for a definition
-- that names a vault entry, then compares that file with the approval the same call carries, field by
-- field - the program, the arguments, the cwd, and the environment (the definition's own references plus
-- one self-reference per vault name). No vault is opened and nothing is spawned: host.operation is stubbed
-- so the launch is captured and refused.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
-- ---- the scratch-home guard (round 6) ---------------------------------------------------------
-- This test writes under paths.data(). It refuses to run unless that is a SCRATCH home: WASM_AGENT_HOME
-- must be set (the runner's own directory), the data directory must be under it, and a data directory
-- that already holds a node's keys or secrets is a REAL node - never this test's to write in.
local function refuse_real_home()
  local scratch = tostring(host.getenv('WASM_AGENT_HOME') or '')
  local data = dofile('lua/core/paths.lua').data()
  local live = host.path_kind(data .. '/keys') == 'dir' or host.path_kind(data .. '/secrets') == 'dir'
  if scratch == '' or data:find(scratch, 1, true) ~= 1 or live then
    print('SKIP refusing to write under ' .. data .. ' (set WASM_AGENT_HOME to a scratch directory)')
    os.exit(77)
  end
end
refuse_real_home()

assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)', '[]')).ok)
dofile('lua/core/memory.lua').setup()
local mcp = dofile('lua/core/mcp.lua')
local checks, failed = 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then failed = failed + 1; print('FAIL ' .. label) end
end

-- A runtime directory this test owns, made the one the node resolves.
local dir = paths.data() .. '/request-shape-' .. tostring(host.uuid()):sub(1, 8)
for _, name in ipairs(mcp.RUNTIME) do assert(host.write_file(dir .. '/' .. name, '// runtime stub: ' .. name .. '\n')) end
local real_getenv = host.getenv
-- Round 8: the allow-list judges a program by what the file IS, so a fixture interpreter has to be a
-- real NATIVE binary named node. The platform's own /usr/bin/env is ELF and is copied once per scratch
-- home: a shell script called node-fixture is exactly what the allow-list refuses.
local function native_copy(path)
  local source = host.getenv('WA_NATIVE_FIXTURE')
  if not source or source == '' then
    for _, candidate in ipairs({ '/usr/bin/env', '/bin/env', '/usr/bin/true', '/bin/true' }) do
      local facts = host.file_magic and host.file_magic(candidate)
      if facts and (dofile('lua/vendor/json.lua').decode(facts).magic or '') == 'elf' then source = candidate break end
    end
  end
  assert(source, 'a native binary to copy for the interpreter fixture')
  local parent = path:match('^(.*)/[^/]+$')
  if parent and host.path_kind(parent) ~= 'dir' then host.exec('mkdir -p ' .. parent, nil, 20) end
  host.exec('cp ' .. source .. ' ' .. path, nil, 20)
  assert(host.path_kind(path) == 'file', 'a native fixture at ' .. path)
  return path
end
local node_fixture = native_copy(dir .. '/bin/node')
host.getenv = function(name)
  if name == 'WA_MCP_SCRIPT_DIR' then return dir end
  if name == 'WA_NODE' then return node_fixture end
  return real_getenv(name)
end
local connector = dir .. '/conn.mjs'
assert(host.write_file(connector, 'export const run = 1;\n'))

local definition = { id = 'shape', name = 'Shape', transport = 'stdio', program = '/usr/bin/node',
  args = { connector }, cwd = '/tmp', env = { MAIL_USER = 'MAIL_USER' }, tools = { echo = 'write' },
  vault_env = { FIXTURE_TOKEN = 'fixture_token' }, timeout_seconds = 5 }
local probe_row = { ok = true, schema_hash = 'fixture',
  tools = { { name = 'echo', description = 'echo', input_schema_json = '{"type":"object"}' } } }
local store = { schema = 1, revision = 1, servers = { shape = { definition = definition, enabled = false,
  vault_approved = false, revision = 1, probe = probe_row } } }
assert(json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
  json.encode({ 'mcp.extensions.v1', json.encode(store) }))).ok)

-- The operator's own "on" is the approval; then the call is captured instead of launched.
local enabled = mcp.control({ action = 'enable', id = 'shape', expected_revision = 1 },
  { role = 'master', operator = true, session_id = 'op' })
local real_operation = host.operation
local start
host.operation = function(action, payload)
  if action == 'start' then start = json.decode(payload); return json.encode({ error = 'fixture_stop' }) end
  return real_operation(action, payload)
end
local answer = mcp.call(mcp.namespace('shape', 'echo'), {}, { session_id = 'model' })
host.operation = real_operation
host.getenv = real_getenv

local request_path = start and start.args and start.args[3]
local request = request_path and json.decode(host.read_file(request_path))
check(enabled.ok == true, 'the operator enable recorded an approval: ' .. json.encode(enabled))
check(request ~= nil, 'the launch names a request file that exists: ' .. tostring(request_path))
check(answer.error == 'mcp_operation_not_started', 'the call reached the launch (the stub refused it): ' .. json.encode(answer))
local approval = start.vault_approval or {}
check(start.vault_env and start.vault_env.FIXTURE_TOKEN == 'fixture_token', 'the kernel is handed the ENTRY NAME, never the value')
check(approval.form == mcp.APPROVAL_FORM, 'the approval names the form it was recorded in: ' .. tostring(approval.form))
check(request.server.program == approval.program, 'server.program is the approved program')
check(json.encode(request.server.args) == json.encode(approval.args), 'server.args are the approved arguments')
check(tostring(request.server.cwd or '') == tostring(approval.cwd or ''), 'server.cwd is the approved cwd')
check(request.server.vault_env ~= nil, 'the request still carries the vault NAMES for the console side')

-- operations.rs (request_server_problem): the environment the child hands the server must be the
-- definition's own references plus one self-reference per vault name the kernel injects.
local expected = {}
for _, entry in ipairs(approval.env or {}) do expected[entry.name] = entry.ref end
for _, name in ipairs(approval.vault or {}) do expected[name] = name end
local observed, expected_count, observed_count = {}, 0, 0
for name, reference in pairs(request.server.env or {}) do observed[name] = reference; observed_count = observed_count + 1 end
for _ in pairs(expected) do expected_count = expected_count + 1 end
local same = observed_count == expected_count
for name, reference in pairs(expected) do if observed[name] ~= reference then same = false end end
check(same, 'server.env is the approved environment plus the vault self-references: ' .. json.encode(observed))
check(#(approval.files or {}) >= #mcp.RUNTIME + 1, 'and the file list it re-reads is the runtime plus the connector')

if failed > 0 then print(string.format('mcp request shape: %d failed of %d checks', failed, checks)) os.exit(1) end
print(string.format('mcp request shape ok (%d checks)', checks))
