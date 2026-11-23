-- read/ls/grep/write/edit take the same optional `node` `remote` takes (mission
-- tool-args-honest-and-same-on-peers, item 7).
--
-- The finding (worker notes 183 and 257): a path meant for a peer landed on the LOCAL node without a word -
-- one worker wrote a peer's file onto this machine, and the only evidence was the path it had typed. The
-- five file tools now route through THE SAME CALL `remote` makes, so a local call and a peer call cannot
-- drift apart, and every answer names the node the bytes landed on.
--
-- TWO SCRATCH NODES IN ONE PROCESS, never the real fleet: the transport (`nodes.find` / `nodes.remote_call`)
-- is the seam `tools.remote` uses, and it records what crossed it. What this does NOT prove, and the report
-- says so: the relay, the peer's signature, and two machines - the peer's files here are this filesystem.
--
-- Each of these fails on 86399e56\^:
--   * write/edit/read/ls/grep with a peer name reach that peer's capability with the arguments intact and
--     `node` stripped (on the base the write lands HERE and the answer says nothing about a node);
--   * a name that is THIS node runs the call here, as a local call with this session's context;
--   * a call that already arrived from a peer is refused by name, never forwarded a second hop;
--   * every one of the five declares `node` in its schema, so a model can read the field.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
-- One module instance for this script and tools.lua, so the transport stand-in below is the one it calls.
local original_dofile = dofile
local nodes = original_dofile('lua/core/nodes.lua')
dofile = function(path) if path == 'lua/core/nodes.lua' then return nodes end return original_dofile(path) end
local memory = original_dofile('lua/core/memory.lua'); memory.setup()
local tools = original_dofile('lua/core/tools.lua')
dofile = original_dofile
host.http = function() error('network forbidden in this fixture') end
host.http_stream = host.http

local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end
local home = host.paths().home
local HERE, PEER = 'fixture-here', 'fixture-peer'
local sent = {}
nodes.find = function(name)
  if name == HERE then return { name = HERE, node_id = HERE, local_node = true, online = true } end
  if name == PEER then return { name = PEER, node_id = PEER, online = true } end
  return nil
end
nodes.operator_status = function() return { operator_of_peer = true } end
nodes.remote_call = function(node, capability, args)
  sent[#sent + 1] = { node = tostring(node and node.name or node), capability = capability, args = args }
  return { ok = true, node = PEER, capability = capability, path = type(args) == 'table' and args.path or nil }
end
nodes.node_name = function() return HERE end

local ctx = { user_id = 'master', session_id = 'fixture-session' }
local function call(name, args) return tools.dispatch(memory, name, args, 'master', ctx) end

-- 1. Each file tool with a peer name crosses to that peer, with the arguments intact and no `node`.
local cases = {
  { 'write', { path = '/peer/one.txt', content = 'hello', node = PEER } },
  { 'edit', { path = '/peer/one.txt', node = PEER, edits = { { old_text = 'a', new_text = 'b' } } } },
  { 'read', { path = '/peer/one.txt', node = PEER } },
  { 'ls', { path = '/peer', node = PEER } },
  { 'grep', { path = '/peer', pattern = 'hello', context = 1, node = PEER } },
}
for _, case in ipairs(cases) do
  local name, args = case[1], case[2]
  sent = {}
  local answer = call(name, args)
  local crossed = sent[1]
  check(crossed ~= nil and crossed.capability == name,
    name .. ' with node=' .. PEER .. ' runs there (sent: ' .. json.encode(crossed or {}):sub(1, 160) .. ')')
  check(crossed ~= nil and crossed.args ~= nil and crossed.args.node == nil,
    name .. ' strips node from the arguments it sends: ' .. json.encode(crossed and crossed.args or {}):sub(1, 160))
  -- Every argument the caller gave arrives with the same value. A field the RUNTIME adds on the way out is
  -- allowed and must be one the validator already names (a read asks for the picture's bytes, for example),
  -- so this cannot quietly pass on a field the caller never sent and nothing declares.
  local validator = dofile('lua/core/tool_arguments.lua')
  local intact, extra = true, nil
  for key, value in pairs(args) do
    if key ~= 'node' and json.encode(crossed and crossed.args[key]) ~= json.encode(value) then intact = false end
  end
  for key in pairs(crossed and crossed.args or {}) do
    if key ~= 'node' and args[key] == nil and validator.INTERNAL[key] == nil then extra = tostring(key) end
  end
  check(intact, name .. ' sends every other argument unchanged: ' .. json.encode(crossed and crossed.args or {}):sub(1, 160))
  check(extra == nil, name .. ' adds only a runtime field the validator names (got: ' .. tostring(extra) .. ')')
  check(type(answer) == 'table' and answer.node == PEER,
    name .. ' answers with the node the call ran on: ' .. json.encode(answer):sub(1, 160))
end

-- 2. A name that is THIS node runs the call here, with this session's context - no hop.
sent = {}
local local_write = call('write', { path = home .. '/landed-here.txt', content = 'here', node = HERE })
check(#sent == 0, 'node=this node makes no remote call')
check(local_write.ok == true and host.read_file(home .. '/landed-here.txt') == 'here',
  'node=this node writes here: ' .. json.encode(local_write):sub(1, 160))
check(local_write.node == HERE, 'and the answer names this node: ' .. tostring(local_write.node))

-- 3. A call that already arrived from a peer is answered here or refused here, never forwarded again.
local forwarded = tools.dispatch(memory, 'write', { path = '/peer/two.txt', content = 'x', node = PEER },
  'master', { user_id = 'master', peer_call = true, session_id = 'peer:fixture' })
check(type(forwarded) == 'table' and forwarded.error == 'node_not_forwarded', 'a peer call is not forwarded again: ' .. json.encode(forwarded):sub(1, 200))
check(forwarded.effect == 'none', 'and it has no effect')
local history = tools.dispatch(memory, 'sessions', { node = PEER }, 'master',
  { user_id = 'master', peer_call = true })
check(history.error == 'history_node_not_forwarded', 'history keeps its own refusal: ' .. json.encode(history):sub(1, 160))

-- 4. Every one of the five declares `node`, so the field is in what the model reads.
for _, name in ipairs({ 'read', 'ls', 'grep', 'write', 'edit' }) do
  local parameters = tools.parameters(name, 'master') or {}
  check((parameters.properties or {}).node ~= nil, name .. ' declares node in its schema')
end

print(('file tool node: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
