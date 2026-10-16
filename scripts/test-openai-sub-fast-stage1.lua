-- Offline only. Run with explicit WASM_AGENT_LUA_ROOT and private home/DB.
local policy=dofile('lua/core/openai_sub_fast_policy.lua')
local wire=dofile('lua/core/subscription_wire.lua')
local catalogue=dofile('lua/core/openai_sub_catalogue.lua')
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(value, message) assert(value,message); checks=checks+1 end
local function eq(a,b,message) check(a==b,message) end
local function refuses(fn, expected)
  local ok,err=pcall(fn)
  check(not ok and tostring(err):find(expected,1,true),expected)
end
-- Any accidental transport/auth access fails immediately, not a live probe.
host.http_sse=function() error('FORBIDDEN_NETWORK') end
host.http=function() error('FORBIDDEN_NETWORK') end
for _,model in ipairs({'gpt-6.1-sol','gpt-6-astra','gpt-6-sol','gpt-6-luna'}) do
  local entry=catalogue.get(model)
  local original=wire.body(model,{{role='user',content='synthetic'}},nil,{},'low',entry)
  original.service_tier='ultrafast' -- stale/default expensive tier must be cleared OFF
  local before=json.encode(original)
  for _,enabled in ipairs({false,true}) do
    local selection=policy.selection('openai-sub',model,enabled,entry)
    eq(selection.account_entitlement,'unknown','no account claim')
    local body=policy.request(original,selection)
    eq(body.model,model,'model unchanged')
    eq(body.reasoning.effort,original.reasoning.effort,'reasoning unchanged')
    eq(body.reasoning.effort,'low','LOW preserved')
    eq(body.service_tier,enabled and 'priority' or nil,'native tier representation')
    local decoded=json.decode(json.encode(body))
    eq(decoded.service_tier,enabled and 'priority' or nil,'serialized tier')
    eq(json.encode(original),before,'caller not mutated')
    body.service_tier=original.service_tier
    eq(json.encode(body),before,'only tier changes, including tool/concurrency fields')
  end
end
local off=policy.selection('openai-sub','unknown',nil)
eq(off.enabled,false,'missing preference defaults OFF')
eq(policy.request({},off).service_tier,nil,'unknown model OFF works')
refuses(function() policy.selection('openai-sub','unknown',true) end,'fast_mode_model_unknown')
refuses(function() policy.selection('openai-sub','gpt-5.5',true,catalogue.get('gpt-5.5')) end,'fast_mode_model_unknown')
refuses(function() policy.selection('openai-sub','gpt-6.1-sol','true') end,'fast_mode_invalid_boolean')
refuses(function() policy.selection('openai-sub','gpt-6.1-sol',true,{id='other'}) end,'fast_mode_metadata_model_mismatch')
refuses(function() policy.selection('openai-sub','gpt-6.1-sol',true,{id='gpt-6.1-sol',service_tiers={}}) end,'fast_mode_model_unsupported')
for _,provider in ipairs({'opencode-go','openai','unknown'}) do
  local selection=policy.selection(provider,'gpt-6.1-sol',true)
  eq(selection.applicable,false,'provider not applicable')
  eq(selection.enabled,true,'preference retained')
  eq(policy.request({model='same'},selection).service_tier,nil,'no tier injection')
  eq(policy.observation(selection,{}).requested,nil,'no requested tier for other provider')
end
for _,tier in ipairs({'priority','fast'}) do
  local selection=policy.selection('openai-sub','future',true,{id='future',service_tiers={{id=tier}}})
  eq(policy.request({},selection).service_tier,tier,'advertised exact tier id')
end
local on=policy.selection('openai-sub','gpt-6.1-sol',true)
for _,response in ipairs({{}, {service_tier=''}, {service_tier=false}}) do
  local observed=policy.observation(on,response)
  eq(observed.actual,nil,'missing/malformed actual not inferred')
  eq(observed.actual_known,false,'actual unknown')
  eq(observed.matches_requested,nil,'match unknown')
end
local usage={input_tokens=100,output_tokens=20,total_tokens=120,
  input_tokens_details={cached_tokens=40},output_tokens_details={reasoning_tokens=5}}
local response={service_tier='default',usage=usage}
local before=json.encode(response)
local observed=policy.observation(on,response)
eq(observed.requested,'priority','requested retained')
eq(observed.actual,'default','downgrade visible')
eq(observed.matches_requested,false,'downgrade not success')
eq(json.encode(response),before,'raw counts unchanged, no premium multiplication')
eq(policy.observation(on,{service_tier='fast'}).matches_requested,true,'fast/priority alias')
eq(policy.observation(on,{service_tier='ultrafast'}).matches_requested,false,'ultrafast distinct')
eq(policy.observation(off,{service_tier='default'}).matches_requested,true,'standard reported')
-- Exercise native parser actual-tier capture with a synthetic terminal response.
response.status='completed'
response.id='resp_synthetic_fast_stage1'
response.output={}
local session=wire.session()
session.event('response.completed',json.encode({type='response.completed',response=response}))
local parsed=session.result('gpt-6.1-sol')
eq(parsed.usage.prompt_tokens,100,'native raw input unchanged')
eq(parsed.usage.completion_tokens,20,'native raw output unchanged')
eq(parsed.usage.total_tokens,120,'native total unchanged')
eq(parsed.usage.prompt_tokens_details.cached_tokens,40,'native cache unchanged')
eq(parsed.usage.completion_tokens_details.reasoning_tokens,5,'native reasoning count unchanged')
eq(parsed.service_tier,'default','native parser captures actual terminal tier')
eq(policy.observation(on,parsed).actual_known,true,'terminal metadata remains known')
print('openai-sub fast stage1 ok ('..checks..' checks; no network)')
