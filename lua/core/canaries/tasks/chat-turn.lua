-- CANARY TASK: one whole chat turn, end to end, in this child's own ledger.
--
-- THE MODEL IS THE ONLY THING STUBBED, and it is stubbed at the host's stream boundary (`host.http_stream`)
-- exactly as scripts/fixtures/start-instant-turn.lua does: no HTTP, no provider, no paid call, and every
-- other step of the turn - the session row, the prompt, the real agent loop, the transcript write - is the
-- shipping path. If the chat is broken (the loop raises, the answer never lands in the ledger), this fails
-- at the stage it broke in.
local json = dofile('lua/vendor/json.lua')
local h = dofile('lua/core/canaries/tasks/harness.lua')

h.stage('provider')
local getenv = host.getenv
local env = {
  WASM_AGENT_LLM_API_KEY = 'canary-only',
  WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0',
  WASM_AGENT_MAX_TOOL_ROUNDS = '1',
}
host.getenv = function(key) if env[key] ~= nil then return env[key] end return getenv(key) end
host.http = function() error('the canary makes no HTTP call') end

h.stage('ledger')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local provider = dofile('lua/core/provider.lua')
local native_dofile = dofile
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return native_dofile(path) end
local agent = native_dofile('lua/core/agent.lua')
dofile = native_dofile

h.stage('session')
local session = memory.start_session('', 'canary: chat', { user_id = 'master' })
h.check(type(session) == 'string' and session ~= '', 'session', 'no session was created: ' .. tostring(session))

local ANSWER = 'canary answer 7f3a'
h.stage('turn')
-- One reply, and the shape the stream boundary answers with: the answer and its end, nothing else.
host.http_stream = function()
  return json.encode({ status = 200, content = ANSWER, stream_complete = true, finish_reason = 'stop', tool_calls = {} })
end
local bot = agent.new(session, function() end, 'master', 'master', '')
local ran, answer = pcall(function() return bot:run('canary: say the answer') end)
h.check(ran, 'turn', 'the turn raised: ' .. tostring(answer))
h.check(type(answer) == 'string' and #answer > 0, 'turn', 'the turn answered nothing')

h.stage('readback')
local raw = host.sql_query('SELECT role, content FROM messages WHERE session_id=? ORDER BY seq', json.encode({ session }))
local decoded = type(raw) == 'string' and json.decode(raw) or raw
h.check(type(decoded) == 'table', 'readback', 'the transcript could not be read: ' .. tostring(decoded))
local asked, replied = false, false
for _, row in ipairs(decoded) do
  if row.role == 'user' and tostring(row.content):find('canary', 1, true) then asked = true end
  if row.role == 'assistant' and tostring(row.content):find(ANSWER, 1, true) then replied = true end
end
h.check(asked, 'readback', 'the question is not in the transcript')
h.check(replied, 'readback', 'the answer is not in the transcript: the turn did not land')

h.ok()
