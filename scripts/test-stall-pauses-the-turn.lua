-- A STALL PAUSES THE TURN; IT DOES NOT END IT (mission turn-survives-a-provider-stall, item 1).
--
-- Measured 24/11 on work: each provider stall ended the run, and the self-wake that followed started a
-- SECOND turn (reason "run failed: provider_stalled"), so one ask that stalled twice cost three turns
-- and the person saw a new prompt row they had never typed.
--
-- The retry loop that already lives inside the run (agent.lua's transient loop) refused this class:
-- `provider.is_transient` returns false for a response timeout, deliberately - the short replay inside
-- `provider` had already fired. The class now has its own in-run budget (`stalled_attempts`, default
-- the original request plus one pause-retry) and its own backoff.
--
-- What is pinned here:
--   * a run whose FIRST provider call stalls once asks exactly TWICE and finishes: one run, one user
--     row, one assistant row, no failure row, and no `[run failure]` row (that row is what a new turn
--     was bought with);
--   * the pause is announced once as a provider_retry row whose reason names the stall and whose
--     attempt/limit are the stall's own (1/2), so the person is told what is happening;
--   * every event of the turn carries ONE run id: nothing was restarted;
--   * with the pause turned OFF by name (ATTEMPTS=1), the same stall ends the run - so this row cannot
--     pass by having retried something else.
--
-- Hermetic: the provider is replaced, no network, no real sleeping, a scratch home.
local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY = 'test-only', WASM_AGENT_PROVIDER = 'opencode-go',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-stall-turn',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS = '0' }
local cleared = { WASM_AGENT_PROVIDER_RESPONSE_RETRIES = true }
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

-- A stall's text, exactly the shape the transport raises (the marker is what the host writes).
local STALL = 'provider_error: timeout: receive response (provider_stalled: no response within 90s)'
local function answer(text)
  return { content = text, tool_calls = {}, finish_reason = 'stop', stream_complete = true,
    usage = { prompt = 10, completion = 5 } }
end

local function rows_for(session_id)
  local ok, raw = pcall(host.sql_query,
    'SELECT role, substr(content,1,80) AS head FROM messages WHERE session_id=? ORDER BY seq',
    json.encode({ session_id }))
  if not ok then return nil, tostring(raw) end
  local okd, rows = pcall(json.decode, raw)
  if not okd then return nil, 'unreadable' end
  return rows
end

local function retry_rows(session_id)
  local ok, raw = pcall(host.sql_query,
    'SELECT count(*) AS n FROM harness_events WHERE kind=? AND session_id=?',
    json.encode({ 'provider_retry', session_id }))
  if not ok then return nil end
  local okd, rows = pcall(json.decode, raw)
  if not okd or not rows[1] then return nil end
  return tonumber(rows[1].n)
end

-- ---- one stall, one turn ----------------------------------------------------------------
local session = memory.start_session('', 'stall-pauses-the-turn', { user_id = 'master', node_id = '', title = 'stall-pauses-the-turn' })
local bot = agentlib.new(session, function() end, 'master', 'master', '')
local calls = 0
provider.complete_with = function()
  calls = calls + 1
  if calls == 1 then error(STALL) end
  return answer('the answer after the pause')
end
local ok, reply = pcall(bot.run, bot, 'ask once')
check(ok, 'the turn finished: ' .. tostring(ok and '' or reply))
check(calls == 2, 'the provider was asked exactly twice (got ' .. tostring(calls) .. ')')
check(slept_ms > 0, 'and the second ask came after a pause (waited ' .. tostring(slept_ms) .. ' ms)')
local retries = retry_rows(session)
check(retries == 1, 'one pause row was written (got ' .. tostring(retries) .. ')')
local rows, why = rows_for(session)
if not rows then
  check(false, 'the session rows are readable: ' .. tostring(why))
else
  local users, assistants, failures = 0, 0, 0
  for _, row in ipairs(rows) do
    if row.role == 'user' then users = users + 1 end
    if row.role == 'assistant' then assistants = assistants + 1 end
    local head = tostring(row.head or '')
    if head:find('[run failure]', 1, true) or head:find('run_failed', 1, true) then failures = failures + 1 end
  end
  check(users == 1, 'ONE user row (got ' .. tostring(users) .. ')')
  check(assistants == 1, 'ONE assistant row (got ' .. tostring(assistants) .. ')')
  check(failures == 0, 'no failure row and no [run failure] row (got ' .. tostring(failures) .. ')')
end

-- ---- the budget this change owns: by name, clamped, and the class it is for ------------------
-- Measured while writing this row: counting provider asks or provider_retry ROWS is not this change's
-- ground - the identical-repeat ceiling and the run's own re-drive call the provider too and write rows
-- of the same kind. So the control pins the two things the change actually introduces.
-- The budget is a constant the module carries, so a row hands it DATA - it used to be set through the
-- environment, which is the override product code may not have.
local was_attempts = provider.STALLED_ATTEMPTS
provider.STALLED_ATTEMPTS = 1
check(provider.stalled_attempts() == 1, 'the budget is read by name')
check(provider.clamped_stalled_attempts(0) == 1, 'zero is clamped up to one: a stall is never "no retry" by accident')
check(provider.clamped_stalled_attempts(9) == 4, 'and above four it is clamped down')
provider.STALLED_ATTEMPTS = was_attempts
check(provider.stalled_attempts() == provider.STALLED_ATTEMPTS, 'the default is stated beside it: ' .. tostring(provider.STALLED_ATTEMPTS))
check(provider.stalled_backoff_ms(1) >= 1500 and provider.stalled_backoff_ms(1) <= 2500,
  'the first pause is 2 s, jittered (got ' .. tostring(provider.stalled_backoff_ms(1)) .. ' ms)')
check(provider.stalled_backoff_ms(9) <= 38000, 'and the pause is capped, not exponential without end')

print(string.format('ok stall-pauses-the-turn: %d checks, %d failed', checks, failed))
if failed > 0 then error('stall-pauses-the-turn failed') end

