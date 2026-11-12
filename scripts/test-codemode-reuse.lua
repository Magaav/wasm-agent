-- Code mode is always fresh, and reuse is explicit (#120, 11/11). The evidence: one work session
-- called `email_search({from:"Laura"})` four times with identical arguments, because nothing in the
-- result said whether the world had moved since the answer it already had. Implicit caching was
-- refused by the operator that night - "sometimes models want to recheck if something turned out
-- differently, so caching risks breaking awareness" - so reuse happens only when a script asks for it
-- by name (`results.get`, `results.last`) or by option (`tools.x(args, {reuse: "60s"})`), and a
-- repeated read says what changed (`prior:{call, age_s, same}`).
--
-- What is asserted (docs/CODEMODE.md, "Always fresh, explicit reuse"):
--   1. every call executes, every time - repeats and effectful calls alike;
--   2. an effect between two identical reads is visible as a changed answer, and `prior.same` says so;
--   3. `{reuse:"60s"}` answers the earlier result without dispatching, marked `{reused_from, age_s}`;
--   4. `{reuse:"1ms"}` - older than the requested age - runs fresh and sees the world;
--   5. `results.get(hash)` returns the retained prior result and `results.last(n,{tool})` lists the
--      journal newest first;
--   6. `results.diff(a,b)` reports what changed between two results, and says `same` when nothing did;
--   7. the repeat is counted in telemetry, so the value of explicit reuse stays measurable.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local telemetry=dofile('lua/core/telemetry.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
local root=dofile('lua/core/paths.lua').data()..'/reuse'
assert(host.write_file(root..'/note.txt','first'))
local sid=memory.start_session('','codemode explicit reuse',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
-- What the node really dispatched: the measurement this whole test rests on. A cache would show up
-- here as a call the model made that the dispatcher never saw.
local dispatched={}
local function dispatch(name,params,raw)
 dispatched[#dispatched+1]={name=name,params=params}
 return tools.dispatch(memory,name,params,'master',ctx)
end
local function dispatched_for(tool)
 local count=0
 for _,entry in ipairs(dispatched)do if entry.name==tool then count=count+1 end end
 return count
end
local function run(code)
 local result=codemode.run(memory,{code=code},'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return result,result and result.value and json.decode(result.value) or nil
end
local function wait(seconds)
 local started=host.now()
 while host.now()-started<seconds do end
end
local note=json.encode(root..'/note.txt')

-- 1. Two identical reads are two calls. Nothing is cached inside a turn.
local fresh,first=run('return await tools.read({path:'..note..'});')
check(fresh.ok and first.content=='first','a read answers its content: '..tostring(fresh.error))
check(dispatched_for('read')==1,'the first read was dispatched once')
local repeat_result,second=run('return await tools.read({path:'..note..'});')
check(repeat_result.ok and dispatched_for('read')==2,'the identical read runs again: two calls, two dispatches')
check(first.prior==nil,'the first read of a target carries no prior: '..json.encode(first.prior))

-- 2. A repeat carries prior:{call, age_s, same} against the earlier identical call.
check(type(second.prior)=='table','the repeat carries prior: '..tostring(repeat_result.value):sub(1,200))
check(second.prior.same==true,'an unchanged answer repeats as prior.same=true: '..json.encode(second.prior))
check(type(second.prior.call)=='number' and type(second.prior.age_s)=='number','prior names the earlier call and its age: '..json.encode(second.prior))

-- 3. An effect between two reads is visible as a changed answer - the reason implicit caching was
-- refused. `prior.same` is the change detector.
local changed_result,changed=run('await tools.write({path:'..note..',content:"second"}); return await tools.read({path:'..note..'});')
check(changed_result.ok and changed.content=='second','a read after a write sees the write: '..json.encode(changed):sub(1,200))
check(type(changed.prior)=='table' and changed.prior.same==false,'the changed answer repeats as prior.same=false: '..json.encode(changed.prior))
check(dispatched_for('read')==3 and dispatched_for('write')==1,'the effect itself ran too (reads=3, writes=1): '..dispatched_for('read')..'/'..dispatched_for('write'))
-- An effectful call repeats as a call, never as a cached answer.
local writes_before=dispatched_for('write')
local twice=run('await tools.write({path:'..note..',content:"third"}); await tools.write({path:'..note..',content:"third"}); return null;')
check(twice.ok and dispatched_for('write')==writes_before+2,'two identical writes are two writes, never reused: '..dispatched_for('write'))

-- 4. Explicit reuse answers the *session's* earlier result and dispatches nothing. The file is moved
-- on between the read and the reuse from outside any script, so an answer that said "fourth" could
-- only have come from running the call.
local third=run('return await tools.read({path:'..note..'});')
check(third.ok and third.value and json.decode(third.value).content=='third','a read after the writes sees the third content: '..tostring(third.value):sub(1,120))
assert(host.write_file(root..'/note.txt','fourth'))
local before_reuse=dispatched_for('read')
local reused,reused_value=run('return await tools.read({path:'..note..'},{reuse:"60s"});')
check(reused.ok and dispatched_for('read')==before_reuse,'{reuse:"60s"} dispatches nothing: '..dispatched_for('read'))
check(reused_value.content=='third','the reused answer is the one this session already had, not the world now: '..json.encode(reused_value):sub(1,160))
check(type(reused_value.reused_from)=='number' and type(reused_value.age_s)=='number','the reused result is marked {reused_from, age_s}: '..json.encode({reused_from=reused_value.reused_from,age_s=reused_value.age_s}))

-- 5. The age is honoured: the same request with an age younger than the answer runs fresh - and now
-- the answer says "fourth", which proves the fresh path reached the file.
wait(0.05)
local stale,stale_value=run('return await tools.read({path:'..note..'},{reuse:"1ms"});')
check(stale.ok and dispatched_for('read')==before_reuse+1,'{reuse:"1ms"} is older than the answer, so the call runs: '..dispatched_for('read'))
check(stale_value.reused_from==nil and stale_value.content=='fourth','a fresh call is not marked reused and sees the current file: '..json.encode(stale_value):sub(1,120))

-- 6. The journal, and the retained results behind it.
local journal,journal_value=run('return await results.last(3,{tool:"read"});')
check(journal.ok and #journal_value.results==3,'results.last(3,{tool:"read"}) lists three rows: '..tostring(journal.value):sub(1,200))
check(journal_value.results[1].age_s<=journal_value.results[3].age_s,'the journal is newest first: '..json.encode(journal_value.results):sub(1,240))
check(journal_value.results[1].call>journal_value.results[3].call,'every row has its own call id: '..json.encode(journal_value.results):sub(1,200))
local got,got_value=run('const rows=await results.last(1,{tool:"read"}); const full=await results.get(rows.results[0].result); return full;')
check(got.ok and type(got_value.value)=='table' and got_value.value.content=='fourth','results.get(sha256) returns the full prior result under value: '..tostring(got.value):sub(1,200))
local same,same_value=run('const rows=await results.last(4,{tool:"read"}); const d=await results.diff(rows.results[0].result,rows.results[0].result); return d;')
check(same.ok and same_value.same==true and same_value.count==0,'results.diff of a result with itself says same: '..json.encode(same_value):sub(1,200))
local different,different_value=run('const rows=await results.last(4,{tool:"read"}); const d=await results.diff(rows.results[1].result,rows.results[0].result); return d;')
check(different.ok and different_value.same==false,'results.diff of two different answers says same=false: '..json.encode(different_value):sub(1,200))
local content_change=false
for _,entry in ipairs(different_value.changed or {})do if entry.path=='$.content' then content_change=true end end
check(content_change,'the diff names the field that changed: '..json.encode(different_value.changed):sub(1,200))

-- 7. The repeats are counted, so the value of explicit reuse is measurable rather than asserted.
local events=telemetry.events(sid,0,500)
local repeats,same_true,same_false=0,0,0
for _,event in ipairs(events.events or {})do
 if event.kind=='codemode_repeat' then
  repeats=repeats+1
  local payload=event.payload or {}
  if payload.same==true then same_true=same_true+1 end
  if payload.same==false then same_false=same_false+1 end
 end
end
check(repeats>=3,'repeated identical reads are counted in telemetry (saw '..repeats..'): '..tostring(events.reason))
check(same_true>=1 and same_false>=1,'telemetry records both an unchanged and a changed repeat ('..same_true..'/'..same_false..')')

print('codemode explicit reuse ok ('..checks..' checks; real sandbox)')
