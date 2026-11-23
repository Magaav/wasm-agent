-- MIXED FLEET: a field this node added is confirmed on the peer's own catalogue before the call leaves
-- (mission tool-args-honest-and-same-on-peers, follow-up).
--
-- Until the mission's build is rolled out, peers run a build that IGNORES an argument it does not know.
-- Sending `stdin` or `context` there would be the silent drop the mission closed on this node, one hop
-- out - so `tools.remote` asks the cached peer catalogue first and refuses LOCALLY (effect none) with the
-- field and the peer's version when the answer is not yes. Unknown is not yes: a peer whose catalogue
-- says nothing about the tool is refused too, never assumed.
--
-- Two scratch peers in one process, never the fleet: `nodes.list` / `nodes.remote_call` are stubs, and the
-- catalogue they answer is the real shape `federation.refresh` caches.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local original_dofile = dofile
local json = original_dofile('lua/vendor/json.lua')
local memory = original_dofile('lua/core/memory.lua'); memory.setup()
-- ONE nodes instance for this script, tools.lua and federation.lua, so the transport stand-in below is the
-- one they call (the pattern scripts/test-remote-edit.lua uses).
local nodes = original_dofile('lua/core/nodes.lua')
local tools, federation
local function with_stub_nodes(fn)
  dofile = function(path)
    if path == 'lua/core/nodes.lua' then return nodes end
    return original_dofile(path)
  end
  local ok, value = pcall(fn)
  dofile = original_dofile
  if not ok then error(value) end
  return value
end
host.http = function() error('network forbidden in this fixture') end
host.http_stream = host.http
local checks, failed = 0, 0
local function check(ok, label) checks = checks + 1; if not ok then failed = failed + 1; print('FAIL ' .. label) end end

local OLD, NEW = 'fixture-old', 'fixture-new'
local catalogues = {
  [OLD] = { version = '0.1.1', tools = {
    { name = 'bash', description = 'Run a command', parameters = { type = 'object', properties = { command = { type = 'string' }, cwd = { type = 'string' } } } },
    { name = 'grep', description = 'Find text', parameters = { type = 'object', properties = { pattern = { type = 'string' }, path = { type = 'string' } } } },
    { name = 'read', description = 'Read a file', parameters = { type = 'object', properties = { path = { type = 'string' } } } } } },
  [NEW] = { version = '0.1.2', tools = {
    { name = 'bash', description = 'Run a command', parameters = { type = 'object', properties = { command = { type = 'string' }, cwd = { type = 'string' }, stdin = { type = 'string' } } } },
    { name = 'grep', description = 'Find text', parameters = { type = 'object', properties = { pattern = { type = 'string' }, path = { type = 'string' }, context = { type = 'integer' } } } } } },
}
nodes.list = function() return {
  { node_id = OLD, name = OLD, online = true },
  { node_id = NEW, name = NEW, online = true } } end
nodes.find = function(sel)
  if sel == OLD then return { node_id = OLD, name = OLD, online = true } end
  if sel == NEW then return { node_id = NEW, name = NEW, online = true } end
  return nil
end
nodes.operator_status = function() return { operator_of_peer = true } end
-- The refresh asks reachability before it asks for a catalogue; a stub peer with no endpoints would be
-- culled there and its catalogue never asked (measured: the entry then carried no tools at all).
nodes.reachable = function() return true end
local sent = {}
nodes.remote_call = function(id, capability, args)
  if capability == 'federation' and type(args) == 'table' and args.action == 'catalog' then
    local catalogue = catalogues[id] or { version = '0.1.1', tools = {} }
    return { ok = true, tools = catalogue.tools, version = catalogue.version }
  end
  sent[#sent + 1] = { id = tostring(id), capability = capability, args = args }
  return { ok = true, node = tostring(id), capability = capability }
end
with_stub_nodes(function()
  tools = original_dofile('lua/core/tools.lua')
  federation = original_dofile('lua/core/federation.lua')
  -- The refresh reads `nodes` through its own dofile: the stub has to still be installed while it runs, or
  -- it asks the real roster and caches nothing (measured: both peers then looked unknown).
  federation.refresh()
end)
local ctx = { user_id = 'master' }
local function call(name, args) return tools.dispatch(memory, name, args, 'master', ctx) end

-- 1. A peer whose catalogue lacks the field gets the refusal, and NOTHING is sent to it.
sent = {}
local old_stdin = call('remote', { node = OLD, capability = 'bash', command = 'cat', stdin = 'hello' })
check(old_stdin.error == 'peer_field_unsupported', 'a field the peer does not declare is refused locally: ' .. json.encode(old_stdin):sub(1, 300))
check(old_stdin.effect == 'none', 'and nothing happened: ' .. tostring(old_stdin.effect))
check(old_stdin.field == 'stdin' and old_stdin.peer == OLD, 'the refusal names the field and the peer')
check(tostring(old_stdin.message):find('without stdin', 1, true) ~= nil and tostring(old_stdin.message):find('0.1.1', 1, true) ~= nil,
  'and says which build: ' .. tostring(old_stdin.message))
check(#sent == 0, 'no call reached the peer: ' .. json.encode(sent):sub(1, 200))

sent = {}
local old_context = call('remote', { node = OLD, capability = 'grep', pattern = 'x', path = '/r', context = 2 })
check(old_context.error == 'peer_field_unsupported' and old_context.field == 'context', 'grep context is refused the same way: ' .. json.encode(old_context):sub(1, 260))
check(#sent == 0, 'and nothing was sent for it')

-- 2. A peer that DECLARES them gets the call, field and all.
sent = {}
local new_stdin = call('remote', { node = NEW, capability = 'bash', command = 'cat', stdin = 'hello' })
check(new_stdin.error == nil, 'a peer that declares the field is called: ' .. json.encode(new_stdin):sub(1, 200))
check(#sent == 1 and sent[1].capability == 'bash' and sent[1].args.stdin == 'hello',
  'and the field travelled: ' .. json.encode(sent):sub(1, 240))
sent = {}
local new_context = call('remote', { node = NEW, capability = 'grep', pattern = 'x', context = 2 })
check(new_context.error == nil and #sent == 1 and sent[1].args.context == 2, 'grep context travels to a peer that declares it: ' .. json.encode(sent):sub(1, 240))

-- 3. A capability that carries none of these fields is untouched, and an unknown peer is not assumed.
sent = {}
local plain = call('remote', { node = OLD, capability = 'bash', command = 'ls' })
check(plain.error == nil and #sent == 1, 'a call without the new fields is unchanged: ' .. json.encode(plain):sub(1, 200))
sent = {}
local nowhere = call('remote', { node = 'fixture-not-cached', capability = 'bash', command = 'cat', stdin = 'x' })
check(nowhere.error == 'unknown_node:fixture-not-cached', 'an unknown node is still the unknown-node refusal: ' .. tostring(nowhere.error))
check(#sent == 0, 'and nothing was sent')

print(('remote field support: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
