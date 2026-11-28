-- THE PROVIDER COMPONENT FROM LUA (claude-inside-wa, split A slice 2): the door /login and /model use.
--
-- The component (rust/components/provider, contract in wit/provider/provider.wit) is the one that knows the
-- accounts and the models; this module is the caller's side of that boundary and nothing else. It translates
-- one JSON request into one JSON answer, the same shape lua/core/model_gateway.lua uses for its seam, so a
-- component that is missing, refused or answered nonsense falls back the same way everywhere.
--
-- THE FALLBACK IS NAMED, NEVER SILENT: every function answers nil plus a reason when the capability is absent
-- ("component_capability_missing"), so /login can say "this node has no provider component; the list below is
-- the built-in one" instead of showing an empty list that would read as "you are signed in to nothing".
local json = dofile('lua/vendor/json.lua')

local M = {}

M.CAPABILITY = 'provider'

-- One call. Returns the answer table, or nil plus the reason there is none.
local function call(op, arguments)
  if type(host[M.CAPABILITY]) ~= 'function' then return nil, 'component_capability_missing' end
  local request = { op = tostring(op) }
  for key, value in pairs(arguments or {}) do request[key] = value end
  local ok, answer = pcall(host[M.CAPABILITY], json.encode(request))
  if not ok then return nil, 'component_call_failed' end
  if type(answer) == 'string' then
    local decoded_ok, decoded = pcall(json.decode, answer)
    answer = decoded_ok and decoded or nil
  end
  if type(answer) ~= 'table' then return nil, 'component_no_answer' end
  if answer.ok == false then
    -- The component's own refusal, with the words it used: a caller must not invent a second vocabulary.
    return nil, tostring(answer.error or answer.reason or 'component_refused')
  end
  return answer
end

function M.available()
  return type(host[M.CAPABILITY]) == 'function'
end

function M.list_accounts()
  local answer, why = call('list-accounts')
  if not answer then return nil, why end
  if type(answer.accounts) ~= 'table' then return nil, 'component_answer_malformed' end
  return answer.accounts
end

function M.begin_login(hint)
  local answer, why = call('begin-login', { hint = hint })
  if not answer then return nil, why end
  return answer.step or answer, nil
end

function M.continue_login(session, input)
  local answer, why = call('continue-login', { session = session, input = input })
  if not answer then return nil, why end
  return answer.step or answer, nil
end

function M.list_models(account)
  local answer, why = call('list-models', { account = account })
  if not answer then return nil, why end
  if type(answer.models) ~= 'table' then return nil, 'component_answer_malformed' end
  return answer.models
end

return M
