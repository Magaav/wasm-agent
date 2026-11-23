-- CANARY TASK: a run block, end to end, in this child's own ledger.
--
-- The path a user takes: the model answers with a ```js run block, the node EXECUTES it, the block's
-- effect is real (a file appears), its result goes back to the model, and the model's second answer ends
-- the turn. Only the model is stubbed, at the host's stream boundary; the block, the sandbox, the tool
-- bridge and the transcript are the shipping ones.
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
  WASM_AGENT_MAX_TOOL_ROUNDS = '3',
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
local session = memory.start_session('', 'canary: run block', { user_id = 'master' })
h.check(type(session) == 'string' and session ~= '', 'session', 'no session was created: ' .. tostring(session))

local home = os.getenv('WASM_AGENT_HOME') or ''
local marker = home .. '/canary-run-block.txt'
local ANSWER = 'the block ran, answer 5c1d'
-- The model asks for the run tool with the script in its code argument - the shape a run block takes on
-- the wire since the harness stopped reading fence markup as a call (a message with no tool call is an
-- answer). The script writes into this child's own home.
local SCRIPT = table.concat({
  'const r = await tools.write({ path: ' .. string.format('%q', marker) .. ', content: "the block ran" });',
  'return { ok: r.ok === true };',
}, '\n')

h.stage('turn')
local calls = 0
host.http_stream = function()
  calls = calls + 1
  if calls == 1 then
    return json.encode({ status = 200, content = 'running it', stream_complete = true, finish_reason = 'tool_calls',
      tool_calls = { { id = 'call-run-1', type = 'function', ['function'] = { name = 'run', arguments = json.encode({ code = SCRIPT }) } } } })
  end
  return json.encode({ status = 200, content = ANSWER, stream_complete = true, finish_reason = 'stop', tool_calls = {} })
end
local bot = agent.new(session, function() end, 'master', 'master', '')
local ran, answer = pcall(function() return bot:run('canary: run the block') end)
h.check(ran, 'turn', 'the turn raised: ' .. tostring(answer))

h.stage('effect')
local written = host.read_file(marker)
if written ~= 'the block ran' then
  local diag = host.sql_query('SELECT role, content FROM messages WHERE session_id=? ORDER BY seq', json.encode({ session }))
  print('diagnostic: model_calls=' .. tostring(calls) .. ' transcript=' .. tostring(diag):sub(1, 1500))
  h.fail('effect', 'the run block did not write its file: ' .. tostring(written))
end

h.stage('readback')
local raw = host.sql_query('SELECT role, content FROM messages WHERE session_id=? ORDER BY seq', json.encode({ session }))
local decoded = type(raw) == 'string' and json.decode(raw) or raw
h.check(type(decoded) == 'table', 'readback', 'the transcript could not be read: ' .. tostring(decoded))
local replied = false
for _, row in ipairs(decoded) do
  if row.role == 'assistant' and tostring(row.content):find('5c1d', 1, true) then replied = true end
end
h.check(replied, 'readback', 'the turn never answered after the block ran (model calls: ' .. tostring(calls) .. ')')

h.ok()
