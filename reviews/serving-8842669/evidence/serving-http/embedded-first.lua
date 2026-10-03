
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv;local profile='account-a';local key='fixture-key'
host.getenv=function(k)
 if k=='WASM_AGENT_PROVIDER_ACCOUNT_PROFILE' then return profile end
 if k=='WASM_AGENT_LLM_API_KEY' then return key end
 return getenv(k)
end
local p=dofile('lua/core/provider.lua');local calls=0;local raw_http=host.http;local seam
host.http=function(...) calls=calls+1;local result=raw_http(...);print('RAW_HTTP '..result);if seam then seam() end;return result end
local function sql(s,v) return json.decode(host.sql_exec(s,json.encode(v or {}))) end
local checks=0;local function check(v,label) assert(v,label);checks=checks+1;print('ok '..label) end
local function call(text) return pcall(p.complete_with,'fixture',{{role='user',content=text}},nil,false,{}) end
local function recover() assert(p.recover_serving(p.serving_binding(),'private independently verified recovery',true).ok) end
if getenv('SERVING_TEST_MODE')=='restart' then
 check(p.serving('fixture').state=='blocked','real HTTP monthly block persisted across process restart')
 local before=calls;check(not call('correct') and calls==before,'persisted monthly block zero HTTP calls')
 profile='corrupt-account';before=calls
 check(p.serving('fixture').reason=='provider_eligibility_corrupt','corrupt account persisted fail closed')
 check(not call('correct') and calls==before,'corrupt restart zero HTTP calls')
 recover();check(call('correct') and p.serving('fixture').state=='observed_serving','corrupt recovery followed by genuine bound inference')
 profile='account-a'
else
 check(p.serving('fixture').state=='unknown','absent legacy state unknown')
 check(not call('monthly') and calls==1 and p.serving('fixture').state=='blocked','actual HTTP monthly429 establishes durable account block')
 local before=calls;key='rotated-key';check(not call('correct') and calls==before,'rotated key and healthy node do not probe quota')
 profile='account-b';check(p.serving('fixture').state=='unknown','other account route isolated')
 for _,text in ipairs({'other429','prose','transport'}) do call(text);check(p.serving('fixture').state=='unknown','real HTTP unsupported '..text..' not quota') end
 check(call('wrong') and p.serving('fixture').state=='unknown','HTTP200 wrong model not serving evidence')
 check(call('missing') and p.serving('fixture').state=='unknown','HTTP200 missing response model not serving evidence')
 check(call('correct') and p.serving('fixture').state=='observed_serving','actual correctly bound HTTP success certifies serving')
 recover();local binding=p.serving_binding()
 seam=function() sql("UPDATE provider_serving SET state='blocked',reason='provider_monthly_quota',model='fixture',generation=generation+1 WHERE binding=?",{binding}) end
 check(call('correct') and p.serving('fixture').state=='blocked','newer concurrent block wins real successful HTTP CAS')
 seam=nil;recover()
 seam=function() profile='account-c' end
 check(call('correct') and p.serving('fixture').state=='unknown','actual inflight account drift cannot recover foreign account')
 seam=nil;profile='account-b';check(p.serving('fixture').state=='unknown','actual inflight account drift retains original unknown')
 local old_env=host.getenv
 seam=function() host.getenv=function(k) if k=='WASM_AGENT_LLM_BASE_URL' then return getenv(k)..'/other-provider' end return old_env(k) end end
 check(call('correct') and p.serving('fixture').state=='unknown','changed provider endpoint cannot certify old request route')
 seam=nil;host.getenv=old_env
 profile='corrupt-account';check(call('correct'),'create private corrupted fixture')
 sql("UPDATE provider_serving SET state='corrupted' WHERE binding=?",{p.serving_binding()})
 before=calls;check(not call('correct') and calls==before,'corrupted durable row refuses all actual HTTP')
 profile='account-a'
end
-- Account-a remains monthly blocked for signed peer status checks.
print('real serving HTTP: '..checks..' checks, 0 skips, 0 paid calls; loopback HTTP='..calls)
