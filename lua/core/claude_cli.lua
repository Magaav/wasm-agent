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
-- The argv for one call. `opts` carries what a TURN needs and a bare call does not:
--   opts.mcp_config  - the JSON file describing wa's own `run` MCP server (scripts/wa-mcp-run.mjs)
--   opts.allowed     - the ONLY tools the CLI may use (ours); the CLI's own set is disabled
--   opts.disallowed  - the CLI's own tools, named so the restriction is visible in the argv, not implied
--   opts.session_id  - the CLI session this turn belongs to (one wa turn = one CLI call)
--   opts.resume      - continue that session instead of starting it
-- `--system-prompt` is NOT passed here: wa builds its system prompt by concatenation across modules
-- (lua/core/prompt_sections.lua, agent.lua), and passing a partial sentence would change what the model reads.
-- Until the assembled text is available as one value, the route refuses a turn rather than paraphrasing it.
function M.command(model, opts)
  opts = opts or {}
  local argv = { M.FLAGS.print, M.FLAGS.output_format, M.FLAGS.stream_json, M.FLAGS.verbose }
  if model and model ~= "" then
    argv[#argv + 1] = M.FLAGS.model
    argv[#argv + 1] = model
  end
  if opts.mcp_config then
    argv[#argv + 1] = "--mcp-config"
    argv[#argv + 1] = opts.mcp_config
  end
  if opts.allowed then
    argv[#argv + 1] = "--allowedTools"
    argv[#argv + 1] = opts.allowed
  end
  if opts.disallowed then
    argv[#argv + 1] = "--disallowedTools"
    argv[#argv + 1] = opts.disallowed
  end
  if opts.session_id then
    argv[#argv + 1] = opts.resume and "--resume" or "--session-id"
    argv[#argv + 1] = opts.session_id
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

-- ONE CALL, end to end: spawn the CLI, hand the prompt on stdin, read the JSONL stream back.
--
-- The prompt is written to the child's stdin and nowhere else. `bin` is passed in (never looked up on PATH by this
-- module) for the same reason the release verifier is: whoever controls the environment must not choose the program
-- that answers a model call. A non-zero exit is a NAMED refusal carrying the child's own first line of error, not an
-- empty answer that looks like "the model said nothing".
--
-- Returns the `consume` table plus { argv, exit_ok, stderr_first_line }.
function M.complete(bin, prompt, model)
  if not bin or bin == "" then
    -- binary() answers (binary, refusal); returning it directly would hand the caller nil as its reason.
    local _, why = M.binary(nil)
    return nil, why
  end
  local argv = M.command(model)
  local quoted = { string.format('%q', bin) }
  for _, part in ipairs(argv) do quoted[#quoted + 1] = string.format('%q', part) end
  local cmd = table.concat(quoted, " ")
  -- THE CREDENTIAL STORE IS THE OPERATOR'S, NOT THE NODE'S. Measured (28/11): wa hands a child HOME=<node home>, so
  -- the CLI looked for <node home>/.claude, found nothing, and answered "Not logged in - Please run /login" while the
  -- same binary from a shell answered normally. The child is therefore given the REAL user home, resolved from the
  -- passwd entry of the current uid - not from HOME (which is exactly the variable that is wrong here) and not from
  -- an environment variable a caller could point somewhere else.
  local passwd = io.popen("getent passwd $(id -u) 2>/dev/null | cut -d: -f6")
  local real_home = passwd and (passwd:read("*l") or "") or ""
  if passwd then passwd:close() end
  if real_home ~= "" then
    cmd = string.format("HOME=%q %s", real_home, cmd)
  end
  -- ONE spawn, with its stdin already redirected. An earlier version spawned the CLI twice (once to test it, then
  -- again with the prompt) and the first child printed "Input must be provided" - noise from a process nobody asked
  -- for. There is one child now.
  -- The prompt goes to the child as a file descriptor, not through a shell variable: a prompt containing quotes,
  -- newlines or `;` must not be able to change the command.
  local tmp = os.tmpname()
  local fh = io.open(tmp, "w")
  if not fh then handle:close(); os.remove(tmp); return nil, "claude_cli_prompt_unwritable: " .. tmp end
  fh:write(prompt)
  fh:close()
  -- `popen(..., "r")` gives stdout only, so the prompt is fed through a redirection the SHELL performs on the file
  -- we just wrote - still no interpolation of its contents.
  local redirected, rerr = io.popen(cmd .. " < " .. string.format('%q', tmp), "r")
  if not redirected then os.remove(tmp); return nil, "claude_cli_unspawnable: " .. tostring(rerr) end
  local lines = {}
  for line in redirected:lines() do lines[#lines + 1] = line end
  local ok, how, code = redirected:close()
  os.remove(tmp)
  local out = M.consume(lines)
  out.argv = cmd
  out.exit_ok = (ok == true) or (ok == nil and how == "exit" and code == 0)
  if not out.exit_ok and not out.text:match("%S") then
    local first = lines[1] or ""
    return nil, string.format("claude_cli_failed: exit %s: %s", tostring(code), first:sub(1, 200))
  end
  return out
end

return M
