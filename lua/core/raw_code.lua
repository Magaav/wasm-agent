-- The raw code channel (WASM_AGENT_RAW_CODE, default off, per node).
--
-- With the switch on, the model may write its script as plain code in one fenced block tagged
-- ```js run instead of a JSON-escaped `codemode` tool call. Measured on 166 real scripts (15/11):
-- 6.0% of the model's output bytes were JSON overhead (712 escaped newlines, 1067 escaped quotes,
-- the wrapper), and every escape is a chance to get one wrong.
--
-- ONE PATHWAY: the block is not a second way to run code. `M.take` turns it into the same `codemode`
-- tool call the model could have sent (name `codemode`, arguments `{code=<block>}`), appended to the
-- step's own `tool_calls`; the tool loop then dispatches, records, redacts, projects and reports it
-- exactly as it does a codemode call, so the transcript, the evidence, the status lines, the UI, the
-- telemetry and steering cannot tell the two apart. What is different is only what the harness had to
-- say about the block itself (`notes`, a refusal), and that rides with the result.
--
-- Rules (operator design, 15/11):
--   - only a block whose info string is `js run` (or `javascript run`) runs; any other code block is text;
--   - one run block per message; with several, the LAST runs and the result says so;
--   - text after the run block is dropped from the step (the script's result replaces it);
--   - a run block the reply ended inside (stream cut, no closing fence) never runs: it is answered with
--     a refusal, and an empty run block is refused too;
--   - a message with no run block and no tool call is a plain answer, as before.
--
-- Stop sequence: `WASM_AGENT_RAW_CODE=stop` also asks the provider to stop at a closing fence
-- (`STOP`). It is opt-in because a stop sequence cannot tell a run block's closing fence from any other
-- one: a plain answer with an ordinary code block in it would be cut at that block. The provider strips
-- the stop text, so with `stop` a reply that ended (`finish_reason=stop`) inside an open block had its
-- fence eaten: a run block there is complete, and any other block gets its fence back.
--
-- Raw first: `WASM_AGENT_RAW_CODE=first` makes the run block THE way of working (CodeAct style) instead
-- of an extra. Measured 15/11: with `1` the model saw the sentence in all four A/B sessions and still made
-- every step a `codemode` tool call, because codemode was declared and its own history showed tool calls.
-- With `first`:
--   - `codemode` is not declared to the provider (`M.without_codemode`); the harness still dispatches the
--     synthesized call exactly as above (one pathway), and a codemode call the model sends anyway still runs;
--   - the code-mode guidance opens with `M.FIRST_GUIDANCE` instead of the codemode-call wording;
--   - the request renders each raw-channel call the way the model wrote it (`M.render_history`): the
--     assistant text is the thought plus its run block, with no tool_calls entry, and the result follows
--     as a user message `M.OBSERVATION` .. <the exact text the tool row carries>. The STORED rows are
--     unchanged (assistant tool_call + tool row), so the transcript, evidence, UI and telemetry are too.
--   - no stop sequence (a stop sequence would cut an ordinary answer at its first code block).
local json = dofile("lua/vendor/json.lua")
local M = {}

-- Model-facing. One sentence, appended to the code-mode guidance only while the switch is on.
M.GUIDANCE = "You may also run a script by ending your message with one ```js run block of plain code instead of a codemode call; it runs the same way."

-- Model-facing (operator-reviewed, verbatim). With `first` it opens the code-mode guidance in place of
-- the codemode-call sentence (lua/core/codemode_policy.lua, `guidance_for`).
M.FIRST_GUIDANCE = "Work in code: end your message with one ```js run block; it runs as one script in which every tool is `tools.<name>(args)`, and what it returns comes back to you. A message without a run block is your answer."

-- With `first`, the marker a raw-channel result is sent back under (a user message, no tool pairing).
M.OBSERVATION = "Observation:\n"

M.STOP = "\n```\n"

function M.mode()
  local value = tostring(host.getenv("WASM_AGENT_RAW_CODE") or ""):lower()
  if value == "1" or value == "on" or value == "true" then return "on" end
  if value == "stop" then return "stop" end
  if value == "first" then return "first" end
  return nil
end

-- Active only where a codemode call could have run: the switch is on and code mode is enabled.
function M.active(policy)
  return M.mode() ~= nil and type(policy) == "table" and policy.enabled == true
