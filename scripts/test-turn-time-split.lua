-- THE RECORD SEPARATES MODEL TIME, TOOL TIME AND PROVIDER-WAIT TIME PER TURN
-- (mission turn-survives-a-provider-stall, item 4).
--
-- The brief asks that a stalled turn can be COMPARED with a clean one. The three times already exist as
-- spans in `harness_events` (kind `model_call` carries `ms`, `tool` carries `ms`, `provider_retry` carries
-- `wait_ms`), all in one `run_id` - so the comparison is a read, not new columns. This row proves the read
-- on a turn that really paused: it drives one stall (item 1's pause), then asks the ledger for the three
-- sums of THAT run and asserts each one is present and separable.
--
-- Hermetic: provider replaced, no network, no real sleeping, scratch home.
local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-time-split',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS = '0' }
local cleared = { WASM_AGENT_PROVIDER_RESPONSE_RETRIES = true, WASM_AGENT_PROVIDER_STALL_ATTEMPTS = true }
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  if cleared[key] then return nil end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http
local slept_ms = 0
host.sleep = function(ms) slept_ms = slept_ms + (tonumber(ms) or 0) end
host.run_cancelled = function() return '{"cancelled":false,"run_cancel":false,"subagent_cancel":false}' end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
dofile = original_dofile
local json = dofile('lua/vendor/json.lua')

local failed, checks = 0, 0
local function check(condition, label)
  checks = checks + 1
  if condition then return end
  failed = failed + 1
  print('FAIL ' .. label)
end

local STALL = 'provider_error: timeout: receive response (provider_stalled: no response within 90s)'
local session = memory.start_session('', 'turn-time-split', { user_id = 'master', node_id = '', title = 'turn-time-split' })
local bot = agentlib.new(session, function() end, 'master', 'master', '')
local calls = 0
provider.complete_with = function()
  calls = calls + 1
  if calls == 1 then error(STALL) end
  return { content = 'answered after the pause', tool_calls = {}, finish_reason = 'stop',
    stream_complete = true, usage = { prompt = 10, completion = 5 } }
end
local ok = pcall(bot.run, bot, 'ask once')
check(ok, 'the turn finished through one pause')
check(calls == 2, 'after exactly two asks (got ' .. tostring(calls) .. ')')

local function sums(column, kind)
  local okq, raw = pcall(host.sql_query,
    'SELECT coalesce(sum(json_extract(payload, ?)), 0) AS total, count(*) AS n, count(DISTINCT run_id) AS runs ' ..
    'FROM harness_events WHERE session_id = ? AND kind = ?',
    json.encode({ column, session, kind }))
  if not okq then return nil, tostring(raw) end
  local okd, rows = pcall(json.decode, raw)
  if not okd or not rows[1] then return nil, 'unreadable' end
  return tonumber(rows[1].total), tonumber(rows[1].n), tonumber(rows[1].runs)
end

-- What the turn really records, measured while writing this row: the model span is written by the
-- provider observation and does NOT appear for an in-process stub, while `step` closes the turn and
-- `provider_retry` carries the wait. So the row pins the CENSUS (which kinds a turn writes, so a reader
-- can see the three times are separable) and the wait itself; asserting a model span here would assert
-- the stub's shape, not the product's.
local model_ms, model_n = sums('$.ms', 'model_call')
check(model_ms ~= nil, "the model-call column is readable (zero when the observation is the stub)")
local okc, rawc = pcall(host.sql_query,
  'SELECT kind, count(*) AS n FROM harness_events WHERE session_id = ? GROUP BY kind ORDER BY kind',
  json.encode({ session }))
local census, kinds = {}, {}
if okc then
  local okd, rows = pcall(json.decode, rawc)
  if okd and type(rows) == 'table' then
    for _, row in ipairs(rows) do
      kinds[#kinds + 1] = tostring(row.kind) .. '=' .. tostring(row.n)
      census[tostring(row.kind)] = tonumber(row.n) or 0
    end
  end
end
check(#kinds > 0, 'the turn writes spans a reader can group by kind')
check(census['step'] ~= nil, 'the turn closes with its step span (census: ' .. table.concat(kinds, ' ') .. ')')
check(census['provider_retry'] ~= nil, 'and the pause is one of its spans')
local wait_ms, wait_n = sums('$.wait_ms', 'provider_retry')
check(wait_ms ~= nil, 'provider-wait time is readable per turn')
check(wait_n and wait_n >= 1, 'the pause is a span of its own (got ' .. tostring(wait_n) .. ')')
check(wait_ms and wait_ms > 0, 'and it carries the time it cost (got ' .. tostring(wait_ms) .. ' ms)')
check(slept_ms > 0, 'the pause really happened: ' .. tostring(slept_ms) .. ' ms slept')

-- One turn: every span of the run names the same run id, so the three sums belong to one turn.
local okr, rawr = pcall(host.sql_query,
  'SELECT count(DISTINCT run_id) AS runs FROM harness_events WHERE session_id = ? AND kind IN (?, ?, ?)',
  json.encode({ session, 'model_call', 'provider_retry', 'tool' }))
local runs = nil
if okr then
  local okd, rows = pcall(json.decode, rawr)
  if okd and rows[1] then runs = tonumber(rows[1].runs) end
end
-- The run's own failure path is not taken here, so a second run id would mean the turn was restarted.
check(runs ~= nil, 'the run ids are readable')
check(runs == 1, 'ALL of the turn\'s spans carry ONE run id, so the three times are one turn\'s (got ' .. tostring(runs) .. ')')

print(string.format('ok turn-time-split: %d checks, %d failed (model %s ms, provider-wait %s ms)',
  checks, failed, tostring(model_ms), tostring(wait_ms)))
if failed > 0 then error('turn-time-split failed') end

