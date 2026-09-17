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
-- Failure text is persisted in the trace and shown in the session view, so it is
-- redacted before it is stored, not only when it is displayed.
local redact = dofile("lua/core/redact.lua")

local M = {}
M.__index = M

local SYSTEM = table.concat({
  "You are wasm-agent, a concise, local-first assistant with durable memory.",
  "",
  "Memory (facts the user asked you to keep) is on demand, so you must ask for it:",
  "- Before answering anything about the user - their names, preferences, codewords,",
  "  settings, accounts, projects, or what was decided earlier - call `recall` first.",
  "- Never answer a question about the user from your own guesswork, and never say the",
  "  memory store is empty without having called `recall` in this turn. Checking is",
  "  cheap; being wrong about the user is not.",
  "- If `recall` returns nothing, say plainly that you have nothing stored about it.",
  "- When the user asks you to remember something, call `remember` and confirm briefly.",
  "- For other questions, answer directly: do not call memory tools just to look busy.",
  "- For past conversations use `search_turns` (past sessions) or",
  "  `search_messages`/`conversation` (the message ledger).",
  "",
  "Language: reply in the language of the user's latest message, unless they ask for a",
  "different one. Match their language even when your instructions are in English.",
  "",
  "Style: keep replies short, never invent facts, and say what you did not do.",
}, "\n")

-- The environment line is built at load time so the model never guesses the
-- dialect: on Windows it guessed POSIX and spent a whole tool budget on `pwd`,
-- `ls` and `grep` failing with "not recognized as an internal or external
-- command".
local ENVIRONMENT = dofile("lua/core/platform.lua").describe()

