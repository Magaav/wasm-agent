-- Loaded by the isolated, source-root policy wrapper; no provider calls or children.
local original_dofile = dofile
local json = original_dofile('lua/vendor/json.lua')
local checks = 0
local function check(ok, label) assert(ok, label); checks=checks+1 end
local route = 'openai-sub'
local mock_provider = {
  active=function() return {id=route} end,
  settings=function() return {model='gpt-6.1-sol'} end,
  unservable=function(model) if model=='unsupported' then return 'model_provider_incompatible' end end,
  reasoning=function() return {supported=true,levels={'low','high','xhigh'}} end,
}
local remote_args
local mock_nodes = {is_master=function() return true end, list=function() return {} end,
  find=function() return {online=true,node_id='peer'} end,
  remote_call=function(_, action, args)
    if action=='status' then return {} end
    remote_args=json.decode(json.encode(args))
    return {subagent_id='remote-child',session_id='remote-session',model=args.model,reasoning=args.reasoning}
  end}
dofile=function(path)
  if path=='lua/core/provider.lua' then return mock_provider end
  if path=='lua/core/nodes.lua' then return mock_nodes end
  if path=='lua/core/users.lua' then return {find=function() return {role='master'} end,is_master=function() return true end} end
  if path=='lua/core/completions.lua' then return {watch=function() end,status=function() return {} end} end
  return original_dofile(path)
end
local api=dofile('lua/core/subagents.lua')
local ctx={user_id='selection-owner',role='master',session_id='parent',run_id='parent-run',model='gpt-6.1-sol',reasoning='xhigh'}
local profile={model='gpt-6.1-sol',reasoning='low',provider='openai-sub',approved_models={'alternate','unsupported'}}
local selected=assert(api.selection({},ctx,profile))
check(selected.model=='gpt-6.1-sol' and selected.reasoning=='low' and selected.provider=='openai-sub','omitted all selects Sol LOW')
selected=assert(api.selection({model='alternate',reasoning='high',provider='openai-sub'},ctx,profile))
check(selected.model=='alternate' and selected.reasoning=='high','explicit approved override')
selected=assert(api.selection({model='alternate'},ctx,profile))
check(selected.model=='alternate' and selected.reasoning=='low','omitted reasoning uses profile')
selected=assert(api.selection({reasoning='high'},ctx,profile))
check(selected.model=='gpt-6.1-sol' and selected.reasoning=='high','omitted model uses profile')
selected=assert(api.selection({},ctx,{}))
check(selected.model==ctx.model and selected.reasoning=='xhigh' and selected.provider==route,'legacy parent fallback')
local _,err=api.selection({model='unapproved'},ctx,profile)
check(err=='model_not_approved:unapproved','approval unchanged')
_,err=api.selection({model='unsupported'},ctx,profile)
check(err=='model_provider_incompatible','unsupported model refused')
_,err=api.selection({provider='other'},ctx,profile)
check(err=='provider_route_unavailable:other','explicit unavailable route refused')
route='other'
_,err=api.selection({},ctx,profile)
check(err=='provider_route_unavailable:openai-sub','profile unavailable route refused')
route='openai-sub'
_,err=api.selection({reasoning='invalid'},ctx,profile)
check(err=='reasoning_not_approved:invalid','unsupported reasoning refused')
local paths=original_dofile('lua/core/paths.lua')
assert(host.write_file(paths.config()..'/subagent-profiles/selection-fixture.json',json.encode({
 schema_version=1,id='selection-fixture',allowed_tools={},limits={},model=profile.model,
 reasoning=profile.reasoning,provider=profile.provider,approved_models=profile.approved_models})))
