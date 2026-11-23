-- The three lines a canary task shares: the stage it reached, the failure it names, and the answer
-- a reader parses. There is no fourth.
--
-- A task is run by `wa` in a CHILD process with a scratch home (lua/core/feature_canary.lua, M.child):
-- its exit code is the verdict, the last `stage:` line is where it got to, and a `FAIL <stage>: <detail>`
-- line is what a CANARY VERDICT carries instead of 'it failed'. That is the whole protocol, on purpose -
-- a stage nobody printed is a stage nobody reached.
local M = {}

function M.stage(name)
  print('stage: ' .. tostring(name))
  io.stdout:flush()
end

function M.fail(stage, detail)
  print(string.format('FAIL %s: %s', tostring(stage), tostring(detail)))
  io.stdout:flush()
  os.exit(3)
end

-- A condition the stage cannot go on without.
function M.check(value, stage, detail)
  if not value then M.fail(stage, detail) end
  return value
end

function M.ok()
  print('CANARY OK')
  io.stdout:flush()
end

return M
