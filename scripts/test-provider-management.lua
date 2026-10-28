-- Synthetic operator contract: the one provider route (OpenCode Go), vault routing, no credential echo.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local native_getenv=host.getenv
local env={WASM_AGENT_PROVIDER='opencode-go',WASM_AGENT_LLM_API_KEY='synthetic-legacy',
 WASM_AGENT_OPENCODE_GO_VAULT_URL='http://127.0.0.1:9',WASM_AGENT_VAULT_OPERATOR_URL='http://127.0.0.1:8801'}
host.getenv=function(k)if env[k]~=nil then return env[k]end return native_getenv(k)end
local checks=0
local function check(v,label)checks=checks+1;assert(v,label)end
local generation='go-generation-1'
local calls=0
host.http=function(method,url,headers,body)
 calls=calls+1
 if not url:find('/status',1,true)then error('unexpected external request')end
 local result={vault_id='11111111-1111-4111-8111-111111111111',providers={['opencode-go']={configured=true,enabled=true,generation=generation}}}
 return json.encode({status=200,body=json.encode(result)})
end
local vault=dofile('lua/core/vault.lua')
check(vault.base('opencode-go')=='http://127.0.0.1:9/opencode-go/v1','Go explicit vault route')
check(vault.ROUTES['openai-sub']==nil and vault.base('openai-sub')==nil,'no ChatGPT route through the vault')
local provider=dofile('lua/core/provider.lua')
local manager=dofile('lua/core/provider_management.lua')
check(manager.device==nil,'no device-login flow remains')
local state=manager.state()
check(#state.providers==1 and state.providers[1].id=='opencode-go' and state.providers[1].label=='OpenCode Go','one management route')
check(state.providers[1].source=='vault','truthful source')
check(state.providers[1].generation==generation and state.providers[1].entitlement=='unknown','presence not entitlement')
local scoped=manager.state('fixture-owner')
check(type(scoped.embed_scope)=='string' and scoped.embed_scope:match('^[a-f0-9]+$') and #scoped.embed_scope==64,'only a public node/account scope crosses the frame boundary')
check(manager.state('fixture-owner').embed_scope==scoped.embed_scope and manager.state('different-owner').embed_scope~=scoped.embed_scope,'frame scope is stable for reload recovery and distinct per account')
env.WASM_AGENT_OPENCODE_GO_VAULT_URL='native';env.WASM_AGENT_LLM_API_KEY='';env.OPENCODE_GO_API_KEY='synthetic-lower-alias'
check(manager.state().providers[1].configured==false,'empty effective highest-precedence key is unconfigured, without silently adopting a lower alias')
env.WASM_AGENT_OPENCODE_GO_VAULT_URL='http://127.0.0.1:9';env.WASM_AGENT_LLM_API_KEY='synthetic-legacy';env.OPENCODE_GO_API_KEY=nil
check(state.quota:find('same exhausted workspace',1,true)~=nil,'monthly quota explained')
local answers={'1'};local output={};manager.cli({print=function(s)output[#output+1]=s end,ask=function()return table.remove(answers,1)end})
check(table.concat(output):find('http://127.0.0.1:8801',1,true)~=nil,'CLI management offers enrolled operator page, not terminal key reader')
check(provider.active().id=='opencode-go','opening management does not select/change provider')
check(not table.concat(output):find('synthetic-legacy',1,true),'no credential echo')
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
check(#manager.state().providers==1 and provider.active().id=='opencode-go','management remains usable after monthly429 without wrong-provider side effect')
print(string.format('provider management: %d checks, 0 skips, 0 paid calls',checks))
