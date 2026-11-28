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
    -- THE SERVING NODE ANSWERS (26/11, Fable item 2b): see lua/core/canaries/serving.lua.
    local serving = dofile('lua/core/canaries/serving.lua')
    local answered, answer, how = serving.ask('whatsapp_search', { kind = 'voice', limit = 5 })
    -- A QUEUED ANSWER IS NOT A BREAK (26/11, Fable item c, kept through the merge): a node that does not hold the
    -- account answers state = queued while the owner is still being asked. That is not_proven; every other
    -- refusal keeps the FAIL r4 made it.
    if type(answer) == "table" and tostring(answer.state or "") == "queued" then
      return "not_proven", "queued", "the account question is still queued on the serving node"
    end
    if not answered then return false, tostring(answer.error or 'index_unreadable'), serving.detail(answer, tostring(answer.detail or '')) end
    if not answered then return false, 'index_unreadable', tostring(raw) end
    if type(answer) ~= 'table' then return false, 'index_unreadable', 'the voice search answered nothing' end
    local hits = answer.hits or answer.messages or {}
    -- A REFUSAL IS NOT AN EMPTY INDEX (26/11, openclaw). A node that runs no wa-whatsapp component answers
    -- whatsapp_component_absent (with the state and the owner) BEFORE any index is touched; reading that as an
    -- empty index turns a stopped component into an account with no data - the one thing a canary must not do.
    if type(answer) == 'table' and answer.error then
      return false, tostring(answer.error),
      'the query was REFUSED, not answered: ' .. tostring(answer.error)
        .. (answer.state and (' (state ' .. tostring(answer.state) .. ')') or '')
        .. (answer.owner and ('; the account is served by ' .. tostring(answer.owner)) or '')
    end
    -- RULING (c), 25/11: zero voice notes on the account node is nothing-to-test, not a broken feature.
    if #hits == 0 then return 'not_proven', 'no_data', 'no_data: no voice note in the index' end
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
