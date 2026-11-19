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
--   - every run block runs, in order (19/11, #D): with several, each one runs and each result says which
--     block it answers ("run block 2 of 3"); the batch stops at the first block that fails;
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
M.FIRST_GUIDANCE = "Work in code: end your message with one ```js run block (nothing after its closing fence: the result replaces it); it runs as one script in which every tool is `tools.<name>(args)`, and what it returns comes back to you. A message without a run block is your answer. "

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
  -- `only` empties the declared surface because the run block is the one way to act. On a node whose
  -- transport is a NATIVE CALL that reasoning is inverted: emptying the surface would remove the very
  -- tool the model is told to call (review MUST 1). So `only` yields to a tool_call transport, and the
  -- transport is read from the same decision the guidance comes from - profile first, then the named
  -- provider default - never from a model name.
  local function native_transport()
    local ok, lib = pcall(dofile, "lua/core/model_profile.lua")
    if not ok or type(lib) ~= "table" then return false end
    local provider_ok, provider_lib = pcall(dofile, "lua/core/provider.lua")
    if not provider_ok then return false end
    local settings_ok, settings = pcall(provider_lib.settings)
    if not settings_ok or type(settings) ~= "table" then return false end
    local profile = lib.read(settings.model)
    if type(profile) == "table" then
      local conform_ok, conform = pcall(dofile, "lua/core/conform.lua")
      if conform_ok and type(conform) == "table" then
        local decision = conform.decide(profile)
        if decision and decision.transport then return decision.transport == lib.TOOL_CALL end
      end
    end
    return lib.builtin_transport and lib.builtin_transport(settings.provider) == lib.TOOL_CALL
  end
  local active = policy == nil and M.mode() == "only" or (M.active(policy) and M.mode() == "only")
  if not active then return false end
  return not native_transport()
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
  -- The tagged arms of the A/B (next-round.md, 19/11 ~17:10). They are modes here for the one
  -- reason every other mode is: the parser below must know them, or an unknown value returns nil
  -- and nil means "off" - which is exactly how E2/E3 ended in one round with the block never read.
  if value == "e2" or value == "e3" then return value end
  -- The native transports (review MUST 6). They are modes here for one reason only: mode() is what
  -- tells the loop whether the raw channel is on at all, and a native turn still needs the LEAK
  -- SAFETY NET (below) - a model that writes <bash>{}<bash> as plain text instead of calling the run
  -- tool must earn ONE named continue, never a silent ending. An unknown value returns nil, and nil
  -- means off, so these two have to be named or the net never runs.
  if value == "native" or value == "bash" then return value end
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
  local mode = M.mode()
  -- The tagged arms stop at their own closer (next-round.md 19/11 ~15:50): the harness supplies the
  -- end of the block, so anything the model writes after it is cut rather than read as an action.
  if (mode == "e2" or mode == "e3") and M.active(policy) then return { "</codeact>" } end
  if M.active(policy) and mode == "stop" then return { M.STOP } end
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

-- The fence tag, read the way a model writes it. The tag is the language "js" (or "javascript", any
-- case) followed by the word "run", and three other spellings mean the same thing (#51/C):
--   the tag followed by code on the same fence line - that code is line 1 of the script;
--   any run of spaces or tabs between the language and the word run;
--   "javascript" instead of "js", and the tag in any letter case.
-- Measured 19/11 (mission logs, docs/missions/reports/thinking-block.md): a model wrote its tag and its
-- first statement on one fence line, this parser read the whole message as prose, and the step ended with
-- its action as text. Returns the code that shared the fence line ("" when the line held only the tag),
-- or nil when the fence is not a run block at all.
local function run_tag(info)
  local text = tostring(info or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local lang, rest = text:match("^(%a+)%s+(.*)$")
  if not lang then return nil end
  lang = lang:lower()
  if lang ~= "js" and lang ~= "javascript" then return nil end
  rest = rest:gsub("^%s+", "")
  if rest == "run" then return "" end
  local inline = rest:match("^run%s+(.-)%s*$")
  if inline and inline ~= "" then return inline end
  return nil
end

local function is_run(info) return run_tag(info) ~= nil end

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
-- Which CodeAct transport this node offers, and the guidance that goes with it (docs/AGENT-SEAT.md,
-- principles 2 and 7). The choice comes from the model PROFILE the conformance suite stored, never from
-- a model name: a profile is a measurement, and a name is a guess.
--
-- With no profile the default is conservative and says so once: a model that can call tools is offered
-- the run tool (a native call needs no fence closed), and one that cannot is offered the block.
M.TRANSPORT_NOTICE_SHOWN = false

-- `supports_tools` is whether this turn can declare tools at all - what the model can actually call.
-- Returns the transport ("tool_call" or "block"), where the choice came from, and the one-line notice
-- when it came from the default rather than from a measurement.
function M.transport_for(model, supports_tools)
  local ok, profile_lib = pcall(dofile, "lua/core/model_profile.lua")
  if ok and type(profile_lib) == "table" then
    local profile = profile_lib.read(model)
    if type(profile) == "table" then
      local conform_ok, conform = pcall(dofile, "lua/core/conform.lua")
      if conform_ok and type(conform) == "table" then
        local decision = conform.decide(profile)
        if decision and decision.transport then
          return decision.transport, "profile", nil
        end
      end
    end
  end
  -- A NAMED DEFAULT before the conservative fallback (review MUST 1): the provider decides, because
  -- every model behind it speaks one action channel. Keyed by provider id, never by model name.
  local provider_ok, provider_lib = pcall(dofile, "lua/core/provider.lua")
  if ok and type(profile_lib) == "table" and provider_ok then
    local settings_ok, settings = pcall(provider_lib.settings)
    local builtin = settings_ok and type(settings) == "table"
      and profile_lib.builtin_transport and profile_lib.builtin_transport(settings.provider)
    if builtin and supports_tools then return builtin, "builtin", nil end
  end
  local transport = supports_tools and "tool_call" or "block"
  local notice = string.format(
    "conform: no profile for %s, using the conservative %s transport; run `wa conform %s` to measure it",
    tostring(model or "this model"), transport, tostring(model or "this model"))
  return transport, "default", notice
end

-- The guidance sentence that matches a transport. A model offered the run tool is told about the run
-- tool; one offered the block is told about the block. Saying both is what made a measured model answer
-- a choice it did not have (the 17/11 offer, M.take).
function M.guidance_for(transport)
  if transport == "tool_call" then
    return "Work in code: call the run tool with `code` - it runs as one script in which every tool is "
      .. "`tools.<name>(args)`, and its result comes back to you. Use `raw` to carry a file body or a "
      .. "patch exactly. A message with no tool call is your answer. " .. M.BATCHING
  end
  return M.FIRST_GUIDANCE .. " " .. M.BATCHING
end

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
        open = { open = index, char = char, ticks = ticks, info = info, inline = run_tag(info), run = is_run(info) }
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
-- the whole text is easy to get subtly wrong, and this is two comparisons per line). Only where a codemode
-- call could actually run - see `M.take`, which is the only caller.
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

-- A fence inside a list item: CommonMark lets a fenced block sit up to three spaces inside its container, so
-- a fence at column 4 or more is still a real code block when a list item opens at or before that column.
-- Returns that item's content column, or nil when the fence is not inside one. The parser cannot answer this
-- (it does not track containers), so the one reader that has to tell "the model's prose" from "the model's
-- action" answers it here.
local function list_content_column(lines, index)
  for position = index - 1, 1, -1 do
    local text = lines[position].text
    if text:find('%S') then
      local lead, body = text:match('^(%s*)(%S.*)$')
      local marker, spaces = body:match('^([-*+])( +)')
      if not marker then marker, spaces = body:match('^(%d+[.)])( +)') end
      if marker then return #lead + #marker + #spaces end
      if #lead < 4 then return nil end -- a paragraph (or a shallower continuation): no list item opens here
    end
  end
  return nil
end

-- A run block the parser did not turn into a call is still an action the model asked for - if the reply meant
-- it as one. Returns the first such block ({line, text, reason}) so the loop can fail the turn by name instead
-- of recording the block as the answer (18/11: a 4-space indented block ended the turn with `0 tools` and
-- rc 0). `policy` is the codemode policy, exactly as `M.take` gets it: an untagged ```js is only an action
-- where code mode could run it.
--
-- Three shapes are the model's TEXT, and failing an answer over them is worse than the miss this exists for
-- (review of 18/11). They were all failures, because every line was scanned on its own:
--   - a fence inside a block the parser DID read: a ```js run example inside a ````md block is that block's
--     content, and `M.parse` already says so - so the answer is decided by `M.parse`, not by a line scan;
--   - a fence inside a list item (`list_content_column`): valid CommonMark, a documented sample;
--   - a plain ```js in an answer on a node whose code mode is OFF: `only` is the default mode even there, but
--     nothing could run the block, so it was never an action (`M.only(policy)`, not `M.mode()`).
-- What is left - a fence the parser could have seen and did not - is the miss this was written for.
function M.unexecuted(text, policy)
  text = tostring(text or '')
  local lines = lines_of(text)
  local inside = {}
  for _, block in ipairs((M.parse(text))) do
    for index = block.open, block.close or #lines do inside[index] = true end
  end
  local only = M.only(policy)
  for index, line in ipairs(lines) do
    if not inside[index] then
      local indent, mark, info = line.text:match('^([ \t]*)([`~]+)(.*)$')
      if mark then
        local char = mark:sub(1, 1)
        local tag = tostring(info or ''):lower():gsub('%s+$', '')
        local intended = mark == string.rep(char, #mark) and #mark >= 3
          and (run_tag(tag) ~= nil or (only and (tag == 'js' or tag == 'javascript')))
        local column = intended and #indent > 3 and list_content_column(lines, index) or nil
        if intended and not (column and #indent >= column) then
          local why = #indent > 3
            and string.format('it is indented %d spaces, so it is an indented code block and not a fence', #indent)
            or 'it is inside another block, or its fence never closes'
          return { line = index, text = line.text, reason = string.format(
            'the %sjs run block at line %d did not run: %s; write it at the start of a line, as %sjs run ... %s',
            string.rep(char, 3), index, why, string.rep(char, 3), string.rep(char, 3)) }
        end
      end
    end
  end
  return nil
end

-- PHASE 0 verdict (evidence and verdict: docs/missions/reports/thinking-block.md). The run block arrives
-- in the provider's REASONING field, not in its content, and the first version of the harness read only
-- the answer, so the turn failed "reasoning is not an answer" with the action it was built to run never
-- run. Nothing below executes the thinking: the reasoning is the model's own, and a script found there is
-- never this node's action channel. What this decides is the SENTENCE - which shape of "wrote it in the
-- wrong field" the model wrote - so the one continue it is given names the one thing to change.
--
-- Only the LAST block matters, and only when it ENDS the thinking (nothing but whitespace after it). A
-- block the thinking went on from is the model reasoning ABOUT code - a sketch it then rejected - and
-- naming that as the lost action would be a wrong diagnosis.
--   run        a complete js run block ends the thinking: the action, in the wrong field;
--   cut_run    the thinking ended inside a js run block, so those bytes are not the script it meant;
--   plain_js   the thinking ends with a js or javascript block never tagged run: a sample by this
--              node's own rule (the header of this file), so a tag to add rather than a script to send;
--   nil        no block, or a last block that is none of these: the step reasoned and stopped (#22).
M.IN_THINKING_SHAPES = { run = true, cut_run = true, plain_js = true }
local PLAIN_JS = { js = true, javascript = true }
local TICK = string.rep(string.char(96), 3)

function M.in_thinking(reasoning)
  local text = tostring(reasoning or "")
  if not has_fence(text) then return nil end
  local blocks, lines = M.parse(text)
  local last = blocks[#blocks]
  if not last then return nil end
  local closed = last.close ~= nil
  -- Nothing but whitespace after the block. An unclosed block already runs to the end of the text.
  local last_line = lines[last.close or #lines]
  if text:sub(last_line.finish + 1):find("%S") then return nil end
  local code_lines = {}
  for index = last.open + 1, closed and last.close - 1 or #lines do
    code_lines[#code_lines + 1] = lines[index].text
  end
  if closed and last.inline and last.inline ~= "" then table.insert(code_lines, 1, last.inline) end
  local tag = tostring(last.info or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local found = { line = last.open, bytes = #table.concat(code_lines, "\n"), closed = closed }
  if last.run then
    found.shape = closed and "run" or "cut_run"
  elseif PLAIN_JS[tag] then
    found.shape = "plain_js"
  else
    return nil
  end
  return found
end

-- How many times in a row the harness asks for the action in the answer before the turn fails by name.
-- One: the measured failure is a model writing in the wrong field, and naming it once is a diagnosis; a
-- second consecutive one is a model that cannot follow it, and the run must not end rc=0 with nothing run.
M.THINKING_CONTINUES = 1

-- Model-facing (operator-reviewed; verbatim in the report). One sentence naming the one thing to change,
-- then where to write it. Never "retry": the model did the work, in the wrong field.
function M.thinking_notice(found)
  local shape = type(found) == "table" and tostring(found.shape) or ""
  local reason
  if shape == "cut_run" then
    reason = "your " .. TICK .. "js run block was in your thinking, not in your answer, and it was cut off "
      .. "before its closing " .. TICK .. " line, so nothing ran"
  elseif shape == "plain_js" then
    reason = "the " .. TICK .. "js block you wrote was in your thinking, not in your answer, and it was "
      .. "tagged js rather than js run, so nothing ran"
  else
    reason = "the run block you wrote was in your thinking, not in your answer, so nothing ran"
  end
  return "[Harness notice] This message had no answer: " .. reason
    .. ". Write it in your ANSWER, as one " .. TICK .. "js run block that ends with a " .. TICK .. " line."
end

-- Model-facing. The step reasoned and stopped with nothing to run (#22).
function M.reasoning_only_notice()
  return "[Harness notice] This message had no answer: you reasoned and then stopped, so nothing ran. "
    .. "Write your next step in your ANSWER: the script as one " .. TICK .. "js run block, or the answer "
    .. "itself and why."
end

-- The name the run fails with when the block is still only in the thinking after the harness asked for it
-- once. Never rc=0 with the action unexecuted.
function M.thinking_failure(found)
  local shape = type(found) == "table" and tostring(found.shape) or ""
  local what = shape == "cut_run" and "a " .. TICK .. "js run block that was never closed"
    or shape == "plain_js" and "a " .. TICK .. "js block that is not tagged js run"
    or "a run block"
  return "run_block_in_thinking: " .. what .. " is in the model's reasoning, not in its answer, and the "
    .. "harness asked for it in the answer once already; nothing ran, so the turn is failed rather than "
    .. "finished without its action"
end

function M.reasoning_only_failure()
  return "reasoning_only: the step reasoned and returned no answer and no action, and the harness asked "
    .. "for an answer once already; nothing ran, so the turn is failed rather than finished without it"
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

-- Tool-call markup written as TEXT: the leftover, when a call could not be read from it.
--
-- The formats this module can RUN are read first (M.native_calls, above) and become calls. What this names
-- is the rest: the model wrote its own call format into the answer and no call was formed from it, so
-- nothing ran and the step is not an answer. Measured 19/11: `<ds_tool>{"command":...}</ds_tool>` in the
-- answer at land-routing 00:59 (the run ended there, 19 rounds, no action) and a leftover
-- `}}</parameter>` at thinking-block 00:41 (the run ended on "Let me do these in parallel.}}</parameter>").
--
-- An allow-list, not a block-list (the formats this project has actually seen a model write): a marker that
-- is not here is prose, and prose is an answer. The list is deliberately short, because a false positive
-- costs the model a step.
M.MARKUP_MARKERS = {
  "<ds_tool>", "</ds_tool>", "<ds_safety>", "</ds_safety>", "<ds_invoke>", "</ds_invoke>",
  "</parameter>", "<tool_call>", "</tool_call>", "<function_call>", "<function_calls>",
  "<antml:invoke", "</antml:invoke>", "</invoke>", "<|python_tag|>",

}

-- Returns { marker = <what was found> } or nil. Pure: no host, no state.
-- The shapes the review named in MUST 6 that this list did not carry: a model writing its trained
-- call format as text (<bash>...</bash>, <run>...</run>, <invoke name=...>...</invoke>).
--
-- They are checked as PAIRS, not as bare openers, and that is deliberate: this detector runs on
-- every answer the loop reads, so a sentence that merely MENTIONS a tag - "use <bash> to run it" -
-- must stay an answer. A pair that opens and closes is a call the model meant; a lone word in prose
-- is not. The list stays an allow-list: a shape not named here is prose.
M.MARKUP_PAIRS = {
  { "<bash>", "</bash>" },
  { "<run>", "</run>" },
  { "<invoke ", "</invoke>" },
}

function M.markup_in_text(text)
  local raw = tostring(text or "")
  if raw == "" then return nil end
  for _, found in ipairs(M.MARKUP_MARKERS) do
    if raw:find(found, 1, true) then return { marker = found } end
  end
  for _, pair in ipairs(M.MARKUP_PAIRS) do
    local opens = raw:find(pair[1], 1, true)
    if opens and raw:find(pair[2], opens + #pair[1], true) then
      return { marker = pair[1]:gsub(" $", "") }
    end
  end
  -- DeepSeek's token bar written with either character (the two spellings M.native_calls normalises).
  if raw:find("\239\189\156", 1, true) or raw:find("|DSML|", 1, true) then return { marker = "<|DSML|>" } end
  return nil
end

-- The SECOND transport (docs/AGENT-SEAT.md, principle 2): a native tool call run({code, raw?}).
--
-- A fenced run block and a run call are the same action, so this adds no pathway: it turns the
-- arguments into the call M.take forms for a block, and that call dispatches as codemode. What the
-- model chooses is only the transport; the results come back the same way.
--
-- raw carries named raw blocks - a file body, a patch - as an object, and every value is emitted as
-- a JSON string literal, so the bytes reach the script exactly as the model wrote them and are never
-- escaped *inside* the code (principle 4). One JSON encode is lossless and reversible; hand-quoting
-- is not. The names are identifiers the script reads, so only identifier-shaped names are accepted:
-- a name that is not one would silently become a different variable.
-- The batching instruction (batch-spec.md, 19/11): measured evidence was 1.0 tool calls per round
-- in EVERY run of the task A/B, so the model was doing one small call at a time. The sentence is
-- the same text in all three places the model can read it, and a test pins it in each (the three
-- descriptions are built by different modules, so a copy that drifts is a real defect).
M.BATCHING = "One run(code) can do a whole step: read, search, edit and check in the same script, "
  .. "with Promise.all for the parts that do not depend on each other, and return only what you "
  .. "need to decide the next step. Prefer one script per step over many small calls."

local RAW_PREFIX = "__raw"

function M.run_tool_schema()
  return { name = "run", description = "Run one script, the same way a fenced js run block does: "
    .. "code is the script, and every tool inside it is tools.<name>(args). Use raw to carry file "
    .. "bodies or patches exactly, as an object keyed by the variable name the script should read "
    .. "(each value reaches the script byte for byte, never escaped into the code). " .. M.BATCHING,
    schema = { type = "object", properties = {
      code = { type = "string" },
      raw = { type = "object", additionalProperties = { type = "string" } },
    }, required = { "code" } } }
end

-- The run call as the codemode call it stands for, or nil and a model-facing refusal. Pure: no
-- host, no state - the caller dispatches what this returns.
function M.native_run(args)
  local args_type = type(args)
  if args_type == "string" then
    local ok, decoded = pcall(json.decode, args)
    args = ok and type(decoded) == "table" and decoded or { code = args }
  elseif args_type ~= "table" then
    args = {}
  end
  local code = args.code
  if type(code) ~= "string" or not code:find("%S") then
    return nil, { error = "run_needs_code", effect = "none",
      note = "the run call needs code: the script is the string it runs, exactly as a fenced run block is" }
  end
  local raw = args.raw
  if raw == nil then return { code = code } end
  if type(raw) ~= "table" then
    return nil, { error = "run_raw_not_object", effect = "none",
      note = "raw is an object of name -> text (one entry per raw block); it is not a string" }
  end
  local names = {}
  for name in pairs(raw) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
      return nil, { error = "run_raw_name", effect = "none",
        note = "a raw block name must be an identifier the script can read (letters, digits, _), "
          .. "because that name is the variable the bytes arrive in" }
    end
    if type(raw[name]) ~= "string" then
      return nil, { error = "run_raw_not_text", effect = "none", name = name,
        note = "raw block " .. name .. " is not text; raw blocks carry file bodies and patches, not values" }
    end
  end
  local literal = json.encode(raw)
  return { code = "const " .. RAW_PREFIX .. " = " .. literal .. ";\n" .. code, raw_blocks = names }
end

-- The native-markup path of `take`: the calls run as raw-channel codemode calls; the text before the
-- markup stays as the step's thought.
local function take_native(result, found)
  local content = result.content or ""
  local incomplete = result.stream_complete == false or result.finish_reason == "length"
  local calls = {}
  for _, call in ipairs(result.tool_calls or {}) do calls[#calls + 1] = call end
  local first, made = nil, {}
  local items = found.calls
  if #items == 0 then items = { { name = "", code = "" } } end
  for _, item in ipairs(items) do
    local id = "call_raw_" .. (host.uuid():gsub("-", ""))
    first = first or { id = id, blocks = #items, bytes = #item.code, notes = {}, native = found.format }
    made[#made + 1] = id
    calls[#calls + 1] = { id = id, type = "function", ["function"] = { name = "codemode", arguments = json.encode({ code = item.code }) } }
  end
  result.tool_calls = calls
  -- The lookup the loop uses, one entry per call this path formed (#D): the note is about the markup as
  -- a whole, so every call formed from it carries it. A call the MODEL sent keeps its own id and no entry.
  first.calls = {}
  for _, id in ipairs(made) do first.calls[id] = first end
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

function M.take(result, stop_sent, policy)
  local content = result.content or ""
  -- The tagged arms (E2/E3) are a different transport for the same action, so they enter through this
  -- same door and form the same codemode call. Their parser answers either an act (with its code), a
  -- named finish, or invalid_message_shape with the reason.
  local arm = dofile("lua/core/ab_arms.lua").current()
  if arm == "e2" or arm == "e3" then
    local tags = dofile("lua/core/arm_tag.lua")
    -- The provider's stop sequence removes the closing tag it stopped at, so a reply that DID close its
    -- block arrives here without the closer. `stop_sent` is the proof it was written: put it back, the
    -- same way the fence path restores a fence its stop sequence ate, so a closed block is not called
    -- unterminated.
    -- Only an OPEN block needs its closer put back. A reply that finished without acting (a
    -- <message> alone) has no block at all, and appending a closer to it manufactured an orphan
    -- closer that the parser then refused as text outside the tags (measured: round 4 of the E2 smoke).
    local opened = content:find("<codeact>", 1, true)
    local closed = content:find("</codeact>", 1, true)
    if stop_sent and opened and (not closed or closed < opened) then
      content = content .. "</codeact>"
    end
    local parsed = tags.parse(content, arm)
    if parsed.shape == "act" then
      local code = { code = parsed.code }
      local id = "call_raw_" .. (host.uuid():gsub("-", ""))
      local calls = {}
      for _, call in ipairs(result.tool_calls or {}) do calls[#calls + 1] = call end
      calls[#calls + 1] = { id = id, type = "function", ["function"] = { name = "codemode", arguments = json.encode(code) } }
      result.tool_calls = calls
      local entry = { id = id, index = 1, blocks = 1, bytes = #parsed.code, notes = {} }
      if parsed.message and parsed.message ~= "" then
        entry.notes[#entry.notes + 1] = "progress: " .. parsed.message
      end
      if parsed.dropped then
        entry.notes[#entry.notes + 1] = parsed.dropped_reason
      end
      result.content = (parsed.message or "")
      if result.finish_reason == "stop" or result.finish_reason == nil then
        result.raw_finish_reason = result.finish_reason
        result.finish_reason = "tool_calls"
      end
      entry.calls = { [id] = entry }
      return entry
    end
    if parsed.shape == "finish" then
      result.content = parsed.final_message or ""
      result.arm_final = true
      return nil
    end
    -- Neither shape: nothing runs, and the reason is named so the loop can continue once.
    return { invalid_message_shape = true, reason = parsed.reason, excerpt = parsed.excerpt }
  end
  -- Call markup in the text, and no real tool call: in `first`/`only` the model had nothing declared to
  -- call with, so its own format leaked into the text. A run block, if any, still wins below.
  -- The LEAK SAFETY NET for the native transports (review MUST 6). In native/bash mode the action is
  -- a tool call; a model that instead writes its trained call format as TEXT (<bash>, <invoke>,
  -- <tool_call>, DeepSeek's DSML bar) has done nothing, and the harness used to accept that text as
  -- the answer. The reader names it so the loop can ask once, by name; a second one fails the run.
  local mode_now = M.mode()
  if (mode_now == "native" or mode_now == "bash") and #(result.tool_calls or {}) == 0 then
    local leaked = M.markup_in_text(content)
    if leaked then
      return { leaked_markup = true, marker = leaked.marker, bytes = #content }
    end
  end
  local native = (#(result.tool_calls or {}) == 0) and M.native_calls(content) or nil
  if native and not has_fence(content:sub(1, native.start - 1)) then
    return take_native(result, native)
  end
  if not has_fence(content) then return nil end
  -- `only` mode: code is the *only* way to act, so an untagged ```js fence is the action, not a sample.
  -- Measured 17/11: told "end your message with one ```js run block", the model wrote ```js — a sample by
  -- the harness's rule, so nothing ran and no tool was left to fall back to. The tag is honoured as
  -- written in `first` mode, where a plain code block can still be an answer.
  --
  -- `M.only(policy)`, and NOT `M.mode() == "only"` (review of 18/11, item 1). `only` is the default mode on
  -- every node, including one whose code mode is OFF: there the retag turned every ordinary ```js sample in an
  -- answer into a codemode call, and the call was refused `codemode_not_enabled`. A block is re-tagged as the
  -- step's action only where a codemode call could run; everywhere else only a block the model itself tagged
  -- `js run` acts, as the rules above say.
  if M.only(policy) then content = M.retag(content) end
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
  -- Every run block runs, in order (#D, 19/11). A message that carries three blocks asked for three
  -- actions; running only the last one dropped two of them silently, and the model then re-issued work it
  -- had already written. The calls are formed in the order the model wrote them, so the tool loop
  -- dispatches them in that order, and each result comes back labelled "run block 2 of 3" (M.note). The
  -- loop stops that batch at the first block that fails and answers every later one "did not run"
  -- (lua/core/agent.lua, the raw batch): running on top of a failure is worse than not running.
  local calls, entries, order = {}, {}, {}
  for _, call in ipairs(result.tool_calls or {}) do calls[#calls + 1] = call end
  local first
  for index, run in ipairs(runs) do
    local code_lines = {}
    -- Code that shared the fence line is line 1 (#51/C): a fence tagged "js run" with a statement after it
    -- on the same line is a run block, and the script it asks for starts with what the model wrote there.
    if run.inline and run.inline ~= "" then code_lines[1] = run.inline end
    for line_index = run.open + 1, run.close and run.close - 1 or #lines do
      code_lines[#code_lines + 1] = lines[line_index].text
    end
    local code = table.concat(code_lines, "\n")
    local id = "call_raw_" .. (host.uuid():gsub("-", ""))
    calls[#calls + 1] = { id = id, type = "function", ["function"] = { name = "codemode",
      arguments = json.encode({ code = code }) } }
    local entry = { id = id, index = index, blocks = #runs, bytes = #code, notes = {} }
    first = first or entry
    entries[id] = entry
    order[#order + 1] = entry
    if incomplete then
      entry.incomplete = true
    elseif not run.close and not stopped then
      entry.refusal = refusal("raw_code_unterminated",
        "the ```js run block was never closed (the reply ended inside it), so none of it ran",
        "send the whole script again in one ```js run block that ends with a ``` line"
          .. (M.mode() == "first" and "" or ", or as a codemode call"))
    elseif not code:find("%S") then
      entry.refusal = refusal("raw_code_empty",
        "empty run block: the ```js run block had no code, so nothing ran",
        "put the script between the ```js run line and its closing ``` line")
    end
    -- Which block this result answers, whenever there is more than one: the labels are the order the
    -- results arrive in, so a model reading two results knows which script each one belongs to.
    if #runs > 1 then entry.notes[#entry.notes + 1] = string.format("run block %d of %d", index, #runs) end
  end
  result.tool_calls = calls
  if incomplete then return first end
  -- Only text AFTER the last block is dropped: the blocks before it are actions, and prose between two
  -- blocks is the model's own comment on them. Each result replaces its own block's text.
  local last_run = runs[#runs]
  local after = last_run.close and content:sub(lines[last_run.close].finish + 1) or ""
  if after:find("%S") then
    local entry = order[#order]
    entry.notes[#entry.notes + 1] = string.format(
      "the %d byte(s) you wrote after the last run block were dropped; this result replaces them", #after)
  end
  result.content = (content:sub(1, lines[runs[1].open].start - 1):gsub("%s+$", ""))
  if result.finish_reason == "stop" or result.finish_reason == nil then
    result.raw_finish_reason = result.finish_reason
    result.finish_reason = "tool_calls"
  end
  -- The lookup the loop uses: one entry per call it formed, keyed by the call id.
  first.calls = entries
  return first
end

-- The line a result carries for the model when the harness had something to say about its block.
-- `entry` is one block's entry (M.take returns them keyed by call id): with several blocks in one
-- message the first note is the label ("run block 2 of 3"), so a result says which script it answers.
function M.note(entry)
  if type(entry) ~= "table" or #(entry.notes or {}) == 0 then return nil end
  return "[raw code] " .. table.concat(entry.notes, "; ") .. "."
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
-- The tagged arms render their own history (next-round.md 19/11 ~15:50): the model's action was a
-- <codeact> block and the harness answered <result>...</result>, so a replay that showed a tool-call
-- pair would teach the model a shape its prompt forbids - and it then echoed <result> itself, which
-- the parser correctly refused. Byte for byte what the arm was told it would see.
function M.render_tag_history(messages)
  if type(messages) ~= "table" then return messages end
  local out, index = {}, 1
  while index <= #messages do
    local message = messages[index]
    local raws = {}
    if message.role == "assistant" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do
        if M.is_raw(call.id) then raws[#raws + 1] = call end
      end
    end
    if #raws == 0 then
      out[#out + 1] = message
      index = index + 1
    else
      local wanted = {}
      for _, call in ipairs(raws) do wanted[call.id] = true end
      local rendered = {}
      for key, value in pairs(message) do rendered[key] = value end
      -- The replay must be a shape the prompt ALLOWS. The stored content is the action's own
      -- <message> text, so it is wrapped back in its tags: a bare line followed by <codeact> taught
      -- the model to write text outside the tags, and the parser then refused it (measured: round 2
      -- failed with "text outside the tags" after a correct round 1).
      local said = type(message.content) == "string" and message.content or ""
      local text = said ~= "" and ("<message>" .. said .. "</message>") or ""
      for _, call in ipairs(raws) do
        local code = ""
        local ok, decoded = pcall(json.decode, (call["function"] or {}).arguments or "{}")
        if ok and type(decoded) == "table" then code = tostring(decoded.code or "") end
        text = text .. (text ~= "" and "\n" or "") .. "<codeact>\n" .. code .. "\n</codeact>"
      end
      rendered.content = text
      rendered.tool_calls = nil
      out[#out + 1] = rendered
      index = index + 1
      local results = {}
      while index <= #messages and messages[index].role == "tool" do
        local result = messages[index]
        if wanted[result.tool_call_id] then
          local content = type(result.content) == "string" and result.content or tostring(result.content or "")
          results[#results + 1] = content
        else
          out[#out + 1] = result
        end
        index = index + 1
      end
      if #results > 0 then
        out[#out + 1] = { role = "user", content = "<result>\n" .. table.concat(results, "\n") .. "\n</result>" }
      end
    end
  end
  return out
end

function M.render_history(messages)
  if type(messages) ~= "table" then return messages end
  local arm = dofile("lua/core/ab_arms.lua").current()
  if arm == "e2" or arm == "e3" then return M.render_tag_history(messages) end
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
