-- Mode permission is deterministic; delegation decisions belong to coordinator inference.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local mode=dofile('lua/core/orchestration_mode.lua')
local sid=memory.start_session('','chat',{user_id='master'})
local ctx={role='master',user_id='master',session_id=sid}
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
check(not mode.read(sid).enabled,'default off')
local on=mode.control({mode_action='toggle',revision=0},ctx)
check(on.ok and on.orchestration.enabled and on.orchestration.revision==1,'explicit toggle on')
check(mode.control({mode_action='toggle',revision=0},ctx).error=='orchestration_mode_conflict','stale toggle cannot double flip')
check(mode.read(sid).enabled,'CAS conflict retains state')
check(mode.control({mode_action='toggle',revision=1},{role='guest',user_id='master',session_id=sid}).error=='orchestration_operator_only','guest refusal')
check(mode.control({mode_action='get'},{role='master',user_id='other',session_id=sid}).error=='forbidden_parent_session','owner refusal')
check(mode.control({mode_action='get'},{role='master',user_id='master',session_id=sid,subagent={}}).error=='orchestration_operator_only','child refusal')
local off=mode.control({mode_action='toggle',revision=1},ctx)
check(off.ok and not off.orchestration.enabled,'toggle off retains false')
check(not dofile('lua/core/orchestration_mode.lua').read(sid).enabled,'persists across module reload')
check(mode.is_task('human task') and not mode.is_task('[Sentinel notice]\ninstalled') and not mode.is_task('[Child completion notice] reported'),'notice classification retained')
mode.control({mode_action='set',revision=2,enabled=true},ctx)
local native=dofile;local started=0
dofile=function(path)if path=='lua/core/subagents.lua' then return {control=function()started=started+1;error('must reason before native dispatch')end} end return native(path)end
local parent={session_id=sid,run_id='request-one',role='master',user='master',node='',model='fixture'}
for _,text in ipairs({'implement exact task','go','are you working?','[Sentinel notice] update','[Child completion notice] reported'}) do
 check(mode.route(parent,text,{{path='image.png'}})==nil,'no pre-inference delegation: '..text)
