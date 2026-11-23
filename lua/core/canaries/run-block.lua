-- CANARY: run blocks (lua/core/codemode.lua through a turn, lua/core/agent.lua).
--
-- Loopback: a child node with its own home and ledger, the model stubbed so its first answer is a
-- ```js run block and its second answer ends the turn (lua/core/canaries/tasks/run-block.lua). The block
-- writes a file in that scratch home, so a block that stops executing is proven broken without running
-- anything in the operator's tree.
local feature_canary = dofile('lua/core/feature_canary.lua')

local M = { mode = 'loopback' }

function M.run(ctx)
  local child = feature_canary.child(ctx, {}, { env = { 'WA_SCRIPT=lua/core/canaries/tasks/run-block.lua' } })
  if child.code == 0 and (child.out or ''):find('CANARY OK', 1, true) then return true, 'readback', 'the block ran, its effect is real, the turn finished' end
  return false, child.stage or 'unknown', tostring(child.fail or child.err or child.out or ''):gsub('%s+$', '')
end

return M
