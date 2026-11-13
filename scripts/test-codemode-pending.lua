-- One pending-call handle for every code-mode call (docs/CODEMODE.md, "Pending calls"; the operator's
-- decision of 12/11). A call that can outlive its wait - a build, `scripts/fast.sh`, a deploy, a long
-- `bash` - used to block the script that started it. Now it answers {state:"pending", op} and
-- `wait(op)` resumes it, from the same script, the next turn, or a resumed session of the same scope.
--
-- What is asserted here, numbered as the decision is:
--   1. one handle shape for every tool: {state:"pending", op, tool, waited_s, progress};
--   2. `wait_s` on any call: default 60, range 0..300, effective = min(wait_s, 300, script remaining
--      minus a margin) - and a call that finishes in time answers exactly as before;
--   3. one resume built-in, `wait(op | [ops])`, 1..20 ops, answers in the order asked, batches with
--      other calls (and no batch may ask about a twenty-first);
--   4. starting is an effect, waiting is a read: a resume dispatches no tool call at all;
--   5. handles outlive the script - a later script in the same scope waits on an earlier one's op;
--   6. every pending answer carries bounded progress (the tail of what the call printed);
--   7. `cancel(op)` stops work that can be stopped, and answers `not_cancellable` with the reason for
--      a kind that cannot (a sent message stays sent);
--   8. no orphans: an op nobody resumed still settles, and is reported exactly once;
--   9. at most 16 pending calls per session, refused by name past it;
--  10. a settled result stays in `results`, so `results.get(op)` re-reads it without re-running;
--  11. no deadlocks: the wait holds no lock (`Promise.all([wait, read, wait])`), a stop/steer aborts it
--      at once, an unreachable supervisor answers `pending` with the reason, and a resume never
--      re-runs an effect (the command's marker file has one line, not two).
-- The native loop and the component loop both run this file: `scripts/test-codemode-component.sh`
-- runs it with WA_CODEMODE_COMPONENT=1, so the same checks pass through the seam
-- (docs/CORE-SPLIT.md).
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local pending=dofile('lua/core/codemode_pending.lua')
local paths=dofile('lua/core/paths.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
local sid=memory.start_session('','one pending handle',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local scope=host.sha256(json.encode({session=sid,user='master',role='master',
 workspace=memory.session_workspace and memory.session_workspace(sid) or nil,
 profile=ctx.subagent and ctx.subagent.allowed or nil}))
-- Every dispatch the node really made: a resume that re-ran something would show up here, and a
-- `wait` that dispatched anything at all would too.
local dispatched={}
local function dispatch(name,params,raw)
 dispatched[#dispatched+1]={name=name,params=params}
 return tools.dispatch(memory,name,params,'master',ctx)
end
local function count_of(name,tool)
 local n=0
 for _,entry in ipairs(dispatched)do if entry.name==name and (not tool or (type(entry.params)=='table' and entry.params.action==tool)) then n=n+1 end end
 return n
end
local function run(code,timeout_ms)
 local args={code=code}
 if timeout_ms then args.timeout_ms=timeout_ms end
 local result=codemode.run(memory,args,'master',ctx,catalog,function()return catalog end,dispatch,execution)
 local value=nil
 if type(result)=='table' and type(result.value)=='string' then
  local ok,decoded=pcall(json.decode,result.value)
  if ok then value=decoded end
 end
 return result,value
end
local function lines_of(path)
 local text=host.read_file(path)
 if type(text)~='string' then return 0 end
 local n=0 for _ in text:gmatch('\n')do n=n+1 end
 return n
end
local data=paths.data()..'/pending-test'
assert(host.write_file(data..'/marker.txt',''))  -- truncated: the marker is this test's own
assert(host.write_file(data..'/note.txt','a note the batch reads between two waits'))
local marker=json.encode(data..'/marker.txt')

-- 2. The bounds of a wait, before any script runs: default, ceiling, and the script's own clock.
check(pending.DEFAULT_WAIT_S==60,'a call that names no wait_s waits 60 s')
check(pending.MAX_WAIT_S==300,'no wait exceeds 300 s')
check(pending.effective_ms(nil,nil)==60000,'the default wait is 60 000 ms')
check(pending.effective_ms(1000,nil)==300000,'wait_s beyond the ceiling is capped at 300 s')
check(pending.effective_ms(0,nil)==0,'wait_s=0 starts the call and hands back the handle at once')
check(pending.effective_ms(5,7000)==5000,'a wait is bounded by the script: 7 000 ms left, 5 s asked, 5 s waited')
check(pending.effective_ms(30,5000)==3000,'the script\'s remaining time minus the answer margin wins over wait_s')
check(pending.effective_ms(30,1000)==0,'a script with less time left than the margin does not wait at all')
-- `wait_s` is taken out before the tool's schema sees the arguments; without it the text is untouched.
local stripped,wait_s=pending.strip('{"command":"echo hi","wait_s":5}')
check(wait_s==5 and type(stripped)=='string' and not stripped:find('wait_s'),'wait_s is taken out of a call\'s arguments: '..tostring(stripped))
local _,_,bad_wait=pending.strip('{"command":"echo hi","wait_s":"soon"}')
check(bad_wait=='invalid_wait_s','a wait_s that is not a number is refused by name, never defaulted')
local same,absent=pending.strip('{"command":"echo hi"}')
check(absent==nil and same=='{"command":"echo hi"}','a call that names no wait_s keeps its arguments byte for byte')

-- 1 + 6 + 11(d). The handle, its progress, the resume, and the effect that ran exactly once.
local first,first_value=run([==[
const marker = ]==]..marker..[==[;
const started = await tools.bash({command: 'echo one >> ' + marker + '; sleep 1; echo finished', wait_s: 0});
const shaped = {state: started.state, op: typeof started.op, tool: started.tool,
  waited_s: started.waited_s, progress: started.progress && started.progress.state,
  progress_bytes: started.progress && started.progress.output_bytes};
const resumed = await wait(started.op, {wait_s: 20});
return {shaped: shaped, op: started.op, resumed: {state: resumed.state, code: resumed.result && resumed.result.code,
  out: resumed.result && resumed.result.stdout, complete: resumed.result && resumed.result.output_complete}};
]==],60000)
check(first.ok==true,'a script that starts a call and resumes it runs: '..tostring(first.error))
check(first_value and first_value.shaped.state=='pending','a call still running after wait_s answers state=pending')
check(first_value and first_value.shaped.op=='string','the pending answer names an op handle')
check(first_value and first_value.shaped.tool=='bash','the handle says which tool is running')
check(first_value and first_value.shaped.waited_s==0,'the handle says how long this call waited')
-- The operation's own lifecycle, not one word of it: a call handed back with `wait_s:0` can still be
-- `accepted` (the supervisor has not spawned the shell yet) when the handle is built. What must be
-- true is that a pending answer always says where the work is, never that it is one particular phase.
local progress_state=tostring(first_value and first_value.shaped.progress or '')
check(progress_state=='accepted' or progress_state=='running' or progress_state=='draining',
 'every pending answer carries progress: '..progress_state)
check(first_value and type(first_value.shaped.progress_bytes)=='number','the pending progress reports the output size it has so far')
check(first_value and first_value.resumed.state=='done','wait(op) resumes a running call to done')
check(first_value and first_value.resumed.code==0 and tostring(first_value.resumed.out or ''):find('finished'),
 'the resumed answer is the call\'s own result: '..json.encode(first_value and first_value.resumed):sub(1,200))
check(lines_of(data..'/marker.txt')==1,'the resumed call ran exactly once (the marker has one line, saw '..lines_of(data..'/marker.txt')..')')
local the_op=first_value and first_value.op

-- 4. Waiting is a read: the resume dispatched no bash and no new operation.
local before_bash=count_of('bash')
local again,again_value=run('const again = await wait("'..tostring(the_op)..'", {wait_s: 5}); return {state: again.state, code: again.result && again.result.code};',30000)
check(again.ok==true and again_value.state=='done','a second wait answers the same settled handle')
check(count_of('bash')==before_bash,'a resume dispatches nothing: no second bash call was made')

-- 10. The settled result stays in `results`, so it can be re-read by name without re-running.
local reread,reread_value=run('const full = await results.get("'..tostring(the_op)..'"); return {ok: full.ok, code: full.value && full.value.code, out: full.value && full.value.stdout};',30000)
check(reread.ok==true and reread_value.ok==true,'results.get(op) answers a settled handle: '..json.encode(reread_value):sub(1,240))
check(reread_value.code==0 and tostring(reread_value.out or ''):find('finished'),'results.get(op) returns the call\'s own result')
check(lines_of(data..'/marker.txt')==1,'results.get(op) re-reads without re-running (still one line)')

-- 2 + 1. A call that finishes inside its wait answers exactly as it did before handles existed.
local plain,plain_value=run([==[
const done = await tools.bash({command: 'echo plain'});
return {value: done, state: done.state, code: done.code, out: done.stdout};
]==],60000)
check(plain.ok==true,'a plain bash call in code mode still runs: '..tostring(plain.error))
-- The operation's own `state` field is in the snapshot `bash` has always answered (`completed`), so
-- "not wrapped" is about the handle: no `pending`, an op id, and the command's own result.
check(plain_value and plain_value.state~='pending' and type(plain_value.op)=='nil',
 'a call that finishes in time is not wrapped in a handle')
check(plain_value and plain_value.code==0 and tostring(plain_value.out or ''):find('plain'),
 'a call that finishes in time answers the command result: '..json.encode(plain_value):sub(1,200))

-- 5. Handles outlive the script: the next script of the same scope waits on the earlier one's op.
local opened,opened_value=run([==[
const started = await tools.bash({command: 'sleep 2; echo later', wait_s: 0});
return {op: started.op, state: started.state};
]==],60000)
check(opened.ok==true and opened_value.state=='pending','a script can end with a call still running')
check(host.read_file(pending.dir()..'/'..scope..'.json')~=nil,'the handle is recorded on disk per scope')
local later,later_value=run('const late = await wait("'..tostring(opened_value.op)..'", {wait_s: 20}); return {state: late.state, out: late.result && late.result.stdout};',60000)
check(later.ok==true and later_value.state=='done','the next script resumes the earlier script\'s call')
check(tostring(later_value.out or ''):find('later'),'the resumed result is the earlier call\'s output')

-- 2, continued: a script that passes a non-numeric wait_s is told so by name.
local invalid,invalid_value=run('let answer=null; try { await tools.bash({command:"echo hi", wait_s:"soon"}); } catch (error) { answer=String(error); } return {answer: answer};',30000)
check(invalid.ok==true and tostring(invalid_value and invalid_value.answer or ''):find('invalid_wait_s'),
 'a script that passes a non-numeric wait_s is refused by name, not defaulted: '..json.encode(invalid_value):sub(1,160))

-- 3 + 11(a). One resume built-in, a batch in the order asked, batched with a read: no lock is held.
local batch,batch_value=run([==[
const note = ]==]..json.encode(data..'/note.txt')..[==[;
const a = await tools.bash({command: 'sleep 1; echo a', wait_s: 0});
const b = await tools.bash({command: 'sleep 12; echo b', wait_s: 0});
const [ra, page, rb] = await Promise.all([wait(a.op, {wait_s: 20}), tools.read({path: note}), wait(b.op, {wait_s: 0})]);
const both = await wait([a.op, b.op], {wait_s: 0});
const any = await wait([a.op, b.op], {wait_s: 2, until: 'any'});
let tooMany = null;
try { await wait(Array.from({length: 21}, () => a.op)); } catch (error) { tooMany = String(error); }
return {ra: ra.state, rb: rb.state, page: typeof page.content, first: both[0] && both[0].op, second: both[1] && both[1].op,
  order: both[0].op === a.op && both[1].op === b.op, states: [both[0].state, both[1].state],
  anyLen: Array.isArray(any) ? any.length : -1, anyState: any[0] && any[0].state,
  refused: String(tooMany), ops: {a: a.op, b: b.op}};
]==],60000)
check(batch.ok==true,'a batch of waits runs with a read between them: '..tostring(batch.error))
check(batch_value and batch_value.ra=='done','wait inside Promise.all settles the first op')
check(batch_value and batch_value.rb=='pending','a batched wait about a running op answers pending')
check(batch_value and batch_value.page=='string','the read between two waits was answered in the same script')
check(batch_value and batch_value.order==true,'a batch answers one entry per op in the order asked')
-- Lua sees the JS array 1-based: states[1] is the first op, states[2] the second.
check(batch_value and batch_value.states[2]=='pending' and batch_value.states[1]=='done',
 'the entry for the running op says pending: '..json.encode(batch_value and batch_value.states))
-- `until:"any"` stops *waiting* at the first settled op and still answers every op it was asked
-- about, which is what lets a step drop the finished ones and keep the rest.
check(batch_value and batch_value.anyLen==2 and batch_value.anyState=='done',
 'until:"any" answers every op, the settled one first: '..tostring(batch_value and batch_value.anyLen))
check(batch_value and tostring(batch_value.refused or ''):find('at_most_20'),'a batch of 21 ops is refused by name: '..tostring(batch_value and batch_value.refused))
local slow_op=batch_value and batch_value.ops and batch_value.ops.b

-- The pool (the operator's follow-up, 12/11): a batch that grows and shrinks across steps. Script 1
-- starts five calls and keeps none of them in mind; script 2 asks `pending()` what is open, waits
-- until one is done, drops the finished, adds two more, and waits for the rest - every outcome
-- arriving exactly once and nothing running twice.
assert(host.write_file(data..'/pool-marker.txt',''))
local pool_marker=json.encode(data..'/pool-marker.txt')
local pool_script1,pool_value1=run([==[
const marker = ]==]..pool_marker..[==[;
const ops = [];
for (let i = 1; i <= 5; i++) {
  const started = await tools.bash({command: 'echo pool' + i + ' >> ' + marker + '; sleep ' + i + '; echo done' + i, wait_s: 0});
  ops.push(started.op);
}
return {ops: ops};
]==],90000)
check(pool_script1.ok==true and type(pool_value1.ops)=='table' and #pool_value1.ops==5,
 'script 1 starts five calls and keeps no handle in mind: '..json.encode(pool_value1):sub(1,160))
local pool_script2,pool_value2=run([==[
const marker = ]==]..pool_marker..[==[;
const open = await pending();
let pool = open.ops.map(o => o.op);
const collected = [];
const first = await wait(pool, {until: 'any', wait_s: 60});
for (const entry of first) {
  if (entry.state === 'pending') continue;
  collected.push(entry.op);
  pool = pool.filter(op => op !== entry.op);
}
const added = [];
for (const n of [6, 7]) {
  const started = await tools.bash({command: 'echo pool' + n + ' >> ' + marker + '; sleep 1; echo done' + n, wait_s: 0});
  added.push(started.op);
}
pool = pool.concat(added);
const rest = await wait(pool, {wait_s: 120});
for (const entry of rest) collected.push(entry.op);
const afterAll = await pending();
return {openAtStart: open.ops.length, firstLen: first.length,
  firstDone: first.filter(e => e.state !== 'pending').length,
  restLen: rest.length, collected: collected, unique: new Set(collected).size,
  allDone: rest.every(e => e.state === 'done'), leftOpen: afterAll.ops.length};
]==],180000)
check(pool_script2.ok==true,'script 2 drives the pool: '..tostring(pool_script2.error))
check(pool_value2 and pool_value2.openAtStart>=5,'pending() answers the five handles script 1 left: '..tostring(pool_value2 and pool_value2.openAtStart))
check(pool_value2 and pool_value2.firstLen==pool_value2.openAtStart and pool_value2.firstDone>=1,
 'wait(until:"any") answers every open op with at least one settled: '..json.encode(pool_value2 and {f=pool_value2.firstLen,d=pool_value2.firstDone}))
check(pool_value2 and pool_value2.restLen==pool_value2.openAtStart-pool_value2.firstDone+2,
 'the rest of the pool plus the two new calls are waited in one call: '..json.encode(pool_value2 and {r=pool_value2.restLen}))
check(pool_value2 and pool_value2.allDone==true,'every call in the pool finished')
-- Relative to what `pending()` answered, because an earlier script in this file may still have work
-- open: what must be true is that the pool script collected each open handle plus its two new calls,
-- exactly once.
check(pool_value2 and pool_value2.unique==#pool_value2.collected and #pool_value2.collected==pool_value2.openAtStart+2,
 'every outcome arrives exactly once across the two waits: '..json.encode(pool_value2 and {c=#pool_value2.collected,u=pool_value2.unique,o=pool_value2.openAtStart}))
check(pool_value2 and pool_value2.leftOpen==0,'the pool is empty once every outcome was collected: '..tostring(pool_value2 and pool_value2.leftOpen))
check(lines_of(data..'/pool-marker.txt')==7,
 'the pool ran each call exactly once (seven marker lines, saw '..lines_of(data..'/pool-marker.txt')..')')

-- `pending()` is a read: it changes nothing, and it names the tool each handle belongs to.
local empty_pending,empty_pending_value=run('const p = await pending(); return {count: p.count, ops: p.ops.length};',30000)
check(empty_pending.ok==true and empty_pending_value.count==0,'pending() is empty once every handle was collected')
local listed,listed_value=run([==[
const started = await tools.bash({command: 'sleep 20; echo never', wait_s: 0});
const p = await pending();
return {op: started.op, count: p.count, tool: p.ops[0] && p.ops[0].tool, state: p.ops[0] && p.ops[0].state,
  hasProgress: !!(p.ops[0] && p.ops[0].progress)};
]==],60000)
check(listed.ok==true and listed_value.count==1 and listed_value.tool=='bash',
 'pending() names the tool behind each open handle: '..json.encode(listed_value):sub(1,200))
check(listed_value and listed_value.hasProgress==true,'pending() carries the progress the executor already knows')
local cancelled_listed,cancelled_listed_value=run('const stopped = await cancel("'..tostring(listed_value.op)..'"); return {cancelled: stopped.cancelled};',30000)
check(cancelled_listed.ok==true and cancelled_listed_value.cancelled==true,'the listed handle can be cancelled by name')

-- 11(b). A stop/steer aborts the wait at once: the op stays recorded and the answer is pending.
local steer_op,steer_op_value=run([==[
const started = await tools.bash({command: 'sleep 20; echo never', wait_s: 0});
return {op: started.op};
]==],60000)
check(steer_op.ok==true and type(steer_op_value.op)=='string','a long call is started before a wait is steered')
local real_cancel=host.run_cancelled
local calls=0
host.run_cancelled=function()
 calls=calls+1
 if calls>1 then return json.encode({cancelled=true}) end
 return json.encode({cancelled=false})
end
local interrupted_at=host.now()
local steer,steer_value=run('const entry = await wait("'..tostring(steer_op_value.op)..'", {wait_s: 30}); return {state: entry.state, reason: entry.reason, progress: entry.progress && entry.progress.state};',60000)
local interrupted_ms=math.floor(((tonumber(host.now()) or interrupted_at)-interrupted_at)*1000)
host.run_cancelled=real_cancel
check(steer.ok==true and steer_value and steer_value.state=='pending','a cancelled wait answers pending, not a failure: '..json.encode(steer_value):sub(1,200))
check(steer_value and steer_value.reason=='run_cancelled','the interrupted wait says why: '..tostring(steer_value and steer_value.reason))
check(interrupted_ms<15000,'the wait was aborted at once instead of waiting out its 30 s (took '..interrupted_ms..' ms)')
local still,still_value=run('const entry = await wait("'..tostring(steer_op_value.op)..'", {wait_s: 0}); return {state: entry.state};',30000)
check(still.ok==true and still_value.state=='pending','an interrupted wait leaves the operation recorded, not lost')

-- 11(c). An unreachable supervisor is a reason, never a hang and never a false `failed`.
local unreachable=function(name,params,raw) return {error='operation_supervisor_unreachable'} end
local blind=pending.wait(unreachable,{scope=scope,remaining_ms=5000},tostring(steer_op_value.op),{wait_s=5})
check(type(blind)=='table' and blind.state=='pending','an unreachable supervisor answers pending: '..json.encode(blind):sub(1,240))
check(type(blind)=='table' and blind.progress and blind.progress.reason=='operation_supervisor_unreachable',
 'the pending answer carries the reason the wait could not be completed')

local refused_resume=pending.wait(function() return {error='must not dispatch'} end,{scope=scope,remaining_ms=5000},tostring(the_op),{wait_s="soon"})
check(type(refused_resume)=='table' and refused_resume.error=='invalid_wait_s','wait refuses a non-numeric wait_s by name')

-- 7. cancel(op) stops work that can be stopped.
local started_cancel,started_cancel_value=run([==[
const started = await tools.bash({command: 'sleep 30; echo never', wait_s: 0});
return {op: started.op, state: started.state};
]==],60000)
check(started_cancel.ok==true and started_cancel_value.state=='pending','a long call is started before it is cancelled')
local cancelled,cancelled_value=run('const stopped = await cancel("'..tostring(started_cancel_value.op)..'"); return {cancelled: stopped.cancelled, state: stopped.state, error: stopped.error};',30000)
check(cancelled.ok==true and cancelled_value and cancelled_value.cancelled==true,'cancel(op) stops a running call: '..json.encode(cancelled_value):sub(1,200))
check(cancelled_value and cancelled_value.state=='cancelled','the cancelled handle answers its own state')
local after_cancel,after_cancel_value=run('const entry = await wait("'..tostring(started_cancel_value.op)..'", {wait_s: 5}); return {state: entry.state, reason: entry.reason, code: entry.result && entry.result.code};',60000)
-- A failed call is an answer, not an exception: the script read `state` and `reason` and kept running.
check(after_cancel.ok==true,'a failed pending call does not throw inside the script: '..tostring(after_cancel.error))
check(after_cancel_value and after_cancel_value.state=='failed','a cancelled call is never reported as done: '..json.encode(after_cancel_value):sub(1,200))
check(after_cancel_value and after_cancel_value.reason=='cancelled','the failed entry says why: '..tostring(after_cancel_value and after_cancel_value.reason))
-- The operator's ruling (12/11): the word is `reason`, and the help text must agree with the
-- behaviour - news about a call never throws, so a failed entry carries no `error`.
check(after_cancel_value and after_cancel_value.error==nil,'a failed entry answers reason, never error')
check(pending.WAIT_HELP.description:find('{state:"failed", op, reason}',1,true)~=nil,
 'the wait help names the failed shape the same way the implementation answers it')
check(pending.WAIT_HELP.description:find('error',1,true)==nil,'the wait help promises no error key for a failed call')
-- `searchTools` matches a keyword as a SUBSTRING of name+description, so a builtin whose help says
-- "read" (or "already", which contains it) shadows the `read` tool in a three-row query - measured
-- twice on 12/11, once each time a new help text was written. Matching is a separate change; until
-- then these entries keep out of that namespace and this is the check that keeps them there.
for _, name in ipairs({'WAIT_HELP','PENDING_HELP','CANCEL_HELP'}) do
 local help=pending[name]
 check(type(help)=='table' and not tostring(help.description):lower():find('read',1,true),
  name..' does not shadow the read tool with the word "read"')
end
-- 7, second half: a kind whose effect cannot be stopped says so instead of pretending.
local outbox_scope=string.rep('b',64)
pending.save(outbox_scope,{ops={['op-sent-1']={op='op-sent-1',tool='message_send_fixture',kind='outbox',state='running',reported=false}}})
pending.EXECUTORS['message_send_fixture']={kind='outbox',cancel=false,cancel_why='a sent message stays sent'}
local refused_cancel=pending.cancel(function() error('a not_cancellable answer must not dispatch') end,{scope=outbox_scope},'op-sent-1')
pending.EXECUTORS['message_send_fixture']=nil
check(type(refused_cancel)=='table' and refused_cancel.error=='not_cancellable','an effect that cannot be stopped is not_cancellable')
check(refused_cancel and refused_cancel.why=='a sent message stays sent','not_cancellable carries the reason in the recorder\'s words')

-- 9. At most 16 pending calls per session; the seventeenth is refused by name.
local full_scope=string.rep('c',64)
local full={ops={}}
for index=1,pending.MAX_OPEN do
 full.ops['op-full-'..index]={op='op-full-'..index,tool='bash',kind='operation',state='running',reported=false}
end
pending.save(full_scope,full)
local overflow=pending.invoke(function() error('a full session must not start another call') end,
 {scope=full_scope,remaining_ms=5000,ctx={}},'bash',{command='true'},'{"command":"true"}',0)
check(type(overflow)=='table' and overflow.error=='codemode_pending_limit','the 17th pending call is refused by name: '..json.encode(overflow):sub(1,200))
check(overflow and overflow.limit==pending.MAX_OPEN,'the refusal says the limit')

-- 8. No orphans: an op nobody resumed still settles, and is reported exactly once.
local orphan,orphan_value=run([==[
const started = await tools.bash({command: 'sleep 1; echo nobody watched', wait_s: 0});
return {op: started.op};
]==],60000)
check(orphan.ok==true and type(orphan_value.op)=='string','a call is started and nobody resumes it')
host.sleep(2500)
local announced=run('return 1;',30000)
local reported=false
for _,row in ipairs(type(announced)=='table' and announced.pending_settled or {})do
 if row.op==orphan_value.op then reported=row.state=='done' end
end
check(reported,'an unreported settled call is announced on the next script: '..json.encode(announced and announced.pending_settled or {}):sub(1,240))
local second=run('return 1;',30000)
local repeated=false
for _,row in ipairs(type(second)=='table' and second.pending_settled or {})do
 if row.op==orphan_value.op then repeated=true end
end
check(repeated==false,'a settled call is announced exactly once')

-- The outbox executor (land6's WhatsApp send): the queue id the connector answers is the handle, a
-- wait reads the queue, and a cancel says why it cannot stop a message that is already sent. Driven by
-- a fake connector here, because a real account is not what this file is measuring; the connector's
-- own queue, backoff and one-send-per-job behaviour is `scripts/test-whatsapp-send-waits.lua`'s job.
local outbox_scope=string.rep('d',64)
local outbox_calls={}
local function outbox_dispatch(name,args,raw)
  outbox_calls[#outbox_calls+1]={name=name,args=args}
  if name~='mcp_whatsapp_send' then return {error='unexpected_tool:'..tostring(name)} end
  if args.id==nil then return {ok=true,state='pending',id=42,waited_s=0} end
  if (tonumber(args.wait_s) or 0)>0 then
    return {ok=true,state='done',id=tonumber(args.id),message_id='MSG-'..tostring(args.id),served_by='acct-node'}
  end
  return {ok=true,state='pending',id=tonumber(args.id),waited_s=0}
end
local outbox_opts={scope=outbox_scope,remaining_ms=60000,ctx={}}
local sent=pending.invoke(outbox_dispatch,outbox_opts,'mcp_whatsapp_send',
 {chat='1234@s.whatsapp.net',text='hello'},'{"chat":"1234@s.whatsapp.net","text":"hello"}',0)
check(type(sent)=='table' and sent.state=='pending' and sent.op=='msg-42','a send that outlives its wait answers a handle: '..json.encode(sent):sub(1,200))
check(sent and sent.tool=='mcp_whatsapp_send','the handle names the connector call it belongs to')
local outbox_list=pending.list(outbox_dispatch,outbox_opts)
check(outbox_list.count==1 and outbox_list.ops[1].op=='msg-42','pending() lists the outbox handle too')
local outbox_cancel=pending.cancel(outbox_dispatch,outbox_opts,'msg-42')
check(outbox_cancel.error=='not_cancellable' and outbox_cancel.why=='a sent message stays sent',
 'cancel on a queued message is not_cancellable, in the recorder\'s words: '..json.encode(outbox_cancel))
local queued=0
for _, call in ipairs(outbox_calls) do if call.args.id==nil then queued=queued+1 end end
check(queued==1,'nothing was queued twice by the handle being listed or cancelled (queued '..queued..')')
local outbox_wait=pending.wait(outbox_dispatch,outbox_opts,'msg-42',{wait_s=5})
check(outbox_wait.state=='done' and outbox_wait.result and outbox_wait.result.message_id=='MSG-42',
 'wait(op) collects the outbox outcome: '..json.encode(outbox_wait):sub(1,200))
local kept_outbox=pending.retained('msg-42',outbox_scope)
check(type(kept_outbox)=='table' and kept_outbox.message_id=='MSG-42','results.get(op) re-reads the outbox outcome')
for index=2,#outbox_calls do
  check(outbox_calls[index].args.id==42 and outbox_calls[index].args.chat==nil,
   'every read after the send carries the id and no message: '..json.encode(outbox_calls[index].args))
end

-- 3, continued: the discovery entry a script reads for the resume.
local help_ok=false
local searched,searched_value=run('const rows = await searchTools("select:wait,cancel,pending"); return {names: rows.map(r => r.name)};',30000)
if searched.ok and type(searched_value)=='table' then
 local seen={} for _,name in ipairs(searched_value.names or {})do seen[name]=true end
 help_ok=seen['wait']==true and seen['cancel']==true and seen['pending']==true
end
check(help_ok,'searchTools("select:wait,cancel") answers both builtins: '..json.encode(searched_value):sub(1,200)..json.encode(searched_value):sub(1,200))

print('codemode pending handles ok ('..checks..' checks; real sandbox)')
