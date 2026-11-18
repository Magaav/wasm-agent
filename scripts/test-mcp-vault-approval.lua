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
  cwd = '/home/agent/work tree',
  env = { { name = 'MAIL_USER', ref = 'MAIL_USER' }, { name = 'LANG', ref = 'LC_ALL' } },
  args = { '/home/agent/scripts/fixture.mjs', '--token', 'a b' },
  files = { { path = '/home/agent/scripts/fixture.mjs', sha256 = string.rep('aa', 32) },
            { path = '/home/agent/scripts/lib/other.mjs', sha256 = string.rep('bb', 32) } },
  vault = { 'FIXTURE_TOKEN', 'SECOND_ONE' },
}
local text = mcp.vault_approval_text(fixture)
ok(has(text, 'mcp-vault-approval/v3\nprogram /usr/bin/node\n'), 'the canonical text names its version and program')
ok(has(text, '\narg a%20b\n'), 'a space inside an argument is escaped, not a separator: ' .. text)
eq(host.sha256(text), 'f45cc25f36c7315cbccfc17c5c1e37b5a9e99f02dff27911130bf5e80b5b8aec',
  'the digest the Rust side pins for the same fixture')
-- v2 added two fields to that digest - the directory the launch runs in and the plain (non-vault)
-- environment it asks for, sorted by name so a caller's table order cannot change it - and v3 (round 6)
-- adds the interpreter the launch spawns and the arguments resolved from the connector's own directory.
ok(has(text, 'cwd /home/agent/work%20tree'), 'the cwd is in it, escaped like every field: ' .. text)
ok(has(text, 'env LANG=LC_ALL') and has(text, 'env MAIL_USER=MAIL_USER'), 'and the plain environment')
-- The same directory or environment in another form is another digest: a moved connector, or one that
-- now asks for another variable, is not the launch the operator approved.
local moved_cwd = { program = fixture.program, cwd = '/tmp', env = fixture.env, args = fixture.args,
  files = fixture.files, vault = fixture.vault }
ok(host.sha256(mcp.vault_approval_text(moved_cwd)) ~= host.sha256(text), 'another cwd is another digest')
local moved_env = { program = fixture.program, cwd = fixture.cwd, env = { { name = 'PROXY', ref = 'PROXY' } },
  args = fixture.args, files = fixture.files, vault = fixture.vault }
ok(host.sha256(mcp.vault_approval_text(moved_env)) ~= host.sha256(text), 'another environment is another digest')

-- A newline (or a tab) in a field cannot forge a line of the digest.
ok(not has(mcp.vault_approval_text({ program = '/bin/sh', args = { 'a\nb' }, files = {}, vault = {} }),
  '\narg a\nb\n'), 'a newline in an argument is escaped rather than forging a line')

-- ---- 2. the digest covers every script the connector runs ------------------------------------
-- A directory this test owns, made the runtime the node resolves (WA_MCP_SCRIPT_DIR), so nothing here
-- writes into the node's install or into this checkout.
local real_getenv = host.getenv
local dir = paths.data() .. '/mcp/vault-approval-' .. tostring(host.uuid()):sub(1, 8)
local node_override = dir .. '/node-fixture'
host.getenv = function(name)
  if name == 'WA_MCP_SCRIPT_DIR' then return dir end
  if name == 'WA_NODE' then return node_override end
  return real_getenv(name)
end
for _, name in ipairs(mcp.RUNTIME) do
  -- The client core really does import child_process (it spawns the connector the approval names), which
  -- is why the exemption below is about IT and not about any file: the stub carries the import so the
  -- exemption is proved rather than assumed.
  local body = name == 'mcp-client-core.mjs'
    and "import { spawn } from 'node:child_process';\nexport const stub = 1;\n"
    or '// runtime stub: ' .. name .. '\n'
  assert(host.write_file(dir .. '/' .. name, body), 'a runtime stub: ' .. name)
end
local connector = dir .. '/connector.mjs'
assert(host.write_file(connector, 'export const run = 1;\n'), 'the connector script')
assert(host.write_file(dir .. '/node-fixture', '#!/bin/sh\nexit 0\n'), 'the interpreter fixture')
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

