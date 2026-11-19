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
host.getenv = (function(native)
  return function(key)
    if key == 'WASM_AGENT_RENDEZVOUS' then return 'http://127.0.0.1:1' end
    return native(key)
  end
end)(host.getenv)

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

-- 5. A name the roster never knew is still unknown_node: the fix must not turn typos into offline peers.
local typo = nodes.remote_call('no-such-node', 'bash', { command = 'true' })
check(tostring(typo.error):find('^unknown_node:no%-such%-node', 1) ~= nil,
  'a peer never seen is still unknown_node, got ' .. tostring(typo.error))

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

print('network roster offline ok (' .. checks .. ' checks)')
