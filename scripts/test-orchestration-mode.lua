-- Deterministic routing/mode contract, hermetic and no paid inference.
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
check(off.ok and not off.orchestration.enabled,'toggle off works (false not nil)')
check(not dofile('lua/core/orchestration_mode.lua').read(sid).enabled,'persists across module reload')
check(mode.is_task('human task') and not mode.is_task('[Sentinel notice]\ninstalled') and not mode.is_task('[Child completion notice] reported'),'automatic notices never route recursively')
mode.control({mode_action='set',revision=2,enabled=true},ctx)
local native=dofile;local started,request_context=0,nil
local stub={control=function(args,context)started=started+1;request_context={args=args,ctx=context};return {subagent_id='worker',session_id='child-session',state='accepted',settled=false}end}
dofile=function(path)if path=='lua/core/subagents.lua' then return stub end return native(path)end
local parent={session_id=sid,run_id='request-one',role='master',user='master',node='',model='fixture'}
local routed=mode.route(parent,'implement exact task',{{path='image.png'}})
check(routed.ok and started==1 and request_context.args.prompt=='implement exact task','exact request native dispatch and immediate receipt')
check(request_context.args.profile==mode.PROFILE and request_context.args.idempotency_key=='route:request-one','dedup identity per parent run')
check(request_context.args.context:find('image.png',1,true),'attachments preserved as refs')
parent.subagent={};check(mode.route(parent,'task')==nil and started==1,'worker cannot route itself');parent.subagent=nil
check(mode.route(parent,'[Sentinel notice] update')==nil and started==1,'notice stays coordinator')
stub.control=function()return {error='node_full',not_started=true}end
routed=mode.route(parent,'next')
check(not routed.ok and routed.reply:find('No direct fallback',1,true),'refusal visible, no fallback')
dofile=native
local subagents=dofile('lua/core/subagents.lua')
local profile,problem=subagents.resolve(mode.PROFILE,{role='master'})
check(profile and profile.allowed.integrate and not profile.allowed.subagent and not profile.allowed.client and not profile.allowed.remote,'worker exact tool contract')
check(profile.instructions:find('NEVER call Sentinel',1,true) and profile.instructions:find('report',1,true),'coordinator/worker installation split')
check(profile.limits.timeout_seconds==0 and not profile.limits.max_tokens,'no new cumulative coding deadline/token cap')
local other=memory.start_session('','chat',{user_id='master'})
check(subagents.start({profile=mode.PROFILE,prompt='must refuse'},{role='master',user_id='master',session_id=other}).error=='orchestration_mode_not_enabled','worker profile cannot be used from off conversation')
memory.meta_set('orchestration-mode:'..other,'broken')
check(not pcall(mode.read,other),'corrupt mode fails visibly instead of guessed off')
print('orchestration mode ok ('..checks..' checks, 0 skipped; no inference)')
