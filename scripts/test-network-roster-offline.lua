-- A peer that is merely unreachable stays in the roster and is answered by name.
--
-- Brief (19/11 ~12:17 UTC, work node): after the laptop had internet again, 'wa nodes' listed only
-- itself and every 'wa call <peer>' answered unknown_node:<peer>. The cause is here: a failed roster
-- read fell through to the empty table it had initialised, so the cache was REPLACED by {}, and a
-- network blip became a fleet with no peers in it. Nothing but a restart brought them back.
-- This row pins the three behaviours the fix owes:
--   * a FAILED read keeps every peer it knew, marked offline with when it was last seen;
--   * a call to such a peer answers peer_offline:<name> (last seen ...), never unknown_node;
--   * a SUCCESSFUL read may still remove a peer - that is the rendezvous' own answer, not our guess.
-- Hermetic: a fake rendezvous over host.http; no network, no live node, no fleet.
local json = dofile('lua/vendor/json.lua')

-- ---- the scratch-home guard ----------------------------------------------------------------
-- The roster cache lives in this process, but the node's identity, name file and binding are read
-- from the home. It refuses to run against a real node's home: WASM_AGENT_HOME must be set and the
-- data directory must live under it.
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
-- BOTH knobs, and the mesh flag cleared, exactly as the other network rows do: under the fast path
-- WASM_AGENT_RELAY is empty and WA_MESH is unset, while a developer's shell has them set. A row that
-- only overrides the rendezvous reads whatever the runner happens to export, and it passed on this
-- machine and failed in the fast path for exactly that reason.
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

local identity = json.decode(host.node_identity())
local PEER = { node_id = string.rep('ab', 16), name = 'box', endpoints = {},
  public_key = identity.public_key, relay_attached = false, last_seen = clock }

-- A rendezvous the test controls: 'up' answers the roster, 'down' answers nothing usable.
local mode, reads = 'up', 0
host.http = function(method, url)
  reads = reads + 1
  if mode == 'up' then
    return json.encode({ status = 200, body = json.encode({ nodes = { PEER } }) })
  end
  -- What a dropped link looks like from here: no answer at all. The read must not be mistaken for
  -- "the rendezvous says there are no peers".
  return json.encode({ status = 503, body = '' })
end

-- NO PROBE CHILDREN. nodes.list() fans out a live capability probe: `wa nodes probe <peer>` as a real
-- child process. This row is about the ROSTER, and it promises no network and no live node, so the host
-- refuses to start any operation here. Before node-ops B that probe's await was refused by the host
-- (ownerless) and returned at once; once the await worked, every list() waited up to the probe deadline
-- on a child that, with this row's frozen clock, was joined again and again - the row hung 6 of 6 under
-- concurrency (bisected to 7c650dc8). Refusing the start keeps the roster path itself unchanged.
host.operation = function(action)
  return json.encode({ error = 'operation_disabled_for_test', action = action })
end
local nodes = dofile('lua/core/nodes.lua')
local function find(name)
  for _, node in ipairs(nodes.list()) do
    if node.name == name then return node end
  end
  return nil
end

-- 1. With the rendezvous up, the peer is known and online.
check(find('box') ~= nil, 'a live read lists the peer')
local live = find('box')
check(live.online ~= false, 'and does not mark it offline')

-- 2. The link drops, the cache expires, and the read fails: the peer must survive, offline.
-- NOTE: no nodes.invalidate() here. That call is the deliberate "forget everything" path (a rename
-- or a rebind), and an outage must never go through it. What an outage does is expire the 15 s cache
-- TTL, so the next list() really asks the rendezvous - and that read is the one that fails.
mode = 'down'
clock = clock + 60           -- past the cache TTL, so the next list() really reads
local after = find('box')
check(after ~= nil, 'a FAILED roster read does not erase the peers it already knew')
check(after.online == false, 'the kept peer is marked offline')
check(after.last_seen ~= nil, 'and carries when it was last seen')
check(after.roster_stale == true, 'and says the roster entry is stale, not freshly confirmed')

-- 3. A read that keeps failing keeps the peer: an outage is not a deletion, however long it lasts.
for _ = 1, 5 do
  clock = clock + 60
  check(find('box') ~= nil, 'the peer survives another failed read')
