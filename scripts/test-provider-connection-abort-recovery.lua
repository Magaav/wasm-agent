-- A host-side socket abort is a lost link, not a terminal provider answer.
--
-- Observed incident: a mid-run internet outage ended the turn with
--   lua/core/provider.lua:1268: lua/core/provider.lua:1208: provider_error: io: An established
--   connection was aborted by the software in your host machine. (os error 10053).
-- The text matched neither CONNECTION_TEXT (the default-on patient bucket) nor TRANSIENT_TEXT
-- (opt-in, 0 by default), so the agent's retry loop never ran; after the internet returned the
-- operator had to press Continue. Hermetic: the provider is replaced before the agent runs, so no
-- network, inference or live node state is touched.
local json=dofile('lua/vendor/json.lua')
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0'}
host.getenv=function(key) if overrides[key]~=nil then return overrides[key] end return native_getenv(key) end
host.http=function() error('unexpected HTTP in hermetic test') end
host.http_stream=host.http
-- The backoff budget is what this fix is about; its duration is not. The wait loop still counts
-- every slice and checks cancellation between slices.
host.sleep=function() end
local native_cancelled=host.run_cancelled
local native_subagent=host.subagent

local memory=dofile('lua/core/memory.lua'); memory.setup()
local telemetry=dofile('lua/core/telemetry.lua')
local original_dofile=dofile
local provider=dofile('lua/core/provider.lua')
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib=original_dofile('lua/core/agent.lua')
dofile=original_dofile

local checks=0
local function check(ok,message) assert(ok,message); checks=checks+1 end
local function session(title) return memory.start_session('',title,{user_id='master',node_id='',title=title}) end
local usage={prompt_tokens=1000,completion_tokens=20,total_tokens=1020}
local incident='lua/core/provider.lua:1268: lua/core/provider.lua:1208: provider_error: io: ' ..
  'An established connection was aborted by the software in your host machine. (os error 10053).'

-- 1. The exact observed shape takes the patient connection policy AND is retryable; the agent's
-- loop condition reads the second, so a connection pattern in one list alone would retry nothing.
check(provider.is_connection_lost(incident),
  'the observed Windows socket abort chooses the patient connection policy')
check(provider.is_transient(incident),
  'the same text is retryable, or the connection loop above it never runs')
check(provider.is_connection_lost('provider_error: connection was aborted'),
  'the phrase without the io:/errno tail still classifies')
check(provider.is_connection_lost('provider_error: os error 10053'),
  'the numeric errno alone still classifies')
check(provider.is_connection_lost('provider_error: an established connection was aborted'),
  'the established-socket spelling classifies')
check(provider.is_connection_lost('provider_error: connection aborted'),
  'the shorter abort spelling stays in the same class')
check(provider.is_connection_lost('provider_error: connection reset'),
  'the existing connection-loss shapes keep working')
check(provider.is_connection_lost('provider_error: timeout: connect'),
  'the earlier connect-timeout fix is not regressed')

-- 2. Nearby terminal/provider answers must stay terminal.
check(not provider.is_connection_lost('provider_http_400: {"error":{"message":"bad request"}}'),
  'a request refusal is not a lost link')
check(not provider.is_connection_lost('provider_http_401: invalid api key'),
  'an auth refusal is not a lost link')
check(not provider.is_connection_lost('provider_error: invalid api key'),
  'a provider-side auth error is not a lost link')
check(not provider.is_connection_lost('provider_error: model does not support this protocol'),
  'a route refusal is not a lost link')
check(not provider.is_connection_lost('provider_http_429: {"error":{"message":"monthly quota"}}'),
  'a rate-limit refusal is not a lost link')
check(not provider.is_connection_lost('run_cancelled'),'a user cancellation is not a lost link')
check(not provider.is_connection_lost('subagent_cancelled'),'a child cancellation is not a lost link')
check(not provider.is_connection_lost('provider_error: timeout: receive response'),
  'a sent request that timed out stays in its own smaller budget')
check(not provider.is_response_timeout(incident),
  'the abort keeps the pre-response timeout budget out of it')
check(not provider.is_rate_limited(incident),'the abort is not misread as an HTTP refusal')
local subscription_abort='subscription_stream_failure: stage=response_body cause=ECONNABORTED; ' .. incident
check(not provider.is_connection_lost(subscription_abort),
  'the subscription bridge keeps its own reconnect cycle')
check(not provider.is_transient(subscription_abort),
  'the subscription exclusion is unchanged in the transient classifier too')

-- 3. The patient defaults the incident must inherit: bounded, not a new scheduler.
check(provider.connection_retries()==20,'the patient default is 20 attempts')
check(provider.connection_wait_seconds()==900,'the patient default waits up to 900 s')

