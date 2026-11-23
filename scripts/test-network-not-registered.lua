-- A NODE THAT NEVER REGISTERED IS TOLD SO, BY NAME.
--
-- Brief (23/11, scratch measurement): with only the PEER serving, every call attempt answered
-- roster_unavailable - 240 attempts over 120 s. The rendezvous answers GET /nodes only to a node it can
-- VERIFY, and it learns a node's key when that node registers (rust/wa-rendezvous, register()). So a node
-- that never serves cannot call anybody, and the answer it got named a network problem instead of its own
-- missing registration: the fix for one has nothing to do with the fix for the other.
--
-- This row pins the three answers, and that they stay distinct:
--   * 401 `unknown_node` on the roster read  -> not_registered, not retryable, with the fix line;
--   * a read that fails ANY other way (503, 401 bad_signature_key) -> roster_unavailable, retryable;
--   * a readable roster that omits the name    -> unknown_node, exactly as before.
-- Hermetic: a fake rendezvous over host.http; no network, no live node, no fleet.
local json = dofile('lua/vendor/json.lua')

-- ---- the scratch-home guard ----------------------------------------------------------------
-- The identity, name file and binding are read from the home; the roster cache is in this process. It
-- refuses to run against a real node's home: WASM_AGENT_HOME must be set and the data directory must
-- live under it (rule: every row that probes state creates its own scratch home).
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

local checks = 0
local function check(value, label) assert(value, label); checks = checks + 1 end

local clock = 1792000000
host.now = function() return clock end
-- BOTH knobs, and the mesh flag cleared, exactly as the other network rows do: the fast path and a
-- developer's shell export different values, and a row that only overrides one of them reads whatever
-- the runner happens to have.
host.getenv = (function(native)
  return function(key)
    if key == 'WASM_AGENT_RENDEZVOUS' or key == 'WASM_AGENT_RELAY' then return 'http://127.0.0.1:1' end
    if key == 'WA_MESH' or key == 'WA_MESH_COMPONENT' then return nil end
    return native(key)
  end
end)(host.getenv)
host.mesh_call = function(ask)
  local decoded_ok, question = pcall(json.decode, ask)
  if decoded_ok and type(question) == 'table' and question.gate then
    return json.encode({enabled = false})
  end
  return json.encode({error = 'mesh_disabled_for_test'})
end
-- No probe children: this row is about the roster read, it promises no network and no live node, and
-- nodes.list() fans out `wa nodes probe <peer>` as real children.
host.operation = function(action)
  return json.encode({ error = 'operation_disabled_for_test', action = action })
end

-- A rendezvous the test controls. Every answer below is a shape the SHIPPED rendezvous really sends
-- (rust/wa-rendezvous/src/rendezvous.rs, verify()/list()).
local answer = { status = 200, body = json.encode({ nodes = {} }) }
host.http = function(method, url)
  return json.encode(answer)
end

local nodes = dofile('lua/core/nodes.lua')

-- 1. The rendezvous holds no key for this node: 401 unknown_node on GET /nodes.
answer = { status = 401, body = json.encode({ error = 'unknown_node' }) }
local blind = nodes.remote_call('box', 'bash', { command = 'true' })
check(tostring(blind.error):find('^not_registered:box', 1) ~= nil,
  'an unregistered caller is told not_registered by name, got ' .. tostring(blind.error))
check(blind.connector == 'not_registered', 'and carries the connector code, got ' .. tostring(blind.connector))
check(blind.retryable == false, 'and says a retry cannot help: the registration is what is missing')
check((blind.message or ''):find('not registered', 1, true) ~= nil,
  'and the sentence says what is wrong, got ' .. tostring(blind.message))
check((blind.message or ''):find('Nothing was sent', 1, true) ~= nil,
  'and says nothing was sent, so nothing ran there')
check((blind.fix or ''):find('wa serve', 1, true) ~= nil,
  'and the fix names the one command that registers this node, got ' .. tostring(blind.fix))
check(nodes.not_registered() == true, 'and the module reports the missing registration')
check(nodes.roster_unreadable() == true, 'while the roster is still honestly unreadable')

-- 2. Any OTHER refusal of the roster read is not a missing registration: it stays the outage answer,
--    and it stays retryable. A key mismatch is the important one - the rendezvous KNOWS the id there.
for _, other in ipairs({ { status = 401, body = json.encode({ error = 'bad_signature_key' }) },
    { status = 503, body = '' }, { status = 500, body = json.encode({ error = 'internal' }) } }) do
  answer = other
  clock = clock + 60
  local refused = nodes.remote_call('box', 'bash', { command = 'true' })
  check(tostring(refused.error):find('^roster_unavailable:box', 1) ~= nil,
    'a ' .. tostring(other.status) .. ' refusing the READ is roster_unavailable, got ' .. tostring(refused.error))
  check(refused.retryable == true, 'and is worth retrying (status ' .. tostring(other.status) .. ')')
  check(nodes.not_registered() == false, 'and is never called a missing registration')
end

-- 3. Once the rendezvous answers, a name it does not list is unknown_node again - the older answer,
--    unchanged, so this row adds a case without moving the ones beside it.
answer = { status = 200, body = json.encode({ nodes = {} }) }
clock = clock + 60
local typo = nodes.remote_call('no-such-node', 'bash', { command = 'true' })
check(tostring(typo.error):find('^unknown_node:no%-such%-node', 1) ~= nil,
  'a readable roster that omits the name is still unknown_node, got ' .. tostring(typo.error))
check(nodes.not_registered() == false, 'and a successful read clears the missing registration')

print('network not registered ok (' .. checks .. ' checks)')