local fleet=dofile('lua/core/orchestrator.lua')
fleet.control({action='placement',policy={enabled=true,nodes={{node='peer',max_tasks=1}}}},ctx,api)
local receipt=fleet.enqueue({prompt='fixture',profile='selection-fixture',idempotency_key='selection-remote'},ctx)
check(receipt.subagent_id~=nil and receipt.reasoning=='low','queue resolves profile before serialization')
local rows=json.decode(host.sql_query('SELECT args,context FROM orchestration_tasks WHERE owner=?',json.encode({ctx.user_id})))
local args,parent=json.decode(rows[1].args),json.decode(rows[1].context)
check(args.model==profile.model and args.reasoning=='low' and args.provider=='openai-sub','durable remote selection')
check(parent.reasoning=='xhigh' and ctx.reasoning=='xhigh','parent unchanged')
fleet.tick(api)
check(remote_args and remote_args.reasoning=='low' and remote_args.provider=='openai-sub','remote placement sends resolved selection')
-- Local placement uses the same serialized fields and does not derive parent overrides.
fleet.control({action='placement',policy={enabled=true,nodes={{node='local',max_tasks=1}}}},ctx,api)
local local_receipt=fleet.enqueue({prompt='fixture',profile='selection-fixture',idempotency_key='selection-local'},ctx)
local local_args,local_ctx
fleet.tick({control=function(a,c) local_args=a;local_ctx=c;return {subagent_id='local-child',session_id='local-session'} end})
check(local_args.reasoning=='low' and local_args.model==profile.model and local_ctx.reasoning=='xhigh','local placement retains child/parent distinction')
-- Follow-up/steer routing must not reselect from the parent's current settings.
local message
fleet.control({action='message',id=local_receipt.subagent_id,text='continue',idempotency_key='followup',reasoning='xhigh'},ctx,
 {control=function(a)
   if a.action=='lookup_session' then return {found=true,task={subagent_id='local-child',session_id='local-session'}} end
   message=a;return {subagent_id='next-child',session_id='local-session'} end})
