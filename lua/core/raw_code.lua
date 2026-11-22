-- The run tool, and the ONE path (Victor 21/11: erase the other paths and keep the one that is
-- proven).
--
-- What this module is now, and nothing else:
--   * the script a run({code, raw}) call builds: every raw block is bound as the variable its key
--     names AND the whole object is bound as `raw`, byte for byte, never escaped into the code;
--   * the ONE sentence the model is told about that tool (M.guidance_for), with the batching
--     instruction riding inside it;
--   * the leak safety net (end of this file): a model that writes its tool call, or a run block, as
--     plain TEXT gets ONE named continue that names the run tool, and a second consecutive one fails
--     the run BY NAME instead of ending the turn with nothing run.
--
-- WHAT IS GONE (change/one-run-path, Victor 21/11). The fenced js-run block was a second transport,
-- chosen by WASM_AGENT_RAW_CODE with the values only, first, stop, on/1/true, e2, e3, bash, native,
-- codemode, off/0/false/no. Those modes also narrowed the declared tool list (only, first), rendered
-- the history as text (first), carried a stop sequence (stop) and read A/B arms (e2, e3, bash -
-- lua/core/ab_arms.lua, deleted). Two transports are two things to get wrong; the measured cost of
-- the fenced one is named in the reports (a run block written in the model's THINKING 21 times in one
-- mission, 21/11; a live follow-up that failed after 46 rounds because the model would not stop
-- writing its call as text).
--
-- The switch is REFUSED BY NAME rather than ignored (M.switch_refusal). An unknown value read as
-- "off" is exactly how the removed doors kept coming back: only on 17/11, and
-- WASM_AGENT_RAW_CODE=codemode exported by the launchers until 21/11.
local json = dofile("lua/vendor/json.lua")
local M = {}

-- The batching instruction (batch-spec.md, 19/11): measured evidence was 1.0 tool calls per round in
-- EVERY run of the task A/B, so the model was doing one small call at a time. The sentence is the
-- same text in every place the model can read it, and a test pins it in each.
M.BATCHING = "One run(code) can do a whole step: read, search, edit and check in the same script, "
  .. "with Promise.all for the parts that do not depend on each other, and return only what you "
  .. "need to decide the next step. Prefer one script per step over many small calls."

-- Model-facing (operator-reviewed, verbatim). The ONE transport. These bytes are identical to the
-- sentence a native thread was already given, on purpose: the frozen prompt prefix of every thread
-- that already runs this way is what the cache compares (lua/core/prompt_cache.lua), and this branch
-- changes no prompt byte for them.
M.GUIDANCE = "Work in code: call the run tool with `code` - it runs as one script in which every tool is "
  .. "`tools.<name>(args)`, and its result comes back to you. Use `raw` to carry a file body or a "
  .. "patch exactly. A message with no tool call is your answer. " .. M.BATCHING

function M.guidance_for() return M.GUIDANCE end

local RAW_PREFIX = "__raw"

-- Names a raw block cannot take: each name becomes a `const` the script reads, so a JavaScript
-- reserved word would not compile, and tools, __raw or a built-in the script relies on would be
-- shadowed for the whole script. Refused by name instead of failing inside the sandbox.
local RAW_RESERVED = {}
for name in ([[break case catch class const continue debugger default delete do else enum export extends
  false finally for function if import in instanceof new null return super switch this throw true try typeof
  var void while with yield let static implements interface package private protected public await
  arguments eval undefined NaN Infinity tools __raw console JSON Promise Object Array String Number Boolean
  Math Date Error RegExp Map Set Symbol globalThis]]):gmatch("%S+") do RAW_RESERVED[name] = true end
-- raw is ALSO bound by native_run to the whole object, so a block NAMED raw would collide with that
-- binding and the script would not compile; it is refused by name like the words above (21/11).
RAW_RESERVED.raw=true

