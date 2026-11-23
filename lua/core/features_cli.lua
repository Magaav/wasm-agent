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
    -- `wa features canary json` is the shape a PEER answers: the release step asks every updated node this
    -- one question after the fleet read-back, and reads the machine's own words rather than a table it parses
    -- out of a printed line.
    local only, as_json = (args or {})[3], false
    if only == 'json' then only, as_json = nil, true end
    if (args or {})[4] == 'json' then as_json = true end
    local results, why = feature_canary.run_all(only and { only = only } or {})
    if not results then
      if as_json then print(json.encode({ ok = false, error = tostring(why) })) else print('canaries: ' .. tostring(why)) end
      return 1
    end
    local failed = 0
    for _, result in ipairs(results) do
      -- 'off' is not a failure (the feature is switched off by its own configuration) and not a pass.
      if not result.ok and not result.skipped and not result.off then failed = failed + 1 end
    end
    if as_json then
      local rows = {}
      for _, result in ipairs(results) do
        rows[#rows + 1] = { feature = result.feature, ok = result.ok and true or false,
          off = result.off and true or false, skipped = result.skipped and true or false,
          stage = tostring(result.stage or ''), detail = result.detail and tostring(result.detail) or nil }
      end
      print(json.encode({ ok = failed == 0, failed = failed, features = rows }))
    else
      for _, line in ipairs(feature_canary.lines(results)) do print(line) end
    end
    return failed == 0 and 0 or 1
  end
  print(USAGE)
  return 2
end

return M
