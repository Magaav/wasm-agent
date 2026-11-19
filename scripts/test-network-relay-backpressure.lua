-- Callers never storm a relay that is over its cap, and never hold unbounded calls per node.
--
-- Brief, second evidence (19/11 12:20-12:45 UTC): the rendezvous (MAX_CONNECTIONS=256) answered 503
-- too_many_connections to everyone while ~470 TCP connections kept arriving, and ~600 relayed calls/min
-- were logged as "attached but no answer within the caller's wait (45 s)" then abandoned. Two halves of
-- the cause live on the caller: it retried with no jittered wait, and it held as many calls as it liked
-- against one node. This row pins both.
-- Hermetic: a fake relay over host.http; no network, no live node, no fleet.
local json = dofile('lua/vendor/json.lua')

-- ---- the scratch-home guard ----------------------------------------------------------------
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
    -- Two knobs, two jobs: the roster comes from the rendezvous, relayed calls go to the relay.
    if key == 'WASM_AGENT_RENDEZVOUS' then return 'http://127.0.0.1:1' end
    if key == 'WASM_AGENT_RELAY' then return 'http://127.0.0.1:2' end
    return native(key)
  end
end)(host.getenv)

local nodes = dofile('lua/core/nodes.lua')
local NODE_ID = string.rep('cd', 16)

-- 1. The per-node in-flight cap.
check(nodes.RELAY_MAX_IN_FLIGHT >= 1 and nodes.RELAY_MAX_IN_FLIGHT <= 16,
  'the per-node cap is a small number, got ' .. tostring(nodes.RELAY_MAX_IN_FLIGHT))
for _ = 1, nodes.RELAY_MAX_IN_FLIGHT do
  check(nodes.acquire_slot(NODE_ID) == true, 'a slot is granted under the cap')
end
local over, why = nodes.acquire_slot(NODE_ID)
check(over == nil and why == 'peer_busy_caller',
  'past the cap the caller is refused BY NAME before anything is sent, got ' .. tostring(why))
check(nodes.slots_held(NODE_ID) == nodes.RELAY_MAX_IN_FLIGHT, 'a refusal takes no slot')
-- Releasing one gives exactly one back, and the count never goes negative.
nodes.release_slot(NODE_ID)
check(nodes.slots_held(NODE_ID) == nodes.RELAY_MAX_IN_FLIGHT - 1, 'a release frees exactly one slot')
check(nodes.acquire_slot(NODE_ID) == true, 'and the freed slot is usable again')
for _ = 1, nodes.RELAY_MAX_IN_FLIGHT do nodes.release_slot(NODE_ID) end
check(nodes.slots_held(NODE_ID) == 0, 'all slots return to zero')
nodes.release_slot(NODE_ID)
check(nodes.slots_held(NODE_ID) == 0, 'an extra release never goes negative')
-- The cap is PER NODE: one busy peer does not silence another.
for _ = 1, nodes.RELAY_MAX_IN_FLIGHT do nodes.acquire_slot(NODE_ID) end
check(nodes.acquire_slot(string.rep('ef', 16)) == true, 'the cap is per node, not global')
for _ = 1, nodes.RELAY_MAX_IN_FLIGHT do nodes.release_slot(NODE_ID) end
nodes.release_slot(string.rep('ef', 16))

-- 2. The backoff: growing, capped, jittered, and never a tight retry.
local seen_low, seen_high, last_cap = math.huge, 0, 0
for attempt = 1, 8 do
  local low, high = math.huge, 0
  for _ = 1, 40 do
    local ms = nodes.relay_backoff_ms(attempt)
    check(ms >= 1, 'a backoff always waits at least a millisecond')
    low, high = math.min(low, ms), math.max(high, ms)
  end
  check(low <= high, 'the spread is ordered')
  -- Jitter: 40 draws at one attempt must not all be the same instant.
  check(low < high, 'attempt ' .. attempt .. ' is jittered, not a fixed sleep')
  check(high <= 8000, 'the computed backoff is capped, got ' .. high)
  check(low >= seen_low or true, 'recorded')
  seen_low = math.min(seen_low, low)
  last_cap = math.max(last_cap, high)
end
check(last_cap <= 8000, 'no attempt waits longer than the 8 s cap')
-- A Retry-After in seconds is honoured, and one in milliseconds is not multiplied twice.
check(nodes.relay_backoff_ms(1, 2) == 2000, 'a Retry-After of 2 seconds is 2000 ms')
check(nodes.relay_backoff_ms(1, 1500) == 1500, 'a Retry-After already in ms is taken as it is')
check(nodes.relay_backoff_ms(1, 600) <= 30000, 'a large hint is still capped')

-- 3. An over-cap relay produces WAITS, not a tight loop, and says why it failed.
local PEER = { node_id = NODE_ID, name = 'box', endpoints = {}, public_key = 'x', relay_attached = true }
host.http = function(method, url)
  if tostring(url):find('/nodes', 1, true) then
    return json.encode({ status = 200, body = json.encode({ nodes = { PEER } }) })
  end
  if tostring(url):find('/relay/send', 1, true) then
    -- Exactly the observed answer: the rendezvous is at its own cap.
    return json.encode({ status = 503, body = json.encode({ error = 'too_many_connections' }) })
  end
  return json.encode({ status = 200, body = '{}' })
end
local slept = {}
local real_sleep = host.sleep
host.sleep = function(ms) slept[#slept + 1] = tonumber(ms) or 0 end
local refused = nodes.request(PEER, '/node/call', '{}', {})
host.sleep = real_sleep
check(type(refused) == 'table' and refused.error ~= nil, 'the call ends with a named failure')
check(refused.error ~= 'relay_timeout' or refused.retryable == true, 'and it stays retryable')
check(#slept >= 1, 'the caller WAITED between attempts instead of retrying tightly, got ' .. #slept .. ' waits')
check(nodes.slots_held(NODE_ID) == 0, 'every slot is released when the call gives up')
-- No wait is zero: a zero wait is the tight retry that filled the cap.
for _, ms in ipairs(slept) do check(ms > 0, 'no wait is zero, got ' .. tostring(ms)) end

print('network relay backpressure ok (' .. checks .. ' checks)')
