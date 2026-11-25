-- THE CANARY ACCOUNT GATE (25/11): does THIS node serve an account of this kind, or is the canary asking a
-- question this machine cannot answer?
--
-- MEASURED (v0.1.2 cut, 25/11): on the laptop that cuts, mail / whatsapp-receive / whatsapp-index /
-- whatsapp-transcription answered FAIL index_empty / no_voice_notes - the index answers and holds nothing,
-- because no account of that kind is served here at all. A FAIL says the FEATURE is broken.
--
-- THE SIGNAL IS THE PRODUCT'S OWN, and it is the one the host capability uses to refuse a send on a node
-- without the worker (rust/wa-capabilities/src/whatsapp_query.rs:131-140 `component_missing`): the service
-- registry's answer for that component, field `state`, is "running" on the node that serves the account. The
-- same registry is what `wa services status <name>` prints (lua/core/services.lua:112-115).
--
-- FIELDS READ, never a value invented here: `state` (the registry's own word), and for WhatsApp `owner`
-- (WASM_AGENT_WHATSAPP_OWNER, rust/wa-capabilities/src/whatsapp_query.rs:139-142) which names the node that
-- does serve it. A component that is installed but stopped is NOT the same as a node with no account, and the
-- reason says which.
local json = dofile('lua/vendor/json.lua')

local M = {}

-- <component> [, <answer>] -> true | false, reason
-- `answer` is the registry answer itself, so a row can drive every case in one process - and so can
-- WA_CANARY_ACCOUNT_ANSWER, the same seam for a row that runs a real canary end to end.
function M.present(component, answer)
  local name = tostring(component)
  local raw = answer or host.getenv('WA_CANARY_ACCOUNT_ANSWER')
  if raw == nil or raw == '' then
    local ok, got = pcall(host.service, json.encode({ action = 'status', name = name }))
    if not ok then return false, 'the service registry could not be read for ' .. name .. ': ' .. tostring(got) end
    raw = got
  end
  local doc, decoded = raw, false
  if type(raw) == 'string' then
    local good, parsed = pcall(json.decode, raw)
    doc, decoded = (good and type(parsed) == 'table') and parsed or nil, true
  end
  if type(doc) ~= 'table' then
    return false, 'the service registry answered nothing about ' .. name .. (decoded and '' or '')
  end
  local state = tostring(doc.state or '')
  if state == 'running' then return true end
  local detail = 'this node runs no ' .. name .. ' component (' ..
    (state == '' and 'no such service in the registry' or state) .. ')'
  local owner = doc.owner
  if type(owner) ~= 'string' or owner == '' then owner = host.getenv('WASM_AGENT_WHATSAPP_OWNER') end
  if type(owner) == 'string' and owner ~= '' then detail = detail .. '; the account is served by ' .. owner end
  return false, detail
end

return M
