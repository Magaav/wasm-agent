-- Private synthetic native/broker request, persistence, pin and scope proof.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local paths=dofile('lua/core/paths.lua')
local native=host.getenv
local env={WASM_AGENT_PROVIDER='openai-sub',WASM_AGENT_OPENAI_SUB_VAULT_URL='native',
 WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/fast-fixture/credentials.json',
 WASM_AGENT_SUBSCRIPTION_TRANSPORT_RETRIES='0',WASM_AGENT_LLM_SUMMARY_MODEL='gpt-6-sol'}
host.getenv=function(k)if env[k]~=nil then return env[k] end return native(k) end
local credential={version=1,provider='openai-codex',type='oauth',access='synthetic-fast-access',refresh='synthetic-fast-refresh',expires=host.now()*1000+3600000,account_id='synthetic-account',generation='native-fast-1'}
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(credential)))
local checks,calls=0,0
local function check(v,label) checks=checks+1;assert(v,label) end
local function eq(a,b,label)check(a==b,label..' got '..tostring(a))end
local actual='priority';local status=200;local requests={};local broker_generation='broker-fast-1'
host.http=function(method,url)
 if url:find('/status',1,true) then return json.encode({status=200,body=json.encode({providers={['openai-sub']={configured=true,enabled=true,generation=broker_generation}}})}) end
 error('unexpected HTTP '..url)
