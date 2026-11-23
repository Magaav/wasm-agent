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

-- CANARY: the WhatsApp index (whatsapp_search / whatsapp_contacts answer from it).
--
-- Read-only: the node queries its own index. 'answers nothing' is a failure on a node that runs the
-- component - the auto indexer stopping is exactly the silence this mission exists for.
local M = { mode = 'read' }
function M.run()
  if type(host.whatsapp_contacts) ~= 'function' or type(host.whatsapp_search) ~= 'function' then
    return false, 'capability_missing', 'this binary has no WhatsApp query capability'
  end
  local ok, raw = pcall(host.whatsapp_contacts, '{}')
  if not ok then return false, 'index_unreadable', tostring(raw) end
  local contacts = type(raw) == 'string' and json.decode(raw) or raw
  if type(contacts) ~= 'table' then return false, 'index_unreadable', 'the contacts query answered nothing' end
  local list = contacts.chats or contacts.contacts or {}
  if #list == 0 then return false, 'index_empty', 'the index answers, but knows no chat' end
  return true, 'index', 'the index knows ' .. #list .. ' chat(s)'
end
return M
