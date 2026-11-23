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

-- CANARY: sending (the durable send route answers by name).
--
-- A canary must never message a person, so this exercises the route the way an operator checks it: ask
-- for the state of a send that does not exist and require a NAMED answer instead of a raise. It proves
-- the queue behind every send is reachable; it does not prove a message left the node, and it says so.
local M = { mode = 'read' }
function M.run()
  if type(host.whatsapp_send_status) ~= 'function' then return false, 'capability_missing', 'this binary has no whatsapp_send_status' end
  local ok, raw = pcall(host.whatsapp_send_status, json.encode({ id = 'canary-no-such-send' }))
  if not ok then return false, 'route_raised', tostring(raw) end
  local answer = type(raw) == 'string' and json.decode(raw) or raw
  if type(answer) ~= 'table' then return false, 'route_unanswered', 'the send route answered nothing' end
  if answer.state == nil and answer.error == nil then
    return false, 'route_unnamed', 'the send route answered neither a state nor a named refusal'
  end
  return true, 'route', 'the send route answers by name (' .. tostring(answer.state or answer.error) .. ')'
end
return M
