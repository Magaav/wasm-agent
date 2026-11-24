-- CANARY: the WhatsApp index (whatsapp_search / whatsapp_contacts answer from it).
--
-- WHAT IT TOUCHES ON A LIVE NODE, exactly: ONE read query, `host.whatsapp_contacts` with no filter. No index
-- write, no media, no download, no send (the send and approval doors are replaced with functions that raise
-- for the length of the exercise, lua/core/canaries/guard.lua). 'answers nothing' is a failure on a node
-- that runs the component - the auto indexer stopping is exactly the silence this mission exists for.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('lua/core/canaries/guard.lua')

local M = { mode = 'read' }

function M.run()
  local ran, ok, stage, detail = guard.no_send(function()
    if type(host.whatsapp_contacts) ~= 'function' or type(host.whatsapp_search) ~= 'function' then
      return false, 'capability_missing', 'this binary has no WhatsApp query capability'
    end
    local answered, raw = pcall(host.whatsapp_contacts, '{}')
    if not answered then return false, 'index_unreadable', tostring(raw) end
    local contacts = type(raw) == 'string' and json.decode(raw) or raw
    if type(contacts) ~= 'table' then return false, 'index_unreadable', 'the contacts query answered nothing' end
    local list = contacts.chats or contacts.contacts or {}
    if #list == 0 then return false, 'index_empty', 'the index answers, but knows no chat' end
    return true, 'index', 'the index knows ' .. #list .. ' chat(s)'
  end)
  if not ran then return false, 'send_attempted', tostring(ok) end
  return ok, stage, detail
end

return M
