-- Native discovery/guard proof: private DB/home and mocked client only.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local envelope=dofile('lua/core/envelope.lua')
local checks=0;local function check(value,label)assert(value,label);checks=checks+1 end
local data=dofile('lua/core/paths.lua').data();assert(host.write_file(data..'/bound/artifact.html','exact existing artifact'))
local sid='binding-discovery';if not memory.session(sid) then memory.start_session('','binding',{id=sid,user_id='master'}) end
local ctx={session_id=sid,user_id='master',role='master'}
local state={required=true,state='allocated',worktree=data..'/bound'}
local reads,client_calls=0,0
local bound=setmetatable({session_workspace=function()reads=reads+1;return state end},{__index=memory})
host.client=function() client_calls=client_calls+1;return json.encode({connected=true,fixture=true}) end
host.http=function()error('no network allowed')end;host.http_stream=host.http
local phase=host.getenv('WA_BINDING_PHASE') or 'seed'
if phase=='restart' then
 local persisted,prior=envelope.resolve(tools.all('master'),'client',ctx)
 check(persisted~=nil and prior==nil,'a permitted definition resolves after a native restart without rediscovery')
end
local function entry(reply,name)for _,tool in ipairs(reply.tools or {})do if tool.name==name then return tool end end end
local schemas=tools.envelope('master',ctx);local prefix=json.encode(schemas)
reads=0
local found=tools.dispatch(bound,'tool_search',{query='client',limit=1},'master',ctx)
local client=entry(found,'client')
check(client and client.execution and client.execution.status=='blocked','discovery reports blocked client before invocation')
check(client.execution.available==false and client.execution.workspace_binding=='unsupported' and client.execution.reason=='workspace_execution_context_unsupported','permitted client has truthful binding refusal')
check(found.loaded==0 and client.loaded==false,'blocked client definition is not loaded')
check(reads==1,'discovery reads workspace once, not once per catalogue item')
check(client.execution.next:find('artifact link',1,true) and client.execution.next:find('status',1,true),'artifact/no-status recovery guidance')
check(found.guidance[1]:find('Do not invoke client',1,true),'blocked choice explicitly visible to planner')
local refused_calls=0
-- Deterministic task plan uses discovery evidence instead of making two known-refused calls.
if client.execution.status~='blocked' then
 for _,args in ipairs({{action='browser',target='open',url='file:///artifact.html'},{action='status'}}) do
  local r=tools.dispatch(bound,'client',args,'master',ctx);if r.error then refused_calls=refused_calls+1 end
 end
end
check(refused_calls==0 and client_calls==0,'binding-aware plan makes zero refused attempts or client effects')
check(host.read_file(data..'/bound/artifact.html')=='exact existing artifact','existing artifact remains complete')
check(json.encode(tools.envelope('master',ctx))==prefix,'discovery never changes declaration prefix')
local route=tools.dispatch(bound,'tool_call',{name='client',arguments={action='status'}},'master',ctx)
-- Discovery no longer gates the call; the workspace fence still does, with the direct call's
-- exact named refusal.
check(route.error=='workspace_execution_context_unsupported','routed blocked tool refuses with the same native workspace guard')
for _,action in ipairs({'status','browser','screenshot'}) do
 local denied=tools.dispatch(bound,'client',{action=action,target='open'},'master',ctx)
 check(denied.error=='workspace_execution_context_unsupported','direct native guard remains for '..action)
end
check(client_calls==0,'guard controls do not reach the client')
local canonical;for _,tool in ipairs(tools.all('master'))do if tool['function'].name=='client' then canonical=tool end end
check(json.encode(client.schema)==json.encode(canonical),'metadata does not rewrite native definition/schema hash')
reads=0
local caps=tools.dispatch(bound,'capabilities',{},'master',ctx)
check(reads==1,'capabilities shares one workspace snapshot')
for _,name in ipairs({'client','shell','remote','spell_run'})do
 check(caps.execution[name].status=='blocked' and caps.execution[name].available==false,'blocked capability '..name)
