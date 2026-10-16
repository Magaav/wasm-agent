-- Synthetic operator contract, separate-source routing, native device/CAS/cancel/no-replay.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local native_getenv=host.getenv
local env={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='synthetic-legacy',
 WASM_AGENT_OPENCODE_GO_VAULT_URL='http://127.0.0.1:9',WASM_AGENT_OPENAI_SUB_VAULT_URL='native',
 WASM_AGENT_VAULT_OPERATOR_URL='http://127.0.0.1:8801',WASM_AGENT_OPENAI_SUB_STORE=paths.data()..'/provider-fixture/credentials.json',
 WASM_AGENT_OPENAI_SUB_AUTH_BASE='http://127.0.0.1:1'}
host.getenv=function(k)if env[k]~=nil then return env[k]end return native_getenv(k)end
local checks=0
local function check(v,label)checks=checks+1;assert(v,label)end
local generation='go-generation-1'
local calls,exchanges=0,0
local mode='pending'
local function b64(s)return(memory.base64_encode(s):gsub('+','-'):gsub('/','_'):gsub('=+$',''))end
local access=b64('{}')..'.'..b64('{"https://api.openai.com/auth":{"chatgpt_account_id":"synthetic-account"}}')..'.sig'
local previous={version=1,provider='openai-codex',type='oauth',access='synthetic-old-access',refresh='synthetic-old-refresh',expires=host.now()*1000+3600000,account_id='old-account',generation='native-generation-1'}
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(previous)))
host.http=function(method,url,headers,body)
 calls=calls+1
 local result
 if url:find('/status',1,true)then result={vault_id='11111111-1111-4111-8111-111111111111',providers={['opencode-go']={configured=true,enabled=true,generation=generation},['openai-sub']={configured=false,enabled=true,generation='absent'}}}
 elseif url:find('/usercode',1,true)then result={device_auth_id='private-fixture-device',user_code='FIXTURE-CODE',interval=1}
 elseif url:find('/deviceauth/token',1,true)then
  if mode=='pending'then return json.encode({status=403,body='{}'})end
  result={authorization_code='private-fixture-code',code_verifier='private-fixture-verifier'}
 elseif url:find('/oauth/token',1,true)then exchanges=exchanges+1;if mode=='unknown'then error('synthetic socket loss')end;result={access_token=access,refresh_token='synthetic-new-refresh',expires_in=3600}
 else error('unexpected external request')end
 return json.encode({status=200,body=json.encode(result)})
end
local vault=dofile('lua/core/vault.lua')
check(vault.base('opencode-go')=='http://127.0.0.1:9/opencode-go/v1','Go explicit vault route')
check(vault.base('openai-sub')==nil,'native subscription preserved')
env.WASM_AGENT_VAULT_URL='http://127.0.0.1:10'
check(vault.base('openai-sub')==nil,'native override beats global compatibility setting')
env.WASM_AGENT_OPENAI_SUB_VAULT_URL=''
check(vault.base('openai-sub')=='http://127.0.0.1:10/openai-sub','global compatibility preserved')
env.WASM_AGENT_OPENAI_SUB_VAULT_URL='native'
local provider=dofile('lua/core/provider.lua')
local manager=dofile('lua/core/provider_management.lua')
previous.expires=host.now()*1000-1
previous.last_error={code='fixture_error',detail='synthetic-old-access'}
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(previous)))
local before=calls;local state=manager.state()
check(exchanges==0,'opening management never refreshes an expired unrelated subscription credential')
check(state.providers[1].error=='subscription_authentication_error' and not json.encode(state):find('synthetic-old-access',1,true),'management metadata cannot return credential-echoing historical error detail')
previous.last_error=nil
previous.expires=host.now()*1000+3600000
assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(previous)))
check(#state.providers==2 and state.providers[1].label=='OpenAI subscription' and state.providers[2].label=='OpenCode Go','only two friendly management routes')
check(state.providers[1].source=='native' and state.providers[2].source=='vault','truthful separate sources')
check(state.providers[2].generation==generation and state.providers[2].entitlement=='unknown','presence not entitlement')
check(state.quota:find('same exhausted workspace',1,true)~=nil,'monthly quota explained')
local answers={'2','manage'};local output={};manager.cli({print=function(s)output[#output+1]=s end,ask=function()return table.remove(answers,1)end})
check(table.concat(output):find('http://127.0.0.1:8801',1,true)~=nil,'CLI management offers enrolled operator page, not terminal key reader')
check(provider.active().id=='opencode-go','opening management does not select/change provider')
check(not table.concat(output):find('synthetic-legacy',1,true),'no credential echo')
local auth=dofile('lua/core/openai_sub_auth.lua')
previous.expires=host.now()*1000-1;assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(previous)))
local acquire=auth.acquire_lock
local before_race=calls
auth.acquire_lock=function()
 local racing={};for k,v in pairs(previous)do racing[k]=v end;racing.generation='racing-generation'
 assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(racing)))
 return function()end
