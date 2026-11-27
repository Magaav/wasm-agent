-- ROUNDS AND BYTES, BEFORE AND AFTER TIMERS (job item 4, 27/11). One scripted conversation through the
-- real loop (the pattern of scripts/test-leak-net.lua): the stub provider's first reply is the measured
-- shape, "await new Promise(r => setTimeout(r, 30))", written by 27 of the 36 recoverable scripts in the
-- 7-day ledger. What the row reports is what the model paid: the rounds it needed and the bytes of the
-- scripts it had to write. On a build with the timers the first script answers; on the base build it is a
-- ReferenceError, the loop feeds it back, and the model must write the corrected script (await sleep(30)).
--
-- Hermetic: no network, a scratch home (the guard refuses the real one).
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local agentlib = dofile('lua/core/agent.lua')

local real_getenv = host.getenv
local overrides = {
  WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_API_KEY = 'timers-rounds-fixture',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0',
}
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  return real_getenv(key)
end

local serial = 0
local rounds = 0
local script_bytes = 0
local function run_call(code)
  return { id = 'call_run_' .. tostring(serial), type = 'function',
    ['function'] = { name = 'run', arguments = json.encode({ code = code }) } }
end
local PROMISE = 'await new Promise(r => setTimeout(r, 30)); return "waited";'
local SLEEP = 'await sleep(30); return "waited";'
-- The stub is ONE model behaviour, not a script of three replies: it writes the Promise shape first,
-- and retries with the corrected script ONLY when the sandbox refused (that is what a model does), then
-- answers.
local current = nil
local function last_tool_failed(session)
  if not session then return nil end
  local rows = memory.session_messages(session) or {}
  for i = #rows, 1, -1 do
    if rows[i].role == 'tool' then
      return tostring(rows[i].content or ''):find('is not defined', 1, true) ~= nil
    end
  end
  return nil
end
local replies = {
  { content = 'Pausing first.', finish_reason = 'tool_calls', tool_calls = { run_call(PROMISE) } },
  { content = 'Paused another way.', finish_reason = 'tool_calls', tool_calls = { run_call(SLEEP) } },
  { content = 'Done.' },
}
local index = 0
host.http_stream = function()
  rounds = rounds + 1
  local failed = last_tool_failed(current)
  local reply = replies[3]
  if failed == nil then reply = replies[1]
  elseif failed == true then reply = replies[2] end
  index = index + 1
  if reply.tool_calls then
    for _, call in ipairs(reply.tool_calls) do
      script_bytes = script_bytes + #tostring(call['function'].arguments or '')
    end
  end
  local body = { status = 200, content = reply.content or '', reasoning = '',
    finish_reason = reply.finish_reason or 'stop', tool_calls = reply.tool_calls or {} }
  return json.encode(body)
end

serial = serial + 1
local who = 'timers-rounds'
local sid = memory.start_session('', 'timers rounds', { user_id = who, node_id = '', title = 'timers' })
current = sid
local bot = agentlib.new(sid, function() end, 'master', who, '')
bot.stream = true

local asked = 'pause 30 ms, then say done'
local ok_run, reply = pcall(bot.run, bot, asked)
if not ok_run then error('the turn did not finish: ' .. tostring(reply), 0) end

local rows = memory.session_messages(sid) or {}
local tool_rows = 0
local first_failed = nil
for _, row in ipairs(rows) do
  if row.role == 'tool' then
    tool_rows = tool_rows + 1
    local content = tostring(row.content or '')
    if first_failed == nil then
      first_failed = content:find('setTimeout is not defined', 1, true) ~= nil
    end
  end
end
print(string.format('timers rounds: rounds=%d tool_rows=%d script_bytes=%d first_failed=%s',
  rounds, tool_rows, script_bytes, tostring(first_failed)))
-- What the timers must buy, on this row's own numbers: the first script WORKS (no retry), so the model
-- spends one run round and one answer instead of a retry, and writes one script instead of two. Measured
-- on the base build (04b7a38b, no timers) with this same row: rounds=3 tool_rows=2 script_bytes=118
-- first_failed=true.
if first_failed ~= false then error('the first script must work with timers (a ReferenceError means the names are missing)', 0) end
if tool_rows ~= 1 then error('exactly one run call: got ' .. tostring(tool_rows), 0) end
if rounds ~= 2 then error('two rounds (call, answer): got ' .. tostring(rounds), 0) end
print('timers rounds ok: 2 rounds, 72 script bytes (before: 3 rounds, 118 bytes) for the same task')
