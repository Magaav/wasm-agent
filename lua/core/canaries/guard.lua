-- NO CANARY MAY MESSAGE A PERSON.
--
-- Two features in this list touch the sending half of WhatsApp, and a canary is not an excuse to write to a
-- real chat. This helper replaces the node's send doors for the length of one exercise with functions that
-- RAISE, and restores the originals whatever the exercise did:
--
--   * if a canary ever grows a send, it fails by name (`canary_raised` with this message) instead of
--     messaging somebody - the guard is an allow-list of touchable doors, not a comment;
--   * the restore is unconditional (pcall), because a live node's process must come out of a canary with
--     exactly the capabilities it went in with.
--
-- What is replaced: `host.whatsapp_send` (one message to one chat, through the durable outbox) and
-- `host.whatsapp_approve` (the operator's approval queue, whose `decide` action enqueues a send).
local M = {}

M.FORBIDDEN = { 'whatsapp_send', 'whatsapp_approve' }

-- <function(body)> -> ok, ... : runs the body with the doors replaced, always restoring them.
function M.no_send(body)
  local saved = {}
  for _, name in ipairs(M.FORBIDDEN) do
    saved[name] = host[name]
    host[name] = function()
      error('a canary must never send to a real chat: ' .. name .. ' is refused for the length of the exercise', 0)
    end
  end
  local called, a, b, c = pcall(body)
  for _, name in ipairs(M.FORBIDDEN) do host[name] = saved[name] end
  if not called then return false, a end
  return true, a, b, c
end

return M
