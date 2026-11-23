-- CANARY: scheduled jobs (host.jobs over the sentinel's jobs store).
--
-- Loopback: a child node with its own home lists this node's jobs and reads the run history out of its own
-- scratch store (lua/core/canaries/tasks/scheduled-jobs.lua). No job of the operator's is listed, enabled
-- or run; the store's own answer is the exercise.
local feature_canary = dofile('lua/core/feature_canary.lua')
local M = { mode = 'loopback' }
function M.run(ctx)
  local child = feature_canary.child(ctx, {}, { env = { 'WA_SCRIPT=lua/core/canaries/tasks/scheduled-jobs.lua' } })
  if child.code == 0 and (child.out or ''):find('CANARY OK', 1, true) then
    local stage = 'idle'
    if (child.out or ''):find('stage: history') then stage = 'history' end
    return true, stage, 'the jobs store answers and its history is readable'
  end
  return false, child.stage or 'unknown', tostring(child.fail or child.err or child.out or ''):gsub('%s+$', '')
end
return M
