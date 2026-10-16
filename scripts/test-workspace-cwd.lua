-- Actual native dispatch/process proof. Only the collector's private linked repositories.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local ws=dofile('lua/core/workspaces.lua')
local source=assert(host.getenv('WA_CWD_SOURCE'))
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end
local function norm(p) return tostring(p):gsub('\\','/'):gsub('^//%?/',''):gsub('/$',''):lower() end
local function eq(a,b) return norm(a)==norm(b) end
local function op(action,args) return json.decode(host.operation(action,json.encode(args or {}))) end
local parent=memory.start_session('','cwd parent',{user_id='master'})
memory.set_session_worktree(parent,source)
local function allocate(label)
 local id=memory.start_session('',label,{user_id='master',parent_session_id=parent,workspace_required=true})
 local w,e=ws.ensure(memory,id,parent);assert(w,e)
 return id,w,{session_id=id,user_id='master',changes={files={}}}
end
local a,wa,ca=allocate('cwd-a')
local b,wb,cb=allocate('cwd-b')
local function dispatch(name,args,ctx) return tools.dispatch(memory,name,args,'master',ctx or ca) end
local function verify(r,w,marker,requested,where)
 check(r.code==0 or r.ok==true,'actual process succeeded: '..json.encode(r))
 local pwd,git=tostring(r.stdout):match('([^\r\n]+)\r?\n([^\r\n]+)')
 -- pwd -W gives native paths under Git Bash; Unix uses pwd -P.
 check(eq(pwd,where or w.worktree) and eq(git,w.worktree),'pwd and Git root match binding: '..tostring(r.stdout))
 check(host.read_file((where or w.worktree)..'/'..marker)=='owned','marker generated in actual bound cwd')
 check(eq(r.effective_cwd,where or w.worktree),'native launcher attribution matches actual process')
 check(r.cwd_requested==(requested or ''),'original request provenance: '..json.encode(r))
end
local pwd=dofile('lua/core/platform.lua').os()=='windows' and 'pwd -W' or 'pwd -P'
local function command(marker) return pwd..'; git rev-parse --show-toplevel; printf owned > '..marker end
local first
if host.getenv('WA_CWD_NEGATIVE_OPERATION')=='1' then
 local receipt=dispatch('operation',{action='start',command=pwd..'; git rev-parse --show-toplevel'})
 local result=op('await',{id=receipt.operation_id})
 local actual=tostring(result.stdout):match('([^\r\n]+)')
 check(eq(actual,wa.worktree),'operation actual process must start in bound workspace: '..tostring(result.stdout))
end
first=dispatch('bash',{command=command('foreground.txt')})
verify(first,wa,'foreground.txt')
check(first.cwd_source=='session_workspace','authority-derived default is distinct')
assert(host.write_file(wa.worktree..'/sub/seed','seed'))
local sub=dispatch('bash',{command=command('sub.txt'),cwd='sub'})
verify(sub,wa,'sub.txt','sub',wa.worktree..'/sub')
check(sub.cwd_source=='explicit','explicit relative request remains distinct')
local grouped=tools.start_parallel_bash({
 {id='parallel-default',['function']={name='bash',arguments=json.encode({command=command('parallel.txt')})}},
 {id='parallel-sub',['function']={name='bash',arguments=json.encode({command=command('parallel-sub.txt'),cwd='sub'})}}
},memory,'master',ca)
verify(op('await',{id=grouped['parallel-default'].operation_id}),wa,'parallel.txt')
verify(op('await',{id=grouped['parallel-sub'].operation_id}),wa,'parallel-sub.txt','sub',wa.worktree..'/sub')
local start=dispatch('operation',{action='start',command=command('background.txt')..'; sleep 3'})
check(eq(start.effective_cwd,wa.worktree) and start.cwd_requested=='','explicit operation launch receipt attribution')
local other=dispatch('operation',{action='start',command=command('other.txt')..'; sleep 3'},cb)
local relevant=op('relevant',{cwd=wa.worktree})
local during=dispatch('bash',{command=command('during.txt')},cb)
verify(during,wb,'during.txt')
local seen=false
for _,entry in ipairs(relevant.operations or {}) do
 check(entry.operation_id~=other.operation_id,'other bound session not relevant')
 if entry.operation_id==start.operation_id then seen=true end
end
check(seen,'unsettled operation fences its actual bound workspace')
verify(op('await',{id=start.operation_id,wait_for='settled'}),wa,'background.txt')
verify(op('await',{id=other.operation_id,wait_for='settled'}),wb,'other.txt')
local explicit=dispatch('operation',{action='start',cwd='sub',command=command('operation-sub.txt')})
verify(op('await',{id=explicit.operation_id}),wa,'operation-sub.txt','sub',wa.worktree..'/sub')
-- Foreground adoption must index the process launch cwd as well.
local adopted=dispatch('bash',{command=command('adopted.txt')..'; sleep 5 & exit 0'})
check(adopted.promoted==true,'foreground descendants are adopted')
seen=false
for _,entry in ipairs(op('relevant',{cwd=wa.worktree}).operations or {}) do if entry.operation_id==adopted.operation_id then seen=true end end
check(seen,'foreground adopted operation fences actual workspace')
op('cancel',{id=adopted.operation_id});op('await',{id=adopted.operation_id,wait_for='settled'})
local c,wc,cc=allocate('cwd-release-fence')
local held=dispatch('operation',{action='start',command='sleep 5'},cc)
local released,why=ws.release(memory,c,'master')
check(not released and tostring(why):find('workspace_release_operation_unresolved:',1,true)==1,'actual workspace release fences unsettled launch: '..tostring(why))
op('cancel',{id=held.operation_id});op('await',{id=held.operation_id,wait_for='settled'})
released,why=ws.release(memory,c,'master')
check(released and released.state=='released','settled clean workspace can release: '..tostring(why))
local function count() return #op('list') end
local function refuse(name,args,ctx,expected)
 local before=count();local result=dispatch(name,args,ctx)
 check(result.error==expected,'visible admission refusal: '..json.encode(result))
 check(count()==before,'refused admission created no operation')
