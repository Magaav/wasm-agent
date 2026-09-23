-- A provider context-overflow must compact and retry once, not brick the thread.
--
-- This deployment answers a too-large request with a bare `{"model":"deepseek-v4.1-flash"}`
-- and no words at all, so a provider-wording match alone never fires. Without a recovery the
-- thread re-sends the same oversized request on every later turn and never answers again -
-- the failure this file exists to prevent. Hermetic: HTTP is replaced before any agent runs.
local json=dofile('lua/vendor/json.lua')
local native_getenv=host.getenv
local overrides={WASM_AGENT_LLM_API_KEY='test-only',WASM_AGENT_PROVIDER='opencode-go',
  WASM_AGENT_LLM_MODEL='deepseek-v4.1-flash',WASM_AGENT_PI_MODELS_STORE='missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET='0'}
host.getenv=function(key) if overrides[key]~=nil then return overrides[key] end return native_getenv(key) end
host.http=function() error('unexpected HTTP in hermetic test') end
host.http_stream=host.http
local memory=dofile('lua/core/memory.lua'); memory.setup()
-- The agent loads its own copy of provider.lua, so the mock must be installed on the SAME
-- table the agent will use: load the provider once, pin `dofile` to it, then load the agent.
local original_dofile=dofile
local provider=dofile('lua/core/provider.lua')
dofile=function(path) if path=='lua/core/provider.lua' then return provider end return original_dofile(path) end
local agentlib=original_dofile('lua/core/agent.lua')
dofile=original_dofile
local cases=0
local function check(ok,message) assert(ok,message); cases=cases+1 end
local function session(title) return memory.start_session('',title,{user_id='master',node_id='',title=title}) end
local raw={prompt_tokens=1000,completion_tokens=200,total_tokens=1200}

-- 1. Classification: the status is the reliable half, the body is not.
check(provider.is_overflow_error('provider_http_400: {"model":"deepseek-v4.1-flash"}',900000,1000000),
  'a bare 400 near the window is an overflow')
check(not provider.is_overflow_error('provider_http_400: {"model":"deepseek-v4.1-flash"}',1000,1000000),
  'a small 400 with no words is not an overflow')
check(provider.is_overflow_error('provider_http_400: prompt is too long',1000,1000000),
  'the provider wording is recognised even for a small request')
check(provider.is_overflow_error('provider_http_413: request_too_large',1000,1000000),
  'a 413 is an overflow whatever it says')
check(not provider.is_overflow_error('provider_http_429: rate limit, too many tokens',900000,1000000),
  'a throttling error is not an overflow')
check(not provider.is_overflow_error('run_cancelled',900000,1000000),'a cancel is not an overflow')

-- 2. Headroom: a large window reserves proportionally, so the trigger lands *below* the
-- provider's real ceiling instead of above it. This is the half that prevents the 400
-- rather than recovering from it.
local windowlib=dofile('lua/core/model_window.lua')
check(windowlib.policy(1000000)>=100000,'a 1M window reserves at least ten percent')
check(windowlib.policy(128000)==16384,'a small window keeps the fixed reserve')

-- 3. The measured count is a floor even when the system prefix changed (a deploy), because
-- the estimator undercounts and a too-low count is what lets a request cross the limit.
local floor_sid=session('measured-floor')
local floor_bot=agentlib.new(floor_sid,function() end,'master','master','')
floor_bot.measured_prefix='a-prefix-that-no-longer-matches'
floor_bot.measured_messages=10
floor_bot.measured_total=900000
floor_bot.tool_list={}
local floor_tokens,floor_source=floor_bot:context_tokens({{role='system',content='x'},{role='user',content='y'}})
check(floor_tokens>=900000 and floor_source=='measured-floor','the measured count is a floor when the prefix changed')

-- 4. Recovery: the run compacts and retries once, then answers.
local sid=session('overflow-retry')
for i=1,40 do memory.append_turn(sid,{role=i%2==1 and 'user' or 'assistant',content='ROW_'..i..' '..string.rep('work ',100)}) end
local bot=agentlib.new(sid,function() end,'master','master','')
local real_budget=provider.budget
provider.budget=function() return {context=100000,reserve=16384,keep=1000,output=10000,source='test'} end
-- The context is below the compaction trigger but near the window, which is the state the
-- provider actually rejects: only the recovery path (not the ordinary trigger) may fire.
bot.context_tokens=function() return 80000,'test' end
local model_calls=0
provider.complete_with=function(_,messages,_,_,opts)
  if opts and opts.kind=='summary' then return {content='a checkpoint',tool_calls={},finish_reason='stop',usage=raw} end
  model_calls=model_calls+1
  if model_calls==1 then error('provider_http_400: {"model":"deepseek-v4.1-flash"}') end
  return {content='recovered answer',tool_calls={},finish_reason='stop',usage=raw}
end
local reply=bot:run('please continue')
check(reply=='recovered answer','an overflow is retried once and answered')
check(model_calls==2,'exactly one retry was made, not a loop')
check(memory.session(sid).summarized_until>0,'the recovery compacted the transcript')
provider.budget=real_budget
print('overflow recovery ok ('..cases..' checks)')
