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
dofile = original_dofile
local fake_answer = original_dofile('lua/core/fake_answer.lua')

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function session(title) return memory.start_session('', title, { user_id = 'master', node_id = '', title = title }) end
local usage = { prompt_tokens = 1000, completion_tokens = 20, total_tokens = 1020 }
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
  return sid, reply, bot
end
local function fake(text) return { content = text or "<result>\n<name>bash</name>\n<output>x</output>\n</result>",
  tool_calls = {}, finish_reason = 'stop', usage = usage } end
local function answer(text) return { content = text or 'done.', tool_calls = {}, finish_reason = 'stop', usage = usage } end

-- ---------------------------------------------------------------- the ledger reads in time order
local sid, reply = run('fake-ledger-order', { fake(), answer('the listing is in.') })
check(reply == 'the listing is in.', 'the turn answers with the model next step')

local rows = memory.session_messages(sid, { all = true }) or {}
local stripped_at, notice_at
local stripped_row, notice_row
for index, row in ipairs(rows) do
  if row.role == 'assistant' and row.phase == 'fake_tool_result' then stripped_at = index; stripped_row = row end
  if row.role == 'user' and row.phase == 'fake_tool_result'
      and tostring(row.content):find('[Harness notice]', 1, true) then
    notice_at = index; notice_row = row
  end
end
check(stripped_at ~= nil, 'the stripped message has a row of its own')
check(notice_at ~= nil, 'and the harness notice has one too')
check(stripped_at and notice_at and stripped_at < notice_at, string.format(
  'the stripped message comes BEFORE the notice it provoked (message at %s, notice at %s)',
  tostring(stripped_at), tostring(notice_at)))
check(stripped_row and notice_row and tonumber(stripped_row.seq) < tonumber(notice_row.seq),
  string.format('and their sequence numbers agree (%s < %s)', tostring(stripped_row and stripped_row.seq),
    tostring(notice_row and notice_row.seq)))
check(stripped_row and (stripped_row.content or '') == '',
  'the message row is the stripped content: [' .. tostring(stripped_row and stripped_row.content) .. ']')
-- The model's own context keeps the same order it reads in the ledger: the fabricated step, then the
-- notice that tells it what happened.
local before_notice = false
for index, row in ipairs(rows) do
  if index < (notice_at or 0) and row.role == 'assistant' and row.phase == 'fake_tool_result' then before_notice = true end
end
check(before_notice, 'and nothing about the notice was recorded before the message it is about')
local last = rows[#rows]
check(last and last.role == 'assistant' and last.content == 'the listing is in.',
  'the turn still ends with the model real answer')

print(string.format("ok fake-answer-ledger-order: %d checks", checks))
