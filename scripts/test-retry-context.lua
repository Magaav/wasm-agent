-- Retry display rows persist but never become model dialogue or successful answers.
local json=dofile('lua/vendor/json.lua')
local native=host.getenv
host.getenv=function(k)
 if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
 if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
 if k=='WASM_AGENT_LLM_API_KEY' then return 'fixture-only' end
 if k=='WASM_AGENT_PI_MODELS_STORE' then return 'missing-test-store' end
 return native(k)
end
host.http=function()error('network prohibited')end;host.http_stream=host.http
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local real_dofile=dofile
dofile=function(p)if p=='lua/core/provider.lua' then return provider end return real_dofile(p)end
local agent=dofile('lua/core/agent.lua');dofile=real_dofile
local sid=memory.start_session('','retry-context',{user_id='master',node_id=''})
memory.append_turn(sid,{role='user',content='original task'})
memory.append_turn(sid,{role='retry',content='PRIVATE_RETRY_DIAGNOSTIC'})
assert(memory.session_state(sid).state=='unfinished')
assert(memory.session_state(sid).detail:find('provider recovery',1,true))
local bot=agent.new(sid,function()end,'master','master','')
local messages=bot:build_context();assert(#messages==2)
assert(not json.encode(messages):find('PRIVATE_RETRY_DIAGNOSTIC',1,true))
assert(memory.session_messages(sid,{all=true})[2].content=='PRIVATE_RETRY_DIAGNOSTIC')
for i=1,10 do
 memory.append_turn(sid,{role=i%2==1 and 'user' or 'assistant',content=string.rep('dialogue ',400)})
 memory.append_turn(sid,{role='retry',content='PRIVATE_RETRY_DIAGNOSTIC'})
end
provider.budget=function()return {context=10000,reserve=1000,keep=1000,output=1000}end
provider.complete_with=function(_,m)
 assert(not json.encode(m):find('PRIVATE_RETRY_DIAGNOSTIC',1,true),'summary leaked display telemetry')
 return {content='checkpoint',finish_reason='stop',tool_calls={}}
end
bot.context_tokens=function()return 12000,'fixture'end
assert(bot:maybe_compact())
assert(memory.session_messages(sid,{all=true})[2].content=='PRIVATE_RETRY_DIAGNOSTIC')
print('retry context ok (7 checks; no model calls)')
