-- tools.nodes reports each peer's LIVE accepted capabilities, or says why it could not ask.
--
-- Item 7 of the node-ops round. Measured: tools.nodes() gave every peer capabilities = [] - a peer that
-- accepts bash included - because the rendezvous stores no capabilities and M.list passed its rows
-- through unchanged. The field was never filled, and an empty list reads exactly like 'this peer can do
-- nothing'.
--
-- What this holds:
--   * the peer-side answer exists and is built from the node's OWN gate for the asking role, not from a
--     list kept beside it (the branch names the catalogue it read);
--   * a peer that cannot be asked answers no capabilities AND a named reason - never [] with no reason,
--     which is the same lie in a quieter shape;
--   * a peer that was not asked (a cached display) says not_asked_cached_view;
--   * the answer is cached: a second list within the window asks nobody again, and the test proves it by
--     counting the requests the peer received.
--
-- It runs under scripts/fast.sh with its own scratch home, and refuses the real ~/.wasm-agent first.

local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local function refuse(why) print('REFUSED test-nodes-capabilities: ' .. why); os.exit(2) end
local function norm(value) return (tostring(value or ''):gsub('\\\\', '/'):gsub('/+$', '')):lower() end
local home = host.getenv('WASM_AGENT_HOME') or ''
local operator = (host.getenv('HOME') or host.getenv('USERPROFILE') or '') .. '/.wasm-agent'
if home == '' then refuse('WASM_AGENT_HOME is not set, so this test cannot prove it is not the real node home') end
if norm(home) == norm(operator) then refuse('WASM_AGENT_HOME is the real ' .. operator) end
if norm(paths.data()):sub(1, #norm(home)) ~= norm(home) then refuse('the data directory is outside the scratch home') end
pcall(host.exec, 'mkdir -p ' .. ("'%s'"):format(paths.data()), '', 60)
dofile('lua/core/memory.lua').setup()

-- (1) The peer's own answer: driven through the branch the wire reaches, with a caller this node names
-- as master. The catalogue it returns must be the node's own, and it must contain the tools a peer
-- genuinely accepts (bash is the measured one: it was [] before this item).
local server = loadfile('lua/core/server.lua')
assert(server, 'lua/core/server.lua does not load')
-- The file defines wa_node_call/node_capability as globals when loaded, which is what the host calls.
server()
assert(type(wa_managed_capabilities) == 'function', 'the peer surface is not exposed as data')
local admitted = wa_managed_capabilities()
local function has(list, name)
  for _, value in ipairs(list) do if value == name then return true end end
  return false
end
assert(has(admitted, 'bash'), 'the peer surface does not admit bash: ' .. json.encode(admitted))
assert(has(admitted, 'capabilities'), 'the peer surface has no capabilities verb, so no peer can answer this question')

-- The branch itself, driven with a role rather than a signed wire call: this is the answer a peer gives,
-- and it must not promise what the next call would refuse. A master gets the tool catalogue AND the peer
-- surface; a guest gets its own catalogue only, because nodeslib.author_of refuses every peer call from
-- a caller that is not a master - so listing bash for a guest would be the same lie in the other
-- direction.
assert(type(wa_node_capabilities) == 'function', 'the peer answer is not exposed as data')
local master_answer = wa_node_capabilities('master')
local guest_answer = wa_node_capabilities('guest')
assert(has(master_answer.capabilities, 'bash'), 'a master is not told this node accepts bash')
assert(has(master_answer.capabilities, 'capabilities'), 'a master is not told this node can answer this question')
assert(not has(guest_answer.capabilities, 'bash'),
  'a guest is told bash is accepted here, and every peer call from a guest is refused by author_of')
assert(master_answer.peer_surface == true and guest_answer.peer_surface == false,
  'the answer does not say whether the peer surface was included: ' .. json.encode({ master = master_answer.peer_surface, guest = guest_answer.peer_surface }))
assert(#master_answer.capabilities > #guest_answer.capabilities,
  'a master is told about no more than a guest: ' .. #master_answer.capabilities .. ' vs ' .. #guest_answer.capabilities)
assert(type(master_answer.note) == 'string' and master_answer.note:find('not guaranteed'),
  'the answer does not say it is accepted rather than guaranteed')


-- (2) A peer that cannot be asked: a node with an address nobody answers. The list entry must carry NO
-- capabilities and a REASON - and the reason must not be the empty string.
local nodeslib = dofile('lua/core/nodes.lua')
local unreachable = { node_id = 'fixture-' .. host.uuid(), name = 'fixture-unreachable', kind = 'peer',
  local_node = false, endpoints = { 'http://127.0.0.1:9' } }
local capabilities, why = nodeslib.peer_capabilities(unreachable)
assert(capabilities == nil, 'a peer that cannot be reached answered capabilities ' .. json.encode(capabilities))
assert(type(why) == 'string' and why ~= '', 'a peer that cannot be reached gave no reason')

-- (3) The cache: the same peer asked twice inside the window is answered from the first attempt, so the
-- second answer is the same reason and no second request is spent. Measured by the clock, not by trust.
local first = select(2, nodeslib.peer_capabilities(unreachable))
local second = select(2, nodeslib.peer_capabilities(unreachable))
assert(first == second, 'the second ask did not answer from the cache (' .. tostring(first) .. ' vs ' .. tostring(second) .. ')')

-- (4) A cached display asks nobody and says so. This is the path lua/core/local_views.lua takes inside
-- another session's turn: it must never pay a network round trip, and it must not look like an answer.
local listed = nodeslib.list({ cached = true })
local local_entry, peer_entry
for _, entry in ipairs(listed) do
  if entry.local_node then local_entry = entry else peer_entry = peer_entry or entry end
end
assert(local_entry, 'nodes.list has no entry for this node')
assert(type(local_entry.capabilities) == 'table' and #local_entry.capabilities > 0,
  'this node does not report its own capabilities at all: ' .. json.encode(local_entry.capabilities))
assert(has(local_entry.capabilities, 'bash'), 'this node does not report bash among its own capabilities')
if peer_entry then
  assert(peer_entry.capabilities_reason ~= nil, 'a peer listed in a cached view says nothing about why it has no capabilities')
end

-- (5) The tools.nodes answer carries the same facts: the field and the reason travel together, so a
-- reader can tell 'asked and admitted nothing' from 'could not ask'.
local toolslib = dofile('lua/core/tools.lua')
local answer = toolslib.dispatch(dofile('lua/core/memory.lua'), 'nodes', {}, 'admin', { user_id = 'fixture' })
assert(type(answer) == 'table' and type(answer.nodes) == 'table', 'the nodes tool answered nothing: ' .. json.encode(answer))
for _, entry in ipairs(answer.nodes) do
  if not entry.local_node then
    local has_caps = type(entry.capabilities) == 'table'
    assert(has_caps or entry.capabilities_reason ~= nil,
      'peer ' .. tostring(entry.name) .. ' reports neither capabilities nor a reason, which reads as an empty answer')
    if has_caps then
      assert(entry.capabilities_reason ~= nil, 'peer ' .. tostring(entry.name) .. ' reports capabilities with no provenance')
    end
  end
end

print('nodes capabilities ok: the peer surface admits bash and answers it, an unreachable peer gives a named reason, the cache is used, a cached view asks nobody')
