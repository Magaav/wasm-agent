-- CANARY: chat (lua/core/chat.lua, lua/core/agent.lua, lua/core/memory.lua).
--
-- Loopback: a whole turn in a child node with its own home and ledger, the model stubbed at the host's
-- stream boundary (lua/core/canaries/tasks/chat-turn.lua). Nothing of the operator's is read or written,
-- and no provider is called.
local feature_canary = dofile('lua/core/feature_canary.lua')

local M = { mode = 'loopback' }

function M.run(ctx)
  local child = feature_canary.child(ctx, {}, { env = { 'WA_SCRIPT=lua/core/canaries/tasks/chat-turn.lua' } })
  if child.code == 0 and (child.out or ''):find('CANARY OK', 1, true) then return true, 'answered', 'the turn landed in the ledger' end
  return false, child.stage or 'unknown', tostring(child.fail or child.err or child.out or ''):gsub('%s+$', '')
end

return M
