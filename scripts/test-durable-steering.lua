local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv
host.getenv=function(k)
  if k=='WASM_AGENT_LLM_API_KEY' then return 'fixture' end
  if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
  if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
  if k=='WASM_AGENT_PI_MODELS_STORE' then return 'missing' end
  return getenv(k)
end
local memory=dofile('lua/core/memory.lua');memory.setup()
local steering=dofile('lua/core/steering.lua')
local provider=dofile('lua/core/provider.lua')
local original=dofile
local tools=dofile('lua/core/tools.lua')
dofile=function(p)
  if p=='lua/core/provider.lua' then return provider end
  if p=='lua/core/tools.lua' then return tools end
  return original(p)
end
local agent=original('lua/core/agent.lua');dofile=original
local sid=memory.start_session('','steering',{user_id='owner'})
local ctx={user_id='owner',session_id='coordinator'}
local bot=agent.new(sid,function() end,'master','owner','')
local calls,dispatches=0,0
local dispatch=tools.dispatch
tools.dispatch=function(...) dispatches=dispatches+1;return dispatch(...) end
local receipt
provider.complete_with=function(_,messages)
  calls=calls+1
  if calls==1 then
    receipt=steering.control({session_id=sid,text='Use the corrected requirement',idempotency_key='one'},ctx)
    assert(receipt.state=='queued',json.encode(receipt))
    return {content='',tool_calls={{id='stale',type='function',['function']={name='read',arguments='{"path":"AGENTS.md"}'}}},usage={prompt_tokens=10,completion_tokens=10,total_tokens=20}}
  end
  assert(messages[#messages].content=='Use the corrected requirement','next call sees exact steering')
  return {content='corrected',tool_calls={},usage={prompt_tokens=10,completion_tokens=10,total_tokens=20}}
end
assert(bot:run('original')=='corrected' and calls==2 and dispatches==0,'stale tool fenced')
local status=steering.control({action='steering_status',session_id=sid},ctx)
assert(status.receipts[1].state=='read' and status.target.state=='settled','durable receipt settled')
local again=steering.control({session_id=sid,text='Use the corrected requirement',idempotency_key='one'},ctx)
assert(again.deduplicated and again.id==receipt.id,'retry returns original receipt')
local closed=steering.control({session_id=sid,text='Use the corrected requirement',idempotency_key='one'},ctx,receipt.run_id,true)
assert(closed.deduplicated and closed.id==receipt.id,'settled child retry returns accepted receipt')
assert(steering.control({session_id=sid,text='fresh',idempotency_key='closed-new'},ctx,receipt.run_id,true).error=='no_active_steering_target')
assert(steering.control({session_id=sid,text='different',idempotency_key='one'},ctx).error=='idempotency_conflict')
assert(steering.control({session_id=sid,text='new',idempotency_key='two'},ctx).error=='no_active_steering_target')
assert(steering.control({session_id=sid,text='race',idempotency_key='race'},ctx,receipt.run_id).error=='no_active_steering_target','settlement race refuses stale trusted child target')
assert(steering.control({session_id=sid,text='new',idempotency_key='two'},{user_id='other'}).error=='forbidden_steering_session')
local found=0
for _,r in ipairs(memory.session_messages(sid)) do if r.id==receipt.id then found=found+1 end end
assert(found==1,'atomic consumption appends once')
steering.begin('owner',sid,'second')
assert(steering.control({session_id=sid,text='x',idempotency_key='stale',run_id='old'},ctx).error=='steering_target_changed')
local pending=steering.control({session_id=sid,text='next',idempotency_key='second'},ctx)
assert(not steering.admit('owner',sid,'second'),'queued message fences admission')
assert(#steering.consume('owner',sid,'second')==1 and #steering.consume('owner',sid,'second')==0)
assert(steering.admit('owner',sid,'second'),'consumed inbox permits new plan')
steering.control({session_id=sid,text='interrupted',idempotency_key='third'},ctx)
host.sql_exec("UPDATE steering_runs SET boot='old-boot' WHERE session_id=?",json.encode({sid}))
status=steering.control({action='steering_status',session_id=sid},ctx)
assert(status.target.state=='unknown' and status.receipts[#status.receipts].state=='deferred','restart does not replay')
local batch=tools.start_parallel_bash({
 {id='a',['function']={name='bash',arguments='{"command":"echo SHOULD-NOT-RUN"}'}},
 {id='b',['function']={name='bash',arguments='{"command":"echo SHOULD-NOT-RUN"}'}}
},memory,'master',{steering_admit=function() return false end})
assert(batch.a.result.error=='superseded_by_steering' and batch.b.result.error=='superseded_by_steering','parallel dispatch fenced')
assert(dispatches==0,'no stale side effects')
print('durable steering ok')
