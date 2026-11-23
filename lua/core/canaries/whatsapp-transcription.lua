-- CANARY: transcription (a voice note's text is in the index and answers a query).
--
-- WHAT IT TOUCHES ON A LIVE NODE, exactly: ONE read query, `host.whatsapp_search` with `kind = "voice"` and
-- `limit = 5`. No audio is downloaded, nothing is transcribed, nothing is sent (the send and approval doors
-- raise for the length of the exercise, lua/core/canaries/guard.lua). It answers the exact question that
-- stayed silent for two days: is there a TRANSCRIPT in the index, or only the audio's metadata?
local json = dofile('lua/vendor/json.lua')
local guard = dofile('lua/core/canaries/guard.lua')

local M = { mode = 'read' }

function M.run()
  local ran, ok, stage, detail = guard.no_send(function()
    if type(host.whatsapp_search) ~= 'function' then return false, 'capability_missing', 'this binary has no whatsapp_search' end
    local answered, raw = pcall(host.whatsapp_search, json.encode({ kind = 'voice', limit = 5 }))
    if not answered then return false, 'index_unreadable', tostring(raw) end
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
  end)
  if not ran then return false, 'send_attempted', tostring(ok) end
  return ok, stage, detail
end

return M
