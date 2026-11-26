-- CANARY: receiving (a message arrived and the index holds it).
--
-- WHAT IT TOUCHES ON A LIVE NODE, exactly: `host.whatsapp_contacts` and ONE `host.whatsapp_read` of the
-- newest message of the first chat the index knows - both reads. No download, no send, no index write (the
-- send and approval doors raise for the length of the exercise, lua/core/canaries/guard.lua).
local json = dofile('lua/vendor/json.lua')
local guard = dofile('lua/core/canaries/guard.lua')

local M = { mode = 'read' }

function M.run()
  local ran, ok, stage, detail = guard.no_send(function()
    if type(host.whatsapp_contacts) ~= 'function' or type(host.whatsapp_read) ~= 'function' then
      return false, 'capability_missing', 'this binary has no WhatsApp query capability'
    end
    local queried, raw = pcall(host.whatsapp_contacts, '{}')
    -- A QUEUED ANSWER IS NOT A BREAK (26/11): on a node that does not hold the account the tool door refuses with
    -- <tool>_slow and state = queued while the owner is still being asked. That is not_proven; every other refusal
    -- keeps the FAIL r4 made it.  -- (queried)
    local contacts = queried and (type(raw) == 'string' and json.decode(raw) or raw) or nil
    -- A QUEUED ANSWER IS NOT A BREAK (26/11): on a node that does not hold the account the tool door refuses with
    -- <tool>_slow and state = queued while the owner is still being asked. That is not_proven, not a break; every
    -- other refusal keeps the FAIL r4 made it.
    if type(contacts) == "table" and tostring(contacts.state or "") == "queued" then
      return "not_proven", "queued", "the account question is still queued on the serving node"
    end
    local list = type(contacts) == 'table' and (contacts.chats or contacts.contacts or {}) or {}
    -- A REFUSAL IS NOT AN EMPTY INDEX (26/11, openclaw). A node that runs no wa-whatsapp component answers
    -- whatsapp_component_absent (with the state and the owner) BEFORE any index is touched; reading that as an
    -- empty index turns a stopped component into an account with no data - the one thing a canary must not do.
    if type(contacts) == 'table' and contacts.error then
      return false, tostring(contacts.error),
      'the query was REFUSED, not answered: ' .. tostring(contacts.error)
        .. (contacts.state and (' (state ' .. tostring(contacts.state) .. ')') or '')
        .. (contacts.owner and ('; the account is served by ' .. tostring(contacts.owner)) or '')
    end
    -- RULING (c), 25/11: no chat indexed on a node that DOES serve the account is no_data, not a break.
    if #list == 0 then return 'not_proven', 'no_data', 'no_data: no chat in the index' end
    local chat = list[1].chat or list[1].jid or list[1].name
    if not chat then return false, 'index_unreadable', 'the first chat carries no address' end
    local read, read_raw = pcall(host.whatsapp_read, json.encode({ chat = chat, limit = 1 }))
    if not read then return false, 'read_refused', tostring(read_raw) end
    local answer = type(read_raw) == 'string' and json.decode(read_raw) or read_raw
    local messages = type(answer) == 'table' and (answer.messages or {}) or {}
    if #messages == 0 then return false, 'no_messages', 'the chat ' .. tostring(chat) .. ' reads back empty' end
    return true, 'read', 'the newest message of ' .. tostring(chat):sub(1, 24) .. ' reads back'
  end)
  if not ran then return false, 'send_attempted', tostring(ok) end
  return ok, stage, detail
end

return M
