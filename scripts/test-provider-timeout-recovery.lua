-- A provider that accepts a request but sends no response headers must not strand the turn.
--
-- The retry is deliberately narrower than "retry provider errors": no response means no tool call
-- can have been returned or executed, while an HTTP response or a body timeout is an ambiguous
-- completed response. It is bounded and operator-disableable because the upstream may still bill an
-- inference whose edge response was lost. Hermetic: the provider is replaced before the agent runs.
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_PROVIDER_RESPONSE_RETRIES='1'}
host.getenv=function(key) if overrides[key]~=nil then return overrides[key] end return native_getenv(key) end
host.http=function() error('unexpected HTTP in hermetic test') end
host.http_stream=host.http

local memory=dofile('lua/core/memory.lua'); memory.setup()
local original_dofile=dofile
local provider=dofile('lua/core/provider.lua')
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib=original_dofile('lua/core/agent.lua')
dofile=original_dofile

local checks=0
local function check(ok,message) assert(ok,message); checks=checks+1 end
local function session(title) return memory.start_session('',title,{user_id='master',node_id='',title=title}) end
local usage={prompt_tokens=1000,completion_tokens=20,total_tokens=1020}
local timeout='lua/core/provider.lua:614: lua/core/provider.lua:564: provider_error: timeout: receive response'

check(provider.is_response_timeout(timeout),'the observed pre-response timeout must be classified')
check(not provider.is_response_timeout('provider_error: timeout: receive body'),
  'a body timeout is not safe to replay')
check(not provider.is_response_timeout('provider_http_503: unavailable'),
  'an HTTP response is not the no-response case')
check(provider.response_timeout_retries()==1,'the configured retry count must be visible')
check(not provider.is_transient('subscription_stream_failure: stage=response_body cause=ECONNRESET; provider_error: connection reset'),
  'bridge recovery is not multiplied by the generic provider retry policy')
check(not provider.is_response_timeout('subscription_stream_failure: stage=response_headers; provider_error: timeout: receive response'),
  'bridge recovery is not multiplied by the response-timeout policy either')
-- The operator's failure: a run died before its first token with
-- `provider_error: timeout: connect`. Nothing had been sent, so it belonged in the patient,
-- default-on connection bucket and was in none of them.
local connect_timeout='lua/core/provider.lua:1191: lua/core/provider.lua:1131: provider_error: timeout: connect'
check(provider.is_connection_lost(connect_timeout),
  'a connect-phase timeout takes the patient connection policy: nothing was sent, so replaying is safe')
check(not provider.is_response_timeout(connect_timeout),
  'a connect timeout is not the pre-response bucket: it never reached the provider at all')
check(not provider.is_connection_lost('provider_error: timeout: receive response'),
  'a receive timeout stays in its own smaller budget: the request was sent and may have been billed')
check(provider.connection_retries() >= 1,
  'the patient policy for a lost link is on by default, not opt-in like the transient budget')

local sid=session('provider-timeout-retry')
local bot=agentlib.new(sid,function() end,'master','master','')
local calls=0
local attempts={}
provider.complete_with=function(_, messages, _, _, opts)
  calls=calls+1
  attempts[#attempts+1]={round=opts.round,attempt=opts.attempt or 1,content=messages[#messages].content}
  if calls==1 then error(timeout) end
  return {content='recovered answer',tool_calls={},finish_reason='stop',usage=usage}
end
local reply=bot:run('continue after the edge timeout')
check(reply=='recovered answer','the turn must answer after the bounded retry')
check(calls==2,'one timeout must produce exactly one retry')
check(attempts[1].round==1 and attempts[2].round==1 and
  attempts[1].attempt==1 and attempts[2].attempt==2 and
  attempts[1].content==attempts[2].content,
  'two provider attempts in one decision step replay the same input on response timeout')

overrides.WASM_AGENT_PROVIDER_RESPONSE_RETRIES='0'
local disabled=session('provider-timeout-disabled')
local disabled_bot=agentlib.new(disabled,function() end,'master','master','')
local disabled_calls=0
provider.complete_with=function() disabled_calls=disabled_calls+1; error(timeout) end
local ok,problem=pcall(disabled_bot.run,disabled_bot,'do not retry')
check(not ok and tostring(problem):find('timeout: receive response',1,true),
  'the original timeout must remain visible when retry is disabled')
check(disabled_calls==1,'the operator off-switch must prevent the retry')

print('provider timeout recovery ok ('..checks..' checks)')

-- End to end: the operator-observed failure must not end the run. A connect timeout before the
-- first token takes the patient, default-on connection policy, so a link that returns mid-budget
-- still produces an answer instead of a dead turn. One retry here, bounded by env.
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES='1'
local connect_sid=session('provider-connect-timeout-recovery')
local connect_bot=agentlib.new(connect_sid,function() end,'master','master','')
local connect_calls=0
provider.complete_with=function(_,messages,_,_,opts)
  connect_calls=connect_calls+1
  if connect_calls==1 then error(connect_timeout) end
  return {content='answered after the link returned',tool_calls={},finish_reason='stop',usage=usage}
end
local connect_reply=connect_bot:run('answer even though the edge dropped the connect')
check(connect_reply=='answered after the link returned',
  'a connect-phase timeout must not end the run once the link is back')
check(connect_calls==2,'the patient policy replays the unsatisfied connect exactly once here')
print('provider connect-timeout recovery ok ('..checks..' checks)')
