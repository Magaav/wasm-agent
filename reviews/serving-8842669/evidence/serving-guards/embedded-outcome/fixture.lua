-- Private WA_SCRIPT fixture: real provider/orchestrator, SQLite and embedded Lua.
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(v,label) assert(v,label); checks=checks+1; print('ok '..label) end
local real_env=host.getenv
local profile='account-a'
local key='fixture-key'
host.getenv=function(k)
  if k=='WASM_AGENT_PROVIDER_ACCOUNT_PROFILE' then return profile end
  if k=='WASM_AGENT_LLM_API_KEY' then return key end
  if k=='WASM_AGENT_LLM_MODEL' then return 'fixture' end
  if k=='WASM_AGENT_LLM_BASE_URL' then return 'http://127.0.0.1:1/private-mock' end
  return real_env(k)
end
local p=dofile('lua/core/provider.lua')
check(type(p.serving)=='function','compiled availability embedded')
local calls=0
local outcome={status=429,body=json.encode({type='error',error={type='GoUsageLimitError',message='Go usage limit exceeded',metadata={limitName='monthly'}}})}
host.http=function() calls=calls+1; return json.encode(outcome) end
host.http_stream=host.http
host.http=function() calls=calls+1;return json.encode({status=500,body=outcome.body}) end
-- Appended to the shared private fixture prelude by test-serving-contract.cjs.
local mode=real_env('SERVING_TEST_MODE') or 'first'
local binding=p.serving_binding()
local function sql(statement,values) return json.decode(host.sql_exec(statement,json.encode(values or {}))) end
local function recover() check(p.recover_serving(p.serving_binding(),'independently verified private fixture recovery',true).ok,'explicit bound recovery') end
if mode=='restart' then
  check(p.serving('fixture').reason=='provider_eligibility_corrupt','corrupt state survives restart fail closed')
  local before=calls
  check(not pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}),'corrupt restart refuses inference')
  check(calls==before,'corrupt restart zero paid or HTTP calls')
  recover()
else
  check(p.serving('fixture').state=='unknown','legacy absent state unknown')
  pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{})
  check(p.serving('fixture').state=='blocked','real structured monthly seam block')
end
for _,mutation in ipairs({"state='corrupted'","reason='other_reason'","model=''","generation=-1","generation='invalid'"}) do
  recover()
  sql("UPDATE provider_serving SET state='blocked',reason='provider_monthly_quota',model='fixture',generation=1 WHERE binding=?",{binding})
  sql('UPDATE provider_serving SET '..mutation..' WHERE binding=?',{binding})
  local before=calls
  check(p.serving('fixture').reason=='provider_eligibility_corrupt','invalid persisted eligibility fails closed: '..mutation)
  check(not pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}) and calls==before,'invalid state zero HTTP calls: '..mutation)
end
recover()
outcome={status=200,body=json.encode({model='wrong-model',choices={{message={content='foreign response'},finish_reason='stop'}}})}
check(pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}),'foreign response returned without recovery evidence')
check(p.serving('fixture').state=='unknown','wrong model cannot certify serving')
outcome={status=200,body=json.encode({choices={{message={content='unbound response'},finish_reason='stop'}}})}
p.complete_with('fixture',{{role='user',content='test'}},nil,false,{})
check(p.serving('fixture').state=='unknown','missing response model cannot certify serving')
outcome={status=200,body=json.encode({model='fixture',choices={{message={content='unfinished response'}}}})}
p.complete_with('fixture',{{role='user',content='test'}},nil,false,{})
check(p.serving('fixture').state=='unknown','missing completion marker cannot certify serving')
local previous_http=host.http
outcome={status=200,body=json.encode({model='fixture',choices={{message={content='correct response'},finish_reason='stop'}}})}
host.http=function(...)
  local response=previous_http(...)
  sql("UPDATE provider_serving SET state='blocked',reason='provider_monthly_quota',model='fixture',generation=generation+1 WHERE binding=?",{binding})
  return response
end
p.complete_with('fixture',{{role='user',content='test'}},nil,false,{})
check(p.serving('fixture').state=='blocked','stale correctly modeled success cannot clear newer block')
recover()
host.http=function(...)
  local response=previous_http(...)
  sql("UPDATE provider_serving SET generation=generation+2 WHERE binding=?",{binding})
  return response
end
p.complete_with('fixture',{{role='user',content='test'}},nil,false,{})
check(p.serving('fixture').state=='unknown','unknown recovery ABA cannot be overwritten by stale success')
host.http=previous_http
p.complete_with('fixture',{{role='user',content='test'}},nil,false,{})
check(p.serving('fixture').state=='observed_serving','genuine exact request response certifies serving')
recover()
host.http=function(...)
  local response=previous_http(...);profile='account-b';return response
end
p.complete_with('fixture',{{role='user',content='test'}},nil,false,{})
check(p.serving('fixture').state=='unknown','inflight account drift cannot certify different account')
profile='account-a';host.http=previous_http
check(p.serving('fixture').state=='unknown','inflight account drift cannot recover original account')
local identity=p.serving_identity('fixture')
check(identity.model=='fixture' and identity.binding==binding,'independent route identity names requested model')
check(p.serving_identity('fixture','wrong-provider')==nil,'unsupported explicit provider override stays unavailable')
profile='account-b'
check(p.serving_status(identity).reason=='serving_identity_changed','active account change between status phases stays unknown')
profile='account-a'
local real_dofile=dofile
local peeridentity={node_id='peer',model='fixture',provider='opencode-go',account_profile='peer-account',binding=string.rep('a',64),generation=3}
local first,second,reads
local function reset()
  first={serving_identity=json.decode(json.encode(peeridentity))}
  second={serving=json.decode(json.encode(peeridentity))};second.serving.state='blocked';second.serving.reason='provider_monthly_quota'
  reads=0
end
dofile=function(path)
  if path=='lua/core/nodes.lua' then return {find=function() return {node_id='peer'} end,remote_call=function(_,cap,args)
    assert(cap=='status');reads=reads+1
    if args.serving_identity_only then return first end
    check(args.serving_identity.node_id=='peer' and args.serving_identity.model=='fixture','second read carries independently requested tuple')
    return second
  end} end
  return real_dofile(path)
end
local o=real_dofile('lua/core/orchestrator.lua')
reset();check(o.serving_eligible('peer','fixture','opencode-go')==false,'exact bound signed metadata blocks placement')
for _,field in ipairs({'node_id','model','provider','account_profile','binding','generation'}) do
  reset();second.serving[field]=field=='generation' and 4 or 'foreign'
  check(o.serving_eligible('peer','fixture','opencode-go')==true,'foreign second-phase '..field..' cannot block requested route')
end
for _,field in ipairs({'node_id','model','provider'}) do
  reset();first.serving_identity[field]='foreign'
  check(o.serving_eligible('peer','fixture','opencode-go')==true and reads==1,'hostile first-phase '..field..' cannot replace caller intent')
end
reset();first={};second={model_error='provider_monthly_quota'}
check(o.serving_eligible('peer','fixture')==true,'bare model error remains unknown')
reset();second={model_error='provider_monthly_quota'}
check(o.serving_eligible('peer','fixture')==true,'bare second-phase model error remains unknown')
reset();second={};check(o.serving_eligible('peer','fixture')==true,'old peer absent metadata remains unknown')
dofile=real_dofile
-- Leave corruption durable so the next separate process must fail closed.
sql("UPDATE provider_serving SET state='corrupted' WHERE binding=?",{binding})
print('serving-contract: '..checks..' checks, 0 skips, 0 paid calls')
