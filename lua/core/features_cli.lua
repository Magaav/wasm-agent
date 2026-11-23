-- `wa features`: the ONE list of user-facing features, what each last DID, and the canaries that prove
-- them - on the command line, where a release step and an operator both read it.
--
-- Three readings, and each answers a different question:
--   wa features                 what every feature's last success was, and which has stopped (the table)
--   wa features canary [name]   run the canaries (all of them, or one) and record what they answered
--   wa features json            the same rows as data, for the release step and a scratch node's report
--
-- The verdict vocabulary lives in lua/core/feature_health.lua and is not restated here.
local json = dofile('lua/vendor/json.lua')
local feature_health = dofile('lua/core/feature_health.lua')
local feature_canary = dofile('lua/core/feature_canary.lua')

local M = {}

local USAGE = table.concat({
  'usage: wa features                  every feature: its last success, its bound, its verdict',
  '       wa features canary [name]     run the canaries (all, or one) and record the verdicts',
  '       wa features json              the same rows as JSON',
}, '\n')

function M.run(args)
  local verb = tostring((args or {})[2] or '')
  if verb == '' then
    for _, line in ipairs(feature_health.lines()) do print(line) end
    local red, why = feature_health.red()
    if not red then
      print('features: ' .. tostring(why))
      return 1
    end
    -- The exit code is the operator's: a node where something has stopped answers non-zero, so a script
    -- (and a release step) does not have to parse the table to notice.
    return #red == 0 and 0 or 1
  end
  if verb == 'json' then
    local report, why = feature_health.report()
    if not report then
      print(json.encode({ ok = false, error = why }))
      return 1
    end
    print(json.encode({ ok = true, features = report }))
    return 0
  end
  if verb == 'canary' then
    local only = (args or {})[3]
    local results, why = feature_canary.run_all(only and { only = only } or {})
    if not results then
      print('canaries: ' .. tostring(why))
      return 1
    end
    for _, line in ipairs(feature_canary.lines(results)) do print(line) end
    local failed = 0
    for _, result in ipairs(results) do
      if not result.ok and not result.skipped then failed = failed + 1 end
    end
    return failed == 0 and 0 or 1
  end
  print(USAGE)
  return 2
end

return M
