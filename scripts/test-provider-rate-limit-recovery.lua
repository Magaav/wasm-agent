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
-- Brief item 1: a transient error NEVER ends a run while it stays transient, so the class has NO total
-- cap by default. It used to default to 3 (2, 4, 8 s) and that ended runs a 30-second wait would have
-- finished. A bound is now set by name, and the bounded case is the identical repeat below.
check(provider.rate_limit_retries()==math.huge,
  'the refusal policy has no total cap by default (brief item 1: the operator stops it, not a counter)')
check(provider.identical_repeat_ceiling()==10,
  'while an UNCHANGED failure repeating is bounded, so a wall is not a hot loop')
check(provider.rate_limit_backoff_ms(1,1234)==1234,
  'the provider\'s own Retry-After hint is used ahead of the computed backoff')
check(provider.retry_after_ms(busy..' [retry_after_ms=2500]')==2500,
  'the hint survives the string error boundary')
check(provider.rate_limit_backoff_ms(1,nil)==0,
  'the fixture delay makes the agent retry without sleeping')
-- The backoff is the shape the brief asks for: 1 s doubling to a 30 s cap, jittered.
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_DELAY_MS=nil
local first_wait=provider.rate_limit_backoff_ms(1,nil)
check(first_wait>=750 and first_wait<=1500,'the first wait is about 1 s, got '..first_wait)
local capped_wait=provider.rate_limit_backoff_ms(20,nil)
check(capped_wait>=22500 and capped_wait<=37500,'the wait caps at 30 s, got '..capped_wait)
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_DELAY_MS='0'

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

-- ---- brief item 1: a plain 5xx waits without a total cap, and only an UNCHANGED repeat is bounded ----
-- The observed defect: a bare provider_http_503, with no link word in it, got three tries (2, 4, 8 s)
-- and ended the run. Item 1 says a transient error never ends a run while it stays transient.
-- The earlier sections of this row set a bound BY NAME (that is the documented way to bound it), so
-- it is cleared here to measure the DEFAULT the brief specifies.
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_RETRIES=nil
local plain503='lua/core/provider.lua:1405: provider_http_503: {"error":{"message":"upstream is busy"}}'
check(provider.is_rate_limited(plain503),'a plain 503 is a transient refusal')
check(provider.rate_limit_retries()==math.huge,'and it has no total cap by default')