end
for _,name in ipairs({'bash','operation'}) do
 refuse(name,{action='start',cwd='missing-launch',command='printf escaped > refused.txt',_launch_cwd={required=false}},ca,'session_workspace_unavailable: required launch directory is unavailable')
 refuse(name,{action='start',cwd=source,command='printf escaped > refused.txt'},ca,'workspace_cwd_outside_binding')
 refuse(name,{action='start',cwd='../',command='printf escaped > refused.txt'},ca,'workspace_cwd_outside_binding')
end
for _,name in ipairs({'bash','operation'}) do refuse(name,{action='start',command='printf escaped > refused.txt'},cc,'session_workspace_unavailable') end
local before_native=count()
local native_missing=json.decode(host.exec('printf escaped > refused.txt',source..'/missing-native',10,json.encode({requested='',source='session_workspace',required=true})))
check(tostring(native_missing.error):find('session_workspace_unavailable',1,true) and count()==before_native,'native admission cannot substitute a missing required cwd')
local spoofed=dispatch('operation',{action='start',command=pwd..'; git rev-parse --show-toplevel',_launch_cwd={requested='spoof',source='node',required=false}})
local spoof_state=op('await',{id=spoofed.operation_id})
check(spoof_state.cwd_requested=='' and spoof_state.cwd_source=='session_workspace' and eq(spoof_state.effective_cwd,wa.worktree),'model-shaped internal provenance is overwritten by trusted dispatch')
local unavailable=memory.start_session('','missing binding',{user_id='master',workspace_required=true})
for _,state in ipairs({'failed','released'}) do
 memory.set_session_workspace(unavailable,{required=true,state=state,worktree=source})
 for _,name in ipairs({'bash','operation'}) do refuse(name,{action='start',command='printf escaped > refused.txt'},{session_id=unavailable,user_id='master'},'session_workspace_unavailable') end
end
local missing=memory.start_session('','missing directory',{user_id='master',workspace_required=true})
memory.set_session_workspace(missing,{required=true,state='allocated',worktree=source..'/nonexistent'})
for _,name in ipairs({'bash','operation'}) do refuse(name,{action='start',command='printf escaped > refused.txt'},{session_id=missing,user_id='master'},'session_workspace_unavailable') end
-- Exercise the same native dispatch through the real WASM VM (no Node runtime).
local function nested(name,args,ctx)
 local result=dispatch('codemode',{code='text(await tools.'..name..'('..json.encode(args)..'));'},ctx)
 check(result.ok==true,'native nested call: '..json.encode(result))
 return json.decode(result.items[1].text)
end
verify(nested('bash',{command=command('nested.txt')}),wa,'nested.txt')
local worker={session_id=a,user_id='master',subagent={id='orchestration-worker',allowed={codemode=true,read=true,write=true,edit=true,bash=true,operation=true}}}
verify(nested('bash',{command=command('worker-nested.txt')},worker),wa,'worker-nested.txt')
verify(nested('bash',{command=command('nested-sub.txt'),cwd='sub'}),wa,'nested-sub.txt','sub',wa.worktree..'/sub')
local before_nested=count()
local nested_start=dispatch('codemode',{code='return await tools.operation({action:"start",command:"echo forbidden"});'})
check(not nested_start.ok and count()==before_nested,'operation remains excluded from the VM control-plane catalog')
local before_escape=count()
local denied=dispatch('codemode',{code='return await tools.bash('..json.encode({cwd=source,command='printf escaped > refused.txt'})..');'})
check(not denied.ok and tostring(denied.error):find('workspace_cwd_outside_binding',1,true) and count()==before_escape,'nested cwd escape uses identical admission')
local before_missing=count()
local bad=dispatch('codemode',{code='text(await tools.bash({command:"echo forbidden"}));'},{session_id=unavailable,user_id='master'})
check((bad.error=='session_workspace_unavailable' or not bad.ok) and count()==before_missing,'nested unavailable binding refused before execution')
local profile={session_id=a,user_id='master',subagent={allowed={bash=true}}}
check(dispatch('operation',{action='start',command='echo forbidden'},profile).error=='capability_not_in_profile:operation','profile ceiling unchanged')
check(tools.dispatch(memory,'bash',{command='echo forbidden'},'guest',ca).error=='forbidden_for_role:guest','role ceiling unchanged')
-- No command parsing: an intentional later shell cd changes behavior, not launcher attribution.
local later=dispatch('bash',{command='cd sub && '..command('later.txt')})
check(eq(later.effective_cwd,wa.worktree) and host.read_file(wa.worktree..'/sub/later.txt')=='owned','later cd is not falsely reported as launch cwd')
local legacy=memory.start_session('','legacy',{user_id='master'})
local lr=dispatch('bash',{command=pwd..'; git rev-parse --show-toplevel'},{session_id=legacy,user_id='master'})
check(lr.code==0 and eq(lr.effective_cwd,source) and lr.cwd_requested=='' and lr.cwd=='','legacy unbound native default preserved')
check(host.read_file(source..'/refused.txt')==nil,'canonical sentinel has no escaped markers')
print(json.encode({ok=true,checks=checks,a=wa.worktree,b=wb.worktree,paid_calls=0}))