-- 4. The existing loop replays it, visibly, and answers after the link returns.
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES='1'
overrides.WASM_AGENT_PROVIDER_CONNECT_WAIT_SECONDS='30'
local sid=session('provider-connection-abort-retry')
local events={}
local bot=agentlib.new(sid,function(e) events[#events+1]=e end,'master','master','')
local calls=0
provider.complete_with=function(_,messages,_,_,opts)
  calls=calls+1
  if calls==1 then error(incident) end
  return {content='recovered answer',tool_calls={},finish_reason='stop',usage=usage}
end
check(bot:run('keep trying while the link is down')=='recovered answer',
  'the turn answers after the socket abort clears')
check(calls==2,'one abort produces exactly one replay')
local status
for _,event in ipairs(events) do
  if event.type=='status' and tostring(event.text):find('network appears down',1,true) then status=event.text end
end
check(status and status:find('(1/1)',1,true) and status:find('waiting up to 30s',1,true),
  'the wait is visible: cause and attempt/limit plus the link budget')
local ledger=telemetry.events(sid)
local retry
for _,row in ipairs(ledger.events or {}) do
  if row.kind=='provider_retry' and row.phase=='attempt' then retry=row.payload end
end
check(ledger.available and retry and retry.connection_lost==true and retry.attempt==1
    and retry.limit==1 and retry.wait_ms and retry.wait_ms>0,
  'telemetry names the replay and the connection-loss class')

-- 5. The budget stays finite: exhaustion surfaces the original abort.
local exhausted_sid=session('provider-connection-abort-exhausted')
local exhausted_bot=agentlib.new(exhausted_sid,function() end,'master','master','')
local exhausted_calls=0
provider.complete_with=function() exhausted_calls=exhausted_calls+1; error(incident) end
local exhausted_ok,exhausted_problem=pcall(exhausted_bot.run,exhausted_bot,'give up after the budget')
check(not exhausted_ok and tostring(exhausted_problem):find('os error 10053',1,true),
  'an exhausted budget still surfaces the original abort')
check(exhausted_calls==2,'one retry means two provider attempts, then the run fails')

-- 6. The operator off-switch still prevents every replay.
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES='0'
local disabled_sid=session('provider-connection-abort-disabled')
local disabled_bot=agentlib.new(disabled_sid,function() end,'master','master','')
local disabled_calls=0
provider.complete_with=function() disabled_calls=disabled_calls+1; error(incident) end
local disabled_ok,disabled_problem=pcall(disabled_bot.run,disabled_bot,'do not retry')
check(not disabled_ok and tostring(disabled_problem):find('os error 10053',1,true),
  'the original abort stays visible with retry disabled')
check(disabled_calls==1,'the off-switch prevents the replay')

-- 7. Cancellation lands during the wait and stops it without another provider attempt.
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES='2'
local cancel_sid=session('provider-connection-abort-cancelled')
local cancel_calls=0
host.run_cancelled=function() return json.encode({cancelled=cancel_calls>0}) end
provider.complete_with=function() cancel_calls=cancel_calls+1; error(incident) end
local cancel_bot=agentlib.new(cancel_sid,function() end,'master','master','')
local cancel_ok,cancel_problem=pcall(cancel_bot.run,cancel_bot,'cancel during the wait')
check(not cancel_ok and tostring(cancel_problem):match('run_cancelled$')~=nil
    and not tostring(cancel_problem):find('os error 10053',1,true),
  'a foreground cancellation stops the connection wait as a cancellation')
check(cancel_calls==1,'cancellation does not start another provider attempt')

-- 8. A cancelled child stops the same loop with the child's own reason.
local child_sid=session('provider-connection-abort-child-cancelled')
local child_calls=0
host.run_cancelled=function() return json.encode({cancelled=false}) end
host.subagent=function() return json.encode({cancelled=child_calls>0}) end
provider.complete_with=function() child_calls=child_calls+1; error(incident) end
local child=agentlib.new(child_sid,function() end,'master','master','',{subagent={limits={}}})
local child_ok,child_problem=pcall(child.run,child,'stop the child during the wait')
check(not child_ok and tostring(child_problem):match('subagent_cancelled$')~=nil
    and not tostring(child_problem):find('os error 10053',1,true),
  'a child cancellation stops the connection wait as a subagent cancellation')
check(child_calls==1,'a cancelled child is not re-asked')

host.run_cancelled=native_cancelled
host.subagent=native_subagent
print('provider connection abort recovery ok ('..checks..' checks)')