end
check(caps.workspace.required==true and caps.workspace.state=='allocated' and caps.workspace.scope=='workspace_policy_only','workspace policy, not an execution guarantee')
check(caps.execution.bash.status=='argument_dependent' and caps.execution.bash.workspace_binding=='supported','supported shell still requires native cwd/arguments')
check(caps.execution.read_many.status=='not_blocked' and caps.execution.read_many.workspace_binding=='not_applicable','independent read_many unchanged')
check(caps.execution.operation.status=='argument_dependent' and caps.execution.mcp.status=='argument_dependent','action-specific tools are not advertised as uniformly executable')
local child={session_id=sid,user_id='master',subagent={allowed={capabilities=true,tool_search=true,tool_call=true,client=true}}}
local scoped=tools.dispatch(bound,'capabilities',{},'master',child)
check(#scoped.capabilities==4 and scoped.execution.client and not scoped.execution.bash,'capabilities respects exact profile, no wider catalogue')
local denied=tools.dispatch(bound,'tool_search',{query='client',limit=1},'guest',{session_id=sid,user_id='guest'})
check(not entry(denied,'client'),'role-hidden tool has no execution metadata leak')
local readonly={session_id=sid,user_id='master',subagent={allowed={tool_search=true,tool_call=true,read=true}}}
check(not entry(tools.dispatch(bound,'tool_search',{query='client',limit=1},'master',readonly),'client'),'profile-hidden tool not discoverable')
-- An unbound session remains permitted; after binding changes native preflight rechecks it.
state={required=false,state='none'}
local unbound=tools.dispatch(bound,'tool_search',{query='client',limit=1},'master',ctx)
check(unbound.loaded==1 and entry(unbound,'client').execution.status=='not_blocked','unbound discovery and definition loading unchanged')
check(tools.dispatch(bound,'tool_call',{name='client',arguments={action='status'}},'master',ctx).connected==true,'ordinary status reaches only the mock client')
check(client_calls==1,'one explicit mock observation')
state={required=true,state='allocated',worktree=data..'/bound'}
check(tools.dispatch(bound,'tool_call',{name='client',arguments={action='status'}},'master',ctx).error=='workspace_execution_context_unsupported','binding drift rechecked at actual invocation')
local rediscovered=tools.dispatch(bound,'tool_search',{query='client',limit=1},'master',ctx)
check(rediscovered.loaded==0,'rediscovery retires stale loaded client name, not the original definition evidence')
local restored=dofile('lua/core/envelope.lua')
local resolved,problem=restored.resolve(tools.all('master'),'client',ctx)
check(resolved~=nil and problem==nil,'reconstruction keeps a permitted definition callable by name')
check(tools.dispatch(bound,'tool_call',{name='client',arguments={action='status'}},'master',ctx).error=='workspace_execution_context_unsupported','the blocked workspace guard survives reconstruction')
state={required=true,state='failed',error='fixture failure'}
local missing=tools.dispatch(bound,'capabilities',{},'master',ctx)
check(missing.execution.client.reason=='session_workspace_unavailable' and missing.execution.write.status=='blocked','missing required binding never advertises writable execution')
check(missing.execution.read.status=='not_blocked','read-only recovery remains available')
local unreadable=setmetatable({session_workspace=function()error('metadata unreadable')end},{__index=memory})
local unknown=tools.dispatch(unreadable,'tool_search',{query='client',limit=1},'master',ctx)
check(unknown.loaded==0 and entry(unknown,'client').execution.status=='unknown','unreadable metadata cannot fabricate availability')
state={required=1,state='allocated',worktree=data..'/bound'}
check(entry(tools.dispatch(bound,'tool_search',{query='client',limit=1},'master',ctx),'client').execution.status=='blocked','truthy binding flag matches dispatcher semantics')
print(json.encode({ok=true,phase=phase,checks=checks,planner_refused_calls=refused_calls,planner_client_calls=0,mocked_client_calls=client_calls,provider_calls=0}))