-- ---- 4b. the code a connector can load: what the digest covers, and what is refused along with it --
-- (Round 5's second hole.) "Every script file the connector runs" was not true: only an absolute argument
-- with a script extension was hashed, so a relative conn.mjs (resolved from the connector's cwd), an
-- extensionless program (~/bin/conn), a package runner (npx) and every imported module were code the
-- approval never named. M.vault_manifest now follows what each file loads and names what it cannot
-- follow; a connector with any such problem is REFUSED rather than approved with a digest that reads as
-- complete.
local function covers(manifest, path)
  for _, file in ipairs(manifest.files or {}) do if file.path == path then return true end end
  return false
end
local function manifest_of(candidate) return mcp.vault_manifest(candidate, mcp.script_dir()) end
local function problems_text(manifest) return table.concat(manifest.problems or {}, ' | ') end

-- An import is followed: the module beside the script is hashed too.
local lib = dir .. '/lib/extra.mjs'
assert(host.write_file(lib, 'export const value = 2;\n'), 'an imported module')
assert(host.write_file(connector, 'import { value } from "./lib/extra.mjs";\nexport const run = value;\n'), 'an importing script')
local closed = manifest_of(definition)
eq(#closed.problems, 0, 'a self-contained connector is covered: ' .. problems_text(closed))
ok(covers(closed, connector) and covers(closed, lib), 'the module it imports is in the digest, not only the entry script')

-- An extensionless program is code too: "node conn" runs it whatever it is called, and its shebang says
-- which scanner follows it.
local bare = dir .. '/bare-conn'
assert(host.write_file(bare, '#!/usr/bin/env node\nimport { value } from "./lib/extra.mjs";\n'), 'an extensionless program')
local bare_manifest = manifest_of({ program = bare, args = { '--mode', 'stdio' }, vault_env = definition.vault_env })
eq(#bare_manifest.problems, 0, 'an extensionless program is hashed and followed: ' .. problems_text(bare_manifest))
ok(covers(bare_manifest, bare) and covers(bare_manifest, lib), 'the shebang program and its import are both covered')

-- Each of these is refused BY NAME: a digest over an incomplete file list reads as an approval.
local function refuses(tweak, needle, label)
  local candidate = {}
  for key, value in pairs(definition) do candidate[key] = value end
  for key, value in pairs(tweak) do candidate[key] = value end
  local manifest = manifest_of(candidate)
  ok(#manifest.problems > 0 and has(problems_text(manifest), needle), label .. ': ' .. problems_text(manifest))
end
assert(host.write_file(dir .. '/pkg.mjs', 'import left from "left-pad";\nexport default left;\n'), 'a bare import')
assert(host.write_file(dir .. '/computed.mjs', 'export const load = (name) => import(name);\n'), 'a computed import')
assert(host.write_file(dir .. '/machine.py', 'import os\nprint(os.environ)\n'), 'a python script')
refuses({ args = { 'conn.mjs' } }, 'resolved from its own directory', 'a relative script is refused')
refuses({ program = 'node' }, 'not an absolute path', 'a bare program name is refused')
refuses({ program = 'npx' }, 'package runner', 'a package runner is refused')
refuses({ args = { dir .. '/pkg.mjs' } }, 'imports a package', 'an import from node_modules is refused')
refuses({ args = { dir .. '/computed.mjs' } }, 'computed name', 'an import by a computed name is refused')
refuses({ args = { dir .. '/machine.py' } }, 'cannot follow', 'a language whose modules cannot be followed is refused')

-- The operator's own act is where this must refuse: no approval is recorded for a connector whose code
-- cannot be closed, and the row keeps saying so.
local uncovered = { id = 'vault-uncovered', name = 'Uncovered', transport = 'stdio', program = 'npx',
  args = { connector }, tools = { echo = 'write' }, vault_env = { FIXTURE_TOKEN = 'fixture_token' }, timeout_seconds = 5 }
assert(json.decode(host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
  json.encode({ STORE, json.encode({ schema = 1, revision = 1, servers = { ['vault-uncovered'] = {
    definition = uncovered, enabled = false, vault_approved = false, revision = 1, probe = probe } } }) }))).ok,
  'the uncovered row is written')
local refused = mcp.control({ action = 'enable', id = 'vault-uncovered', expected_revision = 1 },
  { role = 'master', operator = true, session_id = 'op' })
eq(refused.error, 'mcp_vault_code_not_covered', "the operator's own on refuses it: " .. json.encode(refused))
eq(refused.tool_call_issued, false, 'and nothing was issued')
ok(type(refused.problems) == 'table' and #refused.problems > 0 and has(refused.note, 'package runner'),
  'the refusal names what is not covered: ' .. tostring(refused.note))
local uncovered_row = json.decode(json.decode(host.sql_query('SELECT value FROM meta WHERE key=?',
  json.encode({ STORE })))[1].value).servers['vault-uncovered']
eq(uncovered_row.vault_approved, false, 'and the row stays unapproved')
ok(uncovered_row.vault_approval == nil, 'with no digest recorded at all')

-- An approval in the form before cwd/env/closure cannot be compared with this one: it is refused by name,
-- and the operator gives it again.
seed({ definition = definition, enabled = true, vault_approved = true, revision = 1, probe = probe,
  vault_approval = { sha256 = manifest.sha256 } })
local old_form = mcp.call(name, {}, { session_id = 'model' })
eq(old_form.error, 'mcp_vault_approval_missing',
  'an approval from the form before v2 predates what it covers: ' .. json.encode(old_form))

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

-- ---- 6. round 6: the interpreter, the arguments, the ownership, and what a script runs ----------
-- Each of these reads M.vault_manifest directly - the one function the approval, the gate and the
-- operator's probe all go through - so a regression is a problem in the digest, not a wording change.
local platform_module = dofile('lua/core/platform.lua')
local function manifest_of(def) return mcp.vault_manifest(def, mcp.script_dir()) end
local function problems_text(manifest) return table.concat(manifest.problems or {}, ' | ') end
local function covered_by(manifest)
  local map = {}
  for _, file in ipairs(manifest.files or {}) do map[file.path] = true end
  return map
end

-- 1. The INTERPRETER (finding 1). The process the vault values are put in is the interpreter the launch
-- SPAWNS - node_program(), i.e. WA_NODE and then the provisioned copy - and it used to be neither hashed
-- nor out of the agent's reach. A file this user owns is a file the digest names.
local user_node = dir .. '/node-fixture'
assert(host.write_file(user_node, '#!/bin/sh\nexit 0\n'), 'the interpreter fixture')
node_override = user_node
local with_interpreter = manifest_of(definition)
ok(covered_by(with_interpreter)[user_node] == true,
  'the interpreter the launch spawns is a file the digest names: ' .. problems_text(with_interpreter))
-- Another interpreter is another digest: WA_NODE pointing somewhere else is not the approved launch.
local other_node = dir .. '/node-other'
assert(host.write_file(other_node, '#!/bin/sh\nexit 0\n'))
node_override = other_node
local other_digest = manifest_of(definition).sha256
node_override = user_node
ok(other_digest ~= with_interpreter.sha256, 'another interpreter is another digest')
-- 2. OWNERSHIP, not a prefix (finding 5): /usr/local/bin and /opt/homebrew belong to the user on macOS,
-- so a path under a platform root is the platform's only when it is root-owned and nobody else can write
-- it - the host's own metadata answers, not a list of names.
if platform_module.os() ~= 'windows' then
  eq(mcp.platform_owned('/usr/bin/env'), true, 'a root-owned system program is the platform\'s own')
  eq(mcp.platform_owned(user_node), false, 'a file this user owns is not, whatever the path looks like')
  eq(mcp.platform_owned(dir .. '/nope'), false, 'and a path that is not there is not the platform\'s')
end
-- An interpreter that is not there is refused by name rather than hashed as if it were.
node_override = dir .. '/no-such-node'
local missing_interpreter = manifest_of(definition)
ok(has(problems_text(missing_interpreter), 'interpreter cannot be read'),
  'an interpreter that is not there is refused: ' .. problems_text(missing_interpreter))
node_override = user_node
-- 3. ARGUMENTS (finding 2): program /usr/bin/node, args {server}, cwd <conn> ran ./server.js unhashed.
local conn_dir = dir .. '/conn'
local server_js = conn_dir .. '/server.js'
assert(host.write_file(server_js, 'export const run = 1;\n'), 'the script a bare word names')
local function with_args(args, cwd)
  return { id = 'vault-args', name = 'Args', transport = 'stdio', program = '/usr/bin/node', args = args,
    cwd = cwd, tools = { echo = 'write' }, vault_env = { FIXTURE_TOKEN = 'fixture_token' }, timeout_seconds = 5 }
end
local bare_manifest = manifest_of(with_args({ 'server' }, conn_dir))
ok(covered_by(bare_manifest)[server_js] == true,
  'a bare argument is resolved from the connector\'s own directory and hashed: ' .. problems_text(bare_manifest))
local no_cwd_manifest = manifest_of(with_args({ 'server' }, nil))
ok(has(problems_text(no_cwd_manifest), 'may name a file this digest cannot resolve'),
  'the same argument with no directory to resolve it from is refused: ' .. problems_text(no_cwd_manifest))
local inline_manifest = manifest_of(with_args({ '-e', 'console.log(process.env.FIXTURE_TOKEN)' }, conn_dir))
ok(has(problems_text(inline_manifest), 'inline code'),
  'node -e is inline code no digest can name: ' .. problems_text(inline_manifest))
-- The value of an option is a value, not a file: a connector with --mode stdio is still approvable.
local option_manifest = manifest_of(with_args({ server_js, '--mode', 'stdio' }, conn_dir))
eq(#(option_manifest.problems or {}), 0, 'an option value is not a file: ' .. problems_text(option_manifest))
-- 4. WHAT A SCRIPT RUNS (finding 3): a wrapper that execs another script is FOLLOWED, an inline string is
-- REFUSED, and a connector that starts a process itself is refused - while the node's own runtime, which
-- does exactly that and is sealed by the request check, is not.
local inner = dir .. '/inner.sh'
local wrapper = dir .. '/wrapper.sh'
assert(host.write_file(inner, 'echo inner\n'))
assert(host.write_file(wrapper, '#!/bin/sh\nexec ' .. inner .. '\n'))
local function shell_definition(script, id)
  return { id = id or 'vault-shell', name = 'Shell', transport = 'stdio', program = '/bin/sh', args = { script },
    tools = { echo = 'write' }, vault_env = { FIXTURE_TOKEN = 'fixture_token' }, timeout_seconds = 5 }
end
local wrapper_manifest = manifest_of(shell_definition(wrapper, 'vault-wrapper'))
ok(covered_by(wrapper_manifest)[inner] == true,
  'a wrapper that execs another script is followed: ' .. problems_text(wrapper_manifest))
local inline_shell = dir .. '/inline.sh'
assert(host.write_file(inline_shell, '#!/bin/sh\nbash -c "echo $FIXTURE_TOKEN"\n'))
local inline_shell_manifest = manifest_of(shell_definition(inline_shell, 'vault-inline-sh'))
ok(has(problems_text(inline_shell_manifest), 'inline shell code'),
  'bash -c is refused: ' .. problems_text(inline_shell_manifest))
local computed_shell = dir .. '/computed.sh'
assert(host.write_file(computed_shell, '#!/bin/sh\nexec "$HOME/bin/server"\n'))
local computed_manifest = manifest_of(shell_definition(computed_shell, 'vault-computed'))
ok(has(problems_text(computed_manifest), 'execs a script chosen while it runs'),
  'an exec of a value is refused: ' .. problems_text(computed_manifest))
local spawner = dir .. '/spawner.mjs'
assert(host.write_file(spawner, "import { execSync } from 'node:child_process';\nexecSync('id');\n"))
local spawner_manifest = manifest_of(with_args({ spawner }, conn_dir))
ok(has(problems_text(spawner_manifest), 'child_process'),
  'a connector that starts a process itself is refused: ' .. problems_text(spawner_manifest))
ok(not has(problems_text(with_interpreter), 'child_process'),
  'the node\'s own runtime is not refused for spawning the connector: ' .. problems_text(with_interpreter))

host.getenv = real_getenv
host.operation = real_operation

if failed > 0 then print(string.format('mcp vault approval: %d failed of %d checks', failed, checks)) os.exit(1) end
print(string.format('mcp vault approval ok (%d checks)', checks))