check(message.id=='local-child' and message.action=='message','followup targets admitted child snapshot')
local discovery_api={control=function(a)
  if a.action=='lookup_session' then return {found=true,task={subagent_id='next-child',session_id='local-session',created_at=99999999999,after_id='local-child',state='completed',settled=true}} end
  return {subagents={{subagent_id='next-child',session_id='local-session',created_at=99999999999,after_id='local-child',state='completed',settled=true}}}
end}
local saved_remote=mock_nodes.remote_call
mock_nodes.remote_call=function() error('discovery must not fan out') end
local _,listing=fleet.control({action='list'},ctx,discovery_api)
check(#listing.subagents==2,'bulk mapping deduplicates local dispatch')
for _,item in ipairs(listing.subagents) do
  check(item.prompt==nil and item.result==nil and item.completion==nil and item.accounting==nil,'lightweight discovery')
end
local _,lookup=fleet.control({action='lookup_session',conversation_id='local-session'},ctx,discovery_api)
check(lookup.found and lookup.task.subagent_id==local_receipt.subagent_id and lookup.task.remote_subagent_id=='next-child','targeted latest continuation preserves dispatch mapping')
local _,remote_lookup=fleet.control({action='lookup_session',conversation_id='remote-session'},ctx,{control=function() return {found=false} end})
check(remote_lookup.found and remote_lookup.task.freshness=='recorded_observation' and remote_lookup.task.stale,'remote discovery is honestly cached')
for _,action in ipairs({'list','lookup_session'}) do
  local _,failure=fleet.control({action=action,conversation_id='local-session'},ctx,
    {control=function() return {error='fixture_runtime_fault'} end})
  check(failure.error=='fixture_runtime_fault','native discovery error stays visible')
end
local _,missing=fleet.control({action='lookup_session'},ctx,
  {control=function() return {error='conversation_id_required'} end})
check(missing.error=='conversation_id_required','missing session id stays visible')
check(lookup.task.parent_session_id=='parent' and lookup.task.parent_run_id=='parent-run' and lookup.task.after_id=='local-child','mapping fields retained')
local stored=json.encode({subagent_id='next-child',session_id='local-session',result={raw='historical'},accounting={provider='openai-sub'},completion={packet='original'}})
assert(host.sql_exec('UPDATE orchestration_tasks SET receipt=? WHERE id=?',json.encode({stored,local_receipt.subagent_id})))
local tail_api={control=function(a)
  if a.action=='lookup_session' then return {found=true,task={subagent_id='newer-tail',session_id='local-session',after_id='next-child',created_at=999999999999}} end
  check(a.id=='newer-tail','advertised tail is controlled: '..a.action)
  check(a.run_id=='expected-run' and a.attempt_id=='expected-attempt','identity fences preserved')
  return {subagent_id=a.id,session_id='local-session',state='completed',settled=true,result={raw='new'}}
end}
local _,tail=fleet.control({action='lookup_session',conversation_id='local-session'},ctx,tail_api)
check(tail.task.remote_subagent_id=='newer-tail','lookup advertises newest tail')
for _,action in ipairs({'cancel','steer','status','result','events'}) do
  fleet.control({action=action,id=local_receipt.subagent_id,run_id='expected-run',attempt_id='expected-attempt'},ctx,tail_api)
end
local unchanged=json.decode(host.sql_query('SELECT receipt FROM orchestration_tasks WHERE id=?',json.encode({local_receipt.subagent_id})))[1].receipt
check(unchanged==stored,'control/discovery preserve full historical receipt')
local _,foreign=fleet.control({action='cancel',id=local_receipt.subagent_id},{user_id='foreign',role='master'},tail_api)
check(foreign.error=='unknown_subagent','foreign alias cannot control tail')
for _,bad in ipairs({{error='native_fault'},{found=true,task={subagent_id='foreign',session_id='foreign-session'}},{found=true}}) do
  local _,failure=fleet.control({action='cancel',id=local_receipt.subagent_id},ctx,{control=function(a)
    check(a.action=='lookup_session','malformed lookup never admits control');return bad end})
  check(failure.error~=nil,'malformed/runtime lookup is visible')
end
for _,state in ipairs({'queued','refused','unknown'}) do
  local detail=state=='refused' and json.encode({error='named_refusal',prompt='must-not-leak',result='must-not-leak'}) or 'named_'..state
  assert(host.sql_exec('UPDATE orchestration_tasks SET state=?,detail=? WHERE id=?',json.encode({state,detail,receipt.subagent_id})))
  local _,page=fleet.control({action='list'},ctx,{control=function() return {subagents={}} end})
  local item
  for _,value in ipairs(page.subagents) do if value.subagent_id==receipt.subagent_id then item=value end end
  check(item.title=='fixture' and item.error==(state=='refused' and 'named_refusal' or 'named_'..state),'state title/named detail retained')
  check(item.stale and item.prompt==nil and item.result==nil,'remote stale detail is lightweight')
end
assert(host.sql_exec("UPDATE orchestration_tasks SET detail='' WHERE id=?",json.encode({receipt.subagent_id})))
local _,empty=fleet.control({action='list'},ctx,{control=function() return {subagents={}} end})
for _,item in ipairs(empty.subagents) do if item.subagent_id==receipt.subagent_id then check(item.error==nil,'empty detail not error') end end
assert(host.sql_exec("UPDATE orchestration_tasks SET state='admitted' WHERE id=?",json.encode({receipt.subagent_id})))
local remote_original=json.decode(host.sql_query('SELECT receipt FROM orchestration_tasks WHERE id=?',json.encode({receipt.subagent_id})))[1].receipt
mock_nodes.remote_call=function(_,_,a) return {subagent_id='remote-child',session_id='remote-session',state='completed',settled=true} end
fleet.control({action='status',id=receipt.subagent_id},ctx,discovery_api)
fleet=dofile('lua/core/orchestrator.lua')
local _,terminal=fleet.control({action='lookup_session',conversation_id='remote-session'},ctx,{control=function() return {found=false} end})
check(terminal.task.state=='completed' and terminal.task.settled and terminal.task.stale,'remote terminal observation survives reload')
check(json.decode(host.sql_query('SELECT receipt FROM orchestration_tasks WHERE id=?',json.encode({receipt.subagent_id})))[1].receipt==remote_original,'remote observation preserves original receipt')
for _,bad in ipairs({{subagent_id='foreign',session_id='remote-session',state='completed',settled=true},{subagent_id='remote-child',session_id='remote-session',state='running',settled=false}}) do
 mock_nodes.remote_call=function() return bad end
 local _,failure=fleet.control({action='status',id=receipt.subagent_id},ctx,discovery_api)
 check(failure.error~=nil,'identity/regressive observations refused')
end
for _,detail in ipairs({json.encode({error=string.rep('e',400)}),json.encode({reason=string.rep('r',400)}),string.rep('d',400),json.encode(string.rep('s',400))}) do
 assert(host.sql_exec('UPDATE orchestration_tasks SET detail=? WHERE id=?',json.encode({detail,receipt.subagent_id})))
 local _,bounded=fleet.control({action='lookup_session',conversation_id='remote-session'},ctx,{control=function() return {found=false} end})
 check(#bounded.task.error==256,'decoded/fallback named errors bounded')
end
mock_nodes.remote_call=saved_remote
dofile=original_dofile
print('subagent selection ok ('..checks..' checks, 0 skipped)')