end
check(started==0,'mode permission never dispatches before coordinator reasoning')
dofile=native
local agent=dofile('lua/core/agent.lua')
local prompt=agent.system_prompt('master','','',{},'full',{orchestration_enabled=true})
check(prompt:find('assess the request using this conversation',1,true),'coordinator has contextual decision instruction')
check(prompt:find('Resolve short continuations such as go from context',1,true),'short continuation resolved by coordinator')
check(prompt:find('Answer questions and status requests here',1,true),'questions remain coordinator work')
check(not prompt:find('ordinary tasks are routed by the harness',1,true),'obsolete no-reasoning policy absent')
check(prompt:find('Route the turn before any effect',1,true),'route-before-effect rule present')
check(prompt:find('orchestration_route_required',1,true) and prompt:find('orchestration_delegate_required',1,true),'both refusals named in coordinator instructions')
check(prompt:find('route_task and subagent are declared in your tool list',1,true),'first-class tools named in coordinator instructions')
check(prompt:find('Read-only assessment',1,true),'read-only assessment stays with the coordinator')
local subagents=dofile('lua/core/subagents.lua')
local profile=subagents.resolve(mode.PROFILE,{role='master'})
check(profile and profile.allowed.integrate and not profile.allowed.subagent and not profile.allowed.client and not profile.allowed.remote,'worker exact tool contract')
check(profile.instructions:find('NEVER call Sentinel',1,true) and profile.instructions:find('report',1,true),'coordinator/worker installation split')
check(profile.limits.timeout_seconds==0 and not profile.limits.max_tokens,'no production coding caps added')
local other=memory.start_session('','chat',{user_id='master'})
check(subagents.start({profile=mode.PROFILE,prompt='must refuse'},{role='master',user_id='master',session_id=other}).error=='orchestration_mode_not_enabled','mode-off profile guard unchanged')
memory.meta_set('orchestration-mode:'..other,'broken')
check(not pcall(mode.read,other),'corrupt mode fails instead of guessed off')
-- The floor is a routing decision, not blind deferral. Mode is still on for `sid`, no route is
-- recorded and no child exists, so the coordinator may assess here but not run the work itself.
local tools=dofile('lua/core/tools.lua')
-- TMPDIR before the cwd: Linux sets neither TEMP nor TMP, and '.' left one file per run in the repository root.
local scratch=host.getenv('TEMP') or host.getenv('TMP') or host.getenv('TMPDIR') or (package.config:sub(1,1)=='/' and '/tmp') or '.'
local function slot() return scratch:gsub('[/\\]+$','')..'/wa-orchestration-floor-'..host.uuid()..'.txt' end
check(mode.admission(sid)==nil and mode.routing(sid)==nil,'no route and no child before any decision')
local target=slot()
local refused=tools.dispatch(memory,'write',{path=target,content='coordinator work'},'master',ctx)
check(refused.error=='orchestration_route_required' and refused.effect=='none' and refused.not_started==true,'direct write refused before a route')
check(type(refused.note)=='string' and refused.note:find('route_task',1,true) and refused.note:find('orchestration-worker',1,true),'refusal names the three routes and the handoff')
check(refused.handoff and refused.handoff.tool=='subagent' and refused.handoff.arguments.profile==mode.PROFILE,'refusal carries the authored-handoff shape')
local written_ok,written=pcall(host.read_file,target)
check(not written_ok or written==nil,'refused write created no file')
check(tools.dispatch(memory,'edit',{path=target,start_line=1,end_line=1,content='x'},'master',ctx).error=='orchestration_route_required','direct edit refused before a route')
check(tools.dispatch(memory,'write_many',{requests={{path=slot(),content='x'}}},'master',ctx).error=='orchestration_route_required','batch write refused before a route')
check(tools.dispatch(memory,'bash',{command='touch '..slot()},'master',ctx).error=='orchestration_route_required','mutating bash refused before a route')
check(tools.dispatch(memory,'operation',{action='start',command='touch '..slot()},'master',ctx).error=='orchestration_route_required','operation start refused before a route')
check(tools.dispatch(memory,'integrate',{},'master',ctx).error=='orchestration_route_required','integrate refused before a route')
-- Talk route: a question reads with no route and no child.
local assessment=tools.dispatch(memory,'read',{path='lua/core/orchestration_mode.lua'},'master',ctx)
check(assessment.error~='orchestration_route_required' and type(assessment.content)=='string','read-only assessment needs no route')
check(tools.dispatch(memory,'bash',{command='git status --porcelain'},'master',ctx).error~='orchestration_route_required','read-only shell needs no route')
check(tools.dispatch(memory,'bash',{command='git status > out.txt'},'master',ctx).error=='orchestration_route_required','redirection is an effect, not a read')
check(tools.dispatch(memory,'bash',{command='git commit -m x'},'master',ctx).error=='orchestration_route_required','mutating git is an effect, not a read')
check(mode.routing(sid)==nil and mode.admission(sid)==nil,'refusals neither route nor start a child')
-- Short direct task: the coordinator records direct and does the short work here.
check(mode.record_route({route='later',task='x'},ctx).error=='route_direct_or_delegate_required','only direct or delegate is a route')
check(mode.record_route({route='direct'},ctx).error=='route_task_required','a route requires the task in the coordinator own words')
local short=mode.record_route({route='direct',task='fix one typo in the readme',reason='short one-step change'},ctx)
check(short.ok and short.route=='direct' and short.started_child==false and short.effect=='none','direct route recorded and starts nothing')
local direct_target=slot()
local acted=tools.dispatch(memory,'write',{path=direct_target,content='short direct work'},'master',ctx)
check(acted.error~='orchestration_route_required' and (acted.applied==true or acted.ok==true),'short direct work allowed after route direct')
if host.read_file and pcall(host.read_file,direct_target) then os.remove(direct_target) end
-- Concrete implementation: routed delegate, the coordinator may not do it itself.
check(mode.record_route({route='delegate',task='implement the connector patch with tests',reason='multi-step change'},ctx).ok,'delegate route recorded')
local blocked=tools.dispatch(memory,'write',{path=slot(),content='should not happen'},'master',ctx)
check(blocked.error=='orchestration_delegate_required' and blocked.effect=='none','delegate route refuses the coordinator implementation')
check(blocked.handoff and blocked.handoff.tool=='subagent' and blocked.note:find('orchestration-worker',1,true),'delegate refusal names the handoff')
check(mode.admission(sid)==nil,'a route never starts a child by itself')
-- The child runs under its own profile, never under the coordinator floor.
local child_ctx={role='master',user_id='master',session_id=sid,run_id=ctx.run_id,subagent={allowed={write=true},profile='explore'}}
check(tools.dispatch(memory,'write',{path=slot(),content='child work'},'master',child_ctx).error~='orchestration_delegate_required','a child dispatch is not gated by the parent floor')
-- Admission is recorded only from an admission receipt, and it lifts the floor for the turn.
check(mode.record_admission(ctx,{subagent_id='fixture-child',session_id='child:fixture',profile=mode.PROFILE})==true,'admission recorded for the turn')
check(mode.admission(sid) and mode.admission(sid).subagent_id=='fixture-child','admission record retained')
local after=slot()
local followup=tools.dispatch(memory,'write',{path=after,content='coordinator work after delegation'},'master',ctx)
check(followup.error~='orchestration_delegate_required' and followup.error~='orchestration_route_required','admission lifts the floor')
check(followup.applied==true or followup.ok==true,'coordinator can act after the child is admitted')
if host.read_file and pcall(host.read_file,after) then os.remove(after) end
-- A new user turn re-arms the floor: the route belongs to the turn that recorded it.
memory.append_turn(sid,{role='user',content='next request after the report'})
check(tools.dispatch(memory,'write',{path=slot(),content='next'},'master',ctx).error=='orchestration_route_required','a new user turn re-arms the decision')
-- First-class surface: both mode tools are declared from the start in mode-on, nowhere else.
local function declared(session_id)
  local names={}
  for _,item in ipairs((tools.envelope('master',{role='master',user_id='master',session_id=session_id}))) do names[item['function'].name]=true end
  return names
