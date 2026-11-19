-- The OpenAI-compatible adapter: POST /chat/completions, streamed or whole.
--
-- Everything provider-specific about this protocol lives here: the three reasoning spellings, the
-- phase / commentary split, the streamed deltas that have to be folded back into one message, the
-- delta-assembled tool calls, and the finish-reason vocabulary. The core receives one record
-- (lua/core/adapters/normalize.lua) and never looks at a delta or a reasoning field.
local normalize = dofile("lua/core/adapters/normalize.lua")
local json = dofile("lua/vendor/json.lua")

local M = {}
M.transport = "openai-completions"

-- This protocol's finish vocabulary, mapped onto the record's. Anything unknown stays nil so the
-- caller can say "unknown" instead of guessing "stop": unknown is not yes.
local FINISH = {
  ["stop"] = "stop",
  ["length"] = "length",
  ["tool_calls"] = "tool_calls",
  ["function_call"] = "tool_calls",
  ["content_filter"] = "content_filter",
}

function M.finish_of(reason)
  if reason == nil or reason == "" then return nil end
  return FINISH[tostring(reason)]
end

-- The usage block, in the record's names. Absent counters are 0, and a payload with no usage at all
-- answers nil rather than a table of zeros that would read as a measured zero.
function M.usage_of(raw)
  if type(raw) ~= "table" then return nil end
  local prompt = raw.prompt_tokens_details or {}
  local completion = raw.completion_tokens_details or {}
  return {
    input_tokens = tonumber(raw.prompt_tokens) or 0,
    output_tokens = tonumber(raw.completion_tokens) or 0,
    cache_read_tokens = tonumber(prompt.cached_tokens) or 0,
    cache_write_tokens = tonumber(raw.cache_write_tokens) or 0,
    reasoning_tokens = tonumber(completion.reasoning_tokens) or 0,
  }
end

-- One whole response body, as the record. `phase` is this edge's own field: it says whether the
-- text it carried was commentary or the final answer, so the split happens here and not in the core.
function M.from_payload(payload)
  payload = type(payload) == "table" and payload or {}
  local choice = (payload.choices or {})[1] or {}
  local message = type(choice.message) == "table" and choice.message or {}
  local phase = tostring(message.phase or "")
  local text = message.content
  local answer = phase == "commentary" and "" or (type(text) == "string" and text or "")
  local commentary = phase == "commentary" and (type(text) == "string" and text or "") or ""
  local calls = {}
  for index, call in ipairs(message.tool_calls or {}) do
    local function_ = type(call["function"]) == "table" and call["function"] or {}
    calls[index] = {
      id = tostring(call.id or ("call_" .. index)),
      type = "function",
      ["function"] = {
        name = tostring(function_.name or ""),
        arguments = tostring(function_.arguments or "{}"),
      },
    }
  end
  local record, problem = normalize.normalize({
    answer_text = answer,
    reasoning = normalize.reasoning_of(message),
    tool_calls = calls,
    finish_reason = M.finish_of(choice.finish_reason) or (#calls > 0 and "tool_calls" or "stop"),
    usage = M.usage_of(payload.usage),
  })
  if not record then return nil, problem end
  record.commentary = commentary
  record.model = payload.model
  record.request_id = payload.id
  return record
end

-- One streamed answer, folded back into the record. `payloads` is the SSE `data:` payloads in the
-- order they arrived (the raw bytes of a recorded stream, so a test replays a provider's own shape).
--
-- This is the provider-specific splitting principle 3 asks for: the deltas, the interleaved tool-call
-- arguments and the usage frame all become one message here. A stream that ends without a finish
-- reason answers `finish_reason = nil` and `cut = true` - the core must be able to tell a cut reply
-- from a finished one, and an invented "stop" would hide it.
function M.from_stream(payloads)
  local text, reasoning, commentary = {}, {}, {}
  local calls, by_index, order = {}, {}, {}
  local finish, usage, saw_event, saw_done = nil, nil, false, false
  for _, data in ipairs(payloads or {}) do
    local body = tostring(data or "")
    if body == "[DONE]" then saw_done = true
    elseif body ~= "" then
      local ok, payload = pcall(json.decode, body)
      if ok and type(payload) == "table" then
        saw_event = true
        if type(payload.usage) == "table" then usage = M.usage_of(payload.usage) end
        if type(payload.error) == "table" or payload.error ~= nil then
          return nil, "provider_error: " .. tostring(type(payload.error) == "table"
            and (payload.error.message or json.encode(payload.error)) or payload.error)
        end
        local choice = (payload.choices or {})[1]
        if type(choice) == "table" then
          if M.finish_of(choice.finish_reason) then finish = M.finish_of(choice.finish_reason) end
          local delta = type(choice.delta) == "table" and choice.delta
            or type(choice.message) == "table" and choice.message or {}
          local phase = tostring(delta.phase or choice.phase or "")
          if type(delta.reasoning_content) == "string" then reasoning[#reasoning + 1] = delta.reasoning_content
          elseif type(delta.reasoning) == "string" then reasoning[#reasoning + 1] = delta.reasoning
          elseif type(delta.reasoning_text) == "string" then reasoning[#reasoning + 1] = delta.reasoning_text end
          if type(delta.content) == "string" and delta.content ~= "" then
            if phase == "commentary" then commentary[#commentary + 1] = delta.content
            else text[#text + 1] = delta.content end
          end
          for _, call in ipairs(delta.tool_calls or {}) do
            local index = tonumber(call.index) or #order + 1
            local entry = by_index[index]
            if not entry then
              local function_ = type(call["function"]) == "table" and call["function"] or {}
              entry = { id = tostring(call.id or ("call_" .. index)), name = tostring(function_.name or ""), args = {} }
              by_index[index] = entry
              order[#order + 1] = index
            else
              local function_ = type(call["function"]) == "table" and call["function"] or {}
              if call.id and call.id ~= "" then entry.id = tostring(call.id) end
              if function_.name and function_.name ~= "" then entry.name = tostring(function_.name) end
            end
            local function_ = type(call["function"]) == "table" and call["function"] or {}
            if type(function_.arguments) == "string" then entry.args[#entry.args + 1] = function_.arguments end
          end
        end
      end
    end
  end
  for position, index in ipairs(order) do
    local entry = by_index[index]
    calls[position] = { id = entry.id, type = "function",
      ["function"] = { name = entry.name, arguments = table.concat(entry.args) ~= "" and table.concat(entry.args) or "{}" } }
  end
  local record, problem = normalize.normalize({
    answer_text = table.concat(text),
    reasoning = table.concat(reasoning),
    tool_calls = calls,
    finish_reason = finish or (#calls > 0 and "tool_calls" or "stop"),
    usage = usage,
  })
  if not record then return nil, problem end
  record.commentary = table.concat(commentary)
  -- A stream that carried no event at all is a shape failure, not an empty answer; one that stopped
  -- before its finish reason (or its [DONE] sentinel) is a cut. Both are said out loud.
  record.no_events = not saw_event
  record.cut = (not saw_done) or finish == nil
  return record
end

return M
