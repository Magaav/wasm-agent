-- Actual Lua/SQLite master route, no model or live job mutations.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local users=dofile('lua/core/users.lua')
dofile('lua/core/server.lua')
local hooks=dofile('lua/core/hook_events.lua')
local checks=0
local function ok(v,label)assert(v,label);checks=checks+1 end
local real_jobs,real_getenv=host.jobs,host.getenv
local actual_before=real_jobs('list','{}')
local calls={}
local jobs={
 {id='onSentinelReturn',name='Sentinel',enabled=true,revision=2,trigger={kind='event',topic='sentinel.return'},action={kind='wake',prompt='PRIVATE-PROMPT'},queued=0,last_delivery={state='unknown',detail='ambiguous HTTP'}},
 {id='extra-handler',name='<img src=x onerror=alert(1)>',enabled=false,revision=3,trigger={kind='event',topic='sentinel.return'},action={kind='run'},queued=1},
 {id='dynamic-event',name='Dynamic',enabled=false,revision=1,trigger={kind='event',topic='custom.changed'},action={kind='run'}},
 {id='scheduled',name='Timer',enabled=true,revision=1,trigger={kind='schedule',every_seconds=60},action={kind='run'}},
 {id='subagent-return-observe',name='Observer',enabled=false,revision=4,trigger={kind='schedule',every_seconds=30},action={kind='run'}}
}
host.jobs=function(action,args)
 calls[#calls+1]=action;assert(action=='list' and args=='{}','view must only list')
 return json.encode({jobs=jobs})
end
host.getenv=function(name)if name=='WA_GRAPH_PATCH_AUDIT' then return '0' end return real_getenv(name)end
local master,guest=users.login('master'),users.login('guest')
local p=json.decode(wa_jobs('{"action":"hooks"}',master))
ok(p.schema==1 and p.read_only,'versioned read-only route')
local byid={};for _,row in ipairs(p.events)do byid[row.id]=row end
ok(byid['sentinel.return'].handler_count==2 and byid['sentinel.return'].enabled_handlers==1,'dynamic handler grouping')
ok(byid['sentinel.return'].handlers[2].last_delivery.state=='unknown','unknown remains visible')
ok(byid['custom.changed'].handlers[1].enabled==false,'configured custom topic discovered disabled')
ok(not byid.scheduled,'schedule is not an event-job topic')
ok(byid['subagent.return'].state:find('disabled',1,true),'disabled producer source job shown')
ok(byid['sentinel.return'].source_job:find('not configured',1,true),'missing optional observer separately shown')
ok(byid.beforeFinalAnswer.state:find('not implemented',1,true),'before final explicitly absent')
ok(byid.final_answer_begin.kind=='display telemetry','provider phase not execution barrier')
ok(byid.run_terminal.kind=='native stream events','failure/done distinct from final-answer event')
ok(byid.patch_audit_before_reply.state:find('disabled',1,true),'audit setting observed')
ok(not json.encode(p):find('PRIVATE-PROMPT',1,true),'prompt payload omitted')
ok(#calls==1 and calls[1]=='list','no mutations')
local count=#calls
ok(json.decode(wa_jobs('{"action":"hooks"}',guest)).error=='forbidden','guest cannot see internal producers')
ok(#calls==count,'guest refusal before store access')
local success=pcall(wa_jobs,'{"action":"hooks"}','invalid-token')
ok(not success,'invalid credential cannot default master')
host.jobs=function()return json.encode({error='store locked'})end
ok(hooks.get().error=='hook_job_store_unavailable','store failure visible')
host.jobs=function()return 'broken JSON'end
ok(hooks.get().error=='hook_job_store_invalid','malformed store visible')
for _,bad in ipairs({false,'bad',{},{{id='bad',trigger={kind='event'},action={kind='run'}}}})do
 local result=hooks.catalogue(bad)
 if type(bad)=='table' and #bad==0 then ok(not result.error and result.returned==9,'empty store retains native inventory')else ok(result.error,'invalid definitions refuse')end
end
jobs[#jobs].enabled=true
p=hooks.catalogue(jobs);local source_on
for _,row in ipairs(p.events)do if row.id=='subagent.return' then source_on=row end end
ok(source_on.state:find('enabled',1,true),'changed source approval reflected without catalogue mutation')
host.getenv=function(name)if name=='WA_GRAPH_PATCH_AUDIT' then return '1' end return real_getenv(name)end
p=hooks.catalogue({});byid={};for _,row in ipairs(p.events)do byid[row.id]=row end
ok(byid.patch_audit_before_reply.state:find('enabled',1,true),'audit on observed not guessed')
host.jobs,host.getenv=real_jobs,real_getenv
local actual=hooks.get();ok(not actual.error and actual.read_only and actual.returned==9,'actual private job store catalogue')
ok(real_jobs('list','{}')==actual_before,'actual store definitions/approvals remain unchanged')
if EMBEDDED then ok(EMBEDDED['lua/core/hook_events.lua']~=nil or host.getenv('WASM_AGENT_LUA_ROOT')~='','module reachable')end
print(json.encode({ok=true,checks=checks,skipped=0,paid_calls=0,scope='read-only hook event route'}))
