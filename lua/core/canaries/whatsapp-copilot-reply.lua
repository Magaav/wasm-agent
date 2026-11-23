-- CANARY: the copilot reply (the component is CONFIGURED to post transcripts back).
--
-- WHAT IT TOUCHES ON A LIVE NODE, exactly: ONE read of the component's stored definition
-- (`<state>/components/wa-whatsapp.json`). It reads no index, sends nothing, and cannot: the send and
-- approval doors are replaced with functions that raise for the length of this exercise
-- (lua/core/canaries/guard.lua). This is the defect the mission starts from
-- (docs/missions/reports/whatsapp-transcription-works.md): the component ships with posting off, the
-- operator's switch pointed at a connector removed on 11/11, and nothing anywhere said so.
--
-- POSTING OFF IS NOT A FAILURE. Fable's rule: with posting disabled the canary answers
-- `off (posting disabled)` - the operator switched it off, and calling that broken would teach everyone to
-- ignore the red. Posting ON with no chat allowed is a real misconfiguration and DOES fail.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local guard = dofile('lua/core/canaries/guard.lua')

local M = { mode = 'read' }

local function component_config(name)
  local path = paths.config() .. '/components/' .. name .. '.json'
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' then return nil, 'the component definition is not readable: ' .. path end
  local parsed, document = pcall(json.decode, text)
  if not parsed or type(document) ~= 'table' then return nil, 'the component definition does not parse: ' .. path end
  return document
end

function M.run()
  local ran, ok, stage, detail = guard.no_send(function()
    local config, why = component_config('wa-whatsapp')
    if not config then return false, 'config_unreadable', why end
    local settings = type(config.config) == 'table' and config.config or {}
    if settings.post_transcripts ~= true then
      return 'off', 'off (posting disabled)', 'wa-whatsapp starts with post_transcripts off, so no copilot reply is posted'
    end
    local allow = settings.post_allow
    if type(allow) ~= 'table' or #allow == 0 then
      return false, 'posting_unscoped', 'post_transcripts is on with an empty post_allow, so nothing can be posted'
    end
    return true, 'config', 'posting is on for ' .. #allow .. ' chat(s)'
  end)
  if not ran then return false, 'send_attempted', tostring(ok) end
  return ok, stage, detail
end

return M
