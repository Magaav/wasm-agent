-- tool_call resolves a permitted name from the registry directly: discovery is a search
-- convenience, not a precondition, so a model that already knows a tool calls it in one step.
-- The fence is unchanged - role, subagent profile, workspace binding and effect class - and this
-- file pins that too: a tool blocked for a workspace or a role still refuses, with the same named
-- error a direct call gets. No model, no network: the web tools are in the catalogue but never
-- invoked, and host.http refuses if anything tries.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local checks=0;local function check(value,label)assert(value,label);checks=checks+1 end
host.http=function()error('no network allowed')end;host.http_stream=host.http

local data=dofile('lua/core/paths.lua').data()
assert(host.write_file(data..'/toolcall-gate/keep.txt','fixture'))
local sid=memory.start_session('','toolcall gate',{user_id='master'})
local ctx={session_id=sid,user_id='master',role='master'}
local all=tools.all('master')

-- Nothing was discovered in this session: no tool_search ran, and the load map has no entry.
local caps=tools.dispatch(memory,'tool_call',{name='capabilities',arguments={}},'master',ctx)
check(type(caps.capabilities)=='table' and #caps.capabilities==#all,'a known tool is callable without discovery')
check(caps.error==nil,'the undiscovered call is not refused')
local recalled=tools.dispatch(memory,'tool_call',{name='recall',arguments={query='nothing stored yet'}},'master',ctx)
check(type(recalled)=='table' and recalled.error==nil,'a second undiscovered permitted call succeeds')

-- An unknown name refuses with a named error and the closest permitted names, so one step can
-- correct it. The vocabulary stays `tool_not_available`; the old `tool_not_loaded` meant "not
-- discovered yet", which is no longer a refusal at all.
local miss=tools.dispatch(memory,'tool_call',{name='capabilties',arguments={}},'master',ctx)
check(type(miss.error)=='string' and miss.error:find('tool_not_available',1,true)==1,'unknown name refuses with the named error')
check(miss.error:find('capabilities',1,true)~=nil,'the refusal lists the closest permitted name')
local vague=tools.dispatch(memory,'tool_call',{name='qzxwv',arguments={}},'master',ctx)
check(vague.error:find('tool_not_available',1,true)==1 and vague.error:find('tool_search',1,true)~=nil,'a name with no near match still names the way to find one')
local huge=tools.dispatch(memory,'tool_call',{name=string.rep('x',4000),arguments={}},'master',ctx)
check(huge.error:find('tool_not_available',1,true)==1 and #huge.error<400,'a huge unknown name is bounded in the refusal')

-- A suggestion may only come from the caller's own permitted names: a guest asking for something
-- near a master-only tool is not told that tool exists.
local guest={session_id=sid,user_id='guest',role='guest'}
local guest_miss=tools.dispatch(memory,'tool_call',{name='forgte',arguments={}},'guest',guest)
check(guest_miss.error:find('tool_not_available',1,true)==1,'a guest gets the named refusal')
check(guest_miss.error:find('forget',1,true)==nil,'a refusal never suggests a tool the role is denied')
-- The permission fence itself is unchanged: a role-denied target is refused, and a direct call
-- keeps its own role refusal.
check(tools.dispatch(memory,'tool_call',{name='forget',arguments={id='x'}},'guest',guest).error:find('tool_not_available',1,true)==1,'guest cannot route an admin tool')
check(tools.dispatch(memory,'forget',{id='x'},'guest').error=='forbidden_for_role:guest','direct role refusal is unchanged')

-- The subagent profile ceiling is rechecked on the resolved target, not just on discovery.
local child={session_id=sid,user_id='master',role='master',subagent={allowed={tool_call=true,capabilities=true}}}
check(tools.dispatch(memory,'tool_call',{name='capabilities',arguments={}},'master',child).error==nil,'a profile-permitted target still runs')
check(tools.dispatch(memory,'tool_call',{name='shell',arguments={command='true'}},'master',child).error:find('tool_not_available',1,true)==1,'a profile-denied target is still refused')

-- A workspace-blocked tool: the routed refusal must be identical to the direct one, and neither
-- may reach the capability behind it.
local client_calls=0
host.client=function()client_calls=client_calls+1;return json.encode({connected=true,fixture=true}) end
local state={required=true,state='allocated',worktree=data..'/toolcall-gate'}
local bound=setmetatable({session_workspace=function()return state end},{__index=memory})
local direct=tools.dispatch(bound,'client',{action='status'},'master',ctx)
local routed=tools.dispatch(bound,'tool_call',{name='client',arguments={action='status'}},'master',ctx)
check(direct.error=='workspace_execution_context_unsupported','direct call refuses the unsupported workspace binding')
check(routed.error~=nil,'the routed call is still refused')
check(routed.error==direct.error,'routed refusal is identical to the direct named refusal')
check(client_calls==0,'neither refusal reached the client')

-- The relaxation and the memory correction are visible to the model: the prompt says a known name
-- is called directly, and that a stored fact is corrected by id rather than forgotten and re-added.
local prompt=dofile('lua/core/agent.lua').system_prompt('master',nil,nil,all,'progressive')
check(prompt:find('call tool_call(name, arguments) with a name you already know',1,true)~=nil,'the prompt teaches calling a known name directly')
check(prompt:find('use tool_search for a name or definition you do not know',1,true)~=nil,'the prompt keeps discovery for unknown tools')
check(prompt:find("call `remember` with that entry's `id`",1,true)~=nil,'the prompt teaches correcting a stored fact by id')

print('tool-call gate ok ('..checks..' checks)')
