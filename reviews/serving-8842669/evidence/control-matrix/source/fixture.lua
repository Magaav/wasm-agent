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

local binding=p.serving_binding()
host.sql_exec('CREATE TABLE provider_serving(binding TEXT PRIMARY KEY,state TEXT NOT NULL,reason TEXT NOT NULL,model TEXT NOT NULL)','[]')
host.sql_exec("INSERT INTO provider_serving VALUES(?,'blocked','provider_monthly_quota','fixture')",json.encode({binding}))
check(p.serving('fixture').state=='blocked','predecessor schema migration preserves monthly block')
local before=calls;local original_now=host.now
host.now=function() return original_now()+366*24*60*60 end
check(p.serving('fixture').state=='blocked','year passage cannot recover quota')
local reads=0
host.http=function(method,url)
 assert(method=='GET','control reads cannot issue inference');reads=reads+1
 return json.encode({status=200,body=json.encode({data={{id='fixture'}},usage={monthly={status='ok',percent=0}}})})
end
p.list_models('opencode-go');p.limits()
check(reads==2 and p.serving('fixture').state=='blocked','successful catalogue and reported fresh monthly allowance are not recovery')
key='rotated-key'
check(p.serving('other-model').state=='blocked','rotated key and alternate model retain account block after controls')
check(not pcall(p.complete_with,'fixture',{{role='user',content='test'}},nil,false,{}) and calls==before,'control success never enables paid inference')
host.now=original_now
print('control matrix: '..checks..' checks, 0 skips, 0 paid calls')
