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
  -- A REAL QUESTION, NOT AN EMPTY ONE (26/11): email_search refuses {limit = 1} with email_empty_query - the
  -- connector needs a question (rust/wa-capabilities/src/email_query.rs:9 lists q/from/subject/mailbox/...), so the
  -- canary was refused before any mailbox was read. The cheapest real question is the newest inbox message.
  -- THE SHARED WAIT, NOT A PRIVATE ONE (mission email-read-waits-on-a-future): the mail index no longer
  -- answers inside a 2 s constant of its own, so a call that names no wait gets a HANDLE at once - and a
  -- handle is not an empty mailbox. The number is read from the file that owns it, never copied.
  local wait_s = dofile("lua/core/codemode_pending.lua").DEFAULT_WAIT_S
  local ok, raw = pcall(host.email_search, json.encode({ mailbox = "INBOX", limit = 1, wait_s = wait_s }))
  if not ok then return false, 'index_unreadable', tostring(raw) end
  local answer = type(raw) == 'string' and json.decode(raw) or raw
  if type(answer) ~= 'table' then return false, 'index_unreadable', 'the search answered nothing' end
  -- A REFUSAL IS NOT AN EMPTY MAILBOX (26/11): a connector that answers an error has not answered about a
  -- mailbox at all, and an empty index would read as "no message" for a feature that never ran.
  if type(answer) == 'table' and answer.error then
    return false, tostring(answer.error), 'the search was REFUSED, not answered: ' .. tostring(answer.error)
      .. (answer.state and (' (state ' .. tostring(answer.state) .. ')') or '')
      .. (answer.owner and ('; the account is served by ' .. tostring(answer.owner)) or '')
  end
  -- A RUNNING QUERY IS NOT AN EMPTY MAILBOX EITHER: the answer says it has not settled yet, which is the
  -- truth about the index, not a fact about the mail in it.
  if answer.state == 'running' or (answer.id ~= nil and answer.messages == nil and answer.hits == nil) then
    return 'not_proven', 'pending', 'the email index has not answered within the shared wait (' .. tostring(wait_s) .. ' s)'
  end
  local messages = answer.messages or answer.hits or {}
  -- RULING (c), 25/11: no chat indexed on a node that DOES serve the account is no_data, not a break.
  if #messages == 0 then return 'not_proven', 'no_data', 'no_data: no message in the index' end
  return true, 'index', 'the email index answers with ' .. #messages .. ' message(s)'
end
return M
