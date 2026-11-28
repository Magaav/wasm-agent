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
  local read = tonumber(raw.cache_read_input_tokens) or 0
  local write = tonumber(raw.cache_creation_input_tokens) or 0
  return {
    -- This protocol's `input_tokens` counts only the uncached part; the record's input is the whole
    -- prompt (what telemetry.normalize reads, with the cached share inside it).
    input_tokens = (tonumber(raw.input_tokens) or 0) + read + write,
    output_tokens = tonumber(raw.output_tokens) or 0,
    cache_read_tokens = read,
    cache_write_tokens = write,
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

-- ---------------------------------------------------------------- the request side
--
-- wa assembles every request in the OpenAI chat shape (a `system` message first, `tool_calls` on the
-- assistant, a `tool` role for results, `image_url` data parts). This folds that one shape onto
-- POST /v1/messages without adding, removing or rewording a byte of wa's own text: the system
-- message becomes `system`, each tool schema keeps its name, description and parameters (as
-- `input_schema`), and a tool result keeps its content.
local OBJECT = { __json_empty = "object" }

-- The Messages API version header. pi sends it through @anthropic-ai/sdk, whose default it is.
M.API_VERSION = "2023-06-01"

-- WHAT A CLAUDE SUBSCRIPTION (OAuth) REQUEST MUST CARRY, in one place, all of it from pi
-- (github.com/earendil-works/pi, formerly badlogic/pi-mono, commit 356d346e48a8,
-- packages/ai/src/api/anthropic-messages.ts):
--   * the two betas an OAuth token needs: line 1279, `features.push("claude-code-20250219", "oauth-2025-04-20")`;
--   * the client identity headers pi sends with an OAuth token: lines 1186-1191
--     (`accept: application/json`, `anthropic-dangerous-direct-browser-access: true`,
--     `user-agent: claude-cli/${claudeCodeVersion}`, `x-app: cli`), with claudeCodeVersion = "2.1.322" (line 110).
-- The Bearer token itself is NOT here: wa-vault sets `Authorization` on the way out (vault/wa_vault.py),
-- so this process only ever sends the placeholder.
M.SUBSCRIPTION_BETAS = { "claude-code-20250219", "oauth-2025-04-20" }
M.SUBSCRIPTION_HEADERS = {
  ["Accept"] = "application/json",
  ["anthropic-dangerous-direct-browser-access"] = "true",
  ["User-Agent"] = "claude-cli/2.1.322",
  ["x-app"] = "cli",
}

-- THE ONE PROMPT PREFIX (reported to the owner; delete this and the call in M.request to drop it).
-- pi, packages/ai/src/api/anthropic-messages.ts:1375-1381: "For OAuth tokens, we MUST include Claude Code
-- identity" (line 1375) - a first system block with exactly this text (line 1380), before the caller's own system prompt, which
-- follows unchanged as the second block. Applied only to Anthropic-subscription requests.
M.SUBSCRIPTION_SYSTEM_PREFIX = "You are Claude Code, Anthropic's official CLI for Claude."

-- The headers for one subscription request, added to the route's common ones.
function M.subscription_headers(headers)
  for name, value in pairs(M.SUBSCRIPTION_HEADERS) do headers[name] = value end
  headers["anthropic-version"] = M.API_VERSION
  headers["anthropic-beta"] = table.concat(M.SUBSCRIPTION_BETAS, ",")
  return headers
end

local function text_of(content)
  if type(content) == "string" then return content end
  local parts = {}
  for _, part in ipairs(type(content) == "table" and content or {}) do
    if type(part) == "table" and part.type == "text" and type(part.text) == "string" then parts[#parts + 1] = part.text end
  end
  return table.concat(parts, "\n")
end

-- One OpenAI content value as a list of Messages blocks: text stays text, a data-URL image becomes a
-- base64 image block. An empty string is no block at all (the API refuses an empty text block).
local function blocks_of(content)
  local out = {}
  if type(content) == "string" then
    if content ~= "" then out[1] = { type = "text", text = content } end
    return out
  end
  for _, part in ipairs(type(content) == "table" and content or {}) do
    if type(part) == "table" then
      if part.type == "text" and type(part.text) == "string" and part.text ~= "" then
        out[#out + 1] = { type = "text", text = part.text }
      elseif part.type == "image_url" then
        local url = type(part.image_url) == "table" and part.image_url.url or part.image_url
        local mime, data = tostring(url or ""):match("^data:([^;,]+);base64,(.*)$")
        if mime and data then
          out[#out + 1] = { type = "image", source = { type = "base64", media_type = mime, data = data } }
        end
      end
    end
  end
  return out
end

local function push(messages, role, blocks)
  if #blocks == 0 then return end
  local last = messages[#messages]
  -- Consecutive turns of one role are one message here (several tool results answer one assistant turn).
  if last and last.role == role then
    for _, block in ipairs(blocks) do last.content[#last.content + 1] = block end
  else
    messages[#messages + 1] = { role = role, content = blocks }
  end
end

-- The Messages body for wa's request. `opts`: model, max_tokens, stream, subscription (bool).
function M.request(messages, tools, opts)
  opts = opts or {}
  local system, out = {}, {}
  for index, message in ipairs(messages or {}) do
    local role = message.role
    if role == "system" and #out == 0 then
      system[#system + 1] = text_of(message.content)
    elseif role == "system" then
      -- A system note in the middle of a conversation has no place of its own in this protocol; its
      -- text goes to the model unchanged as user content.
      push(out, "user", blocks_of(message.content))
    elseif role == "assistant" then
      local blocks = blocks_of(message.content)
      for _, call in ipairs(message.tool_calls or {}) do
        local fn = type(call["function"]) == "table" and call["function"] or {}
        local ok, input = pcall(json.decode, fn.arguments or "{}")
        if not ok or type(input) ~= "table" or next(input) == nil then input = setmetatable({}, OBJECT) end
        blocks[#blocks + 1] = { type = "tool_use", id = tostring(call.id or ("toolu_" .. index)),
          name = tostring(fn.name or ""), input = input }
      end
      push(out, "assistant", blocks)
    elseif role == "tool" then
      local content = blocks_of(message.content)
      if #content == 0 then content = { { type = "text", text = "(no output)" } } end
      push(out, "user", { { type = "tool_result", tool_use_id = tostring(message.tool_call_id or ""), content = content } })
    else
      push(out, "user", blocks_of(message.content))
    end
  end
  local body = { model = opts.model, max_tokens = math.floor(tonumber(opts.max_tokens) or 32000), messages = out }
  local system_blocks = {}
  if opts.subscription then system_blocks[1] = { type = "text", text = M.SUBSCRIPTION_SYSTEM_PREFIX } end
  local system_text = table.concat(system, "\n\n")
  if system_text ~= "" then system_blocks[#system_blocks + 1] = { type = "text", text = system_text } end
  -- PROMPT CACHING, placed as pi places it (packages/ai/src/api/anthropic-messages.ts): Anthropic caches
  -- only up to a block that carries `cache_control`, so the request marks four breakpoints - each system
  -- block (:1381, :1388), the last tool definition (:1825) and the last block of the last message when it
  -- is the user's (:1682-1705). The last one moves forward every round, so each round reads the whole
  -- previous round from the cache. The marker is not part of the cached content, and nothing before it
  -- changes between rounds: the same messages fold to the same blocks, and the encoder sorts keys.
  if #system_blocks > 0 then
    for _, block in ipairs(system_blocks) do block.cache_control = { type = "ephemeral" } end
    body.system = system_blocks
  end
  local last = out[#out]
  if last and last.role == "user" and #last.content > 0 then last.content[#last.content].cache_control = { type = "ephemeral" } end
  if tools and #tools > 0 then
    body.tools = {}
    for _, tool in ipairs(tools) do
      local fn = type(tool["function"]) == "table" and tool["function"] or tool
      local schema = fn.parameters
      if type(schema) ~= "table" or next(schema) == nil then schema = { type = "object", properties = setmetatable({}, OBJECT) } end
      body.tools[#body.tools + 1] = { name = fn.name, description = fn.description, input_schema = schema }
    end
    body.tools[#body.tools].cache_control = { type = "ephemeral" }
    body.tool_choice = { type = "auto" }
  end
  if opts.stream then body.stream = true end
  return body
end

return M