-- Tool rounds: a real coding task is read -> edit -> test -> read again, and
-- eight rounds is not enough for one. Configurable, because a bulk edit wants
-- more and a chat wants fewer.
-- Runaway guard, not a task budget: the loop is bounded by context (see the note
-- before the round loop). A long task compacts mid-turn and keeps going.
-- pi's checkpoint summary, copied: the summary is the only place a run's plan
-- lives. pi ships no todo tool on purpose ("No built-in to-dos. They confuse
-- models."), so the goal, the work in progress, the blockers and the next steps
-- have to survive compaction in a fixed shape or they are simply lost - and
-- compaction now happens mid-turn.
local CHECKPOINT_SUMMARY_PROMPT = table.concat({
  "The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.",
  "",
  "Use this EXACT format:",
  "",
  "## Goal",
  "[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]",
  "",
  "## Constraints & Preferences",
  "- [Any constraints, preferences, or requirements mentioned by user]",
  "- [Or '(none)' if none were mentioned]",
  "",
  "## Progress",
  "### Done",
  "- [x] [Completed tasks/changes]",
  "",
  "### In Progress",
  "- [ ] [Current work]",
  "",
  "### Blocked",
  "- [Issues preventing progress, if any]",
  "",
  "## Key Decisions",
  "- **[Decision]**: [Brief rationale]",
  "",
  "## Next Steps",
  "1. [Ordered list of what should happen next]",
}, "\n")

-- The split-turn case: the span being summarised is the early part of one turn
-- too large to keep, so there are no complete turns to summarise. pi generates
-- this as a second summary and merges it with the history summary; here the
-- span is summarised in one pass with the prefix shape.
local PREFIX_SUMMARY_PROMPT = table.concat({
  "This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.",
  "",
  "Summarize the prefix to provide context for the retained suffix:",
  "",
  "## Original Request",
  "[What did the user ask for in this turn?]",
  "",
  "## Early Progress",
  "- [Key decisions and work done in the prefix]",
  "",
  "## Context for Suffix",
  "- [Information needed to understand the retained recent work]",
  "",
  "Be concise. Focus on what's needed to understand the kept suffix.",
}, "\n")

-- Context budgeting, per tool.
--
-- A tool result is stored whole and trimmed only when it is assembled into the
-- context, because the transcript *is* the record: truncating at write time lost
-- the evidence permanently. A 20 KB read became a 600-byte row, and every later
-- turn worked from that keyhole - which is how "read, then edit" kept missing with
-- old_text_not_found, and how a command's error (at the end of its output) was
-- already gone by the time anyone looked.
--
-- Budgets differ by tool because the useful part does: an error lives at the *end*
-- of a command's output, a file's opening usually identifies it, and an
-- acknowledgement needs almost nothing. pi does the equivalent for bash - it keeps
-- the tail and points at the full output - and this generalises it.
local TOOL_CONTEXT_BUDGET = {
  read = { chars = 8000, keep = "head" },
  session = { chars = 8000, keep = "head" },
  bash = { chars = 4000, keep = "both" },
  shell = { chars = 4000, keep = "both" },
  grep = { chars = 2500, keep = "head" },
  recall = { chars = 2500, keep = "head" },
  ls = { chars = 2000, keep = "head" },
  memories = { chars = 2000, keep = "head" },
  sessions = { chars = 1500, keep = "head" },
  find = { chars = 2500, keep = "head" },
  DEFAULT = { chars = 1500, keep = "head" },
}
local TOOL_STORE_CAP = 200000

-- WASM_AGENT_TOOL_BUDGET=legacy reproduces the old view exactly (600 characters,
-- head only) for every tool. It exists so a claim about the budget can be
-- measured rather than argued: same task, same model, one variable.
local function tool_budget(name)
  if host.getenv("WASM_AGENT_TOOL_BUDGET") == "legacy" then return { chars = 600, keep = "head" } end
  return TOOL_CONTEXT_BUDGET[name] or TOOL_CONTEXT_BUDGET.DEFAULT
end

local function fit_tool_output(name, text)
  local value = tostring(text or "")
  local budget = tool_budget(name)
  if #value <= budget.chars then return value end
  local head, tail, dropped = value:sub(1, budget.chars), "", #value - budget.chars
  if budget.keep == "tail" then
    head, tail = "", value:sub(-budget.chars)
  elseif budget.keep == "both" then
    local half = math.floor(budget.chars / 2)
    head, tail = value:sub(1, half), value:sub(-half)
    dropped = #value - #head - #tail
  end
  -- Say what was dropped and that the full text still exists: an unannounced loss
  -- at the moment of use is the failure mode this whole change is about.
  local marker = string.format("\n…(%s omitted: %d of %d characters; the full result is kept in the transcript)\n",
    budget.keep == "tail" and "earlier output" or (budget.keep == "both" and "middle of this output" or "rest of this result"),
    dropped, #value)
  return head .. marker .. tail
end

local MAX_TOOL_ROUNDS = tonumber(host.getenv("WASM_AGENT_MAX_TOOL_ROUNDS")) or 200
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

-- Instructions are the only thing injected into context by default, read
-- fresh every turn so editing the file takes effect immediately.
--
-- They are scoped by role. The operator instructions name internal paths and
-- the deploy shape, so a guest is given its own file and deliberately does NOT
-- fall back to the operator's: a guest can ask the model to repeat its
-- instructions, and "guest falls back to AGENTS.md" would hand them over.
local function agents_env(role)
  if (role or "master") == "guest" then return "WASM_AGENT_AGENTS_MD_GUEST" end
  return "WASM_AGENT_AGENTS_MD"
end

-- Returns `text, path` for the first readable instruction file. The path
-- matters: a node without the file silently runs uninstructed, so we record
-- which one (if any) was used and warn when a configured path is unreadable.
function M.agents_md(role)
  -- Build the list by appending: an explicit first element of nil would make
  -- `ipairs` stop immediately and silently skip everything else.
  local candidates = {}
  local configured = host.getenv(agents_env(role))
  if configured and configured ~= "" then candidates[#candidates + 1] = configured end
  local name = (role or "master") == "guest" and "AGENTS.guest.md" or "AGENTS.md"
  candidates[#candidates + 1] = name
  candidates[#candidates + 1] = dofile("lua/core/paths.lua").config() .. "/" .. name
  for _, path in ipairs(candidates) do
    local text = host.read_file and host.read_file(path)
    if text and text ~= "" then return text, path end
  end
  return nil, nil
end

-- Guidelines, built the way pi builds them: a base set, entries that depend on
-- which tools actually exist, and project-supplied ones from
-- WASM_AGENT_GUIDELINES (one per line - pi's `promptGuidelines`). Deduplicated,
-- because a repeated instruction is noise.
local function guidelines_for(tool_list)
  local have = {}
  for _, tool in ipairs(tool_list or {}) do
    local name = (tool["function"] or {}).name
    if name then have[name] = true end
  end
  local list, seen = {}, {}
  local function add(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text ~= "" and not seen[text] then
      seen[text] = true
      list[#list + 1] = text
    end
  end
  local extra = host.getenv("WASM_AGENT_GUIDELINES")
  if extra and extra ~= "" then
    for line in extra:gmatch("[^\n]+") do add(line) end
  end
  if have.bash and not (have.grep or have.ls) then
    add("Use bash for file operations like listing and searching")
  end
  add("Before changing this project's behaviour, read the relevant file under docs/ "
    .. "(or the section of AGENTS.md) in full, and follow its cross-references")
  add("When a task matches a skill in <available_skills>, load it with the skill tool before starting")
  add("For anything beyond a trivial command, write a script file and run it: "
    .. "a long one-liner passed through the shell loses its quoting and its backslashes")
  add("Never overwrite the installed UI to instrument it - copy it somewhere first, "
    .. "or the user's window starts running your probe")
  add("Be concise in your responses")
  add("Show file paths clearly when working with files")
  return list
end

local function system_prompt(role, agents, agents_path, tool_list)
  local parts = { SYSTEM, "Running on: " .. ENVIRONMENT }
  if tool_list and #tool_list > 0 then
    -- pi lists the tools in the prompt as well as in the schemas: a model that
    -- under-uses a tool is more likely to reach for it when it is named here.
    local lines = { "Available tools:" }
    for _, tool in ipairs(tool_list) do
      local function_ = tool["function"] or {}
      local snippet = tostring(function_.description or ""):match("^[^.]*") or ""
      lines[#lines + 1] = string.format("- %s: %s", tostring(function_.name or "?"), snippet:sub(1, 110))
    end
    parts[#parts + 1] = table.concat(lines, "\n")
    parts[#parts + 1] = "In addition to the tools above, you may have access to other tools " ..
      "depending on the project."
  end
  local guidelines = guidelines_for(tool_list)
  if #guidelines > 0 then
    local lines = { "Guidelines:" }
    for _, line in ipairs(guidelines) do lines[#lines + 1] = "- " .. line end
    parts[#parts + 1] = table.concat(lines, "\n")
  end
  -- Skills only cost context here as name + description; the body loads on
  -- demand when a task matches (pi's progressive disclosure).
  local skills = dofile("lua/core/skills.lua").prompt_block()
  if skills then parts[#parts + 1] = skills end
  if agents and agents ~= "" then
    -- With the path, so the agent knows which file these rules came from and can
    -- go back and read or edit it. pi stamps it the same way.
    parts[#parts + 1] = "Project-specific instructions and guidelines:\n<project_instructions path=\"" ..
      tostring(agents_path or "AGENTS.md") .. "\">\n" .. agents .. "\n</project_instructions>"
  end
  parts[#parts + 1] = "Your role is `" .. tostring(role or "master") .. "`."
  parts[#parts + 1] = "Current working directory: " .. dofile("lua/core/platform.lua").cwd()
  return table.concat(parts, "\n\n")
end

-- Exported so tests and diagnostics can assert what instructions a role runs with.
M.system_prompt = system_prompt

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
  return host.getenv("WASM_AGENT_LLM_SUMMARY_MODEL") or provider.settings().model
end

-- Rebuild the provider messages from the transcript: system (+AGENTS.md),
-- the compaction summary, then every turn after the watermark.
function M:build_context()
  local session = memory.session(self.session_id) or {}
  local agents, agents_path = M.agents_md(self.role)
  self.agents_source = agents_path
  local tool_list = tools.all(self.role)
  self.tool_list = tool_list
  local messages = { { role = "system", content = system_prompt(self.role, agents, agents_path, tool_list) } }
  if session.summary and session.summary ~= "" then
    messages[#messages + 1] = {
      role = "system",
      content = "Summary of earlier turns in this session:\n" .. session.summary,
    }
  end
  -- Recovery: if this thread was interrupted, the model has to be told, because
  -- its transcript simply ends mid-exchange and it would otherwise assume its
  -- last step either succeeded or never ran. Both assumptions are wrong: the step
  -- may have run without its result being written, and it may have run twice.
  -- Context-only by design - the transcript is what was said, and a synthetic
  -- turn in it would be replayed to every later request as if the agent had said
  -- it (and indexed by search_turns).
  if self.resume_notice then
    messages[#messages + 1] = { role = "system", content = self.resume_notice }
  end
  local rows = memory.session_turns(self.session_id, {
    after_seq = session.summarized_until or 0, limit = 500,
  })
  -- A window that begins with a tool result is missing the tool call it answers
  -- (it was summarised away, or the boundary was cut mid-exchange). Providers
  -- reject an orphan tool result with a 400, so drop leading tool turns until
  -- the window starts on a real message. Compaction avoids creating such a
  -- boundary, but this keeps a rebuilt context valid regardless.
  local started = false
  for _, turn in ipairs(rows) do
    if not started and turn.role == "tool" then
      -- skip the orphan
    elseif turn.role == "user" then
      started = true
      messages[#messages + 1] = { role = "user", content = turn.content }
    elseif turn.role == "assistant" then
      started = true
      local message = { role = "assistant", content = turn.content or "" }
      if type(turn.tool_calls) == "table" and #turn.tool_calls > 0 then
        message.tool_calls = turn.tool_calls
      end
      messages[#messages + 1] = message
    elseif turn.role == "tool" then
      messages[#messages + 1] = {
        role = "tool", tool_call_id = turn.tool_call_id or "",
        name = turn.tool_name or "", content = fit_tool_output(turn.tool_name, turn.content),
      }
    end
  end

  -- A tool call and its result are recorded as separate turns, so a turn that
  -- dies between them leaves a half-written exchange. Providers reject both
  -- halves - a call with no result, and a result with no call - with a 400 that
  -- would otherwise fail *every* later turn in this session, permanently
  -- bricking it. Repair the window instead: keep only exchanges that are
  -- complete, and say so, because silently dropping messages is exactly the
  -- kind of hidden data loss this project forbids.
  local answered = {}
  for _, message in ipairs(messages) do
    if message.role == "tool" and message.tool_call_id ~= "" then
      answered[message.tool_call_id] = true
    end
  end
  local dropped_calls, dropped_results = 0, 0
  for _, message in ipairs(messages) do
    if message.role == "assistant" and message.tool_calls then
      local complete = true
      for _, call in ipairs(message.tool_calls) do
        if not (call.id and answered[call.id]) then complete = false end
      end
      if not complete then
        dropped_calls = dropped_calls + 1
        message.tool_calls = nil
      end
    end
  end
  -- Re-check after dropping calls: a result whose call is gone is now an orphan.
  local declared = {}
  for _, message in ipairs(messages) do
    if message.role == "assistant" and message.tool_calls then
      for _, call in ipairs(message.tool_calls) do declared[call.id] = true end
    end
  end
  for index = #messages, 1, -1 do
    local message = messages[index]
    if message.role == "tool" and not declared[message.tool_call_id] then
      table.remove(messages, index)
      dropped_results = dropped_results + 1
    end
  end
  if dropped_calls > 0 or dropped_results > 0 then
    self.repaired = (self.repaired or 0) + 1
    self.emit({
      type = "status",
      text = string.format("repaired an incomplete tool exchange in the transcript (%d call(s), %d result(s) dropped)",
        dropped_calls, dropped_results),
    })
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
  local limits = provider.budget(self.model)
  local limit = limits.context or 0
  if limit <= 0 then return false end
  local reserve = limits.reserve or COMPACT_RESERVE
  reserve = math.min(reserve, math.max(1000, math.floor(limit / 4)))
  local keep = limits.keep or COMPACT_KEEP
  keep = math.min(keep, math.max(1000, math.floor(limit / 2)))

  -- Trigger on what the provider actually charged us for, not on a sum of
  -- message bodies: the request also carries the system prompt, AGENTS.md and
  -- every tool schema (several thousand tokens), which an estimate of the
  -- transcript alone misses entirely.
  local measured = self.last_prompt_tokens or 0
  local before = measured > 0 and measured or self:context_tokens()
  if before <= (limit - reserve) then return false end

  local session = memory.session(self.session_id) or {}
  local rows = memory.session_turns(self.session_id, {
    after_seq = session.summarized_until or 0, limit = 2000,
  })
  if #rows < 4 then return false end

  -- Keep the newest `keep` tokens *of transcript*; summarise what is older.
  -- `keep` is a whole-prompt budget, and the fixed overhead is always present,
  -- so the transcript share is the remainder. Without this the two metrics are
  -- in different units and the walk never finds anything to drop.
  local keep_transcript = math.max(500, keep - (self.overhead_tokens or 0))
  local budget, cut_index = 0, 0
  for index = #rows, 1, -1 do
    budget = budget + estimate_tokens(rows[index].content)
    if budget >= keep_transcript then
      cut_index = index - 1
      break
    end
  end
  -- The boundary must not split a tool call from its result, in either
  -- direction: an orphan tool result (or a tool call whose results were
  -- summarised away) makes the provider reject the whole request with a 400.
  while cut_index >= 1 and rows[cut_index].role == "tool" do cut_index = cut_index - 1 end
  while cut_index >= 1 and rows[cut_index + 1] and rows[cut_index + 1].role == "tool" do
    cut_index = cut_index - 1
  end
  if cut_index < 1 then return false end
  local cut = rows[cut_index]

  local transcript = {}
  for index = 1, cut_index do
    transcript[#transcript + 1] = string.format("%s: %s", rows[index].role,
      (rows[index].content or ""):sub(1, 2000))
  end
  -- No user message in the span means the cut landed inside one oversized turn:
  -- pi calls this a split turn and summarises the prefix differently, because
  -- there is no completed turn to describe.
  local split_turn = true
  for index = 1, cut_index do
    if rows[index].role == "user" then split_turn = false break end
  end
  -- The previous summary is fed back in and *superseded* rather than appended:
  -- concatenating grew it without bound, and a checkpoint that keeps accreting
  -- stops being a checkpoint.
  local previous = session.summary or ""
  local body = table.concat(transcript, "\n")
  if previous ~= "" then
    body = "Previous summary (supersede it; keep anything still true):\n" .. previous .. "\n\n" .. body
  end
  local prompt = {
    { role = "system", content = split_turn and PREFIX_SUMMARY_PROMPT or CHECKPOINT_SUMMARY_PROMPT },
    { role = "user", content = body },
  }
  local started = host.now()
  -- cache = false: a one-off prompt must not read or write the conversation's
  -- cache (pi does the same, to avoid paying a cache-write premium for nothing).
  local ok, result = pcall(provider.complete_with, self:summary_model(), prompt, nil, false, { cache = false })
  if not ok then
    self.emit({ type = "status", text = "compaction failed: " .. redact.text(tostring(result)):sub(1, 120) })
    return false
  end
  local previous_summary = session.summary or ""
  local merged = tostring(result.content or "")
  if merged == "" then merged = previous_summary end
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
      split_turn = split_turn, superseded = previous_summary ~= "",
      template = split_turn and "prefix" or "checkpoint",
      summary_model = self:summary_model(),
      ms = math.floor((host.now() - started) * 1000),
    } },
  })
  self.emit({ type = "compact", through = cut.seq, tokens_before = before, tokens_after = after })
  return true
end

-- Detect an interrupted thread and prepare the recovery notice.
--
-- The moment to look is the first turn of a process, *before* the new question is
-- appended: at that point the transcript's tail is still the previous turn's, and
-- a tail that is a question, a tool result or an unanswered decision can only
-- mean the process that was working on it did not survive. (A process cannot be
-- killed and keep running, so this is checked once and cached: there is nothing
-- to re-check later in the same process.)
--
-- Two things happen, and they are deliberately different: the interruption is
-- *recorded* durably, so it survives being recovered from, and the model is told
-- in its context, so it re-establishes state instead of assuming the lost step
-- either ran or did not.
function M:note_interruption()
  if self.resume_notice ~= nil then return self.resume_notice end
  self.resume_notice = false
  local state = memory.session_state(self.session_id)
  if not state or state.state ~= "interrupted" then return false end
  memory.mark_interrupted(self.session_id, { seq = state.seq, reason = state.detail })

  local work
  if state.question ~= "" then
    local question = tostring(state.question):gsub("%s+", " ")
    work = 'The question "' .. question:sub(1, 160) .. '" was never answered.'
  elseif #state.pending > 0 then
    work = "The last decision was to run " .. table.concat(state.pending, ", ")
      .. ", and no result for it is recorded."
  else
    work = "The transcript ends after a tool result, so nothing is recorded about what came next."
  end
  self.resume_notice =
    "Recovery notice: your previous turn in this session was interrupted - the process stopped "
    .. "mid-answer. " .. state.detail .. ". " .. work .. " Nothing after that point is recorded, so "
    .. "the unfinished step may have run without its result being saved, or may not have run at all, "
    .. "and re-running it may repeat an effect. Re-establish the real state from the machine before "
    .. "continuing (re-read the files you changed, check `git status` and the ledger), and say plainly "
    .. "what had already been done."
  self.emit({ type = "status", text = "recovering an interrupted thread: " .. state.detail })
  return self.resume_notice
end

function M:turn(text)
  self:note_interruption()
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
  local tool_list = self.tool_list or tools.all(self.role)
  -- Fingerprint of the *stable* prefix (system + AGENTS.md + tool schemas).
  -- Identical across turns unless instructions or tools change, which is what a
  -- provider needs in order to serve the prefix from its KV/context cache.
  local prefix_fingerprint = host.sha256(
    tostring(messages[1] and messages[1].content or "") .. json.encode(tool_list))
  -- The part of every request that is not transcript: system prompt (with
  -- AGENTS.md) + tool schemas. Needed to compare like with like, because the
  -- provider counts the whole prompt while the transcript is only its remainder.
  self.overhead_tokens = estimate_tokens(messages[1] and messages[1].content or "")
    + estimate_tokens(json.encode(tool_list))

  -- The loop is bounded by *context*, not by a round budget - pi's model, and
  -- the better one. A fixed round budget fails the worst way: it stops the turn
  -- mid-task, so the work exists in the transcript but nothing is verified,
  -- committed or reported. Telling the model "wrap up now" ahead of a cut-off
  -- only half-fixes it, because the deadline is artificial in the first place.
  --
  -- Instead the turn keeps its rounds and, when the request approaches the
  -- window, compacts mid-turn (pi calls this a split turn) and rebuilds the
  -- context from the transcript. Each round checks; nothing is cut off.
  -- WASM_AGENT_MAX_TOOL_ROUNDS therefore only guards against a runaway loop, not
  -- against a long task: it should never fire in practice.
  for round = 1, MAX_TOOL_ROUNDS do
    -- Two rounds before the runaway guard, ask the model to wrap up. This is
    -- not a task budget - it is the last resort of a loop that should have
    -- finished long before.
    if (MAX_TOOL_ROUNDS - round) == 2 then
      messages[#messages + 1] = { role = "user", content =
        "You have used a very large number of tool rounds. Stop exploring, verify what you have "
        .. "changed, commit it, and state plainly what is unfinished." }
      self.emit({ type = "status", text = "runaway guard reached - asking the model to wrap up" })
    end
    -- One round is one decision. Announcing it lets the UI close the previous
    -- decision's text and tool topic, so the transcript reads decision -> its
    -- tools -> next decision, instead of every tool topic stacked behind one
    -- growing block of text.
    self.emit({ type = "round", n = round })
    self.emit({ type = "status", text = "model" })
    local llm_started = host.now()
    local agents_var = agents_env(self.role)
    local configured_agents = host.getenv(agents_var)
    if round == 1 and configured_agents and configured_agents ~= "" and not self.agents_source then
      self.emit({ type = "status", text = agents_var .. " configured but unreadable: " .. configured_agents })
    end
    local ok, result = pcall(provider.complete_with, self.model, messages, tool_list, self.stream,
      { session_id = self.session_id })
    if not ok then
      trace[#trace + 1] = { kind = "llm", model = self.model, ok = false,
        ms = math.floor((host.now() - llm_started) * 1000), error = redact.text(tostring(result)):sub(1, 400) }
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
      if round == 1 then
        -- Which instructions, if any, this turn ran with. A node without the
        -- file is visible here instead of being indistinguishable from one with it.
        span.agents_md = self.agents_source
        if self.debug then
          span.request = { model = self.model, messages = messages, tools = tool_list }
        end
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
        content = ((self.debug or #content <= TOOL_STORE_CAP) and content)
          or (content:sub(1, TOOL_STORE_CAP) .. "…(stored truncated at " .. TOOL_STORE_CAP .. " characters)"),
        ok = ok_tool, debug = self.debug,
      })
      messages[#messages + 1] = {
        role = "tool", tool_call_id = call.id or "", name = function_.name or "", content = content,
      }
    end

    -- Mid-turn compaction (pi's "split turn"): everything so far is already in
    -- the transcript, so when the request approaches the window we summarise the
    -- older part and rebuild the context, then keep going in the same turn. The
    -- alternative - stopping the turn to protect the window - throws away the
    -- agent's momentum and leaves the work uncommitted.
    if self:maybe_compact() then
      messages = self:build_context()
      self.emit({ type = "status", text = "context compacted mid-turn - continuing" })
    end
  end

  if reply == "" then
    reply = "(runaway guard: " .. MAX_TOOL_ROUNDS .. " tool rounds without a final answer)"
  end
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
