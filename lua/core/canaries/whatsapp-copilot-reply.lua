local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

-- The component config a WhatsApp feature runs on, read from the node's own state root. Nil plus the
-- reason when it cannot be read: a config nobody can read is not a feature that works.
local function component_config(name)
  local path = paths.config() .. '/components/' .. name .. '.json'
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' then return nil, 'the component definition is not readable: ' .. path end
  local parsed, document = pcall(json.decode, text)
  if not parsed or type(document) ~= 'table' then return nil, 'the component definition does not parse: ' .. path end
  return document
end

-- CANARY: the copilot reply (the component is CONFIGURED to post transcripts back).
--
-- This is the defect the mission starts from (docs/missions/reports/whatsapp-transcription-works.md):
-- the component ships with posting off, the operator's switch pointed at a connector that no longer
-- exists, and nothing anywhere said so. The canary therefore asserts the configuration the component
-- actually starts with, and fails by name when posting is off or no chat is allowed.
local M = { mode = 'read' }
function M.run()
  local config, why = component_config('wa-whatsapp')
  if not config then return false, 'config_unreadable', why end
  local settings = type(config.config) == 'table' and config.config or {}
  if settings.post_transcripts ~= true then
    return false, 'posting_off', 'wa-whatsapp starts with post_transcripts off, so no reply is ever posted'
  end
  local allow = settings.post_allow
  if type(allow) ~= 'table' or #allow == 0 then
    return false, 'posting_unscoped', 'post_transcripts is on with an empty post_allow, so nothing can be posted'
  end
  return true, 'config', 'posting is on for ' .. #allow .. ' chat(s)'
end
return M
