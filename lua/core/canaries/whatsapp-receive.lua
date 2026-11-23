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
    local contacts = queried and (type(raw) == 'string' and json.decode(raw) or raw) or nil
    local list = type(contacts) == 'table' and (contacts.chats or contacts.contacts or {}) or {}
    if #list == 0 then return false, 'index_empty', 'no chat is indexed, so no message could have arrived' end
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
