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
local real_hash=host.sha256
host.sha256=function(text)
 local ok,v=pcall(json.decode,text)
 if ok and type(v)=='table' and #v==3 and v[2]=='opencode-go' then
   return real_hash(json.encode({v[1],v[2],host.getenv('WASM_AGENT_LLM_BASE_URL'),v[3]}))
 end
 return real_hash(text)
end
local p=dofile('lua/core/provider.lua')
check(type(p.serving)=='function','compiled availability embedded')
local calls=0
local outcome={status=429,body=json.encode({type='error',error={type='GoUsageLimitError',message='Go usage limit exceeded',metadata={limitName='monthly'}}})}
host.http=function() calls=calls+1; return json.encode(outcome) end
host.http_stream=host.http
local mode=real_env('SERVING_TEST_MODE') or 'first'
if mode=='restart' then
  check(p.serving('fixture').state=='blocked','restart persisted block')
else
  check(p.serving('fixture').state=='unknown','absent state honestly unknown')
  local ok=pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{})
  check(not ok and calls==1,'authentic monthly HTTP outcome recorded')
end
local saved_env=host.getenv
local binding=p.serving_binding()
for _,endpoint in ipairs({'http://127.0.0.1:1/private-mock/','HTTP://127.0.0.1:1/private-mock','http://127.0.0.1:1/private-mock/./','http://127.0.0.1/private-mock','http://127.0.0.1:80/private-mock'}) do
  host.getenv=function(k) if k=='WASM_AGENT_LLM_BASE_URL' then return endpoint end return saved_env(k) end
  check(p.serving_binding()==binding and p.serving('fixture').state=='blocked','endpoint spelling cannot reset account block')
end
host.getenv=saved_env
local alternate=p.active();alternate.id='different-provider'
check(p.serving('fixture',alternate).state=='unknown','different provider isolated')
local before=calls
check(not pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,true,{}),'blocked streaming refused')
check(calls==before,'responsive blocked route zero HTTP calls')
key='rotated-key'
check(p.serving('other-model').state=='blocked','key rotation and other model do not clear account quota')
profile='account-b'
check(p.serving('fixture').state=='unknown','different configured account binding isolated')
local unknowns={{error='transport timeout GoUsageLimitError monthly'}, {status=429,body='assistant says GoUsageLimitError monthly'}, {status=429,body=json.encode({error={type='OtherError',metadata={limitName='monthly'}}})}}
for _,v in ipairs(unknowns) do
  outcome=v
  pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{})
  check(p.serving('fixture').state=='unknown','unsupported outcome is not quota')
end
profile='account-a'
check(p.recover_serving('wrong','verified',true).error~=nil,'wrong binding recovery refused')
check(p.recover_serving(p.serving_binding(),'verified',false).error~=nil,'unverified recovery refused')
if mode=='restart' then
  check(p.recover_serving(p.serving_binding(),'private operator verification',true).ok,'verified bound recovery')
  outcome={status=200,body=json.encode({model='fixture',choices={{message={content='actual serving'},finish_reason='stop'}}})}
  check(pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}),'authenticated success')
  check(p.serving('fixture').state=='observed_serving','actual success recorded')
end
-- Placement fixture runs real source and real SQL with only peer/API boundaries mocked.
dofile('lua/core/memory.lua').setup()
local real_dofile=dofile
local peerblocked=true
local peeridentity={node_id='cloud',model='fixture',provider='opencode-go',account_profile='cloud-account',binding=string.rep('a',64),generation=1}
local launches={}
dofile=function(path)
  if path=='lua/core/nodes.lua' then return {is_master=function() return true end,find=function() return {online=true,node_id='cloud'} end,remote_call=function(_,cap,args)
    if cap=='status' then
      if args.serving_identity_only then return {serving_identity=peeridentity} end
      local value=json.decode(json.encode(peeridentity));value.state=peerblocked and 'blocked' or 'unknown';value.reason='provider_monthly_quota'
      return {serving=value}
    end
    launches[#launches+1]='cloud';return {subagent_id='remote'}
  end} end
  if path=='lua/core/users.lua' then return {find=function() return {role='master'} end,is_master=function() return true end} end
  if path=='lua/core/provider.lua' then return {serving=function() return {state='unknown'} end} end
  return real_dofile(path)
end
local o=real_dofile('lua/core/orchestrator.lua')
local function sql(s,v) return json.decode(host.sql_exec(s,json.encode(v or {}))) end
sql('DELETE FROM orchestration_tasks');sql('DELETE FROM orchestration_policy')
local function policy(localmax,cloudmax) sql('INSERT OR REPLACE INTO orchestration_policy(owner,policy) VALUES(?,?)',{'fixture-owner',json.encode({enabled=true,nodes={{node='cloud',max_tasks=cloudmax},{node='local',max_tasks=localmax}}})}) end
local function task(id) sql('INSERT INTO orchestration_tasks(id,owner,request_key,args,context,created_at) VALUES(?,?,?,?,?,?)',{id,'fixture-owner',id,json.encode({model='fixture'}),json.encode({}),host.now()}) end
local api={control=function(args) launches[#launches+1]='local';check(args.placement.max_tasks==4,'local bound retained');return {subagent_id='local-child'} end}
policy(4,4);task('test-one');o.tick(api)
check(#launches==1 and launches[1]=='local','monthly blocked healthy peer skipped; approved local chosen')
policy(0,4);task('test-two');o.tick(api);o.tick(api)
local rows=json.decode(host.sql_query("SELECT * FROM orchestration_tasks WHERE id='test-two'",'[]'))
check(#launches==1 and rows[1].state=='queued' and rows[1].detail=='waiting_provider_serving:provider_monthly_quota','all unavailable named durable waiting without duplicate attempt')
peerblocked=false;policy(0,0);o.tick(api)
check(#launches==1,'explicit cloud0 never promoted')
print('provider-serving: '..checks..' checks, 0 skips, 0 paid calls')
