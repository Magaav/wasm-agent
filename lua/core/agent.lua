-- The agent turn loop.
--
-- The transcript in `turns` IS the context: there is no separate in-memory
-- message list, so a session survives a restart and can be inspected, replayed
-- and exported as a fixture. Observability is core: every turn carries a trace
-- of llm calls and tool calls with timings, tokens and failures.
local json = dofile("lua/vendor/json.lua")
local tools = dofile("lua/core/tools.lua")
local provider = dofile("lua/core/provider.lua")
local memory = dofile("lua/core/memory.lua")

local M = {}
M.__index = M

local SYSTEM = table.concat({
  "You are wasm-agent, a concise, local-first assistant with durable memory.",
  "- Memory is on demand: call `recall`/`search_turns` when they would help; never assume.",
  "- When the user asks you to remember something, call `remember` and confirm briefly.",
  "- When the user asks about past conversations, use `recall` (facts), `search_turns`",
  "  (past sessions) or `search_messages`/`conversation` (the message ledger).",
  "- Never invent facts. If memory has nothing, say so plainly.",
  "- Keep replies short.",
}, "\n")

local MAX_TOOL_ROUNDS = 8
local TOOL_TRUNCATE = 600          -- default mode: keep tool output small
local COMPACT_RESERVE = 16384      -- tokens reserved for the reply (like pi)
local COMPACT_KEEP = 20000         -- newest tokens left un-summarised (like pi)

M.usage_total = {
  prompt = 0, completion = 0, total = 0, cached = 0, cost = 0, turns = 0,
  last = { prompt = 0, completion = 0, total = 0, cached = 0, cost = 0 },
}

-- Providers report cache reuse differently; read whichever shape is present.
local function cached_tokens(usage)
  if type(usage) ~= "table" then return 0 end
  local details = usage.prompt_tokens_details or usage.prompt_cache
  if type(details) == "table" and tonumber(details.cached_tokens) then
    return tonumber(details.cached_tokens)
  end
  return tonumber(usage.cached_tokens) or 0
end

function M.usage()
  return M.usage_total
end