end
local raced,race_error=auth.token({expected_generation='native-generation-1'})
check(not raced and race_error.code=='credential_changed' and calls==before_race,'generation rechecked inside refresh lock before any rotating send')
auth.acquire_lock=acquire;previous.expires=host.now()*1000+3600000;assert(host.write_file(env.WASM_AGENT_OPENAI_SUB_STORE,json.encode(previous)))
local operation=host.uuid()
local login,err=manager.device('begin',operation,'fixture-owner');check(login and login.state=='pending','native begin through device contract')
check(auth.status().generation=='native-generation-1','begin retains working auth')
local before_competing=calls
local competing,competing_error=auth.login('browser')
check(not competing and competing_error.code=='login_busy' and calls==before_competing,'legacy login cannot overwrite a managed pending flow')
local imported,import_error=auth.import_from_pi()
check(not imported and import_error.code=='login_busy' and calls==before_competing,'legacy import shares the credential lock and cannot switch account beneath managed login')
check(auth.management_state('fixture-owner').operation==operation and auth.management_state('foreign-owner')==nil,'read-only pending recovery is operator-scoped')
local denied,problem=manager.device('cancel',operation,'foreign-owner');check(not denied and problem.code=='login_scope_mismatch','foreign owner denied')
local duplicate=manager.device('begin',host.uuid(),'fixture-owner');check(not duplicate,'single flight begin')
local cancelled=manager.device('cancel',operation,'fixture-owner');check(cancelled.state=='cancelled','explicit cancellation')
check(auth.status().generation=='native-generation-1','cancellation retains old login')
local stale=manager.device('poll',operation,'fixture-owner');check(not stale and exchanges==0,'cancelled login cannot resurrect')
operation=host.uuid();login=manager.device('begin',operation,'fixture-owner');mode='done';login,err=manager.device('poll',operation,'fixture-owner')
check(login and login.state=='done','human-completed fixture login commits')
check(auth.status().generation~='native-generation-1' and auth.status().operation==operation,'opaque generation/operation readback')
local token,changed=auth.token({expected_generation='native-generation-1'});check(not token and changed.code=='credential_changed','pinned old run refuses new account')
local reconciled=manager.device('status',operation,'fixture-owner');check(reconciled.state=='done' and exchanges==1,'commit reconciles without replay')
operation=host.uuid();manager.device('begin',operation,'fixture-owner');mode='unknown';local unknown=manager.device('poll',operation,'fixture-owner');check(not unknown,'ambiguous exchange held')
local count=exchanges;local retry,held=manager.device('poll',operation,'fixture-owner');check(not retry and held.code=='login_outcome_unknown' and exchanges==count,'unknown exchange never replays')
manager.device('cancel',operation,'fixture-owner')
local absent_before=calls
check(manager.device('status',host.uuid(),'fixture-owner').state=='not_pending' and calls==absent_before,'absent begin outcome reconciles read-only without resend')
local denied_done,done_scope=manager.device('status',auth.status().operation,'foreign-owner')
check(not denied_done and done_scope.code=='login_scope_mismatch','committed operation outcome remains owner-scoped')
check(auth.status().present,'failed replacement preserves usable login')
local upstream_calls=0
host.http_stream=function(method,url,headers,body)
 upstream_calls=upstream_calls+1
 local h=json.decode(headers)
 check(url=='http://127.0.0.1:9/opencode-go/v1/chat/completions','inference remains on explicitly selected broker route')
 check(h.Authorization=='Bearer wa-vault-brokered' and h['X-Wa-Vault-Generation']==generation,'node sees only placeholder and pinned opaque generation')
 return json.encode({status=429,body=json.encode({error={type='GoUsageLimitError',metadata={limitName='monthly',workspace='synthetic-workspace'}}})})
end
provider.pin()
local response=pcall(provider.complete_with,'deepseek-v4.1-flash',{{role='user',content='synthetic fixture'}},{},true,{})
provider.unpin()
check(not response and upstream_calls==1,'monthly 429 is visible with no fallback/retry')
check(#manager.state().providers==2 and provider.active().id=='opencode-go','management remains usable after monthly429 without wrong-provider side effect')
print(string.format('provider management: %d checks, 0 skips, 0 paid calls',checks))
