-- CANARY: remote calls (lua/core/nodes.lua, the peer plane).
--
-- Read-only on this node, and honest about its reach: it proves the addressing half - the roster answers
-- and an unknown peer is REFUSED BY NAME instead of raising - and it does not prove that a live peer
-- answered. A two-node loopback needs a second process serving on a scratch port, which the canary runner
-- cannot start (the host has no background-spawn capability); the release step starting a scratch peer is
-- the next step, and this file says so rather than passing as if a call had been made.
local M = { mode = 'read' }
function M.run()
  local nodes = dofile('lua/core/nodes.lua')
  local answered, peers = pcall(nodes.peers, {})
  if not answered or (type(peers) ~= 'table') then
    return false, 'roster_unreadable', 'the roster did not answer: ' .. tostring(peers)
  end
  local called, refused = pcall(nodes.remote_call, 'canary-no-such-peer', 'runtime_info', {})
  if not called then return false, 'call_raised', 'an unknown peer raised instead of being refused: ' .. tostring(refused) end
  if type(refused) ~= 'table' or type(refused.error) ~= 'string' then
    return false, 'call_unanswered', 'an unknown peer was not refused by name: ' .. tostring(refused and json_encode and '' or refused)
  end
  return true, 'addressing', 'the roster answers and an unknown peer is refused as ' .. tostring(refused.error):sub(1, 60)
end
return M
