-- Actual agent loop, deterministic mock provider; native tools and private workspace.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv;local setting=nil;local asset_override=nil
host.getenv=function(k)
 if k=='WASM_AGENT_CODEMODE' then return setting end
 if k=='WASM_AGENT_CODEMODE_ASSETS' then return asset_override end
 if k=='WASM_AGENT_LLM_API_KEY' then return 'private-fixture' end
 if k=='WASM_AGENT_PROVIDER' then return 'opencode-go' end
 if k=='WASM_AGENT_LLM_MODEL' then return 'deepseek-v4.1-flash' end
 return env(k)
end
host.http=function()error('network forbidden')end;host.http_stream=host.http
local memory=dofile('lua/core/memory.lua');memory.setup()
local provider=dofile('lua/core/provider.lua')
local original=dofile
dofile=function(p)if p=='lua/core/provider.lua' then return provider end;return original(p)end
local agent=original('lua/core/agent.lua');dofile=original
local tools=dofile('lua/core/tools.lua')
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local root=dofile('lua/core/paths.lua').data()..'/coding';assert(host.write_file(root..'/sum.txt','a-b'))
local sid=memory.start_session('','native default coding',{user_id='master'})
memory.set_session_workspace(sid,{required=true,state='allocated',worktree=root})
local rounds=0;local nested
provider.complete_with=function(_,messages,schemas)
 rounds=rounds+1;local names={};for _,s in ipairs(schemas)do names[s['function'].name]=true end
 check(names.codemode,'DEFAULT_POSITIVE: eligible coding exposes codemode without opt-in')
 check(names.read and names.edit and names.write and names.bash and names.read_many and names.session_worktree,'ordinary tools and workspace control retained')
 check(messages[1].content:find('preferred programmatic coding path',1,true),'native runtime guidance present')
 if rounds==1 then
  setting='off' -- active admissions must not follow a later setting change
  return {content='',finish_reason='tool_calls',tool_calls={{id='native-default-call',type='function',['function']={name='codemode',arguments=json.encode({code='const r=await tools.read({path:"sum.txt"}); await tools.edit({path:"sum.txt",edits:[{old_text:r.content,new_text:"a+b"}]}); return (await tools.read({path:"sum.txt"})).content;'})}}}}
 end
 check(rounds==2,'no replay or extra model rounds')
 for _,m in ipairs(messages)do if m.role=='tool' and m.tool_call_id=='native-default-call' then nested=json.decode(m.content) end end
 check(nested and nested.ok and nested.backend=='rust-wasmtime-quickjs-wasi','real native backend result reaches actual agent loop')
 check(#nested.calls==3 and #nested.attempts==3,'all nested results retained')
 for _,call in ipairs(nested.calls)do local bytes=host.read_file(call.evidence.path);check(bytes and host.sha256(bytes)==call.evidence.sha256,'nested original matches exact hash')end
 return {content='FIXTURE-DONE',finish_reason='stop',tool_calls={}}
end
local bot=agent.new(sid,function()end,'master','master','')
check(bot:run('Repair the private coding fixture')=='FIXTURE-DONE','actual agent finishes mock-provider loop')
check(host.read_file(root..'/sum.txt')=='a+b','real workspace edit verified')
local policy=dofile('lua/core/codemode_policy.lua')
local function context(child)return {session_id=sid,user_id='master',subagent=child}end
local function visible(role,c)local names={};for _,s in ipairs(tools.all(role,c,memory))do names[s['function'].name]=true end;return names end
local off=context();check(not visible('master',off).codemode,'explicit off hides declaration')
check(tools.dispatch(memory,'codemode',{code='return 1'},'master',off).error=='codemode_not_enabled','off denies direct invocation')
check(visible('master',off).session_worktree and visible('master',off).bash,'off retains ordinary/control plane')
setting='native';local opt=context();check(visible('master',opt).codemode,'native opt-in compatibility')
check(tools.dispatch(memory,'codemode',{code='return 1'},'master',opt).ok,'explicit native executes')
local prior_dispatch=tools.dispatch;local prior_cancel=host.run_cancelled;local cancelled=false
host.run_cancelled=function()return json.encode({cancelled=cancelled})end
tools.dispatch=function(m,n,a,r,c)local result=prior_dispatch(m,n,a,r,c);if n=='read' then cancelled=true end;return result end
local interrupted=tools.dispatch(memory,'codemode',{code='await tools.read({path:"sum.txt"}); await tools.write({path:"cancelled.txt",content:"never"});'},'master',opt)
tools.dispatch=prior_dispatch;host.run_cancelled=prior_cancel
check(not interrupted.ok and #interrupted.calls==1 and host.read_file(root..'/cancelled.txt')==nil,'cancellation after completed read never admits or replays following effect')
setting='invalid';check(not pcall(policy.pin,memory,'master',context()),'invalid configuration refuses visibly')
setting=nil
check(not visible('guest',context()).codemode,'guest not promoted')
check(not visible('master',context({id='explore',allowed={read=true,codemode=true}})).codemode,'read-only profile not promoted')
local allowed={codemode=true,read=true,write=true,edit=true,bash=true,integrate=true,session_worktree=true}
check(not visible('master',context({id='specialized',allowed=allowed})).codemode,'specialized profile not promoted')
check(not visible('master',context({id='whatsapp-responder',allowed=allowed})).codemode,'WhatsApp profile not promoted')
local worker=context({id='orchestration-worker',allowed=allowed})
check(visible('master',worker).codemode,'authorized coding-worker gets default')
local bounded=tools.dispatch(memory,'codemode',{code='return ("grep" in tools)+"/"+("integrate" in tools)+"/"+("session_worktree" in tools);'},'master',worker)
check(bounded.ok and bounded.value=='"false/false/false"','worker ceiling and outside-guest control plane retained')
local discovery=tools.dispatch(memory,'codemode',{code='const r=await searchTools("read",{limit:8}); return r.tools.some(t=>t.name==="read") && !r.tools.some(t=>t.name==="integrate");'},'master',worker)
check(discovery.ok and discovery.value=='true','worker guest-local discovery needs no facade or new delegation authority')
local denied=tools.dispatch(memory,'codemode',{code='return await tools.grep({pattern:"x"});'},'master',worker)
check(not denied.ok and #denied.calls==0,'wrapper grants no missing primitive')
local effect=tools.dispatch(memory,'codemode',{code='await tools.write({path:'..json.encode(root..'/../outside.txt')..',content:"forbidden"});'},'master',worker)
check(not effect.ok and host.read_file(root..'/../outside.txt')==nil,'native nested workspace effect refuses without writing outside binding')
local unknown=context();local p=policy.pin(memory,'master',unknown)
check(p.enabled,'default policy pinned')
unknown.subagent={id='explore',allowed={read=true}}
check(not policy.admit(memory,'master',unknown),'profile authority drift denied despite pin')
local role_ctx=context();policy.pin(memory,'master',role_ctx)
check(not policy.admit(memory,'guest',role_ctx),'role drift denied despite prior MASTER pin')
local unbound=memory.start_session('','unbound',{user_id='master'})
check(policy.pin(memory,'master',{session_id=unbound}).enabled,'an ordinary operator session gets code mode by default')
check(not policy.pin(memory,'guest',{session_id=unbound}).enabled,'a guest session never does')
local pending=memory.start_session('','pending',{user_id='master'})
memory.set_session_workspace(pending,{required=true,state='requested'})
check(not policy.pin(memory,'master',{session_id=pending}).enabled,'a required but unallocated worktree holds it back')
asset_override=root..'/missing'
local ok,err=pcall(policy.pin,memory,'master',context());check(not ok and tostring(err):find('codemode_not_ready',1,true),'missing assets fail readiness before advertising')
assert(host.write_file(root..'/corrupt/quickjs.wasm','corrupt'));assert(host.write_file(root..'/corrupt/prelude.js','corrupt'))
asset_override=root..'/corrupt';ok,err=pcall(policy.pin,memory,'master',context());check(not ok and tostring(err):find('hash mismatch',1,true),'corrupt assets fail readiness')
asset_override=nil
print(json.encode({ok=true,checks=checks,rounds=rounds,backend=nested.backend,paid_calls=0}))