-- (a) A long, CHANGING outage finishes: far more attempts than the old three-try cap.
local long_sid=session('provider-plain-503-long')
local long_bot=agentlib.new(long_sid,function() end,'master','master','')
local long_calls,long_events=0,{}
local long_real=long_bot.emit
long_bot.emit=function(event) long_events[#long_events+1]=event; return long_real(event) end
provider.complete_with=function()
  long_calls=long_calls+1
  if long_calls<=8 then
    -- The body changes each attempt, as a real busy upstream's does.
    error('provider_http_503: {"error":{"message":"upstream is busy, attempt '..long_calls..'"}}')
  end
  return {content='answered after a long busy spell',tool_calls={},finish_reason='stop',usage=usage}
end
local long_reply=long_bot:run('wait out a long busy spell')
check(long_reply=='answered after a long busy spell',
  'a 503 that keeps changing is waited out well past the old three-try cap, got '..long_calls..' calls')
check(long_calls==9,'it took nine attempts, not three')
local saw_uncapped=false
for _,event in ipairs(long_events) do
  if event.type=='status' and event.text and event.text:find('no limit',1,true) then saw_uncapped=true end
end
check(saw_uncapped,'the row says the wait is uncapped, not that a counter is nearly spent')

-- (b) The IDENTICAL 500 is a wall, not a queue: bounded by its own ceiling, then NAMED.
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_DELAY_MS='0'
overrides.WASM_AGENT_PROVIDER_IDENTICAL_REPEATS='3'
local wall_sid=session('provider-identical-500')
local wall_bot=agentlib.new(wall_sid,function() end,'master','master','')
local wall_calls=0
local wall='lua/core/provider.lua:1405: provider_http_500: {"error":{"message":"deployment is broken"}}'
provider.complete_with=function() wall_calls=wall_calls+1; error(wall) end
local wall_ok,wall_problem=pcall(wall_bot.run,wall_bot,'hit a wall')
check(not wall_ok,'an unchanged 500 still ends the run')
check(wall_calls==3,'it stops at its identical-repeat ceiling, got '..wall_calls)
check(tostring(wall_problem):find('the same failure repeated',1,true)~=nil,
  'and the failure NAMES why it stopped waiting: '..tostring(wall_problem))
check(tostring(wall_problem):find('provider_http_500',1,true)~=nil,
  "while keeping the provider's own words")
overrides.WASM_AGENT_PROVIDER_IDENTICAL_REPEATS=nil

-- (c) The ceiling must NOT apply where repetition is the outage itself. A link answering the same
-- "connection refused" for minutes, and a 503 with a fixed body, both repeat identically - that is what
-- an outage looks like - and bounding them would kill the very run this change exists to save.
overrides.WASM_AGENT_PROVIDER_IDENTICAL_REPEATS='3'
check(not provider.repeats_are_a_wall('provider_error: connection refused'),
  'an identical LOST LINK is not a wall: it repeats exactly this way for as long as the outage lasts')
check(not provider.repeats_are_a_wall('lua/core/provider.lua:1405: provider_http_503: {"error":"busy"}'),
  'an identical 503 is not a wall: the provider is asking us to wait')
for _, status in ipairs({'504','408','425','429','529'}) do
  check(not provider.repeats_are_a_wall('provider_http_'..status..': waiting'),
    'an identical '..status..' is not a wall')
end
check(provider.repeats_are_a_wall('provider_http_500: {"error":"broken deployment"}'),
  'an identical 500 IS a wall')
check(not provider.repeats_are_a_wall('provider_http_502: {"error":{"code":"vault_upstream_unreachable"}}'),
  'an identical vault 502 is the link, not a wall')

-- The link case end to end: twelve identical "connection refused" failures, far past the ceiling of 3,
-- and the turn still finishes when the link returns.
overrides.WASM_AGENT_PROVIDER_CONNECT_RETRIES='20'
overrides.WASM_AGENT_PROVIDER_CONNECT_WAIT_SECONDS='600'
overrides.WASM_AGENT_PROVIDER_RATE_LIMIT_DELAY_MS='0'
overrides.WASM_AGENT_PROVIDER_CONNECT_DELAY_MS='0'
host.sleep=function() end
local refused_sid=session('provider-identical-link')
local refused_bot=agentlib.new(refused_sid,function() end,'master','master','')
local refused_calls=0
provider.complete_with=function()
  refused_calls=refused_calls+1
  if refused_calls<=12 then error('lua/core/provider.lua:1208: provider_error: connection refused') end
  return {content='answered after the outage',tool_calls={},finish_reason='stop',usage=usage}
end
local refused_reply=refused_bot:run('survive an identical-failure outage')
check(refused_reply=='answered after the outage',
  'twelve IDENTICAL link failures do not end the run, got '..refused_calls..' calls')
check(refused_calls==13,'all thirteen attempts were made: the ceiling never applied to the link')

-- ...and the same for a fixed-body 503.
local busy_sid=session('provider-identical-busy')
local busy_bot=agentlib.new(busy_sid,function() end,'master','master','')
local busy_calls=0
provider.complete_with=function()
  busy_calls=busy_calls+1
  if busy_calls<=12 then error('provider_http_503: {"error":"busy"}') end
  return {content='answered after the busy spell',tool_calls={},finish_reason='stop',usage=usage}
end
check(busy_bot:run('survive an identical 503')=='answered after the busy spell',
  'twelve IDENTICAL 503s do not end the run, got '..busy_calls..' calls')
overrides.WASM_AGENT_PROVIDER_IDENTICAL_REPEATS=nil

print('provider rate-limit recovery ok ('..checks..' checks)')