end

-- Raw first: the run block is the way of working, codemode is not declared, history renders as text.
function M.first(policy)
  return M.active(policy) and M.mode() == "first"
end

function M.stop_sequences(policy)
  if M.active(policy) and M.mode() == "stop" then return { M.STOP } end
  return nil
end

local function lines_of(text)
  local out, pos, size = {}, 1, #text
  while pos <= size do
    local newline = text:find("\n", pos, true)
    local last = newline or size
    local line = text:sub(pos, newline and newline - 1 or size):gsub("\r$", "")
    out[#out + 1] = { start = pos, finish = last, text = line }
    pos = last + 1
  end
  return out
end

local function is_run(info)
  local lang, rest = tostring(info):lower():match("^%s*(%a+)%s+(.-)%s*$")
  return (lang == "js" or lang == "javascript") and rest == "run"
end

-- Fenced blocks, CommonMark-style: an opening fence of 3+ backticks (indented at most three spaces,
-- no backtick in its info string) closes at a line of at least as many backticks and nothing else.
-- A fence inside another block is that block's text. An unclosed block runs to the end.
function M.parse(text)
  local blocks, lines, open = {}, lines_of(tostring(text or "")), nil
  for index, line in ipairs(lines) do
    if open then
      local ticks = line.text:match("^ ? ? ?(```+)%s*$")
      if ticks and #ticks >= open.ticks then
        open.close = index
        blocks[#blocks + 1] = open
        open = nil
      end
    else
      local ticks, info = line.text:match("^ ? ? ?(```+)(.*)$")
      if ticks and not info:find("`", 1, true) then
        open = { open = index, ticks = #ticks, run = is_run(info) }
      end
    end
  end
  if open then blocks[#blocks + 1] = open end
  return blocks, lines
end

local function refusal(code, message, fix)
  return { ok = false, error = code, message = message, fix = fix, input = "the ```js run block" }
end

-- Reads the step's reply. No run block: nil, the reply is untouched (except a fence a `stop` sequence
-- ate from an ordinary block, which is put back). A run block: the synthesized codemode call is
-- appended to `result.tool_calls`, and the returned table says what the loop must add (`refusal`
-- instead of running, `notes` for the result). A reply that was cut or hit its output limit keeps its
-- text whole: the step's own cut/limit path refuses every call it formed, this one included.
function M.take(result, stop_sent)
  local content = result.content or ""
  if not content:find("```", 1, true) then return nil end
  local blocks, lines = M.parse(content)
  local runs = {}
  for _, block in ipairs(blocks) do if block.run then runs[#runs + 1] = block end end
  local incomplete = result.stream_complete == false or result.finish_reason == "length"
  local stopped = stop_sent and not incomplete and result.finish_reason == "stop"
  if #runs == 0 then
    local last = blocks[#blocks]
    if stopped and last and not last.close then
      result.content = content .. "\n```"
      return { restored_fence = true }
    end
    return nil
  end
  local run = runs[#runs]
  local code_lines = {}
  for index = run.open + 1, run.close and run.close - 1 or #lines do code_lines[#code_lines + 1] = lines[index].text end
  local code = table.concat(code_lines, "\n")
  local id = "call_raw_" .. (host.uuid():gsub("-", ""))
  local calls = {}
  for _, call in ipairs(result.tool_calls or {}) do calls[#calls + 1] = call end
  calls[#calls + 1] = { id = id, type = "function", ["function"] = { name = "codemode", arguments = json.encode({ code = code }) } }
  result.tool_calls = calls
  local taken = { id = id, blocks = #runs, bytes = #code, notes = {} }
  if incomplete then taken.incomplete = true return taken end
  if not run.close and not stopped then
    taken.refusal = refusal("raw_code_unterminated",
      "the ```js run block was never closed (the reply ended inside it), so none of it ran",
      "send the whole script again in one ```js run block that ends with a ``` line"
        .. (M.mode() == "first" and "" or ", or as a codemode call"))
  elseif not code:find("%S") then
    taken.refusal = refusal("raw_code_empty",
      "empty run block: the ```js run block had no code, so nothing ran",
      "put the script between the ```js run line and its closing ``` line")
  end
  local after = run.close and content:sub(lines[run.close].finish + 1) or ""
  if #runs > 1 then
    taken.notes[#taken.notes + 1] = string.format("your message had %d ```js run blocks; only the last one ran", #runs)
  end
  if after:find("%S") then
    taken.notes[#taken.notes + 1] = string.format(
      "the %d byte(s) you wrote after the run block were dropped; this result replaces them", #after)
  end
  result.content = (content:sub(1, lines[run.open].start - 1):gsub("%s+$", ""))
  if result.finish_reason == "stop" or result.finish_reason == nil then
    result.raw_finish_reason = result.finish_reason
    result.finish_reason = "tool_calls"
  end
  return taken
end

-- The line the result carries for the model when the harness had something to say about the block.
function M.note(taken)
  if type(taken) ~= "table" or #(taken.notes or {}) == 0 then return nil end
  return "[raw code] " .. table.concat(taken.notes, "; ") .. "."
end

function M.is_raw(id)
  return type(id) == "string" and id:sub(1, 9) == "call_raw_"
end

-- With `first`: the tool list the provider is shown, without `codemode` (the harness still runs it).
function M.without_codemode(list)
  if type(list) ~= "table" then return list end
  local out = {}
  for _, item in ipairs(list) do
    if not (type(item) == "table" and type(item["function"]) == "table" and item["function"].name == "codemode") then
      out[#out + 1] = item
    end
  end
  return out
end

-- The run block a stored raw-channel call stands for. `closed=false` (the block was refused as
-- unterminated) renders it as the model sent it: without a closing fence.
local function run_block(call, closed)
  local arguments = type(call["function"]) == "table" and call["function"].arguments or ""
  local ok, decoded = pcall(json.decode, arguments)
  local code = ok and type(decoded) == "table" and type(decoded.code) == "string" and decoded.code or tostring(arguments)
  return "```js run\n" .. code .. (closed == false and "" or "\n```")
end

-- With `first`: the provider messages, with every raw-channel call rendered the way the model wrote it.
-- Runs on a window whose call/result pairing is already valid (build_context repairs it; the loop
-- appends calls and results in order), so a raw call's result is among the tool messages right after
-- it. The assistant message becomes its thought + the run block with no tool_calls entry for that call
-- (other calls of the same step keep theirs, and their tool results stay first, immediately after the
-- assistant message, as the provider requires); the raw result becomes a user message `M.OBSERVATION`
-- .. <the tool message content, byte for byte>. Pure: the caller's list and messages are not changed,
-- and a list with no raw call comes back as is. Idempotent: a rendered list has no raw call left.
function M.render_history(messages)
  if type(messages) ~= "table" then return messages end
  local any = false
  for _, message in ipairs(messages) do
    if message.role == "assistant" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do if M.is_raw(call.id) then any = true end end
    end
  end
  if not any then return messages end
  local out, index = {}, 1
  while index <= #messages do
    local message = messages[index]
    local raws, keep = {}, {}
    if message.role == "assistant" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do
        if M.is_raw(call.id) then raws[#raws + 1] = call else keep[#keep + 1] = call end
      end
    end
    if #raws == 0 then
      out[#out + 1] = message
      index = index + 1
    else
      local wanted = {}
      for _, call in ipairs(raws) do wanted[call.id] = true end
      local results, observations, unterminated = {}, {}, {}
      index = index + 1
      while index <= #messages and messages[index].role == "tool" do
        local result = messages[index]
        if wanted[result.tool_call_id] then
          local content = type(result.content) == "string" and result.content or tostring(result.content or "")
          if content:find("raw_code_unterminated", 1, true) then unterminated[result.tool_call_id] = true end
          observations[#observations + 1] = { role = "user", content = M.OBSERVATION .. content }
        else
          results[#results + 1] = result
        end
        index = index + 1
      end
      local rendered = {}
      for key, value in pairs(message) do rendered[key] = value end
      local text = type(message.content) == "string" and message.content or ""
      for _, call in ipairs(raws) do
        local block = run_block(call, not unterminated[call.id])
        text = text ~= "" and (text .. "\n" .. block) or block
      end
      rendered.content = text
      rendered.tool_calls = #keep > 0 and keep or nil
      out[#out + 1] = rendered
      for _, result in ipairs(results) do out[#out + 1] = result end
      for _, observation in ipairs(observations) do out[#out + 1] = observation end
    end
  end
  return out
end

return M
