-- CANARY: release/update (the node knows which commit it runs, and the install record agrees).
--
-- Read-only on this node: lua/core/build_status.lua is the same answer a release's fleet read-back asks
-- for, and 'unknown' is a failure here rather than a shrug - a node that cannot name the bytes it runs is
-- the state that let a wrong commit pass a read-back.
local M = { mode = 'read' }
function M.run(ctx)
  -- THE NODE THAT CUTS DOES NOT RUN THE NEW BUILD YET: asking it to prove the identity of bytes it has not
  -- installed can only answer unknown (measured 25/11). That is not a broken feature and not a pass.
  if type(ctx) == 'table' and ctx.cutting then
    return 'not_proven', 'cutting', 'this node cuts; it does not run the new build yet'
  end
  local status = dofile('lua/core/build_status.lua')
  local answer, why = status.status()
  if type(answer) ~= 'table' then return false, 'identity_unreadable', tostring(why) end
  local binary = answer.binary or {}
  if not (binary.sha256 and binary.commit) then
    return false, 'identity_unknown', 'the binary cannot name its own commit: ' .. tostring(answer.relation)
  end
  if answer.relation == 'unknown' then
    -- THE FIELD status() ACTUALLY RETURNS (build_status.lua:122). It used to read `relation_reason`,
    -- which no branch sets, so every unknown printed the same sentence and the reason was lost.
    return false, 'identity_unknown', tostring(answer.why or 'the identity relation is unknown')
  end
  return true, 'identity', string.format('%s (%s)', tostring(binary.commit):sub(1, 12), tostring(answer.relation))
end
return M
