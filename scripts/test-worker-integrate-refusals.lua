-- Deterministic no-effect/conflict and unknown-after-push boundary proof.
local json=dofile('lua/vendor/json.lua');local memory=dofile('lua/core/memory.lua');memory.setup()
local resources=dofile('lua/core/resources.lua');local integrate=dofile('lua/core/integrate.lua')
local sid=memory.start_session('','subagent',{id='worker-refusals',user_id='master'})
memory.set_session_workspace(sid,{worktree='owned',required=true,state='allocated',branch='change/worker-refusals'})
local ctx={user_id='master',session_id=sid,run_id='refusal-fixture',subagent={id='orchestration-worker'}}
local native_exec,native_resource,native_write=host.exec,host.resource,host.write_file
local stage,mutations,uncertain,checks='dirty',0,0,0
local function check(v,label)assert(v,label);checks=checks+1 end
local function ok(text)return json.encode({code=0,ok=true,stdout=text or ''})end
host.resource=function(action,args)
 if action=='uncertain' then uncertain=uncertain+1 end
 return json.encode({ok=true})
end
host.exec=function(command)
 if command:find('merge --no-ff',1,true) then mutations=mutations+1;return ok() end
 if command:find('push origin main',1,true) then return json.encode({code=1,ok=false,stderr='private refused push'}) end
 if command:find('status --porcelain',1,true) then return ok(stage=='dirty' and ' M task.txt' or '') end
 if command:find('branch --show-current',1,true) then return ok(command:find("'owned'",1,true) and 'change/worker-refusals' or 'main') end
 if command:find('show -s --format=%B',1,true) then return ok('private task\nAgent: wasm-agent session='..sid) end
 if command:find('rev-parse --path-format=absolute --git-common-dir',1,true) then return ok('private-common') end
 if command:find('worktree list',1,true) then return ok('worktree canonical\nbranch refs/heads/main\n') end
 if command:find('merge-tree',1,true) then return stage=='conflict' and json.encode({code=1,stdout='exact private conflict'}) or ok(string.rep('a',40)) end
 if command:find('HEAD^{tree}',1,true) then return ok(string.rep('a',40)) end
 if command:find('rev-parse',1,true) then return ok(string.rep('b',40)) end
 return ok()
end
check(integrate.run(memory,ctx).error=='integration_dirty_worker' and mutations==0,'dirty worker no canonical mutation')
stage='conflict';local conflict=integrate.run(memory,ctx)
check(conflict.error=='integration_conflict' and conflict.effect=='none' and mutations==0,'conflict before mutation and original detail retained')
stage='push-fail';local failed=integrate.run(memory,ctx)
check(failed.error=='integration_failed' and failed.effect=='unknown' and mutations==1 and uncertain==1,'push after merge ambiguous, retained and lock uncertain')
local before=mutations;local again=integrate.run(memory,ctx)
check(again.error=='integration_effect_already_recorded' and mutations==before,'uncertain integration never automatically repeats Git effects')
local getenv=host.getenv;host.getenv=function(name)if name=='WASM_AGENT_PROVENANCE' then return 'child' end return getenv(name)end
check(dofile('lua/core/update.lua').run().error=='update_coordinator_only','child /update refuses before any facts/sync/backup/request')
host.getenv=getenv
host.exec=native_exec;host.resource=native_resource;host.write_file=native_write
print('worker integrate refusals ok ('..checks..' checks, no inference)')
