-- A whole turn in ONE process, with a stub provider, for the start-instant guard test
-- (`scripts/test-start-instant.lua`). It prints the numbers the guard asserts on and nothing else.
--
-- What it measures:
--   gap_ms          monotonic time from "the run is submitted" to "the first model request is on its
--                   way". That is the number a reader feels (Victor 22/11: "it should start
--                   instantaneously"), and it stays measurable while the ledger is locked: a
--                   ledger-only measurement goes UNKNOWN exactly when the problem is worst, because the
--                   telemetry row it would read is the write that could not land.
--   run_to_model_ms run/start -> first model_call/start, read back from this run's harness_events rows,
--                   printed as `unknown (<reason>)` when either row is absent - never as 0.
-- The step that used to pay for a held write lock is record_turn (the user message), and its own cost is
-- in the preflight row this fixture prints (phases.record_turn) - measured where it happens, not by
-- wrapping memory.append_turn, which cannot work: dofile() re-runs the module, so the table a fixture
-- patches is not the table agent.lua holds (measured: the wrapper never fired).
--
-- The provider is the host's stream boundary (`host.http_stream`), the same one
-- `scripts/test-run-counts.lua` uses: no HTTP, no model, no paid call, and every step before it - the
-- real provider, the real telemetry, the real transcript write - is the shipping path.
--
-- THE RENDEZVOUS. The lock has to be taken AFTER this process has booted: a hold taken before it is
-- absorbed by this process's own `memory.setup()` migration write, and a test that measures the boot
-- measures nothing about the turn. With WA_GO_FILE set, this process says it is ready, waits for that
-- file, and then waits a further WA_GO_SETTLE_MS (default 250 ms) so the driver's lock is certainly in
-- place before the first write: without the settle, a measurement written to race the lock can beat it
-- (measured: an append that should have waited 5006 ms landed in 0 ms because it ran 20 ms early).
local json = dofile('lua/vendor/json.lua')
local getenv = host.getenv
local env = {
  WASM_AGENT_LLM_API_KEY = 'test-only',
  WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash',
  WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0',
  WASM_AGENT_MAX_TOOL_ROUNDS = '1',
  WASM_AGENT_PROVIDER_RESPONSE_RETRIES = '1',
}
host.getenv = function(key) if env[key] ~= nil then return env[key] end return getenv(key) end
host.http = function() error('unexpected HTTP') end
local memory = dofile('lua/core/memory.lua')
memory.setup()
local provider = dofile('lua/core/provider.lua')
local native_dofile = dofile
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return native_dofile(path) end
local agent = native_dofile('lua/core/agent.lua')
dofile = native_dofile

local now_ms = function() return host.monotonic_ms and host.monotonic_ms() or (host.now() * 1000) end

local session = memory.start_session('', 'start instant', { user_id = 'master' })
local emitted = {}
local model_calls = 0
local first_call_ms = nil
host.http_stream = function()
  model_calls = model_calls + 1
  if first_call_ms == nil then first_call_ms = now_ms() end
  return json.encode({ status = 200, content = 'hi', stream_complete = true, finish_reason = 'stop', tool_calls = {} })
end

-- THE AGENT IS BUILT HERE, BEFORE THE RENDEZVOUS, and that order is the measurement. agent.new
-- writes the session's presence row (INSERT INTO session_presence), which is a WRITE: built after the
-- lock was taken it absorbed a 6 s hold and reported a 339 ms run, which measured the constructor and
-- called it a turn (measured: "sql: INSERT INTO session_presence ... spent=5754ms"). The turn starts at
-- bot:run, and that is where the first write it owns happens.
-- Every event carries when it happened: the wait this test is about is a GAP between two of them, not a
-- single number, and a fixture that only prints the total cannot say which step spent it.
local submit_at = nil
local bot = agent.new(session, function(event)
  local at = submit_at and (now_ms() - submit_at) or nil
  event._at = at and math.floor(at) or nil
  emitted[#emitted + 1] = event
end, 'master', 'master', '')

local go_file = getenv('WA_GO_FILE') or ''
if go_file ~= '' then
  print('turn: ready')
  pcall(function() io.stdout:flush() end)
  local budget = (tonumber(getenv('WA_GO_WAIT_S') or '90') or 90) * 1000
  local waited = 0
  while waited < budget do
    if host.read_file and host.read_file(go_file) ~= nil then break end
    host.sleep('20')
    waited = waited + 20
  end
  print('turn: go after_ms=' .. tostring(waited))
  pcall(function() io.stdout:flush() end)
  host.sleep(tostring(tonumber(getenv('WA_GO_SETTLE_MS') or '250') or 250))end

local started = now_ms()
submit_at = started
local ok, problem = pcall(function() return bot:run('hi') end)
local finished = now_ms()
local gap = first_call_ms and (first_call_ms - started) or nil
print(string.format('turn: ok=%s gap_ms=%s wall_ms=%d model_calls=%d reply=%s',
  tostring(ok), gap and tostring(math.floor(gap)) or 'none', math.floor(finished - started),
  model_calls,
  ok and tostring(problem) or 'none'))
if not ok then print('turn: error ' .. tostring(problem)) end

-- Status lines the run emitted, verbatim: the guard test asserts the reader is TOLD what it waits for.
for _, event in ipairs(emitted) do
  if event.type == 'status' and type(event.text) == 'string' then print(string.format('turn: status +%sms %s', tostring(event._at), event.text)) end
end
for _, event in ipairs(emitted) do
  if event.type == 'error' then print('turn: error ' .. tostring(event.error)) end
end

local function rows(statement, params)
  local raw = host.sql_query(statement, json.encode(params or {}))
  local decoded = json.decode(raw)
  if type(decoded) ~= 'table' or decoded.error then return nil, tostring(type(decoded) == 'table' and decoded.error or 'unreadable') end
  return decoded
end
local run_id = bot.run_id
local started_rows, why = rows([[SELECT at FROM harness_events WHERE run_id=? AND kind='run' AND phase='start' ORDER BY seq LIMIT 1]], { run_id })
if not started_rows then print('turn: run_to_model_ms unknown (' .. why .. ')')
elseif not started_rows[1] then print('turn: run_to_model_ms unknown (no run/start row)')
else
  local call_rows, call_why = rows([[SELECT at FROM harness_events WHERE run_id=? AND kind='model_call' AND phase='start' ORDER BY seq LIMIT 1]], { run_id })
  if not call_rows then print('turn: run_to_model_ms unknown (' .. call_why .. ')')
  elseif not call_rows[1] then print('turn: run_to_model_ms unknown (no model_call/start row)')
  else print(string.format('turn: run_to_model_ms %d', math.floor((tonumber(call_rows[1].at) - tonumber(started_rows[1].at)) * 1000))) end
end
local preflight = rows([[SELECT payload FROM harness_events WHERE run_id=? AND kind='preflight' ORDER BY seq DESC LIMIT 1]], { run_id })
if preflight and preflight[1] then print('turn: preflight ' .. tostring(preflight[1].payload)) end

-- What the transcript holds once the turn is over: the guard test asserts nothing was lost.
local stored = rows([[SELECT role, content FROM messages WHERE session_id=? ORDER BY seq]], { session })
if stored then
  local parts = {}
  for _, row in ipairs(stored) do parts[#parts + 1] = tostring(row.role) .. '=' .. tostring(row.content):sub(1, 20) end
  print('turn: transcript ' .. table.concat(parts, ' | '))
else
  print('turn: transcript unknown')
end
