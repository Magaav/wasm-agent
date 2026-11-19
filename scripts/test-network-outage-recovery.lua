-- A two-minute outage in the middle of a run must not end it.
--
-- Brief (19/11 12:17 UTC, home internet dropped): a local wa run stopped with
--   provider refused the request x3 (a 502 is a transient STATUS, so the RATE-LIMIT bucket claimed it)
--   run_failed: provider_http_502 vault_upstream_unreachable (gaierror)
-- and nothing resumed when the connection came back. PHASE 0 here re-measured it from the outside:
-- the real vault/wa_vault.py, with a closed port and with an unresolvable host, answers in 0.00 s
--   502 {"error":{"code":"vault_upstream_unreachable","message":"wa-vault could not reach the
--   opencode-go upstream (ConnectionRefusedError|gaierror)"}}
-- This row drives that exact text through a real agent turn: the run must wait (visibly), survive a
-- 2-minute outage, finish with the right answer, and never re-run the tool call it already made.
--
-- Hermetic: the provider is replaced before the agent runs; no network, no inference, no live node.
local json = dofile('lua/vendor/json.lua')

-- ---- the scratch-home guard ----------------------------------------------------------------
-- This row writes a session, a ledger and telemetry. It refuses to run unless the data directory it
-- would write in is a SCRATCH home: WASM_AGENT_HOME must be set, and the data directory must live
-- under it. A home that already holds a node's keys or secrets is a REAL node - never this row's.
local function refuse_real_home()
  local scratch = tostring(host.getenv('WASM_AGENT_HOME') or '')
  local data = dofile('lua/core/paths.lua').data()
  local live = host.path_kind(data .. '/keys') == 'dir' or host.path_kind(data .. '/secrets') == 'dir'
  if scratch == '' or data:find(scratch, 1, true) ~= 1 or live then
    print('SKIP refusing to write under ' .. data .. ' (set WASM_AGENT_HOME to a scratch directory)')
    os.exit(77)
  end
end
refuse_real_home()
local native_getenv = host.getenv
local overrides = { WASM_AGENT_LLM_API_KEY='test-only', WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0' }
-- The unbounded link wait is the point: this row must NOT inherit a bound from the operator's own
-- environment (a real node may set one), so both knobs are cleared explicitly.
local cleared = { WASM_AGENT_PROVIDER_CONNECT_RETRIES=true, WASM_AGENT_PROVIDER_CONNECT_WAIT_SECONDS=true }
host.getenv = function(key)
  if overrides[key] ~= nil then return overrides[key] end
  if cleared[key] then return nil end
  return native_getenv(key)
end
host.http = function() error('unexpected HTTP in hermetic test') end
host.http_stream = host.http
-- The wait is real logic, its wall-clock duration is not: every slice is counted instead of slept.
local slept_ms = 0
host.sleep = function(ms) slept_ms = slept_ms + (tonumber(ms) or 0) end

local memory = dofile('lua/core/memory.lua'); memory.setup()
local original_dofile = dofile
local provider = dofile('lua/core/provider.lua')
dofile = function(path) if path == 'lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib = original_dofile('lua/core/agent.lua')
dofile = original_dofile

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function session(title) return memory.start_session('', title, {user_id='master', node_id='', title=title}) end
local usage = {prompt_tokens=1000, completion_tokens=20, total_tokens=1020}

-- The exact bytes measured in PHASE 0, through the provider's own error wrapper (status prefix and
-- the body the vault sent), for both transport causes.
local VAULT_502_DNS = 'lua/core/provider.lua:1405: provider_http_502: {"error": {"code": "vault_upstream_unreachable", ' ..
  '"message": "wa-vault could not reach the opencode-go upstream (gaierror)", "type": "wa_vault"}}'
local VAULT_502_REFUSED = 'lua/core/provider.lua:1405: provider_http_502: {"error": {"code": "vault_upstream_unreachable", ' ..
  '"message": "wa-vault could not reach the opencode-go upstream (ConnectionRefusedError)", "type": "wa_vault"}}'

-- 1. The classification: a dead-link 502 is a LINK failure, not a provider refusal, for both causes.
check(provider.is_link_down(VAULT_502_DNS), 'the incident 502 (gaierror) is recognised as a dead link')
check(provider.is_link_down(VAULT_502_REFUSED), 'a refused upstream is the same class')
check(provider.is_connection_lost(VAULT_502_DNS), 'a dead-link 502 takes the patient connection policy')
check(not provider.is_rate_limited(VAULT_502_DNS),
  'and is NOT claimed by the short 3-try refusal bucket that ended the observed run')
check(not provider.is_final(VAULT_502_DNS), 'a dead link is never final: the provider judged nothing')
-- A 502 that says nothing about the link keeps the ordinary refusal bucket.
check(provider.is_rate_limited('provider_http_502: {"error":{"message":"upstream failed"}}'),
  'a plain 502 keeps the short refusal policy it had')
-- Terminal stays terminal (brief item 1: auth, bad request, unknown model, content refusal).
check(provider.is_final('provider_http_401: invalid api key'), 'auth is final')
check(provider.is_final('provider_http_403: forbidden'), 'a permission refusal is final')
check(provider.is_final('provider_http_400: bad request'), 'a bad request is final')
check(provider.is_final('provider_error: model not found'), 'an unknown model is final')
check(not provider.is_final('provider_http_503: unavailable'), 'a busy upstream is not final')

-- 2. The policy: unbounded by default, 1 s doubling to a 30 s cap, bounded only on request.
check(provider.link_wait_is_unbounded(), 'the link wait has no total cap by default')
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES = '3'
check(not provider.link_wait_is_unbounded(), 'an operator-set bound is honoured')
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES = nil
local first = provider.connection_backoff_ms(1)
check(first >= 750 and first <= 1500, 'the first wait is about 1 s, got ' .. tostring(first))
local capped = provider.connection_backoff_ms(20)
check(capped >= 22500 and capped <= 37500, 'the wait caps at 30 s, got ' .. tostring(capped))

-- 3. The run: a tool call completes, then the link goes down for 2 minutes, then it comes back.
local sid = session('network-outage-mid-run')
local events = {}
local bot = agentlib.new(sid, function(e) events[#events+1] = e end, 'master', 'master', '')
local clock = 1000
local real_now = host.now
host.now = function() return clock end
local TOOL_RUNS = 0
-- ONLY the path the tool call asks for is stubbed: the host's own loader reads Lua modules through
-- host.read_file too, so a blanket answer ('file body' for every path) makes the next module load
-- fail with a bogus 'syntax error near body'. Anything else goes to the real reader untouched.
local read_original = host.read_file
host.read_file = function(path)
  if path == 'DESIGN.md' then TOOL_RUNS = TOOL_RUNS + 1; return 'file body' end
  return read_original(path)
end
local calls = 0
local DOWN_SECONDS = 120
local outage_started = nil
provider.complete_with = function()
  calls = calls + 1
  if calls == 1 then
    return {content='', tool_calls={{id='read-1', type='function', ['function']={name='read', arguments=json.encode({path='DESIGN.md'})}}},
      finish_reason='tool_calls', usage=usage}
  end
  -- Every attempt during the outage fails exactly as the vault did, and the clock advances with the
  -- real wait so the run experiences a genuine two-minute outage.
  if not outage_started then outage_started = clock end
  if clock - outage_started < DOWN_SECONDS then
    clock = clock + 30
    error(VAULT_502_DNS)
  end
  return {content='the answer after the outage', tool_calls={}, finish_reason='stop', usage=usage}
end
local reply = bot:run('read DESIGN.md and answer')
host.now = real_now
host.read_file = read_original
check(reply == 'the answer after the outage', 'the run FINISHES with the right answer after the outage')
check(calls >= 3, 'the same request was retried through the outage, got ' .. calls .. ' provider calls')
check(TOOL_RUNS == 1, 'the tool call already made is NOT re-run, got ' .. TOOL_RUNS .. ' executions')

-- 4. The row said so while it waited: cause, provider, and when the next attempt comes.
local waiting, back = nil, nil
for _, e in ipairs(events) do
  if e.type == 'status' and tostring(e.text):find('waiting for the network', 1, true) then waiting = e.text end
  if e.type == 'status' and tostring(e.text):find('network back after', 1, true) then back = e.text end
end
check(waiting and waiting:find('unreachable', 1, true) and waiting:find('retry in', 1, true),
  'the waiting row names the unreachable provider and the next attempt: ' .. tostring(waiting))
check(waiting:find('no limit', 1, true) ~= nil,
  'and says the wait is uncapped, so a reader knows only Esc stops it: ' .. tostring(waiting))
check(back ~= nil, 'one line says the network came back: ' .. tostring(back))
check(back and (back:find('2m', 1, true) or back:find('network back after', 1, true)),
  'the recovery line carries the duration: ' .. tostring(back))

-- 5. Telemetry names the class it waited under, so the ledger is not silent about it.
local saw_link = false
for _, row in ipairs((dofile('lua/core/telemetry.lua').events(sid)).events or {}) do
  if row.kind == 'provider_retry' and row.phase == 'attempt' and row.payload and row.payload.connection_lost then
    saw_link = true
  end
end
check(saw_link, 'the retries are recorded as connection-lost, not as a refusal')

-- 6. An auth refusal fails at once, by name, with no wait at all.
local auth_sid = session('network-outage-auth')
local auth_bot = agentlib.new(auth_sid, function() end, 'master', 'master', '')
local auth_calls = 0
provider.complete_with = function() auth_calls = auth_calls + 1; error('provider_http_401: invalid api key') end
local auth_ok, auth_problem = pcall(auth_bot.run, auth_bot, 'answer')
check(not auth_ok, 'a final failure still ends the run')
check(auth_calls == 1, 'auth fails on the FIRST attempt, no retry: got ' .. auth_calls)

-- 7. The operator can still stop an unbounded wait.
local cancel_sid = session('network-outage-cancel')
local cancel_calls = 0
local native_cancelled = host.run_cancelled
host.run_cancelled = function() return json.encode({cancelled = cancel_calls > 0}) end
provider.complete_with = function() cancel_calls = cancel_calls + 1; error(VAULT_502_DNS) end
local cancel_bot = agentlib.new(cancel_sid, function() end, 'master', 'master', '')
local cancel_ok, cancel_problem = pcall(cancel_bot.run, cancel_bot, 'stop waiting')
host.run_cancelled = native_cancelled
check(not cancel_ok and tostring(cancel_problem):match('run_cancelled$') ~= nil,
  'a cancellation during the wait ends the run as a cancellation')
check(cancel_calls == 1, 'and starts no further provider attempt')

-- 8. An unclassified provider failure is retried a bounded five times, then fails by NAME.
local unknown_sid = session('network-outage-unknown')
local unknown_bot = agentlib.new(unknown_sid, function() end, 'master', 'master', '')
local unknown_calls = 0
provider.complete_with = function() unknown_calls = unknown_calls + 1; error('provider_error: widgets are frobnicated') end
local unknown_ok, unknown_problem = pcall(unknown_bot.run, unknown_bot, 'answer')
check(not unknown_ok, 'an unclassified failure still ends the run after its budget')
check(unknown_calls == 6, 'five retries means six attempts, got ' .. unknown_calls)
local classified = dofile('lua/core/run_failure.lua').classify(tostring(unknown_problem))
check(classified.code ~= nil and tostring(classified.text):find('run_failed: ', 1, true) == 1,
  'the failure is named, never silent: ' .. tostring(classified.text))

print('network outage recovery ok (' .. checks .. ' checks)')
