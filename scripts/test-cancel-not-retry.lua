-- A STOP IS NOT A FAILURE TO REPLAY (change/esc-stops-now, item 4).
--
-- Measured by Fable in the ledger, 23/11: a run the reader stopped wrote a provider_retry
-- "attempt 1 ... reason run_cancelled, wait_ms 1151" row and then waited out that second before the
-- step could end. The cancel reached the provider-call error path as "provider_error: run_cancelled",
-- which matches no known class, and the unclassified bucket replays up to five times by design.
--
-- What is pinned here:
--   * the classification, by an ALLOW-LIST of the two codes a cancellation path raises - and nothing
--     else is a cancellation (a connection failure is still a failure);
--   * a run whose very first provider call comes back cancelled asks the provider exactly ONCE, waits
--     for nothing, and does not write a provider_retry row;
--   * the unclassified-provider bucket is untouched: the same shape of failure that is NOT a stop is
--     still replayed, so this test cannot pass by having deleted the bucket.
--
-- Hermetic: the provider is replaced before the agent runs; no paid call, no network, no sleeps.
local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-cancel-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS = '0' }
-- The operator's own provider tuning is not this row's (see scripts/test-provider-stall-replay.lua).
local cleared = { WASM_AGENT_PROVIDER_RESPONSE_RETRIES = true }
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  if cleared[key] then return nil end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http
local slept_ms = 0
local real_sleep = host.sleep
host.sleep = function(ms) slept_ms = slept_ms + (tonumber(ms) or 0) end
-- This run is not itself cancelled: the cancellation is the provider's answer, which is what the
-- classification sees in the real process too.
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

-- ---- the classification, as an allow-list ------------------------------------------------
check(type(provider.is_cancellation) == 'function', 'provider.is_cancellation exists')
if type(provider.is_cancellation) == 'function' then
  check(provider.is_cancellation('provider_error: run_cancelled'), 'a run cancellation is one')
  check(provider.is_cancellation('run_cancelled'), 'in its bare form too')
  check(provider.is_cancellation('provider_error: subagent_cancelled'), 'a child cancellation is one')
  -- Everything else keeps its own bucket: unknown is not a stop.
  check(not provider.is_cancellation('provider_error: connection refused'), 'a dead link is not a cancellation')
  check(not provider.is_cancellation('provider_error: some new failure'), 'an unknown failure is not one')
  check(not provider.is_cancellation('provider_http_500'), 'a provider refusal is not one')
  check(not provider.is_cancellation(''), 'nothing is not one')
end

local function session(title) return memory.start_session('', title, {user_id = 'master', node_id = '', title = title}) end

local function telemetry_retries(session_id, run_id)
  local ok, raw = pcall(host.sql_query,
    'SELECT count(*) AS n FROM harness_events WHERE kind=? AND phase=? AND session_id=?',
    json.encode({ 'provider_retry', 'attempt', session_id }))
  if not ok then return nil, tostring(raw) end
  local okd, rows = pcall(json.decode, raw)
  if not okd or type(rows) ~= 'table' or not rows[1] then return nil, 'unreadable answer' end
  return tonumber(rows[1].n)
end

-- ---- a stopped run asks once, waits for nothing, and writes no retry row ------------------
local stopped = session('cancel-not-retry')
local bot = agentlib.new(stopped, function() end, 'master', 'master', '')
local calls = 0
provider.complete_with = function() calls = calls + 1; error('provider_error: run_cancelled') end
slept_ms = 0
local ok, problem = pcall(bot.run, bot, 'stop me')
check(not ok, 'the turn still ends as a failure (a stop is not an answer)')
check(tostring(problem):find('run_cancelled', 1, true) ~= nil, 'and it says which: ' .. tostring(problem))
check(calls == 1, 'the provider was asked exactly once (got ' .. tostring(calls) .. ')')
check(slept_ms == 0, 'and nothing waited between attempts (waited ' .. tostring(slept_ms) .. ' ms)')
local retries, why = telemetry_retries(stopped)
check(retries == 0, 'no provider_retry row was written for the stop (' ..
  tostring(retries == nil and ('unreadable: ' .. tostring(why)) or retries) .. ')')

-- ---- the unclassified bucket still replays: this test cannot pass by deleting it ----------
local other = session('cancel-not-retry-unknown')
local bot2 = agentlib.new(other, function() end, 'master', 'master', '')
local calls2 = 0
provider.complete_with = function() calls2 = calls2 + 1; error('provider_error: a failure nobody classified') end
local ok2 = pcall(bot2.run, bot2, 'a real failure')
check(not ok2, 'an unknown provider failure still fails the turn after its replays')
check(calls2 > 1, 'and it IS replayed (asked ' .. tostring(calls2) .. ' times)')

host.sleep = real_sleep
print(string.format('ok cancel-not-retry: %d checks, %d failed', checks, failed))
if failed > 0 then error('cancel-not-retry failed') end
