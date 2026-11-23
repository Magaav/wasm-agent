-- CANARY: the WhatsApp index (whatsapp_search / whatsapp_contacts answer from it).
--
-- WHAT IT TOUCHES ON A LIVE NODE, exactly: TWO read queries, `host.whatsapp_contacts` with no filter and then
-- `host.whatsapp_read` twice on the newest chat it named (the read contract of 23/11: an answer says its
-- as_of/order/index, and a later read is never older). Nothing here names a chat, an id or a message in its
-- report. No index
-- write, no media, no download, no send (the send and approval doors are replaced with functions that raise
-- for the length of the exercise, lua/core/canaries/guard.lua). 'answers nothing' is a failure on a node
-- that runs the component - the auto indexer stopping is exactly the silence this mission exists for.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('lua/core/canaries/guard.lua')

local M = { mode = 'read' }

-- One read, as the numbers this canary judges: only counts and times leave here, never an id or text.
local function read_once(chat)
  local answered, raw = pcall(host.whatsapp_read, json.encode({ chat = chat, limit = 5 }))
  if not answered then return { ok = false, stage = 'read_unreadable', detail = 'the read refused' } end
  local answer = type(raw) == 'string' and json.decode(raw) or raw
  if type(answer) ~= 'table' then return { ok = false, stage = 'read_unreadable', detail = 'the read answered nothing' } end
  if answer.ok == false then
    return { ok = false, stage = 'read_refused', detail = 'the read refused: ' .. tostring(answer.error or 'no reason') }
  end
  if type(answer.as_of) ~= 'number' then
    return { ok = false, stage = 'read_no_as_of', detail = 'the read did not say how fresh it was: no as_of' }
  end
  if type(answer.order) ~= 'table' or answer.order.direction ~= 'newest_first' then
    return { ok = false, stage = 'read_no_order', detail = 'the read did not say which order it answered in' }
  end
  if type(answer.index) ~= 'table' or (answer.index.state ~= 'current' and answer.index.state ~= 'catching_up') then
    return { ok = false, stage = 'read_no_index_state', detail = 'the read did not say whether the writer was current or catching up' }
  end
  if type(answer.messages) ~= 'table' then
    return { ok = false, stage = 'read_no_messages', detail = 'the read carried no message list' }
  end
  return { ok = true, as_of = answer.as_of }
end

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
    -- The read contract of 23/11, on the node that holds the account: a read says how fresh it is
    -- (as_of), in which order (order), whether the writer is behind (index) - and two reads in a row
    -- never go backwards. Two read-only queries, no id and no message text in this report.
    if type(host.whatsapp_read) ~= 'function' then
      return false, 'read_capability_missing', 'this binary has no WhatsApp read capability'
    end
    local newest = list[1] and (list[1].chat or list[1].jid)
    if type(newest) ~= 'string' or newest == '' then return false, 'read_no_chat', 'the contacts answer named no chat to read' end
    local first = read_once(newest)
    if not first.ok then return false, first.stage, first.detail end
    local second = read_once(newest)
    if not second.ok then return false, second.stage, second.detail end
    if second.as_of < first.as_of then
      return false, 'read_went_backwards', 'a later read answered an older picture (as_of went from a later time to an earlier one)'
    end
    return true, 'read', 'the index knows ' .. #list .. ' chat(s); a read answers as_of, order newest-first and a current writer'
  end)
  if not ran then return false, 'send_attempted', tostring(ok) end
  return ok, stage, detail
end

return M
