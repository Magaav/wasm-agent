-- The end of a turn: what an ANSWER is, and what is not one.
--
-- Round 1 (lua/core/raw_code.lua, M.in_thinking) answered one shape: the step reasoned, wrote its run
-- block in its thinking, and the turn failed with nothing run. This module answers the other shapes that
-- end a turn without an action, from the ONE rule the operator set for this round (19/11):
--
--   never end a turn on an action that did not run or on a plan - give ONE named continue (counted), and
--   a second consecutive one fails the run by name (rc != 0).
--
-- The rule lives ONCE, in lua/core/agent.lua: one local gate, one counter (`self.finish_continues`),
-- one limit (M.CONTINUES). This module only names WHICH shape ended the step, so the continue names the
-- one thing to change and the failure names the one thing that was wrong. Nothing here executes anything,
-- reads the ledger or touches the network: it is pure text, and the loop is what acts on it.
--
-- Shapes, each measured in a mission log (docs/missions/reports/thinking-block.md):
--   markup      tool-call markup written as TEXT, so nothing ran. `<ds_tool>{"command":...}</ds_tool>`
--               (land-routing 19/11 00:59), a leftover `}}</parameter>` (thinking-block 00:41). The
--               formats the raw channel can RUN are read first (lua/core/raw_code.lua, M.native_calls);
--               this is what is left: markup no call could be read from.
--   shutdown    the step ended on a "node shutdown" warning about work from BEFORE this session. This
--               harness never sends one (no such string in lua/ or rust/), so it is stale, it is not
--               this session's evidence, and it is not an answer (land-routing 00:50).
--   compaction  the step answered with a context-compaction summary, so the turn ended on a summary
--               instead of continuing the task (edit-transport 01:01: the model's own <analysis> +
--               <summary>; the harness's own checkpoint template is the same shape).
--   plan        a first-person intent at the end of a run that executed NOTHING at all (round 3, item 2:
--               a run that ran a tool has an action, and its closing sentence is the answer to the
--               request). Conservative: a short answer whose LAST sentence asks this agent to do
--               something ("Let me ..."), never one that addresses the user ("Let me know", "your").
--
-- Precedence is the order of the list: the first shape that matches names the continue, because one
-- sentence is the fix and a model given three at once follows none of them.
local M = {}

local TICK = string.rep(string.char(96), 3)

-- One continue, then the run fails by name. ONE number for every shape, and it is published once: the raw
-- channel already owns it for the thinking shape (lua/core/raw_code.lua, THINKING_CONTINUES) and this
-- module re-exports it as the gate's limit, so the two can never drift apart. agent.lua counts every shape
-- against this limit.
M.CONTINUES = dofile("lua/core/raw_code.lua").THINKING_CONTINUES

local function trim(text) return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ---------------------------------------------------------------- 1. markup written as text
-- The markers themselves belong to the raw channel (it is the module that reads a model's own tool
-- markup), so the list and the scan live there: raw_code.markup_in_text().
-- An inline-code span (`marker`) is how a message NAMES a marker instead of writing one: an answer about
-- this very detector does it, and so does a note about a call format. Round 3, item 4: the spans come out
-- before the scan, exactly as a fenced sample is skipped below, because a marker inside backticks was the
-- false positive the operator measured on real answers.
local function without_inline_code(text)
  -- Double-backtick spans first, so a span that contains one backtick is taken whole: the order is what
  -- makes ``a `quoted` marker`` one span instead of three.
  local rest = tostring(text or ""):gsub("``(.-)``", " ")
  rest = rest:gsub("`[^`\n]-`", " ")
  return rest
end

function M.markup(text)
  local raw = tostring(text or "")
  -- A fenced block is a SAMPLE the model wrote, and the raw channel has already looked there for an
  -- action: an answer that quotes a call format inside a fence (a report about this very detector does)
  -- is prose, and failing it would be the false positive this list must not have.
  if raw:find(TICK, 1, true) or raw:find("~~~", 1, true) then return nil end
  local found = dofile("lua/core/raw_code.lua").markup_in_text(without_inline_code(raw))
  if not found then return nil end
  return {
    shape = "markup",
    marker = found.marker,
    -- The operator's sentence, verbatim and undivided: the marker is named AFTER it, so the one thing
    -- the model must read is one clause.
    notice = "[Harness notice] This message had no action: your message contains tool-call markup as "
      .. "text, so nothing ran; act with a js run block in your answer. The markup was " .. found.marker
      .. ", and no call could be read from it. One " .. TICK .. "js run block that ends your message.",
    failure = "tool_call_markup_as_text: the message carried " .. found.marker .. " tool-call markup as "
      .. "text and nothing ran; the harness asked for a js run block in the answer once already, so the "
      .. "turn is failed rather than finished without its action",
  }
end

-- ------------------------------------------------------- 2. a stale node-shutdown notice
-- The measured text (land-routing 19/11 00:50) was the model's own
-- `<system_warning>The previous response was interrupted by a node shutdown ...</system_warning>`
-- followed by a plan, as the last output of the run. A warning about a shutdown of THIS node is not
-- something this harness injects (checked: no such sentence in lua/ or rust/), and work from before this
-- session started is not this session's state: it must not be shown to the session and must not end it.
local SHUTDOWN_MARKERS = { "node shutdown", "node was shut down", "node shut down" }
function M.shutdown(text)
  local raw = tostring(text or "")
  local lowered = raw:lower()
  local marker
  for _, candidate in ipairs(SHUTDOWN_MARKERS) do
    if lowered:find(candidate, 1, true) then marker = candidate break end
  end
  if not marker then return nil end
  -- The notice is the warning, not the model's own thinking: only a warning-shaped sentence counts, so a
  -- model ANSWERING a question about shutdowns ("a node shutdown ends the claim") keeps its answer.
  local warned = lowered:find("<system_warning>", 1, true) ~= nil
    or lowered:find("the previous response was interrupted", 1, true) ~= nil
    or lowered:find("un-settled operations", 1, true) ~= nil
  if not warned then return nil end
  return {
    shape = "shutdown",
    notice = "[Harness notice] That " .. marker .. " warning is not from this session: it describes work "
      .. "from before this session started, this harness never sent it, and it is not an answer. Nothing "
      .. "ran. Continue the task from the state on this machine: your next step in your ANSWER, as one "
      .. TICK .. "js run block.",
    failure = "stale_shutdown_notice: the step ended on a node-shutdown warning about work from before "
      .. "this session started, and the harness asked for the next step once already; nothing ran, so the "
      .. "turn is failed rather than finished on it",
  }
end

-- --------------------------------------------------------- 3. a context-compaction summary
-- `(rest)` is the text with every <analysis>/<summary> block taken out; when nothing but whitespace is
-- left, that text was a compaction and not an answer.
local SUMMARY_BLOCK = { "<analysis>", "<summary>" }
local function without_summary_blocks(text)
  local rest = text
  for _, name in ipairs(SUMMARY_BLOCK) do
    local closing = name:gsub("<", "</")
    local buffer, position = {}, 1
    while true do
      local open_at, after = rest:find(name, position, true)
      if not open_at then buffer[#buffer + 1] = rest:sub(position) break end
      buffer[#buffer + 1] = rest:sub(position, open_at - 1)
      local close_at = rest:find(closing, after, true)
      -- An unclosed block runs to the end, as the raw channel reads an unclosed fence.
      if not close_at then break end
      position = close_at + #closing
    end
    rest = table.concat(buffer)
  end
  return rest
end

-- The harness's own checkpoint template (lua/core/agent.lua, CHECKPOINT_SUMMARY_PROMPT): the same shape
-- when a model reproduces it, and a plan when it does not, so it is named here rather than mistaken for
-- an answer.
local CHECKPOINT_HEADINGS = { "## goal", "## progress", "## next steps" }
local function is_checkpoint(text)
  local lowered = text:lower()
  for _, heading in ipairs(CHECKPOINT_HEADINGS) do
    if not lowered:find(heading, 1, true) then return false end
  end
  return true
end

function M.compaction(text)
  local raw = tostring(text or "")
  local tagged = raw:find("<summary>", 1, true) ~= nil or raw:find("<analysis>", 1, true) ~= nil
  local cleaned = without_summary_blocks(raw)
  local summary_only = tagged and trim(cleaned) == ""
  local checkpoint_only = is_checkpoint(raw)
  if not (summary_only or checkpoint_only) then return nil end
  return {
    shape = "compaction",
    notice = "[Harness notice] This message was a context-compaction summary, not an answer: nothing ran "
      .. "and the turn does not end here. Continue the task from where you stopped, in your ANSWER: your "
      .. "next step as one " .. TICK .. "js run block, or the answer itself and why.",
    failure = "compaction_answer: the step answered with a context-compaction summary instead of "
      .. "continuing the task, and the harness asked for the next step once already; nothing ran, so the "
      .. "turn is failed rather than finished on a summary",
  }
end

-- ------------------------------------------------------------- 4. a plan instead of an action
-- Conservative by construction (operator: "a final answer telling the USER a next step is fine"):
--   * the run must have executed NOTHING at all: after a tool ran, a closing "Done. I'll stop here." is
--     the answer to the request, not a plan (round 3, item 2 - the false positive this rule fired on);
--   * a fenced block anywhere means the reply is an action shape, not a plan (raw_code owns those);
--   * the LAST sentence must be first-person intent, and the answer must be short (<= 3 sentences): a
--     long report that happens to end on "let me" is a report;
--   * a last sentence that addresses the user ("you", "your", "let me know") is a next step for the
--     USER, which is a legitimate final answer, and never a plan of this agent's.
local INTENT = {
  "let me", "let's ", "i'll ", "i will ", "i am going to ", "i'm going to ", "i need to ", "i should ",
  "next, i ", "next i ", "now i ", "then i ", "first, i ", "first i'll ",
}
local function sentences(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local piece = trim(line)
    if piece ~= "" then
      for sentence in (piece .. " "):gmatch("(.-[%.%!%?])%s") do
        local one = trim(sentence)
        if one ~= "" then out[#out + 1] = one end
      end
      -- A line with no sentence ender is one sentence of its own.
      if not piece:find("[%.%!%?]") then out[#out + 1] = piece end
    end
  end
  return out
end
local function begins_with_intent(sentence)
  local lowered = trim(sentence):lower():gsub("^[%*%-#>]+%s*", "")
  for _, phrase in ipairs(INTENT) do
    if lowered:sub(1, #phrase) == phrase then return true end
  end
  return false
end
function M.plan(text, actions)
  local raw = tostring(text or "")
  if trim(raw) == "" then return nil end
  -- Nothing may have run in this run. "actions" is the run's own count of tool calls (agent.lua,
  -- self.run_counts.tool_calls), so a step that acted and then closes with "Done. I'll stop here." is an
  -- answer, never a plan: that closing sentence is what the operator's request was answered with.
  if (tonumber(actions) or 0) > 0 then return nil end
  if raw:find(TICK, 1, true) or raw:find("~~~", 1, true) then return nil end
  local list = sentences(raw)
  if #list == 0 or #list > 3 then return nil end
  local last = list[#list]:lower()
  if last:find(" you", 1, true) or last:find("your", 1, true) then return nil end
  -- "Let me know" asks the USER for the next step: it is addressed to them, not a plan of this agent's.
  if last:find("let me know", 1, true) then return nil end
  if not begins_with_intent(list[#list]) then return nil end
  return {
    shape = "plan",
    notice = "[Harness notice] This message was a plan, not an action: nothing ran. Do the step you just "
      .. "described, in your ANSWER: one " .. TICK .. "js run block that ends your message.",
    failure = "plan_only: the step ended on a first-person intent with no action and no result, and the "
      .. "harness asked for the action once already; nothing ran, so the turn is failed rather than "
      .. "finished on a plan",
  }
end

-- The one entry point the loop calls. `input` is what the loop knows and nothing else:
--   text       the step's answer text (result.content, already through the raw channel)
--   actions    tool calls this RUN executed (self.run_counts.tool_calls): zero means nothing ran, which
--              is the only state in which a closing "Let me ..." can be a plan instead of an answer
-- Returns nil (the text can be an answer) or {shape, notice, failure, ...} - the first shape that matches.
function M.inspect(input)
  if type(input) ~= "table" then return nil end
  local text = tostring(input.text or "")
  if trim(text) == "" then return nil end
  local found = M.markup(text) or M.shutdown(text) or M.compaction(text) or M.plan(text, input.actions)
  return found or nil
end

return M