local function estimate_tokens(text)
  return math.ceil(#tostring(text or "") / 4)
end

-- AGENTS.md is the only thing injected into context by default: instructions,
-- read fresh every turn so editing the file takes effect immediately.
function M.agents_md()
  -- Build the list by appending: an explicit first element of nil would make
  -- `ipairs` stop immediately and silently skip everything else.
  local candidates = {}
  local configured = os.getenv("WASM_AGENT_AGENTS_MD")
  if configured and configured ~= "" then candidates[#candidates + 1] = configured end
  candidates[#candidates + 1] = "AGENTS.md"
  candidates[#candidates + 1] = (os.getenv("HOME") or ".") .. "/.wasm-agent/AGENTS.md"
  for _, path in ipairs(candidates) do
    local text = host.read_file and host.read_file(path)
    if text and text ~= "" then return text end
  end
  return nil
end

local function system_prompt(role, agents)
  local parts = { SYSTEM }
  if agents and agents ~= "" then
    parts[#parts + 1] = "Project instructions (AGENTS.md):\n" .. agents
  end
  parts[#parts + 1] = "Your role is `" .. tostring(role or "master") .. "`."
  return table.concat(parts, "\n\n")
end

function M.new(session_id, on_event, role, user, node)
  role = role or "master"
  user = user or "master"
  node = node or ""
  local session
  if session_id then
    session_id = session_id
    session = memory.session(session_id)
  end
  if not session then
    session_id = memory.ensure_session(user, node, "chat")
    session = memory.session(session_id)
  end
  return setmetatable({
    session_id = session_id,
    role = role,
    user = user,
    node = node,
    debug = session and session.mode == "debug" or false,
    model = provider.settings().model,
    -- Prompt tokens the provider reported for the last request in this session:
    -- the real context size, as opposed to a sum of message bodies.
    last_prompt_tokens = 0,
    emit = on_event or function() end,
    stream = on_event ~= nil,
  }, M)
end

function M:summary_model()
  return os.getenv("WASM_AGENT_LLM_SUMMARY_MODEL") or provider.settings().model
end

-- Rebuild the provider messages from the transcript: system (+AGENTS.md),
-- the compaction summary, then every turn after the watermark.
function M:build_context()
  local session = memory.session(self.session_id) or {}
  local messages = { { role = "system", content = system_prompt(self.role, M.agents_md()) } }
  if session.summary and session.summary ~= "" then
    messages[#messages + 1] = {
      role = "system",
      content = "Summary of earlier turns in this session:\n" .. session.summary,
    }
  end
  local rows = memory.session_turns(self.session_id, {
    after_seq = session.summarized_until or 0, limit = 500,
  })
  for _, turn in ipairs(rows) do
    if turn.role == "user" then
      messages[#messages + 1] = { role = "user", content = turn.content }
    elseif turn.role == "assistant" then
      local message = { role = "assistant", content = turn.content or "" }
      if type(turn.tool_calls) == "table" and #turn.tool_calls > 0 then
        message.tool_calls = turn.tool_calls
      end
      messages[#messages + 1] = message
    elseif turn.role == "tool" then
      messages[#messages + 1] = {
        role = "tool", tool_call_id = turn.tool_call_id or "",
        name = turn.tool_name or "", content = turn.content or "",
      }
    end
  end
  return messages
end

function M:context_tokens()
  local rows = memory.session_turns(self.session_id, { limit = 5000 })
  local total = 0
  for _, turn in ipairs(rows) do total = total + estimate_tokens(turn.content) end
  return total
end

-- Automatic compaction. Policy borrowed from pi: trigger only when the context
-- is within `reserve` of the window, and summarise everything older than
-- `keep` recent tokens - rare, large-chunk compaction rather than frequent small
-- ones. Every compaction rewrites the transcript prefix, so it invalidates the
-- provider's prefix cache from that point on; doing it rarely means paying that
-- once instead of constantly. The transcript keeps everything regardless; only
-- the context is windowed.
function M:maybe_compact()
  local limit = tonumber(os.getenv("WASM_AGENT_LLM_CONTEXT")) or 0
  if limit <= 0 then return end
  local reserve = tonumber(os.getenv("WASM_AGENT_COMPACT_RESERVE")) or COMPACT_RESERVE
  reserve = math.min(reserve, math.max(1000, math.floor(limit / 4)))
  local keep = tonumber(os.getenv("WASM_AGENT_COMPACT_KEEP")) or COMPACT_KEEP
  keep = math.min(keep, math.max(1000, math.floor(limit / 2)))

  -- Trigger on what the provider actually charged us for, not on a sum of
  -- message bodies: the request also carries the system prompt, AGENTS.md and
  -- every tool schema (several thousand tokens), which an estimate of the
  -- transcript alone misses entirely.
  local measured = self.last_prompt_tokens or 0
  local before = measured > 0 and measured or self:context_tokens()
  if before <= (limit - reserve) then return end

  local session = memory.session(self.session_id) or {}
  local rows = memory.session_turns(self.session_id, {
    after_seq = session.summarized_until or 0, limit = 2000,
  })
  if #rows < 4 then return end

  -- Keep the newest `keep` tokens; summarise what is older.
  local budget, cut_index = 0, 0
  for index = #rows, 1, -1 do
    budget = budget + estimate_tokens(rows[index].content)
    if budget >= keep then
      cut_index = index - 1
      break
    end
  end
  -- Never cut at a tool result: it must stay with its tool call.
  while cut_index >= 1 and rows[cut_index].role == "tool" do cut_index = cut_index - 1 end
  if cut_index < 1 then return end
  local cut = rows[cut_index]

  local transcript = {}
  for index = 1, cut_index do
    transcript[#transcript + 1] = string.format("%s: %s", rows[index].role,
      (rows[index].content or ""):sub(1, 2000))
  end
  local prompt = {
    { role = "system", content = "Summarise the conversation below into durable notes: decisions, " ..
        "facts, names, ids, open threads and what failed. Be compact and factual. No preamble." },
    { role = "user", content = table.concat(transcript, "\n") },
  }
  local started = host.now()
  -- cache = false: a one-off prompt must not read or write the conversation's
  -- cache (pi does the same, to avoid paying a cache-write premium for nothing).
  local ok, result = pcall(provider.complete_with, self:summary_model(), prompt, nil, false, { cache = false })
  if not ok then
    self.emit({ type = "status", text = "compaction failed: " .. tostring(result):sub(1, 120) })
    return
  end
  local previous = session.summary or ""
  local merged = previous ~= "" and (previous .. "\n" .. result.content) or result.content
  memory.set_session_summary(self.session_id, cut.seq, merged)
  local after = self:context_tokens()  -- honest post-compaction size of the transcript
  -- Record it in the transcript so a compaction (and the cache invalidation it
  -- causes) is visible in the session view instead of being invisible work.
  memory.append_turn(self.session_id, {
    role = "summary", content = merged, tokens = estimate_tokens(merged), debug = self.debug,
    ms = math.floor((host.now() - started) * 1000),
    trace = { {
      kind = "compact", summarized_until = cut.seq, messages = cut_index,
      tokens_before = before, tokens_after = after, invalidates_cache = true,
      summary_model = self:summary_model(),
      ms = math.floor((host.now() - started) * 1000),
    } },
  })
  self.emit({ type = "compact", through = cut.seq, tokens_before = before, tokens_after = after })
end

function M:turn(text)
  self.emit({ type = "status", text = "thinking" })
  self.debug = (memory.session(self.session_id) or {}).mode == "debug"

  memory.append_turn(self.session_id, { role = "user", content = text, debug = self.debug })

  if not provider.configured() then
    local reply = self:local_turn(text)
    memory.append_turn(self.session_id, { role = "assistant", content = reply, debug = self.debug })
    self.emit({ type = "reply", text = reply })
    return reply
  end

  local messages = self:build_context()
  local trace = {}
  local reply = ""
  local turn = { prompt = 0, completion = 0, total = 0, cached = 0 }
  local turn_started = host.now()
  local tool_list = tools.all(self.role)
  -- Fingerprint of the *stable* prefix (system + AGENTS.md + tool schemas).
  -- Identical across turns unless instructions or tools change, which is what a
  -- provider needs in order to serve the prefix from its KV/context cache.
  local prefix_fingerprint = host.sha256(
    tostring(messages[1] and messages[1].content or "") .. json.encode(tool_list))

  for round = 1, MAX_TOOL_ROUNDS do
    self.emit({ type = "status", text = "model" })
    local llm_started = host.now()
    local ok, result = pcall(provider.complete_with, self.model, messages, tool_list, self.stream,
      { session_id = self.session_id })
    if not ok then
      trace[#trace + 1] = { kind = "llm", model = self.model, ok = false,
        ms = math.floor((host.now() - llm_started) * 1000), error = tostring(result):sub(1, 400) }
      memory.append_turn(self.session_id, {
        role = "assistant", content = "", ok = false, trace = trace, debug = self.debug,
        ms = math.floor((host.now() - turn_started) * 1000),
      })
      error(result)
    end

    if type(result.usage) == "table" then
      local usage = result.usage
      local prompt = tonumber(usage.prompt_tokens) or 0
      local completion = tonumber(usage.completion_tokens) or 0
      local total = tonumber(usage.total_tokens) or (prompt + completion)
      turn.prompt = turn.prompt + prompt
      turn.completion = turn.completion + completion
      turn.total = turn.total + total
      local cached = cached_tokens(usage)
      -- Cost, only when rates are configured: cache reads are a fraction of
      -- input, so a cheap cached turn shows up as cheap rather than as "few".
      local rates = provider.rates(self.model)
      local cost = 0
      if rates then
        local miss = math.max(0, prompt - cached)
        cost = (miss * (rates.input or 0)
          + cached * (rates.cacheRead or rates.input or 0)
          + completion * (rates.output or 0)) / 1000000
        turn.cost = (turn.cost or 0) + cost
        M.usage_total.cost = (M.usage_total.cost or 0) + cost
      end
      M.usage_total.prompt = M.usage_total.prompt + prompt
      M.usage_total.completion = M.usage_total.completion + completion
      M.usage_total.total = M.usage_total.total + total
      M.usage_total.cached = M.usage_total.cached + cached
      turn.cached = turn.cached + cached
      local span = { kind = "llm", model = self.model, ok = true, round = round,
        ms = math.floor((host.now() - llm_started) * 1000), prefix = prefix_fingerprint,
        usage = usage,
        tokens = { prompt = prompt, completion = completion, total = total, cached = cached, cost = cost } }
      -- In debug mode keep the exact request so a failing turn can be replayed
      -- byte for byte (round 1 only: later rounds are derived from tool calls).
      if self.debug and round == 1 then
        span.request = { model = self.model, messages = messages, tools = tool_list }
      end
      -- The provider's own count for this request is the true context size.
      self.last_prompt_tokens = prompt
      trace[#trace + 1] = span
    else
      trace[#trace + 1] = { kind = "llm", model = self.model, ok = true, round = round,
        ms = math.floor((host.now() - llm_started) * 1000), prefix = prefix_fingerprint }
    end
    if result.model and result.model ~= "" then self.model = result.model end

    local calls = result.tool_calls or {}
    local assistant = { role = "assistant", content = result.content or "" }
    if #calls > 0 then assistant.tool_calls = calls end
    messages[#messages + 1] = assistant

    if #calls == 0 then
      -- The final assistant message is recorded once, after the loop, with the
      -- turn's trace. Recording it here as well would duplicate it in context.
      reply = result.content or ""
      break
    end
    memory.append_turn(self.session_id, {
      role = "assistant", content = result.content or "", tool_calls = calls, debug = self.debug,
    })

    for _, call in ipairs(calls) do
      local function_ = call["function"] or {}
      local args = {}
      if function_.arguments and function_.arguments ~= "" then
        local decoded_ok, decoded = pcall(json.decode, function_.arguments)
        if decoded_ok and type(decoded) == "table" then args = decoded end
      end
      self.emit({ type = "tool", name = function_.name, arguments = args })
      local tool_started = host.now()
      local handled, output = pcall(tools.dispatch, memory, function_.name, args, self.role,
        { session_id = self.session_id, user_id = self.user, node_id = self.node })
      if not handled then output = { error = tostring(output) } end
      local ok_tool = type(output) ~= "table" or output.error == nil
      trace[#trace + 1] = { kind = "tool", name = function_.name, ok = ok_tool, round = round,
        ms = math.floor((host.now() - tool_started) * 1000) }
      self.emit({ type = "tool_result", name = function_.name, result = output })

      local content = json.encode(output)
      memory.append_turn(self.session_id, {
        role = "tool", tool_call_id = call.id or "", tool_name = function_.name or "",
        content = (self.debug or #content <= TOOL_TRUNCATE) and content
          or (content:sub(1, TOOL_TRUNCATE) .. "…(truncated)"),
        ok = ok_tool, debug = self.debug,
      })
      messages[#messages + 1] = {
        role = "tool", tool_call_id = call.id or "", name = function_.name or "", content = content,
      }
    end
  end

  if reply == "" then reply = "(tool loop limit reached)" end
  if not self.debug then
    -- keep raw tool payloads out of the persisted assistant reply as well
    reply = reply:sub(1, 8000)
  end
  memory.record_run(host.uuid(), self.session_id, "completed", "completed", reply)
  memory.append_turn(self.session_id, {
    role = "assistant", content = reply, trace = trace, tokens = turn.total, debug = self.debug,
    ms = math.floor((host.now() - turn_started) * 1000),
  })
  M.usage_total.turns = M.usage_total.turns + 1
  M.usage_total.last = turn
  self.emit({ type = "usage", total = M.usage_total, model = self.model })

  self:maybe_compact()
  self.emit({ type = "reply", text = reply })
  return reply
end

-- Deterministic fallback when no model provider is configured.
function M:local_turn(text)
  local lines = {}
  for _, row in ipairs(memory.recall(text, 5)) do lines[#lines + 1] = "- " .. row.content end
  for _, row in ipairs(memory.search_messages(text, nil, 5)) do
    lines[#lines + 1] = "- [" .. row.conversation_id .. "] " .. row.body
  end
  if #lines == 0 then return "No provider is configured and nothing in memory matched." end
  return "memory:\n" .. table.concat(lines, "\n")
end

function M:close()
  memory.finish_session(self.session_id)
end

return M
