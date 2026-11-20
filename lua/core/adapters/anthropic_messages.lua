-- The Anthropic Messages adapter: POST /v1/messages, streamed or whole.
--
-- A different protocol, folded into the same record (lua/core/adapters/normalize.lua): content is a
-- LIST of blocks rather than one string, the thinking arrives as its own `thinking` block type,
-- a tool call is a `tool_use` block with an object for input, and the stop vocabulary is its own.
-- None of that reaches the core.
local normalize = dofile("lua/core/adapters/normalize.lua")
local json = dofile("lua/vendor/json.lua")

local M = {}
M.transport = "anthropic-messages"

-- Anthropic's stop reasons, mapped onto the record's. `end_turn` is this protocol's "stop";
-- `max_tokens` is a cut at the output cap; `tool_use` means the reply is a call. Anything else
-- (a refusal, a pause) stays unknown and the second return of M.normalize says so.
local FINISH = {
  ["end_turn"] = "stop",
  ["stop_sequence"] = "stop",
  ["max_tokens"] = "length",
  ["tool_use"] = "tool_calls",
  ["refusal"] = "content_filter",
}

function M.finish_of(reason)
  if reason == nil or reason == "" then return nil end
  return FINISH[tostring(reason)]
end

function M.usage_of(raw)
  if type(raw) ~= "table" then return nil end
  return {
    input_tokens = tonumber(raw.input_tokens) or 0,
    output_tokens = tonumber(raw.output_tokens) or 0,
    cache_read_tokens = tonumber(raw.cache_read_input_tokens) or 0,
    cache_write_tokens = tonumber(raw.cache_creation_input_tokens) or 0,
    reasoning_tokens = 0,
  }
end

-- Reads a list of content blocks into answer text, thinking and calls. Shared by the whole-body and
-- the streamed shapes, because this protocol sends the same blocks either way.
local function read_blocks(blocks, into)
  into = into or { text = {}, thinking = {}, calls = {} }
  for _, block in ipairs(blocks or {}) do
    local kind = type(block) == "table" and tostring(block.type or "") or ""
    if kind == "text" then
      if type(block.text) == "string" then into.text[#into.text + 1] = block.text end
    elseif kind == "thinking" then
      if type(block.thinking) == "string" then into.thinking[#into.thinking + 1] = block.thinking end
    elseif kind == "redacted_thinking" then
      -- Deliberately not read as reasoning: the provider redacted it, so it is not the model's words.
    elseif kind == "tool_use" then
      local input = block.input
      local arguments = type(input) == "string" and input or json.encode(type(input) == "table" and input or {})
      into.calls[#into.calls + 1] = { id = tostring(block.id or ("toolu_" .. #into.calls + 1)),
        type = "function", ["function"] = { name = tostring(block.name or ""), arguments = arguments } }
    end
  end
  return into
end

function M.from_payload(payload)
  payload = type(payload) == "table" and payload or {}
  if payload.error ~= nil then
    local error_ = type(payload.error) == "table" and (payload.error.message or json.encode(payload.error))
      or payload.error
    return nil, "provider_error: " .. tostring(error_)
  end
  local into = read_blocks(payload.content)
  local calls = #into.calls > 0 and into.calls or nil
  local record, problem = normalize.normalize({
    answer_text = table.concat(into.text),
    reasoning = table.concat(into.thinking),
    tool_calls = calls,
    finish_reason = M.finish_of(payload.stop_reason) or (calls and "tool_calls" or "stop"),
    usage = M.usage_of(payload.usage),
  })
  if not record then return nil, problem end
  record.model = payload.model
  record.request_id = payload.id
  return record
end

-- The streamed shape: `message_start`, `content_block_start`/`content_block_delta`/... and
-- `message_delta`, each a `data:` payload. Tool arguments arrive as `input_json_delta` fragments
-- keyed by the block index, and thinking as `thinking_delta`.
function M.from_stream(payloads)
  local into = { text = {}, thinking = {}, calls = {} }
  local blocks, order = {}, {}
  local finish, usage, saw_event, saw_stop = nil, nil, false, false
  for _, data in ipairs(payloads or {}) do
    local body = tostring(data or "")
    if body ~= "" and body ~= "[DONE]" then
      local ok, payload = pcall(json.decode, body)
      if ok and type(payload) == "table" then
        saw_event = true
        local kind = tostring(payload.type or "")
        if payload.error ~= nil then
          local error_ = type(payload.error) == "table" and (payload.error.message or json.encode(payload.error))
            or payload.error
          return nil, "provider_error: " .. tostring(error_)
        end
        if kind == "message_start" then
          local message = type(payload.message) == "table" and payload.message or {}
          if type(message.usage) == "table" then usage = M.usage_of(message.usage) end
        elseif kind == "content_block_start" then
          local index = tonumber(payload.index) or 0
          local block = type(payload.content_block) == "table" and payload.content_block or {}
          blocks[index] = { kind = tostring(block.type or ""), id = tostring(block.id or ""),
            name = tostring(block.name or ""), args = {}, text = {} }
          order[#order + 1] = index
          if block.type == "text" and type(block.text) == "string" and block.text ~= "" then
            blocks[index].text[1] = block.text
          end
        elseif kind == "content_block_delta" then
          local index = tonumber(payload.index) or 0
          local delta = type(payload.delta) == "table" and payload.delta or {}
          local entry = blocks[index]
          if entry then
            if delta.type == "text_delta" and type(delta.text) == "string" then
              entry.text[#entry.text + 1] = delta.text
            elseif delta.type == "thinking_delta" and type(delta.thinking) == "string" then
              into.thinking[#into.thinking + 1] = delta.thinking
            elseif delta.type == "input_json_delta" and type(delta.partial_json) == "string" then
              entry.args[#entry.args + 1] = delta.partial_json
            end
          end
        elseif kind == "message_delta" then
          local delta = type(payload.delta) == "table" and payload.delta or {}
          if M.finish_of(delta.stop_reason) then finish = M.finish_of(delta.stop_reason) end
          if type(payload.usage) == "table" then
            local merged = M.usage_of(payload.usage)
            if usage and merged then
              -- message_delta's usage carries the output counts; keep the merged view.
              merged.input_tokens = merged.input_tokens > 0 and merged.input_tokens or usage.input_tokens
              merged.cache_read_tokens = merged.cache_read_tokens > 0 and merged.cache_read_tokens or usage.cache_read_tokens
              merged.cache_write_tokens = merged.cache_write_tokens > 0 and merged.cache_write_tokens or usage.cache_write_tokens
            end
            usage = merged
          end
        elseif kind == "message_stop" then
          saw_stop = true
        end
      end
    end
  end
  for _, index in ipairs(order) do
    local entry = blocks[index]
    if entry and entry.kind == "text" then
      into.text[#into.text + 1] = table.concat(entry.text)
    elseif entry and entry.kind == "tool_use" then
      local arguments = table.concat(entry.args)
      into.calls[#into.calls + 1] = { id = entry.id, type = "function",
        ["function"] = { name = entry.name, arguments = arguments ~= "" and arguments or "{}" } }
    end
  end
  local calls = #into.calls > 0 and into.calls or nil
  local record, problem = normalize.normalize({
    answer_text = table.concat(into.text),
    reasoning = table.concat(into.thinking),
    tool_calls = calls,
    finish_reason = finish or (calls and "tool_calls" or "stop"),
    usage = usage,
  })
  if not record then return nil, problem end
  record.no_events = not saw_event
  record.cut = (not saw_stop) or finish == nil
  return record
end

return M
