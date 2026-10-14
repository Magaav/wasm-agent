-- Real native WASI guest and native dispatcher, private DB/home/files only.
local json=dofile('lua/vendor/json.lua')
local getenv=host.getenv;local on=true
host.getenv=function(k)if k=='WASM_AGENT_CODEMODE' then return on and 'native' or '' end;if k=='WASM_AGENT_CODEMODE_ASSETS' then return getenv('WA_QJS_ASSETS') end;return getenv(k)end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
if getenv('WA_CODEMODE_PROOF_PHASE')=='restart' then
 local restored=assert(memory.meta_get('codemode-proof-session'))
 local result=tools.dispatch(memory,'codemode',{code='return load("cursor").id;'},'master',{session_id=restored,user_id='master',role='master'})
 assert(result.ok and result.value=='7','success-only store survives native process restart')
 local stale=json.decode(host.quickjs('admit',json.encode({id=memory.meta_get('codemode-proof-active'),owner=string.rep('a',64)})))
 assert(not stale.ok and stale.error:find('sandbox unavailable',1,true),'restart never recreates or replays an active script')
 print(json.encode({ok=true,checks=2,paid_calls=0,phase='restart'}));return
end
local sid=memory.start_session('','codemode native proof',{user_id='master'})
local root=dofile('lua/core/paths.lua').data()..'/work';assert(host.write_file(root..'/a.txt','alpha'))
local ctx={session_id=sid,user_id='master',role='master'}
local checks=0;local function check(v,label)assert(v,label);checks=checks+1 end
local function call(code,c)return tools.dispatch(memory,'codemode',{code=code},'master',c or ctx)end
local boot=tools.envelope('master',ctx);check(#boot==12,'opt-in adds one tool, read_many and direct tools retained')
local r=call('const r=await tools.read({path:'..json.encode(root..'/a.txt')..'}); text(r.content); return 42;')
check(r.ok and r.backend=='rust-wasmtime-quickjs-wasi' and r.items[1].text=='alpha','native guest calls real read and filters output')
check(#r.calls==1 and r.calls[1].evidence and host.read_file(r.calls[1].evidence.path)~=nil and r.calls[1].evidence.sha256==host.sha256(host.read_file(r.calls[1].evidence.path)),'complete nested original retained with its exact hash')
r=call('await tools.write({path:'..json.encode(root..'/b.txt')..',content:"beta"}); return (await tools.read({path:'..json.encode(root..'/b.txt')..'})).content;')
check(r.ok and r.value=='"beta"' and host.read_file(root..'/b.txt')=='beta' and #r.calls==2,'effectful write/read chain executes through dispatcher')
r=call('await tools.read({path:42}); return 0;')
check(not r.ok and #r.calls==0 and #r.attempts==1 and not r.attempts[1].admitted and host.read_file(r.attempts[1].result.path)~=nil,'typed refusal retains complete failure before tool dispatch')
r=call('return ("tool_call" in tools)+"/"+("codemode" in tools)+"/"+("subagent" in tools)+"/"+typeof process+"/"+typeof fetch;')
check(r.ok and r.value=='"false/false/false/undefined/undefined"','no recursive facade, native host, Node or ambient network')
r=call('store("cursor",{id:7}); return load("cursor").id;')
check(r.ok and r.value=='7','store commits on success')
r=call('return load("cursor").id;');check(r.ok and r.value=='7','scoped store persists across native instances')
r=call('store("cursor",{id:8}); throw new Error("fixture failure");');check(not r.ok,'failed script retains failure')
r=call('return load("cursor").id;');check(r.ok and r.value=='7','failed store does not overwrite prior state')
r=call('tools.write({path:'..json.encode(root..'/never.txt')..',content:"must not dispatch"}); return 1;')
check(r.ok and host.read_file(root..'/never.txt')==nil and #r.unexecuted==1,'unawaited effect is not admitted')
local other=memory.start_session('','other code scope',{user_id='master'})
r=call('return load("cursor");',{session_id=other,user_id='master',role='master'})
check(r.ok and r.value=='undefined','store cannot cross session scope')
local child={session_id=sid,user_id='master',subagent={allowed={codemode=true}}}
r=call('return await tools.read({path:'..json.encode(root..'/a.txt')..'});',child)
check(not r.ok and #r.calls==0,'profile ceiling applies to nested target')
local guest=tools.dispatch(memory,'codemode',{code='return 1'},'guest',ctx)
check(guest.error=='forbidden_for_role:guest','guest direct invocation refused')
local loop=tools.dispatch(memory,'codemode',{code='while(true) {}',timeout_ms=20},'master',ctx)
check(loop.ok==false,'CPU loop is interrupted, not allowed to stall production')
local async_loop=tools.dispatch(memory,'codemode',{code='while(true) await null;',timeout_ms=20},'master',ctx)
check(async_loop.ok==false,'promise-job loop is interrupted between jobs')
r=call('return await import("node:fs");')
check(not r.ok,'module loading cannot reach Node/filesystem')
r=call('text("partial evidence"); throw new Error("failure after output");')
check(not r.ok and r.items[1].text=='partial evidence','script failure preserves partial output')
r=call('await tools.write({path:'..json.encode(root..'/committed.txt')..',content:"retained"}); throw new Error("after effect");')
check(not r.ok and host.read_file(root..'/committed.txt')=='retained','failed script does not undo completed native effects')
local undeclared=tools.dispatch(memory,'codemode',{code='return 1'},'master',{session_id=sid,user_id='master',subagent={allowed={read=true}}})
check(undeclared.error=='capability_not_in_profile:codemode','root wrapper needs explicit profile approval')
local timeout_partial=tools.dispatch(memory,'codemode',{code='text("retained before interrupt"); tools.write({path:'..json.encode(root..'/not-admitted.txt')..',content:"forbidden"}); while(true){}',timeout_ms=20},'master',ctx)
check(not timeout_partial.ok and timeout_partial.items[1].text=='retained before interrupt' and #timeout_partial.unexecuted==1 and host.read_file(root..'/not-admitted.txt')==nil,'VM interrupt retains output and explicitly refuses pending effects')
r=call('let objects=[]; while(true) objects.push(new Array(100000).fill(1));')
check(not r.ok,'heap exhaustion closes VM without admitting effects')
r=call('for(let i=0;i<3000;i++) await tools.read({path:'..json.encode(root..'/a.txt')..',limit:1}); return 3000;')
check(not r.ok and #r.calls>1000 and tostring(r.error):find('all fuel consumed',1,true),'fuel exhaustion is explicit; completed native calls remain retained')
r=call('for(let i=0;i<1000;i++) await tools.read({path:'..json.encode(root..'/a.txt')..',limit:1}); return 1000;')
check(r.ok and #r.calls==1000 and r.value=='1000','1000 deliveries recycle transient native handles below the declared fuel bound')
local function control(action,args)return json.decode(host.quickjs(action,json.encode(args)))end
local owner=string.rep('a',64)
local spec={owner=owner,tools={{name='read',jsName='read',description='test'}},globals={},store={},code='return await tools.read({path:"fixture"});',timeout_ms=30000}
-- Cancellation/deadline before admission and interpreter restart are native-only.
-- No active guest is automatically recreated from persistent session metadata.
local info=json.decode(host.quickjs('info','{}'))
check(info.ok and info.licenses:find('Mario Zechner',1,true) and info.licenses:find('Vercel',1,true),'binary carries both original MIT notices')
r=call('function recurse(){return recurse()}; return recurse();')
check(not r.ok,'recursion is refused within SDK-aligned stack limit')
local active=control('start',spec)
check(active.ok and active.events[1].type=='call','actual native guest queues broker call')
local bad_owner=control('close',{id=active.id,owner=string.rep('b',64)})
check(not bad_owner.ok,'wrong owner cannot close guest')
local missing=control('deliver',{id=active.id,owner=owner,call_id=99,ok=true,payload='{}'})
check(not missing.ok,'unknown result ID cannot settle call')
local completed=control('deliver',{id=active.id,owner=owner,call_id=active.events[1].id,ok=true,payload='{"content":"delivered"}'})
check(completed.ok,'owner can deliver exact pending call')
local duplicate=control('deliver',{id=active.id,owner=owner,call_id=active.events[1].id,ok=true,payload='{}'})
check(not duplicate.ok,'duplicate result refuses without replay')
check(control('close',{id=active.id,owner=owner}).ok,'native guest closes with owner')
check(not control('deliver',{id=active.id,owner=owner,call_id=1,ok=true,payload='{}'}).ok,'closed sandbox cannot be resumed')
spec.timeout_ms=100;local expired=control('start',spec)
check(expired.ok,'deadline fixture begins with an idle pending call')
local began=host.monotonic_ms();while host.monotonic_ms()-began<120 do end
check(not control('admit',{id=expired.id,owner=owner}).ok,'expired sandbox cannot admit another native effect')
check(control('close',{id=expired.id,owner=owner}).ok,'expired idle guest can be safely closed without replay')
check(not control('start',{owner=owner,tools={},globals={},store={},code='return 1',wasm_path=root..'/a.txt'}).ok,'tampered external wasm refuses even after module cache is warm')
check(not control('start',{owner=owner,tools={},globals={},store={},code='return 1',prelude_path=root..'/a.txt'}).ok,'tampered prelude refuses before evaluation')
local original_dispatch=tools.dispatch
local scalar_index=0
tools.dispatch=function(m,n,a,role,c)if n=='read' then scalar_index=scalar_index+1;if scalar_index==1 then return false elseif scalar_index==2 then return nil else return 'scalar' end end;return original_dispatch(m,n,a,role,c)end
r=call('return [await tools.read({path:"a"}),await tools.read({path:"b"}),await tools.read({path:"c"})];')
tools.dispatch=original_dispatch
check(r.ok and r.value=='[false,null,"scalar"]' and #r.calls==3 and r.calls[1].ok and r.calls[2].ok,'valid false/null/string results are preserved, never mislabeled unknown failures')
local read_schema;for _,entry in ipairs(tools.all('master'))do if entry['function'].name=='read' then read_schema=entry['function'] end end
local original_description=read_schema.description;local drift=true
tools.dispatch=function(m,n,a,role,c)local value=original_dispatch(m,n,a,role,c);if n=='read' and drift then drift=false;read_schema.description=original_description..' changed' end;return value end
r=call('await tools.read({path:'..json.encode(root..'/a.txt')..'}); return await tools.read({path:'..json.encode(root..'/a.txt')..'});')
tools.dispatch=original_dispatch;read_schema.description=original_description
check(not r.ok and #r.calls==1 and #r.attempts==2 and not r.attempts[2].admitted,'definition drift is refused before a second native dispatch')
tools.dispatch=function(m,n,a,role,c)local value=original_dispatch(m,n,a,role,c);if n=='write' then error('fixture unknown response after completed effect')end;return value end
r=call('await tools.write({path:'..json.encode(root..'/unknown.txt')..',content:"one effect"});')
tools.dispatch=original_dispatch
local uncertain=json.decode(host.read_file(r.attempts[1].result.path))
check(not r.ok and #r.calls==1 and uncertain.effect=='unknown' and uncertain.replay_allowed==false and host.read_file(root..'/unknown.txt')=='one effect','unknown native exception is retained, never automatically retried')
memory.meta_set('codemode-proof-session',sid)
local paused=control('start',{owner=owner,tools=spec.tools,globals={},store={},code=spec.code,timeout_ms=30000})
check(paused.ok,'restart fixture leaves only a not-admitted guest call')
memory.meta_set('codemode-proof-active',paused.id)
on=false;local disabled=tools.dispatch(memory,'codemode',{code='return 1'},'master',ctx)
check(disabled.error=='codemode_not_enabled' and #tools.envelope('master',ctx)==11,'default-off declaration and dispatch unchanged')
print(json.encode({ok=true,checks=checks,paid_calls=0,backend='rust-wasmtime-quickjs-wasi'}))
