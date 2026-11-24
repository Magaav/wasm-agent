-- CANARY: self-wake (lua/core/selfloop.lua).
--
-- Loopback: the exercise runs in a child node with its own home and ledger
-- (lua/core/canaries/tasks/self-wake.lua), so a wake the canary schedules, claims and settles can never
-- be one of the operator's, and a broken self-loop is proven broken without asking the operator's node
-- to wake up.
--
-- It ends on the half a SERVED node actually uses: `selfloop.tick` - a wake due now must be dispatched by
-- one tick, and it must still be dispatched behind more overdue rows of a parked session than the plan
-- takes (Fable 24/11 12:55Z: no self-wake was dispatched on the live node for two hours while a parked
-- session's 13 overdue rows filled every page of 8, and every claim-then-finish stage here stayed green).
local feature_canary = dofile('lua/core/feature_canary.lua')

local M = { mode = 'loopback' }

function M.run(ctx)
  local child = feature_canary.child(ctx, {}, { env = { 'WA_SCRIPT=lua/core/canaries/tasks/self-wake.lua' } })
  if child.code == 0 and (child.out or ''):find('CANARY OK', 1, true) then return true, 'delivered', 'scheduled, claimed, settled, dispatched by the tick' end
  local stage = child.stage or 'unknown'
  local detail = child.fail or child.err or child.out or ''
  if child.code == nil then stage = child.stage or 'spawn_failed' end
  return false, stage, tostring(detail):gsub('%s+$', '')
end

return M
