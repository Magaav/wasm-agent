local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_RETRIES = '0', WASM_AGENT_RUN_FAILURE_WAKE_SECONDS = '0' }
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return native_getenv(key) end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
local telemetry = original_dofile('lua/core/telemetry.lua')
dofile = original_dofile
local fake_answer = original_dofile('lua/core/fake_answer.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function session(title) return memory.start_session('', title, { user_id = 'master', node_id = '', title = title }) end
local usage = { prompt_tokens = 1000, completion_tokens = 20, total_tokens = 1020 }
local SHAPE = "<result>\n<name>bash</name>\n<output>\n$ ls\nREADME.md\n</output>\n</result>"

-- One turn: the model imitates a tool result, then answers. The provider is a list of replies.
local function run(title, replies)
  local sid = session(title)
  local bot = agentlib.new(sid, function() end, 'master', 'master', '')
  local seen = 0
  provider.complete_with = function()
    seen = seen + 1
    local reply = replies[seen]
    if not reply then error('unexpected provider call ' .. seen) end
    return reply
  end
  local ok, reply = pcall(bot.run, bot, 'do the thing')
  assert(ok, tostring(reply))
  return sid, reply
end
local function fake() return { content = SHAPE, tool_calls = {}, finish_reason = 'stop', usage = usage } end
local function answer(text) return { content = text, tool_calls = {}, finish_reason = 'stop', usage = usage } end

-- ---------------------------------------------------------------- the evidence is kept, verbatim
local sid, reply = run('fake-evidence', { fake(), answer('the listing is in.') })
check(reply == 'the listing is in.', 'the turn answers with the model next step')

local rows = memory.session_messages(sid) or {}
local stripped_row
for _, row in ipairs(rows) do
  if row.role == 'assistant' and row.phase == 'fake_tool_result' then stripped_row = row end
end
check(stripped_row ~= nil, 'the step that was a fabrication has its own row')
check((stripped_row and stripped_row.content or '') == '',
  'and its content is the stripped message: [' .. tostring(stripped_row and stripped_row.content) .. ']')
local entry
for _, item in ipairs(stripped_row and stripped_row.trace or {}) do
  if type(item) == 'table' and item.kind == 'fake_tool_result' then entry = item end
end
check(entry ~= nil, 'the row carries the fake_tool_result trace entry')
check(entry and entry.removed == SHAPE,
  'the removed markup is kept VERBATIM in the run record, not only as a bounded excerpt: ['
    .. tostring(entry and entry.removed) .. ']')
check(entry and tonumber(entry.removed_bytes) == #SHAPE,
  'and its own byte count says so: ' .. tostring(entry and entry.removed_bytes) .. ' vs ' .. #SHAPE)
check(entry and entry.tool == 'bash', 'with the tool the markup named: ' .. tostring(entry and entry.tool))
check(entry and tonumber(entry.excerpt and #entry.excerpt) and #entry.excerpt <= 240,
  'the bounded excerpt is still there for the notice and the status line')

-- The same evidence, in the run's own event ledger (harness_events), so a reader who was not in the
-- turn can see what was removed without reading the transcript.
local event
for _, item in ipairs((telemetry.events(sid, 0, 500) or {}).events or {}) do
  if item.kind == 'fake_tool_result' and item.phase == 'step' then event = item end
end
check(event ~= nil, 'the event ledger has the fake_tool_result step')
check(event and event.payload and event.payload.removed == SHAPE,
  'and the event payload keeps the removed markup verbatim too: ['
    .. tostring(event and event.payload and event.payload.removed) .. ']')
check(event and event.payload and tonumber(event.payload.removed_bytes) == #SHAPE,
  'with its byte count: ' .. tostring(event and event.payload and event.payload.removed_bytes))

-- Nothing fabricated reaches the answer, and the notice says what happened.
local last = rows[#rows]
check(last and last.role == 'assistant' and last.content == 'the listing is in.',
  'the answer row is the model own next step, never the fabrication')
check(tostring(last and last.content):find('<result>', 1, true) == nil, 'and carries no markup')

print(string.format("ok fake-answer-evidence: %d checks", checks))
