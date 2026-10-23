-- Real coordinator inference across the three orchestration routes; private Git, fake provider.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local mode=dofile('lua/core/orchestration_mode.lua');local agent=dofile('lua/core/agent.lua');local sub=dofile('lua/core/subagents.lua')
local source=assert(host.getenv('WA_ROUTING_SOURCE'))
local out=(host.getenv('WA_ROUTING_OUT') or '.'):gsub('\\','/')
local checks=0;local function check(value,label)assert(value,label);checks=checks+1 end
local parent_id=memory.start_session('','chat',{user_id='master'});memory.set_session_worktree(parent_id,source)
local ctx={role='master',user_id='master',session_id=parent_id}
check(mode.control({mode_action='toggle',revision=0},ctx).ok,'mode toggled on')
local task='PRIVATE CONTEXT TASK: implement task.txt, verify it, commit, integrate, report.'
memory.append_turn(parent_id,{role='user',content=task})
memory.append_turn(parent_id,{role='assistant',content='The concrete task is understood; ready for your go.'})
local function bot() return agent.new(parent_id,function()end,'master','master','') end
-- Route 1, talk: a question is answered here with no route, no tool and no child.
local answer=bot():run('READ-ONLY QUESTION: which files exist in the fixture?')
check(answer=='NO-TOOL-ANSWER','question answered directly: '..tostring(answer))
check(mode.admission(parent_id)==nil,'a question starts no child')
check(mode.routing(parent_id)==nil,'a question needs no route')
-- Route 2, short direct task: routed direct, done here in one step.
local short=bot():run('SHORT DIRECT TASK: add the short note to the fixture.')
check(short=='SHORT-DIRECT-ANSWER','short task done directly: '..tostring(short))
local routing=mode.routing(parent_id)
check(routing and routing.route=='direct' and routing.task~='','short task recorded a direct route: '..json.encode(routing))
check(mode.admission(parent_id)==nil,'short direct work starts no child')
-- Route 3, concrete implementation: refused before the route, refused after route=delegate,
-- admitted child, then the coordinator may act again.
local reply=bot():run('go')
check(reply=='COORDINATOR-READY-REPORT','coordinator reasons with prior context, not a raw go dispatch: '..tostring(reply))
local rows=memory.session_messages(parent_id,{all=true})
local receipt,raw_go,pre_route_refusal,delegate_refusal,delegate_route,post_admission_write=false,false,false,false,false,false
for _,row in ipairs(rows)do
  if row.role=='user' and row.content=='go' then raw_go=true end
  if row.role=='tool' then
    local value=json.decode(row.content or '') or {}
    if row.tool_name=='subagent' and value.subagent_id then receipt=value end
    if row.tool_name=='write' and value.error=='orchestration_route_required' then
      check(value.effect=='none','pre-route refusal carries no effect');pre_route_refusal=true
    end
    if row.tool_name=='write' and value.error=='orchestration_delegate_required' then
      check(value.handoff and value.handoff.tool=='subagent','delegate refusal names the handoff');delegate_refusal=true
    end
    if row.tool_name=='route_task' and value.ok and value.route=='delegate' then delegate_route=true end
    if row.tool_name=='write' and (value.applied==true or value.ok==true) then post_admission_write=true end
  end
end
check(raw_go and receipt,'raw request and coordinator native-tool receipt retained')
check(pre_route_refusal and delegate_refusal,'the coordinator was refused before its route and after route=delegate')
check(delegate_route,'the coordinator recorded the delegate route itself')
check(post_admission_write,'the admitted child lifts the coordinator floor for the turn')
local started=json.decode(host.subagent('status',json.encode({id=receipt.subagent_id,owner_user='master'})))
check(not started.settled,'worker held while the coordinator is already free')
check(sub.control({action='steer',id=receipt.subagent_id,text='must not interrupt',idempotency_key='blocked'},ctx).error=='worker_followup_requires_report','mid-task steering denied')
check(sub.control({action='message',id=receipt.subagent_id,text='must wait',idempotency_key='blocked-message'},ctx).error=='worker_followup_requires_report','mid-task followup denied')
check(sub.control({action='steer_session',session_id=receipt.session_id,text='must not bypass',idempotency_key='blocked-alias'},ctx).error=='worker_followup_requires_report','worker session steering guard unchanged')
check(mode.control({mode_action='toggle',revision=1},ctx).ok,'operator remains free to turn off mode')
local release=json.decode(host.http('GET',assert(host.getenv('WA_ROUTING_RELEASE')),'{}',''))
check(release.status==200,'held child released')
local final=sub.control({action='await',id=receipt.subagent_id,wait_ms=60000},ctx)
check(final.state=='completed','real model-free worker completed '..json.encode(final))
check(final.result.reply=='WORKER-MERGED-REPORT','worker report retained')
local child=memory.session_messages(receipt.session_id,{all=true});local integration
for _,row in ipairs(child)do if row.role=='tool' and row.tool_name=='integrate' then integration=json.decode(row.content)end end
check(integration and integration.ok and integration.installed==false,'worker integrated only its private task')
-- The parent keeps the receipt, never the child's transcript: while the worker is held, the
-- child's report is not in the parent ledger.
local leaked=false
for _,row in ipairs(rows)do
  if tostring(row.content or ''):find('WORKER-MERGED-REPORT',1,true) then leaked=true end
end
check(not leaked,'parent ledger holds no child transcript while the worker is held')
check(not mode.read(parent_id).enabled,'off persists without cancelling admitted worker')
print(json.encode({ok=true,checks=checks,skipped=0,parent_id=parent_id,child_id=receipt.subagent_id,
  child_session=receipt.session_id,landed=integration.landed,direct_note=out..'/direct-note.txt',
  after_admission=out..'/coordinator-after-admission.txt'}))
