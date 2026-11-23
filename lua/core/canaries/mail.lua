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

-- CANARY: mail (the email index a mailbox read answers from).
--
-- Read-only on the node that runs the mail component: the index answers a search, and a role node whose
-- index answers nothing is a stopped feature, not an empty mailbox. This node (a laptop without wa-email)
-- reports the feature off-node instead of guessing.
local M = { mode = 'read' }
function M.run()
  if type(host.email_search) ~= 'function' then return false, 'capability_missing', 'this binary has no email_search' end
  local ok, raw = pcall(host.email_search, json.encode({ limit = 1 }))
  if not ok then return false, 'index_unreadable', tostring(raw) end
  local answer = type(raw) == 'string' and json.decode(raw) or raw
  if type(answer) ~= 'table' then return false, 'index_unreadable', 'the search answered nothing' end
  local messages = answer.messages or answer.hits or {}
  if #messages == 0 then return false, 'index_empty', 'the email index answers, but holds no message' end
  return true, 'index', 'the email index answers with ' .. #messages .. ' message(s)'
end
return M
