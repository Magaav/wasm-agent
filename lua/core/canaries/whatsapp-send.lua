-- CANARY: sending (the durable send route answers by name).
--
-- WHAT IT TOUCHES ON A LIVE NODE, exactly: ONE read call, `host.whatsapp_send_status` with an id no send
-- ever had (`canary-no-such-send`). It queues no message, enqueues no job, and cannot reach a chat: the send
-- and approval doors are REPLACED with functions that raise for the length of this exercise
-- (lua/core/canaries/guard.lua), so a send this file does not contain cannot happen - and one it grew later
-- would fail the canary by name instead of writing to somebody's phone.
--
-- It proves the door behind every send is reachable and answers with a state or a NAMED refusal. It does not
-- prove a message left the node, and it says so in its stage.
local json = dofile('lua/vendor/json.lua')
local guard = dofile('lua/core/canaries/guard.lua')

local M = { mode = 'read' }

function M.run()
  local ran, ok, stage, detail = guard.no_send(function()
    if type(host.whatsapp_send_status) ~= 'function' then return false, 'capability_missing', 'this binary has no whatsapp_send_status' end
    local answered, raw = pcall(host.whatsapp_send_status, json.encode({ id = 'canary-no-such-send' }))
    if not answered then return false, 'route_raised', tostring(raw) end
    local answer = type(raw) == 'string' and json.decode(raw) or raw
    if type(answer) ~= 'table' then return false, 'route_unanswered', 'the send route answered nothing' end
    if answer.state == nil and answer.error == nil then
      return false, 'route_unnamed', 'the send route answered neither a state nor a named refusal'
    end
    return true, 'route', 'the send route answers by name (' .. tostring(answer.state or answer.error) .. ')'
  end)
  if not ran then return false, 'send_attempted', tostring(ok) end
  return ok, stage, detail
end

return M