end

-- 4. A call to that peer answers peer_offline with the name and the last-seen stamp - NOT unknown_node.
local refused = nodes.remote_call('box', 'bash', { command = 'true' })
check(type(refused) == 'table' and tostring(refused.error):find('^peer_offline:box', 1) ~= nil,
  'a known but unreachable peer answers peer_offline:<name>, got ' .. tostring(refused.error))
check(tostring(refused.error):find('last seen', 1, true) ~= nil,
  'and the refusal says when it was last seen, got ' .. tostring(refused.error))
check(refused.retryable == true, 'an offline peer is worth retrying, unlike a node that never existed')
check((refused.message or ''):find('never removed from the roster', 1, true) ~= nil,
  'and the sentence says the peer was not deleted')

-- 5. A name the roster never knew answers by what the REGISTRY said, and the two cases differ:
--    while the reserve could not be read the answer is roster_unavailable (never a deletion), and once
--    it is readable a name it omits is unknown_node - which must not have become an "offline" peer.
local blind = nodes.remote_call('no-such-node', 'bash', { command = 'true' })
check(tostring(blind.error):find('^roster_unavailable:no%-such%-node', 1) ~= nil,
  'with the roster unreadable, an unseen name is roster_unavailable, got ' .. tostring(blind.error))
mode = 'up'
clock = clock + 60
local typo = nodes.remote_call('no-such-node', 'bash', { command = 'true' })
check(tostring(typo.error):find('^unknown_node:no%-such%-node', 1) ~= nil,
  'with the roster readable, a name it omits is still unknown_node, got ' .. tostring(typo.error))

-- 6. A read that SUCCEEDS may remove a peer: that is the rendezvous' answer, not our guess.
mode = 'up'
PEER = nil
clock = clock + 60
-- The stub now answers an empty roster, which is the rendezvous saying "nobody is registered".
host.http = function() return json.encode({ status = 200, body = json.encode({ nodes = {} }) }) end
check(find('box') == nil, 'a successful read that omits the peer removes it')

-- 7. And the roster comes back on its own once the rendezvous answers again - no restart.
mode = 'up'
host.http = function() return json.encode({ status = 200,
  body = json.encode({ nodes = { { node_id = string.rep('ab', 16), name = 'box', endpoints = {},
    public_key = identity.public_key, relay_attached = true, last_seen = clock } } }) }) end
clock = clock + 60
local back = find('box')
check(back ~= nil and back.online ~= false, 'the peer is re-learned after the link returns, with no restart')
check(reads > 0, 'the roster was actually read from the rendezvous')

-- ---- SHOULD: a COLD cache during an outage is not "no such node" ------------------------------
-- A node that just started, with the registry unreachable, has no peers to keep. The answer must still
-- be "the roster could not be read", never unknown_node: one reads as a network problem, the other as
-- a deletion.
nodes.invalidate()
mode = 'down'
clock = clock + 60
-- The stubs above were replaced by the later sections of this row, so the mode-aware one is put back:
-- the cold cache must be measured against a registry that really cannot be read.
host.http = function()
  if mode == 'up' then
    return json.encode({ status = 200, body = json.encode({ nodes = {
      { node_id = string.rep('ab', 16), name = 'box', endpoints = {},
        public_key = identity.public_key, relay_attached = true, last_seen = clock } } }) })
  end
  return json.encode({ status = 503, body = '' })
end
local cold = nodes.remote_call('box', 'bash', { command = 'true' })
check(tostring(cold.error):find('^roster_unavailable:box', 1) ~= nil,
  'a cold roster during an outage answers roster_unavailable, not unknown_node, got ' .. tostring(cold.error))
check(cold.retryable == true, 'and it says the call is worth retrying')
check(nodes.roster_unreadable(), 'the module reports the roster as unreadable')
-- Once the registry answers, a name it never knew is unknown_node again.
mode = 'up'
clock = clock + 60
local known = nodes.remote_call('never-registered', 'bash', { command = 'true' })
check(tostring(known.error):find('^unknown_node:', 1) ~= nil,
  'a readable roster that omits the name still answers unknown_node, got ' .. tostring(known.error))

print('network roster offline ok (' .. checks .. ' checks)')