-- The tool as the provider sees it. The description is byte-identical to the one a native thread's
-- frozen tool list carries (the cache compares those bytes too); it still calls the script "the same
-- way a fenced js run block does" because that is what it says today, and rewording it is a prompt
-- change with its own cache miss - named in the mission report, not smuggled into this one.
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
-- host, no state - the caller dispatches what this returns. One pathway (docs/AGENT-SEAT.md,
-- principle 2): everything after this is the same code a codemode call takes.
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
  -- `raw` IS BOUND EVEN WHEN THE CALL HAS NONE (22/11). A script that reads raw.<name> in a call with no
  -- raw argument died with `ReferenceError: raw is not defined` - 7 of the failures measured on the two
  -- days before 22/11 - a message that names the transport instead of the block the script wanted. With an
  -- empty object the script compiles, the name reads `undefined`, and the failure is the one that names
  -- the key. The binding sits on the OPENING LINE of the block, not on a line of its own, so the line
  -- numbers in a compile error stay where they were (lua/core/codemode.lua's script_line maps the stack by
  -- the line the script's code starts on).
  -- The script keeps a block of its OWN, as in the call that has blocks (below): a script that declares its
  -- own `raw` (const raw = await tools.bash(...)) shadows this one instead of dying on a redeclaration.
  if raw == nil then return { code = "const raw = {}; {\n" .. code .. "\n}", raw_blocks = {} } end
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
    if RAW_RESERVED[name] then
      return nil, { error = "run_raw_name", effect = "none", name = name,
        note = "raw block " .. name .. " would shadow a JavaScript word or a name the script needs "
          .. "(tools, JSON, Promise...): pick another name" }
    end
    if type(raw[name]) ~= "string" then
      return nil, { error = "run_raw_not_text", effect = "none", name = name,
        note = "raw block " .. name .. " is not text; raw blocks carry file bodies and patches, not values" }
    end
  end
  local literal = json.encode(raw)
  -- Each block is ALSO its own variable, as the tool description promises ("keyed by the variable
  -- name the script should read"): only __raw was bound, so a script reading body died with
  -- ReferenceError (reported 20/11). The script runs in a block of its own, so a script that still
  -- writes `const body = __raw.body` declares an inner body instead of redeclaring the outer one.
  -- raw IS the whole object too, under the name the description uses: a model that wrote raw.patch in
  -- a run script died with ReferenceError: raw is not defined (20/11 and again 21/11). raw.patch and
  -- patch now read the same bytes.
  return { code = "const " .. RAW_PREFIX .. " = " .. literal .. ";\nconst raw = " .. RAW_PREFIX
      .. ";\nconst { " .. table.concat(names, ", ")
      .. " } = " .. RAW_PREFIX .. ";\n{\n" .. code .. "\n}", raw_blocks = names }
end

-- THE SWITCH IS GONE, AND SAYS SO (Victor 21/11). Every value the removed parser knew, and what door
-- it named: this table exists ONLY so the refusal can name the door the operator is still trying to
-- open. No value is honoured by this build.
M.SWITCH = "WASM_AGENT_RAW_CODE"
M.REMOVED_VALUES = {
  only = "the fenced run block as the only way to act",
  first = "the fenced run block as the way of working",
  stop = "the reply cut at a closing fence",
  ["1"] = "the fenced run block as an extra transport",
  on = "the fenced run block as an extra transport",
  ["true"] = "the fenced run block as an extra transport",
  e2 = "the A/B arm that acted through codeact tags",
  e3 = "the A/B arm that acted through codeact tags",
  bash = "the A/B arm that acted through a shell sentence",
  native = "the native run tool, which is the only path left and needs no switch",
  codemode = "the JSON codemode tool call as the single code door",
  off = "no code channel at all",
  ["0"] = "no code channel at all",
  ["false"] = "no code channel at all",
  no = "no code channel at all",
}

-- nil when the node sets no switch (the ordinary case), or {name=, value=, text=} when it does.
-- EVERY value is refused, known or not: the switch itself is gone, so a value is either a mode this
-- build removed or a word no build ever had - and an unknown value read as "off" is the bug this
-- closes, not a default worth keeping.
-- WHERE THE VALUE CAME FROM (review r1, item 4). The host loads `<config>/env` at start WITHOUT
-- overwriting the real environment (rust/wa-host/src/main.rs, `load_env_file`), so a launcher's
-- `unset` cannot win on a node that keeps the line in that file - and a message that only says "remove
-- it from the environment" sends the operator to the wrong place. This reads the same file the host
-- reads and names it by path when the key is in it.
function M.switch_source()
  local found = nil
  pcall(function()
    local file = dofile('lua/core/paths.lua').config_file()
    local text = host.read_file(file)
    if type(text) ~= 'string' then return end
    for line in text:gmatch('[^\n]+') do
      if line:match('^%s*' .. M.SWITCH .. '%s*=') then found = file break end
    end
  end)
  return found
end

function M.switch_refusal()
  local value = tostring(host.getenv(M.SWITCH) or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return nil end
  local source = M.switch_source()
  local known = M.REMOVED_VALUES[value:lower()]
  local why = known
    and ("that value named " .. known .. ", and this build has one path: the run tool")
    or "no build ever had that value"
  return { name = "run_switch_removed", value = value,
    text = "run_switch_removed: " .. M.SWITCH .. "=" .. value .. " is gone: " .. why .. ". "
      .. "run(code=...) is the only way to act (Victor 21/11), so there is no mode to set and no other "
      .. "path to fall back to. Remove " .. M.SWITCH .. " from this node's environment - and from any "
      .. "launcher, unit or script that exports it."
      .. (source
        and (" It is in " .. source .. ": edit that file (the host reads it at start and a launcher's "
          .. "`unset` does not win over it), then restart the node.")
        or "")
      .. " This run is refused by name and exits non-zero rather than acting through a path this build "
      .. "does not have.", source = source }
end

-- THE PROVIDER DOOR: native tool calls, or a refusal by name - never a quiet move to another path
-- (Victor 21/11). The row is the PROVIDER's (model_profile.builtin_transport), never a model name;
-- a measured profile that says TOOL_CALL opens the same door, which is what "measure it with wa
-- conform" means. Anything else - no row, a row that is not a tool-call transport, no measurement -
-- is refused here and named, at start, so a node cannot end up acting through a door it does not
-- have.
function M.transport_refusal(provider_id, model)
  local ok, profile_lib = pcall(dofile, "lua/core/model_profile.lua")
  if ok and type(profile_lib) == "table" and type(profile_lib.builtin_transport) == "function" then
    if profile_lib.builtin_transport(provider_id) == profile_lib.TOOL_CALL then return nil end
    local read = type(profile_lib.read) == "function" and profile_lib.read(model) or nil
    if type(read) == "table" then
      local cok, conform = pcall(dofile, "lua/core/conform.lua")
      if cok and type(conform) == "table" and type(conform.decide) == "function" then
        local decision = conform.decide(read)
        if type(decision) == "table" and decision.transport == profile_lib.TOOL_CALL then return nil end
      end
    end
  end
  return { name = "provider_cannot_call_tools",
    text = "provider_cannot_call_tools: this provider cannot call tools; add a row or measure it with "
      .. "`wa conform " .. tostring(model or "<model>") .. "` and INSTALL the profile it prints (it measures "
      .. "in a scratch home, so its file is not the one this node reads). run(code=...) is the only way to "
      .. "act on this node, so a provider that cannot answer with a tool call has no path here; the run is "
      .. "refused by name rather than moved to another transport." }
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

-- The fence tag, read the way a model writes it: the language "js" (or "javascript", any case)
-- followed by the word "run", plus the three other spellings a model used (#51/C) - the tag followed
-- by code on the same fence line, any run of spaces between them, and "javascript" for "js".
-- Returns the code that shared the fence line ("" when the line held only the tag), or nil when the
-- fence is not run-tagged. The parser is kept because the leak net reads the SAME shapes a model
-- writes; nothing executes what it finds any more.
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

-- An opening fence: 3+ backticks or 3+ tildes, indented at most three spaces, info string free of its
-- own fence character (CommonMark reads both; a model writes both).
local function fence(line, opening)
  local indent, mark, info = line:match('^( ? ? ?)([`~]+)(.*)$')
  if not mark then return nil end
  local char = mark:sub(1, 1)
  if mark:gsub(char, '') ~= '' or #mark < 3 then return nil end
  if opening then
    if info:find(char, 1, true) then return nil end
    return char, #mark, info
  end
  if info:match('%S') then return nil end
  return char, #mark, info
end

local function has_fence(text)
  return text:find('```', 1, true) ~= nil or text:find('~~~', 1, true) ~= nil
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

M.IN_THINKING_SHAPES = { run = true, cut_run = true, plain_js = true }
local PLAIN_JS = { js = true, javascript = true }
local TICK = string.rep(string.char(96), 3)

-- THE ACTION IN THE WRONG FIELD. The run block arrives in the provider's REASONING, not in its
-- content, and nothing executes the reasoning: it is the model's own. What this decides is the
-- SENTENCE - which shape of "wrote it in the wrong field" the model wrote - so the one continue it is
-- given names the one thing to change. Only the LAST block matters, and only when it ENDS the
-- thinking (nothing but whitespace after it): a block the thinking went on from is the model
-- reasoning ABOUT code, and naming that as the lost action would be a wrong diagnosis.
--   run        a complete run-tagged block ends the thinking;
--   cut_run    the thinking ended inside a run-tagged block;
--   plain_js   the thinking ends with a js or javascript block never tagged run;
--   nil        no block, or a last block that is none of these: the step reasoned and stopped.
function M.in_thinking(reasoning)
  local text = tostring(reasoning or "")
  if not has_fence(text) then return nil end
  local blocks, lines = M.parse(text)
  local last = blocks[#blocks]
  if not last then return nil end
  local closed = last.close ~= nil
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

-- How many times in a row the harness asks for the action in the answer before the turn fails by
-- name. One: the measured failure is a model writing in the wrong field, and naming it once is a
-- diagnosis; a second consecutive one is a model that cannot follow it, and the run must not end rc=0
-- with nothing run.
M.THINKING_CONTINUES = 1

-- Model-facing (operator-reviewed). One sentence naming the one thing to change, then where to write
-- it. Never "retry": the model did the work, in the wrong field. The sentence names the RUN TOOL,
-- because there is no block to send any more (Victor 21/11).
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
    .. ". Act by calling the run tool with the script in its code argument; a message with no tool call "
    .. "is your answer."
end

-- Model-facing. The step reasoned and stopped with nothing to run (#22).
function M.reasoning_only_notice()
  return "[Harness notice] This message had no answer: you reasoned and then stopped, so nothing ran. "
    .. "Write your next step in your ANSWER: call the run tool with the script in its code argument, or "
    .. "write the answer itself and why."
end

-- The name the run fails with when the action is still only in the thinking after the harness asked
-- for it once. Never rc=0 with the action unexecuted.
function M.thinking_failure(found)
  local shape = type(found) == "table" and tostring(found.shape) or ""
  local what = shape == "cut_run" and "a " .. TICK .. "js run block that was never closed"
    or shape == "plain_js" and "a " .. TICK .. "js block that is not tagged js run"
    or "a run block"
  return "run_block_in_thinking: " .. what .. " is in the model's reasoning, not in its answer, and the "
    .. "harness asked for the tool call once already; nothing ran, so the turn is failed rather than "
    .. "finished without its action"
end

function M.reasoning_only_failure()
  return "reasoning_only: the step reasoned and returned no answer and no action, and the harness asked "
    .. "for an answer once already; nothing ran, so the turn is failed rather than finished without it"
end

-- Tool-call markup written as TEXT: the leftover, when a call could not be read from it. An
-- allow-list, not a block-list (the formats this project has actually seen a model write): a marker
-- that is not here is prose, and prose is an answer. The list is deliberately short, because a false
-- positive costs the model a step.
M.MARKUP_MARKERS = {
  "<ds_tool>", "</ds_tool>", "<ds_safety>", "</ds_safety>", "<ds_invoke>", "</ds_invoke>",
  "</parameter>", "<tool_call>", "</tool_call>", "<function_call>", "<function_calls>",
  "<antml:invoke", "</antml:invoke>", "</invoke>", "<|python_tag|>",

}

-- The shapes a model writes when it has a trained call format of its own (<bash>...</bash>,
-- <run>...</run>, <invoke name=...>...</invoke>). They are checked as PAIRS, not as bare openers:
-- this detector runs on every answer the loop reads, so a sentence that merely MENTIONS a tag - "use
-- <bash> to run it" - must stay an answer. A pair that opens and closes is a call the model meant.
-- With one transport these three are always on: there is no mode left that could accept them as
-- prose, and a model that writes one has written its action in the wrong form.
M.MARKUP_PAIRS = {
  { "<bash>", "</bash>" },
  { "<run>", "</run>" },
  { "<invoke ", "</invoke>" },
}

-- Returns { marker = <what was found> } or nil. Pure: no host, no state.
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
  -- DeepSeek's token bar written with either character (the two spellings are both written).
  if raw:find("\239\189\156", 1, true) or raw:find("|DSML|", 1, true) then return { marker = "<|DSML|>" } end
  return nil
end

-- THE MODEL'S PROSE: its answer with the samples it QUOTED taken out. Fenced blocks are removed whole
-- and inline code spans are blanked, because a call format named inside a fence or inside backticks is
-- a quote, not a call the model meant to make (review r1, item 1: a worker that writes about this very
-- net, or a report that quotes the shape, lost its turn to its own prose). Pure: no host, no state.
function M.prose_only(text)
  local body = tostring(text or "")
  if body == "" then return "" end
  local lines = lines_of(body)
  local blocks = M.parse(body)
  local inside = {}
  for _, block in ipairs(blocks) do
    for index = block.open, block.close or #lines do inside[index] = true end
  end
  local kept = {}
  for index, line in ipairs(lines) do
    if not inside[index] then kept[#kept + 1] = line.text end
  end
  local prose = table.concat(kept, "\n")
  -- Double-backtick spans first, so a span that contains one backtick is taken whole (the same order
  -- finish_contract uses: a quoted marker inside backticks is one span, not three).
  prose = prose:gsub("``(.-)``", " ")
  prose = prose:gsub("`[^`\n]-`", " ")
  return prose
end

-- THE ACTING SHAPE WRITTEN AS TEXT (the leak net's second shape). A RUN-TAGGED block that ENDS the
-- answer is the action in the wrong form: nothing runs it any more (the block channel is gone), so the
-- step is not an answer and the model would otherwise end the turn with its action as a sample. Only
-- the LAST block counts, and only when nothing but whitespace follows it - an answer that goes on from
-- a block is prose about code, not a lost action (the same rule as M.in_thinking).
--
-- A block tagged js / javascript WITHOUT the word run is an EXAMPLE, not an action (review r1, item 1):
-- an answer that ends in a sample fence is an answer and earns nothing. Returns
-- { marker = "```js run", line = n } or nil.
function M.text_action(text)
  local body = tostring(text or "")
  if not has_fence(body) then return nil end
  local blocks, lines = M.parse(body)
  local last = blocks[#blocks]
  if not last then return nil end
  local last_line = lines[last.close or #lines]
  if body:sub(last_line.finish + 1):find("%S") then return nil end
  if not last.run then return nil end
  return { marker = TICK .. "js run", line = last.open }
end

return M
