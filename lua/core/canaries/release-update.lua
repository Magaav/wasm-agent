-- CANARY: release/update (the node knows which commit it runs, and the install record agrees).
--
-- Read-only on this node: lua/core/build_status.lua is the same answer a release's fleet read-back asks
-- for, and 'unknown' is a failure here rather than a shrug - a node that cannot name the bytes it runs is
-- the state that let a wrong commit pass a read-back.
local M = { mode = 'read' }
function M.run()
  local status = dofile('lua/core/build_status.lua')
  local answer, why = status.status()
  if type(answer) ~= 'table' then return false, 'identity_unreadable', tostring(why) end
  local binary = answer.binary or {}
  if not (binary.sha256 and binary.commit) then
    return false, 'identity_unknown', 'the binary cannot name its own commit: ' .. tostring(answer.relation)
  end
  if answer.relation == 'unknown' then
    return false, 'identity_unknown', tostring(answer.relation_reason or 'the identity relation is unknown')
  end
  return true, 'identity', string.format('%s (%s)', tostring(binary.commit):sub(1, 12), tostring(answer.relation))
end
return M
