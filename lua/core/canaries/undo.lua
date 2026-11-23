-- CANARY: /undo (lua/core/undo_command.lua through the write tool's change record).
--
-- Loopback: a tool writes a file in a child node's own scratch home, the change is recorded in that
-- child's own ledger, and /undo puts the text back (lua/core/canaries/tasks/undo.lua). No file of the
-- operator's is written, read or restored.
local feature_canary = dofile('lua/core/feature_canary.lua')

local M = { mode = 'loopback' }

function M.run(ctx)
  local child = feature_canary.child(ctx, {}, { env = { 'WA_SCRIPT=lua/core/canaries/tasks/undo.lua' } })
  if child.code == 0 and (child.out or ''):find('CANARY OK', 1, true) then return true, 'readback', 'a change was written, recorded and put back' end
  return false, child.stage or 'unknown', tostring(child.fail or child.err or child.out or ''):gsub('%s+$', '')
end

return M
