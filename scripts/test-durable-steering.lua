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
    return {content='',tool_calls={{id='stale',type='function',['function']={name='write',arguments='{"path":"stale-probe.txt","content":"SHOULD-NOT-RUN"}'}}},usage={prompt_tokens=10,completion_tokens=10,total_tokens=20}}
  end
  assert(messages[#messages].content=='Use the corrected requirement','next call sees exact steering')
  return {content='corrected',tool_calls={},usage={prompt_tokens=10,completion_tokens=10,total_tokens=20}}
end
assert(bot:run('original')=='corrected' and calls==2 and dispatches==0,'stale effect fenced')
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
for _,r in ipairs(memory.session_messages(sid)) do if r.id==receipt.id then
  found=found+1;assert(r.trace[1].kind=='steering' and r.trace[1].state=='read' and r.trace[1].run_id==receipt.run_id,'durable steering display identity')
end end
assert(found==1,'atomic consumption appends once')
steering.begin('owner',sid,'second')
assert(steering.control({session_id=sid,text='x',idempotency_key='stale',run_id='old'},ctx).error=='steering_target_changed')
local pending=steering.control({session_id=sid,text='next',idempotency_key='second'},ctx)
assert(not steering.admit('owner',sid,'second'),'queued message fences admission')
local view=steering.view(sid);assert(view[1].id==pending.id and view[1].state=='queued' and view[1].text==nil,'existing session read exposes bounded queued steering identity without duplicating text or consumption')
assert(#steering.consume('owner',sid,'second')==1 and #steering.consume('owner',sid,'second')==0)
assert(steering.admit('owner',sid,'second'),'consumed inbox permits new plan')
steering.control({session_id=sid,text='interrupted',idempotency_key='third'},ctx)
host.sql_exec("UPDATE steering_runs SET boot='old-boot' WHERE session_id=?",json.encode({sid}))
status=steering.control({action='steering_status',session_id=sid},ctx)
assert(status.target.state=='unknown' and status.receipts[#status.receipts].state=='deferred','restart does not replay')
-- The other half of the fence: a read has no effect for steering to undo, and voiding one costs a
-- whole model round - a live batch of reads was re-issued verbatim one round later. The same
-- stale plan, one read instead of one write, must reach the tool.
local sid2=memory.start_session('','steering-read',{user_id='owner'})
local bot2=agent.new(sid2,function() end,'master','owner','')
local calls2,read_dispatches=0,0
local dispatch2=tools.dispatch
tools.dispatch=function(...) read_dispatches=read_dispatches+1;return dispatch2(...) end
local receipt2
provider.complete_with=function(_,messages)
  calls2=calls2+1
  if calls2==1 then
    receipt2=steering.control({session_id=sid2,text='Use the corrected requirement',idempotency_key='read-one'},ctx)
    assert(receipt2.state=='queued',json.encode(receipt2))
    return {content='',tool_calls={{id='stale-read',type='function',['function']={name='read',arguments='{"path":"AGENTS.md"}'}}},usage={prompt_tokens=10,completion_tokens=10,total_tokens=20}}
  end
  assert(messages[#messages].content=='Use the corrected requirement','the read case must still see the exact steering')
  return {content='corrected',tool_calls={},usage={prompt_tokens=10,completion_tokens=10,total_tokens=20}}
end
assert(bot2:run('original')=='corrected' and calls2==2 and read_dispatches==1,
  'a read must not be voided by queued steering, got ' .. read_dispatches .. ' dispatch(es)')
tools.dispatch=dispatch2

-- The counter is per scenario: the read case above dispatched once, legitimately, and this batch
-- must not dispatch at all.
dispatches=0
local batch=tools.start_parallel_bash({
 {id='a',['function']={name='bash',arguments='{"command":"echo SHOULD-NOT-RUN"}'}},
 {id='b',['function']={name='bash',arguments='{"command":"echo SHOULD-NOT-RUN"}'}}
},memory,'master',{steering_admit=function() return false end})
assert(batch.a.result.error=='superseded_by_steering' and batch.b.result.error=='superseded_by_steering','parallel dispatch fenced')
assert(dispatches==0,'no stale side effects')
-- The fence is for effects. A read has nothing steering could undo, and fencing one costs a whole
-- model round: a steering message that arrived during a batch of reads voided the batch, reads
-- included, and they were re-issued verbatim one round later.
assert(tools.has_effect('bash') and tools.has_effect('write') and tools.has_effect('edit') and
  tools.has_effect('subagent') and tools.has_effect('client'),'an effect must keep the fence')
assert(not tools.has_effect('read') and not tools.has_effect('read_many') and
  not tools.has_effect('grep') and not tools.has_effect('ls') and not tools.has_effect('graph') and
  not tools.has_effect('recall') and not tools.has_effect('session'),'a read must not be fenced by steering')
assert(tools.has_effect('some-plugin-tool-this-file-never-heard-of'),'an unknown tool must default to effectful')
assert(tools.has_effect(nil),'a nameless call must default to effectful')
-- Queue steering DURING an admitted read: the next effect in that batch must be a typed cancellation.
local sid3=memory.start_session('','steering-midbatch',{user_id='owner'})
local events3={};local bot3=agent.new(sid3,function(e) events3[#events3+1]=e end,'master','owner','')
local rounds3=0
provider.complete_with=function()
  rounds3=rounds3+1
  if rounds3==1 then return {content='',tool_calls={
    {id='read-before-fence',type='function',['function']={name='read',arguments='{"path":"AGENTS.md"}'}},
    {id='write-after-fence',type='function',['function']={name='write',arguments='{"path":"NEVER-WRITTEN.txt","content":"forbidden"}'}}
  },usage={prompt_tokens=10,completion_tokens=1}} end
  return {content='corrected',tool_calls={},usage={prompt_tokens=10,completion_tokens=1}}
end
local saved_dispatch=tools.dispatch
tools.dispatch=function(memory_,name,args,role,context)
  local value=saved_dispatch(memory_,name,args,role,context)
  if name=='read' then steering.control({session_id=sid3,text='Stop stale write',idempotency_key='midbatch'},ctx) end
  return value
end
assert(bot3:run('original')=='corrected');tools.dispatch=saved_dispatch
local fenced_event
for _,event in ipairs(events3) do if event.type=='tool_result' and event.name=='write' then fenced_event=event end end
assert(fenced_event and fenced_event.cancelled==true and fenced_event.failed==false and fenced_event.result.executed==false,'typed neutral cancelled event')
local totals=dofile('lua/core/telemetry.lua').snapshot(sid3)
assert(totals.tool_cancelled==1 and totals.tool_failures==0,'actual loop cancellation separated from failure totals')
print('durable steering ok')
