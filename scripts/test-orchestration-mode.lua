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
local subagents=dofile('lua/core/subagents.lua')
local profile=subagents.resolve(mode.PROFILE,{role='master'})
check(profile and profile.allowed.integrate and not profile.allowed.subagent and not profile.allowed.client and not profile.allowed.remote,'worker exact tool contract')
check(profile.instructions:find('NEVER call Sentinel',1,true) and profile.instructions:find('report',1,true),'coordinator/worker installation split')
check(profile.limits.timeout_seconds==0 and not profile.limits.max_tokens,'no production coding caps added')
local other=memory.start_session('','chat',{user_id='master'})
check(subagents.start({profile=mode.PROFILE,prompt='must refuse'},{role='master',user_id='master',session_id=other}).error=='orchestration_mode_not_enabled','mode-off profile guard unchanged')
memory.meta_set('orchestration-mode:'..other,'broken')
check(not pcall(mode.read,other),'corrupt mode fails instead of guessed off')
print('orchestration mode ok ('..checks..' checks, 0 skipped; no inference)')
