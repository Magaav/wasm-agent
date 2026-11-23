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

-- CANARY: receiving (a message arrived and the index holds it).
--
-- Read-only: the newest message of the busiest chat the index knows. An index that knows chats and holds
-- no message is a receive path that stopped.
local M = { mode = 'read' }
function M.run()
  if type(host.whatsapp_contacts) ~= 'function' or type(host.whatsapp_read) ~= 'function' then
    return false, 'capability_missing', 'this binary has no WhatsApp query capability'
  end
  local ok, raw = pcall(host.whatsapp_contacts, '{}')
  local contacts = ok and (type(raw) == 'string' and json.decode(raw) or raw) or nil
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
end
return M
