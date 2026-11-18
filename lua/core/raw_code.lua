-- The raw code channel (WASM_AGENT_RAW_CODE, per node). CodeAct (`only`) is the default since 17/11;
-- `WASM_AGENT_RAW_CODE=codemode` restores the JSON codemode tool call.
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

-- `only`: the run block is the *only* way to act. `first` leaves every ordinary tool declared, so a
-- model that wants one `ls` calls `ls` — measured 17/11, four rounds, three direct calls, zero run
-- blocks, with `first` on. This mode hides the tools a script can express, so the prompt offers no
-- shorter path; they stay dispatchable inside the script (`tools.bash(...)`), which is what the tool
-- loop already does for every capability.
M.ONLY_GENERIC = { bash = true, read = true, write = true, edit = true, ls = true, grep = true, shell = true }

-- `only`: nothing is declared and the run block is the only way to act. Given a policy it also requires
-- the channel to be able to run one: a node whose code mode is off declared NOTHING and then refused to
-- start the turn (no_dispatchable_tools, 18/11) while its ordinary tools were there all along.
function M.only(policy)
  if policy ~= nil then return M.active(policy) and M.mode() == "only" end
  return M.mode() == "only"
end

function M.without_generic(list)
  if type(list) ~= "table" then return list end
  local out = {}
  for _, item in ipairs(list) do
    local name = type(item) == "table" and item["function"] and item["function"].name or nil
    if not (name and M.ONLY_GENERIC[name]) then out[#out + 1] = item end
  end
  return out
end

-- CodeAct is the DEFAULT (operator 17/11: "codeact is really good, make it default"): with the switch
-- unset the run block is the only way to act (`only`). The JSON `codemode` tool call is the opt-out:
-- WASM_AGENT_RAW_CODE=codemode (or off / 0 / false / no).
M.DEFAULT = "only"
local OFF = { codemode = true, off = true, ["0"] = true, ["false"] = true, no = true }
function M.mode()
  local value = tostring(host.getenv("WASM_AGENT_RAW_CODE") or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return M.DEFAULT end
  if OFF[value] then return nil end
  if value == "1" or value == "on" or value == "true" then return "on" end
  if value == "stop" then return "stop" end
  if value == "first" then return "first" end
  -- Add the mode to the *parser*, not only to the helpers: an unknown value returns nil, and nil means
  -- "off" everywhere downstream — a mode the parser does not know silently restores the default (17/11:
  -- `only` was set, `mode()` said nil, codemode was declared again and the model kept sending JSON calls).
  if value == "only" then return "only" end
  return nil
end

-- Active only where a codemode call could have run: the switch is on and code mode is enabled.
function M.active(policy)
  return M.mode() ~= nil and type(policy) == "table" and policy.enabled == true
end

-- Raw first: the run block is the way of working, codemode is not declared, history renders as text.
function M.first(policy)
  local mode = M.mode()
  return M.active(policy) and (mode == "first" or mode == "only")
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

-- An opening fence: 3+ backticks or 3+ tildes, indented at most three spaces, info string free of its own
-- fence character. CommonMark reads both and a model writes both: measured on HEAD (18/11) a `~~~js run
-- block never ran and the turn ended with it as the answer (scripts/test-codeact-default.lua).
local function fence(line, opening)
  local indent, mark, info = line:match('^( ? ? ?)([`~]+)(.*)$')
  if not mark then return nil end
  local char = mark:sub(1, 1)
  if mark:gsub(char, '') ~= '' or #mark < 3 then return nil end
  if opening then
    -- An info string carries no fence character of its own; a bare fence line opens a block with an empty
    -- info string (not a run block), so both cases keep the info exactly as written.
    if info:find(char, 1, true) then return nil end
    return char, #mark, info
  end
  if info:match('%S') then return nil end -- a closing fence line holds nothing but the fence
  return char, #mark, info
end

-- A fence of either character: what a reply must hold before it is worth parsing.
local function has_fence(text)
  return text:find('```', 1, true) ~= nil or text:find('~~~', 1, true) ~= nil
end

