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

-- CANARY: transcription (a voice note's text is in the index and answers a query).
--
-- Read-only, and it answers the exact question that stayed silent for two days: is there a TRANSCRIPT in
-- the index, or only the audio's metadata? A node whose voice notes carry no text fails here by name.
local M = { mode = 'read' }
function M.run()
  if type(host.whatsapp_search) ~= 'function' then return false, 'capability_missing', 'this binary has no whatsapp_search' end
  local ok, raw = pcall(host.whatsapp_search, json.encode({ kind = 'voice', limit = 5 }))
  if not ok then return false, 'index_unreadable', tostring(raw) end
  local answer = type(raw) == 'string' and json.decode(raw) or raw
  if type(answer) ~= 'table' then return false, 'index_unreadable', 'the voice search answered nothing' end
  local hits = answer.hits or answer.messages or {}
  if #hits == 0 then return false, 'no_voice_notes', 'the index holds no voice note to transcribe' end
  for _, hit in ipairs(hits) do
    if type(hit.transcript) == 'string' and hit.transcript ~= '' then
      return true, 'transcript', 'a voice note answers with ' .. #hit.transcript .. ' characters of text'
    end
  end
  return false, 'no_transcript', #hits .. ' voice note(s) in the index, none carrying a transcript'
end
return M