end
local on_names=declared(sid)
check(on_names.subagent and on_names.route_task,'mode-on declares subagent and route_task from the start')
local plain=memory.start_session('','chat',{user_id='master'})
local off_names=declared(plain)
check(not off_names.subagent and not off_names.route_task,'mode-off declares neither mode tool')
local child_names={}
for _,item in ipairs(tools.all_for({read=true,write=true},'master',{session_id=sid,subagent={allowed={read=true,write=true}}},memory)) do child_names[item['function'].name]=true end
check(not child_names.subagent and not child_names.route_task,'children never see subagent or route_task')
-- Direct mode is unchanged: no floor at all with the mode off.
local direct=memory.start_session('','chat',{user_id='master'})
local direct_ctx={role='master',user_id='master',session_id=direct,run_id='direct-run'}
local direct_write=slot()
local direct_result=tools.dispatch(memory,'write',{path=direct_write,content='direct work'},'master',direct_ctx)
check(direct_result.error~='orchestration_route_required' and direct_result.error~='orchestration_delegate_required' and (direct_result.applied==true or direct_result.ok==true),'direct mode unchanged')
check(tools.dispatch(memory,'route_task',{route='direct',task='x'},'master',direct_ctx).error=='orchestration_mode_not_enabled','route_task refuses without the mode')
check(tools.dispatch(memory,'route_task',{route='direct',task='x'},'master',{session_id=sid,subagent={allowed={route_task=true}}}).error=='orchestration_operator_only','a child cannot record a route')
if host.read_file and pcall(host.read_file,direct_write) then os.remove(direct_write) end
print('orchestration mode ok ('..checks..' checks, 0 skipped; no inference)')