-- Fenced blocks, CommonMark-style: an opening fence of 3+ backticks or 3+ tildes (indented at most three
-- no backtick in its info string) closes at a line of at least as many backticks and nothing else.
-- A fence inside another block is that block's text. An unclosed block runs to the end.
function M.parse(text)
  local blocks, lines, open = {}, lines_of(tostring(text or "")), nil
  for index, line in ipairs(lines) do
    if open then
      local char, ticks = fence(line.text, false)
      if char == open.char and ticks >= open.ticks then
        open.close = index
        blocks[#blocks + 1] = open
        open = nil
      end
    else
      local char, ticks, info = fence(line.text, true)
      if char then
        open = { open = index, char = char, ticks = ticks, run = is_run(info) }
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
-- `only` mode: an untagged ```js / ```javascript fence becomes a run block, line by line (a pattern over
-- the whole text is easy to get subtly wrong, and this is two comparisons per line).
function M.retag(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local ticks, info = line:match("^( ? ? ?[`~]+)(.*)$")
    if ticks then
      local tag = tostring(info or ""):gsub("%s+$", "")
      if tag == "js" or tag == "javascript" then line = ticks .. "js run" end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

-- A run block the parser did not turn into a call is still an action the model asked for. Returns the
-- first one it can see ({line, text, reason}) so the loop can fail the turn by name instead of recording
-- the block as the answer (18/11: a 4-space indented block ended the turn with `0 tools` and rc 0).
function M.unexecuted(text, mode)
  local lines = lines_of(tostring(text or ''))
  for index, line in ipairs(lines) do
    local indent, mark, info = line.text:match('^([ \t]*)([`~]+)(.*)$')
    if mark then
      local char = mark:sub(1, 1)
      local tag = tostring(info or ''):lower():gsub('%s+$', '')
      local intended = mark == string.rep(char, #mark) and #mark >= 3
        and (tag == 'js run' or tag == 'javascript run' or (mode == 'only' and (tag == 'js' or tag == 'javascript')))
      if intended then
        local why = #indent > 3
          and string.format('it is indented %d spaces, so it is an indented code block and not a fence', #indent)
          or 'it is inside another block, or its fence never closes'
        return { line = index, text = line.text, reason = string.format(
          'the %sjs run block at line %d did not run: %s; write it at the start of a line, as %sjs run ... %s',
          string.rep(char, 3), index, why, string.rep(char, 3), string.rep(char, 3)) }
      end
    end
  end
  return nil
end

-- A tool call the model wrote as TEXT, in its own training format, because the request declared no tool
-- for it (`first`/`only` hide codemode). Measured 17/11 on work (sessions b08de0ed, 02d9236e): DeepSeek
-- wrote `<｜DSML｜invoke name="js">…code…` and `<｜DSML｜invoke name="bash">` instead of a run block; the
-- reply had no fence, so it was taken as the ANSWER and the turn ended after one step with nothing run.
-- The action was clear, so it runs: a code-ish name (js/run/codemode/…) is the script, any other name is
-- the one-line script `return await tools.<name>(<args>)` (one pathway, same dispatch).
-- Formats read: DeepSeek DSML (`<｜DSML｜invoke name=…>` + `<｜DSML｜parameter name=… string="true">`),
-- and Hermes/Qwen `<tool_call>{"name":…,"arguments":{…}}</tool_call>`.
local CODE_NAMES = { js = true, javascript = true, run = true, code = true, script = true, codemode = true,
  run_js = true, js_run = true, javascript_run = true, execute = true, execute_code = true, python = false }
local CODE_PARAMS = { "code", "script", "source", "js", "program" }

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function script_for(name, args, body)
  name = trim(name)
  if CODE_NAMES[name:lower()] then
    if type(args) == "table" then
      for _, key in ipairs(CODE_PARAMS) do
        if type(args[key]) == "string" then return args[key] end
      end
      local only_value, count = nil, 0
      for _, value in pairs(args) do count = count + 1 only_value = value end
      if count == 1 and type(only_value) == "string" then return only_value end
    end
    local text = trim(body)
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.code) == "string" then return decoded.code end
    -- a fence inside the call body is the code it wraps
    local fenced = text:match("^```[%w ]*\n(.-)\n?```$")
    return fenced or text
  end
  if type(args) ~= "table" then
    local ok, decoded = pcall(json.decode, trim(body))
    args = (ok and type(decoded) == "table") and decoded or {}
  end
  local target = name:match("^[%a_][%w_]*$") and ("tools." .. name) or ("tools[" .. json.encode(name) .. "]")
  local encoded = next(args) == nil and "" or json.encode(args)
  return "return await " .. target .. "(" .. encoded .. ");"
end

-- Returns { start = <byte where the markup begins>, calls = { {name=, code=} }, format = } or nil.
-- `unparsed = true` when the markup is there but no call could be read from it.
function M.native_calls(text)
  text = tostring(text or "")
  local plain = text:gsub("\239\189\156", "|") -- U+FF5C FULLWIDTH VERTICAL LINE, DeepSeek's token bar
  -- DSML: normalise `< | DSML | name` / `</ | DSML | name` to `<DSML:name` / `</DSML:name`.
  local norm = plain:gsub("<%s*(/?)%s*|%s*DSML%s*|%s*", "<%1DSML:")
  local dsml_at = norm:find("<DSML:", 1, true)
  if dsml_at then
    -- `start` must index the ORIGINAL text: count the bytes before the first marker there.
    local start = text:find("<%s*\239\189\156%s*DSML") or text:find("<%s*|%s*DSML") or 1
    local calls = {}
    local rest = norm:sub(dsml_at)
    for name, body in rest:gmatch('<DSML:invoke%s+name%s*=%s*"([^"]*)"%s*>(.-)</DSML:invoke>') do
      calls[#calls + 1] = { name = name, body = body }
    end
    if #calls == 0 then
      -- a reply cut (or a model that never closed the invoke): take the body to the end
      local name, body = rest:match('<DSML:invoke%s+name%s*=%s*"([^"]*)"%s*>(.*)$')
      if name then calls[1] = { name = name, body = body:gsub("</?DSML:[%w_]*>%s*$", "") } end
    end
    local out = {}
    for _, call in ipairs(calls) do
      local args, any = {}, false
      for pname, attrs, value in call.body:gmatch('<DSML:parameter%s+name%s*=%s*"([^"]*)"([^>]*)>(.-)</DSML:parameter>') do
        any = true
        if attrs:find('string%s*=%s*"true"') then
          args[pname] = value
        else
          local ok, decoded = pcall(json.decode, trim(value))
          if ok and decoded ~= nil then args[pname] = decoded else args[pname] = value end
        end
      end
      -- No parameter element: the body IS the value (observed: code directly inside invoke, then a
      -- stray `</DSML:parameter>`). Strip every DSML tag left in it.
      local body = any and "" or call.body:gsub("</?DSML:[^>]*>", "")
      out[#out + 1] = { name = call.name, code = script_for(call.name, any and args or nil, body) }
    end
    return { start = start, calls = out, format = "DSML", unparsed = #out == 0 or nil }
  end
  local tc_at = text:find("<tool_call>", 1, true)
  if tc_at then
    local out = {}
    for body in (text:sub(tc_at) .. "</tool_call>"):gmatch("<tool_call>(.-)</tool_call>") do
      local ok, decoded = pcall(json.decode, trim(body))
      if ok and type(decoded) == "table" and type(decoded.name) == "string" then
        local args = decoded.arguments or decoded.parameters or {}
        if type(args) == "string" then
          local ok2, d2 = pcall(json.decode, args)
          args = ok2 and type(d2) == "table" and d2 or { code = args }
        end
        out[#out + 1] = { name = decoded.name, code = script_for(decoded.name, args, "") }
      end
    end
    return { start = tc_at, calls = out, format = "tool_call", unparsed = #out == 0 or nil }
  end
  return nil
end

-- The native-markup path of `take`: the calls run as raw-channel codemode calls; the text before the
-- markup stays as the step's thought.
local function take_native(result, found)
  local content = result.content or ""
  local incomplete = result.stream_complete == false or result.finish_reason == "length"
  local calls = {}
  for _, call in ipairs(result.tool_calls or {}) do calls[#calls + 1] = call end
  local first
  local items = found.calls
  if #items == 0 then items = { { name = "", code = "" } } end
  for _, item in ipairs(items) do
    local id = "call_raw_" .. (host.uuid():gsub("-", ""))
    first = first or { id = id, blocks = #items, bytes = #item.code, notes = {}, native = found.format }
    calls[#calls + 1] = { id = id, type = "function", ["function"] = { name = "codemode", arguments = json.encode({ code = item.code }) } }
  end
  result.tool_calls = calls
  if incomplete then first.incomplete = true return first end
  if found.unparsed then
    first.refusal = refusal("raw_code_markup",
      "your message had " .. found.format .. " tool-call markup but no call could be read from it, so nothing ran",
      "end your message with one ```js run block; inside it every tool is tools.<name>(args)")
  else
    first.notes[#first.notes + 1] = "your " .. found.format .. " call markup ran as a script; a ```js run block is the native form here"
  end
  result.content = (content:sub(1, found.start - 1):gsub("%s+$", ""))
  if result.finish_reason == "stop" or result.finish_reason == nil then
    result.raw_finish_reason = result.finish_reason
    result.finish_reason = "tool_calls"
  end
  return first
end

function M.take(result, stop_sent)
  local content = result.content or ""
  -- Call markup in the text, and no real tool call: in `first`/`only` the model had nothing declared to
  -- call with, so its own format leaked into the text. A run block, if any, still wins below.
  local native = (#(result.tool_calls or {}) == 0) and M.native_calls(content) or nil
  if native and not has_fence(content:sub(1, native.start - 1)) then
    return take_native(result, native)
  end
  if not has_fence(content) then return nil end
  -- `only` mode: code is the *only* way to act, so an untagged ```js fence is the action, not a sample.
  -- Measured 17/11: told "end your message with one ```js run block", the model wrote ```js — a sample by
  -- the harness's rule, so nothing ran and no tool was left to fall back to. The tag is honoured as
  -- written in `first` mode, where a plain code block can still be an answer.
  if M.mode() == "only" then content = M.retag(content) end
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
