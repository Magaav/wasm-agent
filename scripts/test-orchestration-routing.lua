-- Real coordinator inference before native child admission, private Git and fake provider only.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local mode=dofile('lua/core/orchestration_mode.lua');local agent=dofile('lua/core/agent.lua');local sub=dofile('lua/core/subagents.lua')
local source=assert(host.getenv('WA_ROUTING_SOURCE'))
local parent_id=memory.start_session('','chat',{user_id='master'});memory.set_session_worktree(parent_id,source)
local ctx={role='master',user_id='master',session_id=parent_id}
assert(mode.control({mode_action='toggle',revision=0},ctx).ok)
local task='PRIVATE CONTEXT TASK: implement task.txt, verify it, commit, integrate, report.'
memory.append_turn(parent_id,{role='user',content=task})
memory.append_turn(parent_id,{role='assistant',content='The concrete task is understood; ready for your go.'})
local bot=agent.new(parent_id,function()end,'master','master','')
local reply=bot:run('go')
assert(reply=='COORDINATOR-READY-REPORT','coordinator must reason with prior context, not auto-delegate raw go: '..reply)
local rows=memory.session_messages(parent_id,{all=true});local receipt,raw_go=false,false
for _,row in ipairs(rows)do
 if row.role=='user' and row.content=='go' then raw_go=true end
 if row.role=='tool' and row.tool_name=='subagent' then receipt=json.decode(row.content) end
end
assert(raw_go and receipt and receipt.subagent_id,'raw request and coordinator native-tool receipt retained')
local started=json.decode(host.subagent('status',json.encode({id=receipt.subagent_id,owner_user='master'})))
assert(not started.settled,'worker held while coordinator is already free')
assert(sub.control({action='steer',id=receipt.subagent_id,text='must not interrupt',idempotency_key='blocked'},ctx).error=='worker_followup_requires_report','mid-task steering denied')
assert(sub.control({action='message',id=receipt.subagent_id,text='must wait',idempotency_key='blocked-message'},ctx).error=='worker_followup_requires_report','mid-task followup denied')
assert(sub.control({action='steer_session',session_id=receipt.session_id,text='must not bypass',idempotency_key='blocked-alias'},ctx).error=='worker_followup_requires_report','worker session steering guard unchanged')
assert(mode.control({mode_action='toggle',revision=1},ctx).ok,'operator remains free to turn off mode')
local release=json.decode(host.http('GET',assert(host.getenv('WA_ROUTING_RELEASE')),'{}',''))
assert(release.status==200)
local final=sub.control({action='await',id=receipt.subagent_id,wait_ms=60000},ctx)
assert(final.state=='completed','real model-free worker completed '..json.encode(final))
assert(final.result.reply=='WORKER-MERGED-REPORT','worker report retained')
local child=memory.session_messages(receipt.session_id,{all=true});local integration
for _,row in ipairs(child)do if row.role=='tool' and row.tool_name=='integrate' then integration=json.decode(row.content)end end
assert(integration and integration.ok and integration.installed==false,'worker integrated only its private task')
assert(memory.message_count(parent_id)==6,'context plus one complete coordinator/tool exchange, no child transcript injection')
assert(not mode.read(parent_id).enabled,'off persists without cancelling admitted worker')
print(json.encode({ok=true,checks=12,skipped=0,parent_id=parent_id,child_id=receipt.subagent_id,child_session=receipt.session_id,landed=integration.landed}))
