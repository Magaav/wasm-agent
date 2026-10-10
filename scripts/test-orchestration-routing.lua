-- Real parent route and native worker under local mock inference; private Git only.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local mode=dofile('lua/core/orchestration_mode.lua');local agent=dofile('lua/core/agent.lua');local sub=dofile('lua/core/subagents.lua')
local source=assert(host.getenv('WA_ROUTING_SOURCE'))
local parent_id=memory.start_session('','chat',{user_id='master'});memory.set_session_worktree(parent_id,source)
local ctx={role='master',user_id='master',session_id=parent_id}
assert(mode.control({mode_action='toggle',revision=0},ctx).ok)
local bot=agent.new(parent_id,function()end,'master','master','')
local reply=bot:run('PRIVATE ROUTED TASK: implement task.txt, verify it, commit, integrate, report.')
assert(reply:find('Delegated',1,true),'parent returns immediate delegation receipt: '..reply)
local rows=memory.session_messages(parent_id,{all=true});local receipt
for _,span in ipairs(rows[#rows].trace)do if span.kind=='delegation' then receipt=span.receipt end end
assert(receipt and receipt.subagent_id,'receipt persisted')
local started=json.decode(host.subagent('status',json.encode({id=receipt.subagent_id,owner_user='master'})))
assert(not started.settled,'worker intentionally held after parent is free')
assert(sub.control({action='steer',id=receipt.subagent_id,text='must not interrupt',idempotency_key='blocked'},ctx).error=='worker_followup_requires_report','mid-task steering denied')
assert(sub.control({action='message',id=receipt.subagent_id,text='must wait',idempotency_key='blocked-message'},ctx).error=='worker_followup_requires_report','mid-task followup denied')
assert(sub.control({action='steer_session',session_id=receipt.session_id,text='must not bypass',idempotency_key='blocked-alias'},ctx).error=='worker_followup_requires_report','session steering cannot bypass report-only worker policy')
assert(mode.control({mode_action='toggle',revision=1},ctx).ok,'main remains free to turn off routing')
-- This read-only test control releases the mock provider barrier, not any production effect.
local release=json.decode(host.http('GET',assert(host.getenv('WA_ROUTING_RELEASE')),'{}',''))
assert(release.status==200)
local final=sub.control({action='await',id=receipt.subagent_id,wait_ms=60000},ctx)
assert(final.state=='completed','real worker complete '..json.encode(final))
assert(final.result.reply=='WORKER-MERGED-REPORT','worker final report retained')
local child=memory.session_messages(receipt.session_id,{all=true});local integration
for _,row in ipairs(child)do if row.role=='tool' and row.tool_name=='integrate' then integration=json.decode(row.content)end end
assert(integration and integration.ok and integration.installed==false,'worker integrated, not installed')
assert(memory.message_count(parent_id)==2,'child does not pollute parent transcript or block a model loop')
assert(not mode.read(parent_id).enabled,'off persisted, child was not cancelled')
print(json.encode({ok=true,checks=11,skipped=0,parent_id=parent_id,child_id=receipt.subagent_id,child_session=receipt.session_id,landed=integration.landed}))