end
host.http_sse=function(method,url,headers,body,line)
 calls=calls+1
 requests[#requests+1]={body=json.decode(body),headers=json.decode(headers),url=url}
 if status~=200 then return json.encode({status=status,body='Fast refused synthetic',termination='http_error'}) end
 local response={id='resp_fast_fixture',model='gpt-6.1-sol',status='completed',service_tier=actual,
 output={{type='message',id='msg_fixture',role='assistant',phase='final_answer',content={{type='output_text',text='synthetic answer'}}}},
 usage={input_tokens=100,output_tokens=20,total_tokens=120,input_tokens_details={cached_tokens=40},output_tokens_details={reasoning_tokens=5}}}
 line('data: '..json.encode({type='response.completed',response=response}));line('')
 return json.encode({status=200,termination='callback_stopped'})
end
local provider=dofile('lua/core/provider.lua')
local state=dofile('lua/core/state.lua')
local scope={role='master'}
local function call(kind)
 return provider.complete_with(kind=='summary' and 'gpt-6-sol' or 'gpt-6.1-sol',{{role='user',content='fixture'}},nil,false,{kind=kind or 'model_call'})
end
if native('WA_FAST_RESTART')=='1' then
 eq(provider.fast_mode('gpt-6.1-sol',scope).preference,'coding','restart preference restored')
 provider.pin(scope);call();eq(requests[#requests].body.service_tier,'priority','restart honored');provider.unpin()
 print('fast mode restart ok ('..checks..' checks, 0 paid calls)');return
end
assert(provider.set_provider('openai-sub'))
assert(provider.set_model('gpt-6.1-sol'))
assert(provider.set_reasoning('low'))
eq(provider.fast_mode(nil,scope).enabled,false,'old default OFF')
local rev=state.revision();assert(provider.set_fast_mode('on',rev))
local ok,err=provider.set_fast_mode('off',rev);eq(ok,false,'stale CAS refused');eq(err,'settings_conflict','CAS reason')
eq(provider.fast_mode(nil,scope).enabled,true,'master preference ON')
provider.pin(scope)
local pinned_revision=provider.selection_revision()
local other=dofile('lua/core/provider.lua')
assert(other.set_fast_mode('off',state.revision()))
local result=call();eq(requests[#requests].body.service_tier,'priority','in-flight snapshot ON')
eq(requests[#requests].body.reasoning.effort,'low','LOW unchanged')
eq(result.fast_mode.actual,'priority','actual native reported')
eq(result.fast_mode.requested,'priority','requested retained')
eq(result.request_meta.fast_mode.requested,'priority','requested metadata for UI')
eq(result.observation.fast_mode.actual,'priority','actual in observation payload')
eq(result.usage.total_tokens,120,'raw counts unchanged')
eq(provider.selection_revision(),pinned_revision,'revision pinned')
call('summary');eq(requests[#requests].body.model,'gpt-6-sol','summary model unchanged');eq(requests[#requests].body.service_tier,'priority','summary follows pin')
provider.unpin();provider.pin(scope);call();eq(requests[#requests].body.service_tier,nil,'next run OFF omission');provider.unpin()
assert(provider.set_fast_mode('on',state.revision()))
for _,s in ipairs({{role='guest'},{role='master',profile='whatsapp-responder'},{role='master',profile='explore'},{role='master',profile='orchestration-worker'}}) do
 provider.pin(s);call();eq(requests[#requests].body.service_tier,nil,'unapproved scope OFF');provider.unpin()
end
assert(provider.set_fast_mode('coding',state.revision()))
provider.pin({role='master',profile='orchestration-worker'});call();eq(requests[#requests].body.service_tier,'priority','explicit coding inheritance');provider.unpin()
provider.pin(scope);actual=nil;result=call();eq(result.fast_mode.actual_known,false,'missing actual unknown')
actual='default';result=call();eq(result.fast_mode.matches_requested,false,'downgrade visible')
status=400;local before=calls;ok,err=pcall(call);check(not ok,'Fast rejection visible');eq(calls,before+1,'no hidden tier retry/fallback');status=200;provider.unpin()
assert(provider.set_provider('opencode-go'));eq(provider.fast_mode(nil,scope).applicable,false,'Go inert');eq(provider.fast_mode(nil,scope).preference,'coding','preference retained on switch')
assert(provider.set_provider('openai-sub'));assert(provider.set_model('gpt-5.5'))
check(provider.fast_mode(nil,scope,true).error~=nil,'unsupported model visible and OFF escape available')
assert(provider.set_fast_mode('off',state.revision()));assert(provider.set_model('gpt-6.1-sol'));assert(provider.set_fast_mode('coding',state.revision()))
-- Native auth stays on the native seam; broker retains generation and placeholder.
provider.pin(scope);actual='priority';call();eq(requests[#requests].headers.Authorization,'Bearer synthetic-fast-access','native credential unchanged')
credential.generation='native-fast-2';assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(credential)))
before=calls;ok,err=pcall(call);check(not ok and tostring(err):find('credential_changed',1,true),'native generation drift refused');eq(calls,before,'no dispatch after native generation drift')
provider.unpin();credential.generation='native-fast-1';assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(credential)))
env.WASM_AGENT_OPENAI_SUB_VAULT_URL='http://127.0.0.1:9'
provider=dofile('lua/core/provider.lua');provider.pin(scope);call()
local request=requests[#requests]
eq(request.body.service_tier,'priority','broker serializer ON')
eq(request.headers['X-Wa-Vault-Generation'],'broker-fast-1','broker generation fence retained')
check(request.url:find('/openai-sub/codex/responses',1,true),'broker native route unchanged')
check(not json.encode(request):find('synthetic-fast-access',1,true),'native token never leaks to broker')
call('summary');eq(requests[#requests].body.service_tier,'priority','broker summary follows pin')
broker_generation='broker-fast-2';before=calls;ok,err=pcall(call);check(not ok and tostring(err):find('credential_changed',1,true),'broker generation drift refused: '..tostring(err));eq(calls,before,'no dispatch after broker generation drift');broker_generation='broker-fast-1'
provider.unpin();assert(provider.set_fast_mode('off',state.revision()));provider.pin(scope);call();eq(requests[#requests].body.service_tier,nil,'broker OFF omission');call('summary');eq(requests[#requests].body.service_tier,nil,'broker summary OFF omission');provider.unpin()
assert(provider.set_fast_mode('coding',state.revision()));env.WASM_AGENT_OPENAI_SUB_VAULT_URL='native'
-- Save coding for the independent process restart check.
print('fast mode integration ok ('..checks..' checks, 0 paid calls)')
