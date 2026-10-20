-- A provider refusal must not end the run.
--
-- The observed failure: `provider_http_429: ... Upstream request failed: Endpoint is unavailable.`
-- An HTTP refusal is not an ambiguous lost inference - the provider answered and did not serve the
-- request, so replaying it later cannot duplicate a tool call and cannot be billed a second time.
-- It therefore takes pi's default retry policy (three attempts, 2 s doubling to a 60 s cap) and
-- honours `Retry-After` when the host exposes it. A terminal quota/billing 429 keeps its landed
-- outcome, and the ambiguous transport budget stays opt-in.
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_PROVIDER_RATE_LIMIT_DELAY_MS='0'}
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
local busy='lua/core/provider.lua:1199: lua/core/provider.lua:1141: provider_http_429: ' ..
  '{"error":{"type":"server_error","message":"Upstream request failed: Endpoint is unavailable."}}'

check(provider.is_rate_limited(busy),
  'an HTTP 429 is a refusal: the provider answered and did not serve the request')
check(provider.is_rate_limited('provider_http_503: unavailable'),
  'a 5xx response belongs in the same default-on bucket')
check(not provider.is_rate_limited('provider_http_400: bad request'),
  'a client error is not retried')
check(not provider.is_rate_limited('provider_error: connection reset'),
  'a missing response keeps the ambiguous opt-in policy, not the refusal policy')
check(not provider.is_rate_limited('provider_http_429: {"error":{"type":"GoUsageLimitError",' ..
  '"metadata":{"limitName":"monthly"}}}'),
  'a terminal monthly quota is a landed outcome, not a wait')
check(not provider.is_rate_limited('subscription_http_429: busy'),
  'the subscription bridge keeps its own visible reconnect cycles')
check(provider.rate_limit_retries()==3,
  'the refusal policy is on by default with pi\'s three attempts')
check(provider.rate_limit_backoff_ms(1,1234)==1234,
  'the provider\'s own Retry-After hint is used ahead of the computed backoff')
check(provider.retry_after_ms(busy..' [retry_after_ms=2500]')==2500,
  'the hint survives the string error boundary')
check(provider.rate_limit_backoff_ms(1,nil)==0,
  'the fixture delay makes the agent retry without sleeping')

local sid=session('provider-rate-limit-retry')
local bot=agentlib.new(sid,function() end,'master','master','')
local calls=0
local attempts={}
provider.complete_with=function(_, messages, _, _, opts)
  calls=calls+1
  attempts[#attempts+1]={round=opts.round,attempt=opts.attempt or 1,content=messages[#messages].content}
  if calls==1 then error(busy..' [retry_after_ms=2500]') end
  return {content='recovered answer',tool_calls={},finish_reason='stop',usage=usage}
end
local reply=bot:run('continue through the rate limit')
check(reply=='recovered answer','the turn must answer after the refusal clears')
check(calls==2,'one 429 must produce exactly one retry')
check(attempts[1].round==1 and attempts[2].round==1 and
  attempts[1].attempt==1 and attempts[2].attempt==2 and
  attempts[1].content==attempts[2].content,
  'the retry replays the same decision step and the same input')

-- The operator off-switch disables the whole provider retry surface, including this bucket.
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_RETRIES='0'
local disabled=session('provider-rate-limit-disabled')
local disabled_bot=agentlib.new(disabled,function() end,'master','master','')
local disabled_calls=0
provider.complete_with=function() disabled_calls=disabled_calls+1; error(busy) end
local ok,problem=pcall(disabled_bot.run,disabled_bot,'do not retry')
check(not ok and tostring(problem):find('provider_http_429',1,true),
  'the original refusal must remain visible when retry is disabled')
check(disabled_calls==1,'the operator off-switch must prevent the retry')

-- Exhaustion is visible, not silent: after the budget the run still fails with the provider's
-- reason, and the turn is recorded as a landed failure rather than a fake answer.
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_RETRIES='2'
local exhausted=session('provider-rate-limit-exhausted')
local exhausted_bot=agentlib.new(exhausted,function() end,'master','master','')
local exhausted_calls=0
provider.complete_with=function() exhausted_calls=exhausted_calls+1; error(busy) end
local exhausted_ok,exhausted_problem=pcall(exhausted_bot.run,exhausted_bot,'give up after the budget')
check(not exhausted_ok and tostring(exhausted_problem):find('provider_http_429',1,true),
  'an exhausted retry budget surfaces the refusal')
check(exhausted_calls==3,'two retries means three provider attempts in total')

print('provider rate-limit recovery ok ('..checks..' checks)')
