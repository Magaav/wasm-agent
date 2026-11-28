-- The official `claude` CLI as a provider route (mission claude-inside-wa, part B, route 1).
--
-- WHY THIS ROUTE FIRST (Victor 28/11): the CLI is already on the node and already carries the subscription's own
-- login, so "Claude inside wa" needs no OAuth flow of ours to be testable end to end. The measured stream
-- (`--output-format stream-json --verbose`) is a JSONL of events; this module is the PURE half of driving it -
-- the argv, one event's meaning, and the refusal when the CLI is not there - so the rows judge the mapping
-- without a live call and without a stub that would lie.
--
-- WHAT IT DOES NOT DO: spawn anything (the caller does), keep a token (there is none to keep - the CLI owns its
-- credential), or guess an event shape (an unknown `type` is reported as `unknown`, never as text).
local json = dofile("lua/vendor/json.lua")

local M = {}

-- Every constant below is either a flag the CLI's own `--help` prints (measured 2.1.332) or a field observed in a
-- real run (see ready-claude-b.md and stream-json/event-shapes.jsonl). Nothing is from memory.
M.FLAGS = {
  print = "-p",                 -- `--help`: "-p/--print"
  output_format = "--output-format",  -- `--help`: text|json|stream-json
  stream_json = "stream-json",
  verbose = "--verbose",        -- `--help`: required with --print + stream-json
  model = "--model",
}

-- The argv for one call. The prompt goes on STDIN, never on the command line: a prompt is conversation content and
-- `ps` is world-readable.
function M.command(model)
  local argv = { M.FLAGS.print, M.FLAGS.output_format, M.FLAGS.stream_json, M.FLAGS.verbose }
  if model and model ~= "" then
    argv[#argv + 1] = M.FLAGS.model
    argv[#argv + 1] = model
  end
  return argv
end

-- One JSONL line -> {kind, ...}. Kinds: init, thinking_progress, text, thinking, tool_use, rate_limit, result,
-- unknown. `unknown` carries the raw type so a caller can print it instead of pretending it was content.
function M.event(line)
  local ok, decoded = pcall(json.decode, line)
  if not ok or type(decoded) ~= "table" then return { kind = "unknown", raw_type = "unparsable" } end
  local t = decoded.type
  if t == "system" then
    if decoded.subtype == "init" then
      return { kind = "init", session_id = decoded.session_id, model = decoded.model, tools = decoded.tools }
    end
    if decoded.subtype == "thinking_tokens" then
      return { kind = "thinking_progress", estimated = decoded.estimated_tokens }
    end
    return { kind = "unknown", raw_type = "system:" .. tostring(decoded.subtype) }
  end
  if t == "assistant" then
    local blocks = decoded.message and decoded.message.content or {}
    for _, block in ipairs(blocks) do
      if block.type == "text" then return { kind = "text", text = block.text or "" } end
      if block.type == "thinking" then return { kind = "thinking", text = block.thinking or "" } end
      if block.type == "tool_use" then return { kind = "tool_use", name = block.name, input = block.input } end
    end
    return { kind = "unknown", raw_type = "assistant:empty" }
  end
  if t == "rate_limit_event" then
    local info = decoded.rate_limit_info or {}
    return { kind = "rate_limit", status = info.status, utilization = info.utilization }
  end
  if t == "result" then
    local usage = decoded.usage or {}
    return {
      kind = "result",
      stop_reason = decoded.stop_reason,
      cost_usd = decoded.total_cost_usd,
      input_tokens = usage.input_tokens,
      output_tokens = usage.output_tokens,
      cache_read = usage.cache_read_input_tokens,
      cache_write = usage.cache_creation_input_tokens,
      session_id = decoded.session_id,
    }
  end
  return { kind = "unknown", raw_type = tostring(t) }
end

-- The CLI, or a NAMED refusal. Never a silence and never a fallback to a provider nobody chose.
function M.binary(exists)
  if exists then return exists end
  return nil, "claude_cli_missing: the official claude CLI is not on PATH, so this provider cannot serve a call (install it, or pick another provider)"
end

-- A whole stream, as a caller consumes it: the assistant text joined, the last result's numbers, and every event
-- that was not content (so a caller can print a rate-limit warning without parsing twice).
function M.consume(lines)
  local out = { text = "", thinking = "", events = 0, unknown = {}, tool_calls = {} }
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local ev = M.event(line)
      out.events = out.events + 1
      if ev.kind == "text" then out.text = out.text .. ev.text
      elseif ev.kind == "thinking" then out.thinking = out.thinking .. ev.text
      elseif ev.kind == "tool_use" then out.tool_calls[#out.tool_calls + 1] = { name = ev.name, input = ev.input }
      elseif ev.kind == "result" then
        out.result = ev
        out.session_id = ev.session_id
      elseif ev.kind == "init" then out.session_id = out.session_id or ev.session_id
      elseif ev.kind == "rate_limit" then out.rate_limit = ev
      elseif ev.kind == "unknown" then out.unknown[#out.unknown + 1] = ev.raw_type
      end
    end
  end
  return out
end

return M
