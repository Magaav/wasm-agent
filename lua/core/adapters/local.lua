-- The local adapter: a model served on this machine, outside the provider protocols.
--
-- It exists so "local" is a first-class transport rather than an unstated assumption, and it is
-- deliberately the plainest one: a whole answer, no stream, no provider vocabulary. Anything this
-- adapter is given that it does not understand is refused by name (the second return), because a
-- local runtime that silently drops a field is the failure the contract exists to prevent.
local normalize = dofile("lua/core/adapters/normalize.lua")

local M = {}
M.transport = "local"

-- A local runtime's stop words. Kept as its own table so the mapping is visible rather than implied.
local FINISH = {
  ["stop"] = "stop",
  ["eos"] = "stop",
  ["length"] = "length",
  ["max_tokens"] = "length",
  ["tool_calls"] = "tool_calls",
}

function M.finish_of(reason)
  if reason == nil or reason == "" then return nil end
  return FINISH[tostring(reason)]
end

-- A local runtime answers with the record's own names (answer_text, reasoning, tool_calls,
-- finish_reason, usage) and this function only validates and fills the empties. A runtime that
-- answers an OpenAI-shaped payload is served by the openai-completions adapter instead.
function M.from_payload(payload)
  payload = type(payload) == "table" and payload or {}
  if payload.error ~= nil then
    return nil, "provider_error: " .. tostring(payload.error)
  end
  local record, problem = normalize.normalize({
    answer_text = payload.answer_text,
    reasoning = payload.reasoning,
    tool_calls = payload.tool_calls,
    finish_reason = M.finish_of(payload.finish_reason) or "stop",
    usage = payload.usage,
  })
  if not record then return nil, problem end
  record.model = payload.model
  return record
end

return M
