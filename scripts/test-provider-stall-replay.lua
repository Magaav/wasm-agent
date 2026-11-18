-- A provider that accepted the request and sent no response headers must be replayed, with a wait, an
-- honest bound and a count - and the deadline it waited under must follow the size of the request.
--
-- Measured 18/11, session 100c54ab (mission-fabric): "provider_stalled - timeout: receive response"
-- after 20 rounds ended the turn (rc=1). The replay that exists for exactly this case did not visibly
-- happen, and the deadline it used was one flat 90 s for every request. Three things are pinned here:
--
--   * the deadline scales with the request (base 90 s + 1 s per 4000 tokens past 32000, capped at 300);
--   * the replay predicate matches every shape of "no response headers before the deadline" - the
--     transport's own words AND the host's provider_stalled marker - and never a connect timeout;
--   * the replay WAITS (2, 4, 8 s, jittered), says so in the run, is bounded by the operator's count,
--     and a stall that survives it names the number of replays in the failure.
--
-- Hermetic: the provider is replaced before the agent runs; no paid call, no network.
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0',WASM_AGENT_PROVIDER_RESPONSE_RETRIES='1',
  WASM_AGENT_PROVIDER_RETRIES='0'}
-- A node's own provider tuning is not this row's: WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=300 in the
-- ambient environment would make the base deadline 300 s (measured on avell, 18/11, where it is set for
-- the operator's own sessions), so the row reads the deadline it sets itself and nothing else.
local cleared={WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=true}
host.getenv=function(key)
  if overrides[key]~=nil then return overrides[key] end
  if cleared[key] then return nil end
  return native_getenv(key)
end
host.http=function() error('unexpected HTTP in hermetic test') end
host.http_stream=host.http
local slept_ms=0
local real_sleep=host.sleep
host.sleep=function(ms) slept_ms=slept_ms+(tonumber(ms) or 0) end

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

-- ------------------------------------------------------------------ the deadline follows the request
check(provider.first_response_seconds()==90,'a small request keeps the 90s base deadline')
check(provider.first_response_seconds(8000)==90,'a small request gets no extra time: '
  ..tostring(provider.first_response_seconds(8000)))
check(provider.first_response_seconds(provider.FIRST_RESPONSE_FREE_TOKENS)==90,
  'the free allowance is the base, unchanged')
check(provider.first_response_seconds(36000)==91,'a large request gets more: '
  ..tostring(provider.first_response_seconds(36000)))
check(provider.first_response_seconds(200000)>90 and provider.first_response_seconds(200000)<=300,
  'a 200k-token request gets a longer, capped deadline: '..tostring(provider.first_response_seconds(200000)))
local monotone=true
local previous=provider.first_response_seconds(0)
for _,tokens in ipairs({1000,16000,32000,33000,64000,128000,256000,512000,1000000}) do
  local current=provider.first_response_seconds(tokens)
  if current<previous then monotone=false end
  previous=current
end
check(monotone,'the deadline never shrinks as the request grows')
check(provider.first_response_seconds(1000000)==provider.FIRST_RESPONSE_CEILING_SECONDS,
  'the deadline is capped: '..tostring(provider.first_response_seconds(1000000)))
overrides.WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS='120'
check(provider.first_response_seconds()==120,'the operator base is honoured: '
  ..tostring(provider.first_response_seconds()))
check(provider.first_response_seconds(36000)==121,'and the request size adds to it')
overrides.WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS='0'
check(provider.first_response_seconds(200000)==0,'0 still turns the per-call deadline off')
overrides.WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS='3'
check(provider.first_response_seconds()==10,'a deadline shorter than any request takes is raised to 10s')
overrides.WASM_AGENT_PROVIDER_FIRST_RESPONSE_SECONDS=nil

-- ------------------------------------------------------------------ every shape of "no headers" replays
local transport_stall='lua/core/provider.lua:614: provider_error: timeout: receive response (provider_stalled: no response within 90s)'
check(provider.is_response_timeout(transport_stall),'the transport wording replays')
local host_only='provider_error: edge said nothing (provider_stalled: no response within 90s)'
check(provider.is_response_timeout(host_only),
  'the host marker alone replays, whatever words the edge used: this is the shape that used to end a turn')
check(provider.is_response_timeout('provider_error: timeout: receive response'),
  'the bare transport timeout still replays')
check(not provider.is_response_timeout('provider_error: timeout: connect (provider_stalled: no response within 90s)'),
  'a connect timeout stays in the connection bucket even when the marker is on it')
check(not provider.is_response_timeout('provider_http_503: unavailable'),'an HTTP answer is not a stall')
check(not provider.is_response_timeout('provider_error: timeout: receive body'),
  'a body timeout is not safe to replay')
check(provider.response_timeout_retries()==1,'the documented default is one replay')

-- ------------------------------------------------------------------ the wait before the replay
local first=provider.response_timeout_backoff_ms(1)
local second=provider.response_timeout_backoff_ms(2)
check(first>=1500 and first<=2500,'the first wait is about 2s, jittered: '..first)
check(second>=3000 and second<=5000,'the second wait is about 4s: '..second)
check(provider.response_timeout_backoff_ms(9)<=10000,'the wait is capped: '..provider.response_timeout_backoff_ms(9))

-- ------------------------------------------------------------------ the turn survives one stall
overrides.WASM_AGENT_PROVIDER_RESPONSE_RETRIES='1'
local sid=session('provider-stall-replay')
local events={}
local bot=agentlib.new(sid,function(event) events[#events+1]=event end,'master','master','')
local calls=0
provider.complete_with=function()
  calls=calls+1
  if calls==1 then error(host_only) end
  return {content='recovered after the stall',tool_calls={},finish_reason='stop',usage=usage}
end
slept_ms=0
local reply=bot:run('answer even though the edge went quiet')
check(reply=='recovered after the stall','the turn answers after the bounded replay: '..tostring(reply))
check(calls==2,'exactly one replay: '..tostring(calls))
check(slept_ms>=1500,'the replay waited before asking again: '..tostring(slept_ms)..' ms')
local said,counted=false,false
for _,event in ipairs(events) do
  if event.type=='status' and tostring(event.text):find('did not start a response in time',1,true)
      and tostring(event.text):find('retrying in ',1,true) then said=true end
end
check(said,'the run says the retry and its wait')
check(calls==2,'and the count is one, not a hidden policy: '..tostring(calls))

-- ------------------------------------------------------------------ a stall that never clears is counted
overrides.WASM_AGENT_PROVIDER_RESPONSE_RETRIES='2'
local stuck=session('provider-stall-bounded')
local stuck_bot=agentlib.new(stuck,function() end,'master','master','')
local stuck_calls=0
provider.complete_with=function()
  stuck_calls=stuck_calls+1
  error(transport_stall)
end
slept_ms=0
local ok,problem=pcall(stuck_bot.run,stuck_bot,'never answers')
check(not ok,'a gateway that never answers fails the turn')
check(stuck_calls==3,'the bound is the operator count: 1 try + 2 replays = '..tostring(stuck_calls))
check(tostring(problem):find('after 2 bounded replay(s)',1,true)~=nil,
  'the failure counts the replays instead of reading like the first stall: '..tostring(problem))
check(tostring(problem):find('provider_stalled',1,true)~=nil,'and still carries the name the failure layer reads')
check(slept_ms>=4500,'both waits happened: '..tostring(slept_ms)..' ms')

-- ------------------------------------------------------------------ and the off-switch is respected
overrides.WASM_AGENT_PROVIDER_RESPONSE_RETRIES='0'
local off=session('provider-stall-off')
local off_bot=agentlib.new(off,function() end,'master','master','')
local off_calls=0
provider.complete_with=function() off_calls=off_calls+1; error(host_only) end
local off_ok=pcall(off_bot.run,off_bot,'do not replay')
check(not off_ok,'the operator off-switch keeps the fail-fast')
check(off_calls==1,'and sends exactly one request: '..tostring(off_calls))

host.sleep=real_sleep
print(string.format('ok provider-stall-replay: %d checks',checks))
