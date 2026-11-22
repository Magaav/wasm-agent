-- ONE RESULT SHAPE, whatever the timing (21/11).
--
-- A call that settles inside its wait answers the tool's own result - stdout, code, ok. `wait(op)` on the
-- very same handle used to answer that same result one level down, under `result`, so a model that read
-- `r.result.stdout` on a flat answer got nothing and spent three calls working out which shape it held
-- (the orchestrator's note on the always-available mission, confirmed in code at codemode_pending.lua M.wait).
--
-- What this row pins:
--   1. an inline call and a call collected by wait() expose the SAME keys for stdout/code/ok;
--   2. neither answers a `result` key - there is nothing to reach through;
--   3. a still-running handle keeps the pending shape and flattens nothing;
--   4. an unknown op is a failed entry with a reason, in the same shape;
--   5. a handle nobody resumed is announced (pending_settled) in that same flat shape, with the retained
--      hash beside it for results.get().
-- Hermetic: its own scratch home, local commands only, no peer and no fleet call.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local pending=dofile('lua/core/codemode_pending.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
-- A scratch home of this row's own, and a refusal to run anywhere else: this row writes handles to disk.
local home=tostring(host.getenv('HOME') or '')
local data=dofile('lua/core/paths.lua').data()
assert(home~='' and not home:match('/%.wasm%-agent$') or data:find('scratch',1,true) or data:find('/tmp/',1,true) or data:find('wa%-test',1,true),
 'this row needs a scratch HOME (it writes pending-handle indexes); it refused to run in '..tostring(data))
local sid=memory.start_session('','one result shape',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local function dispatch(name,params,raw) return tools.dispatch(memory,name,params,'master',ctx,raw) end
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

-- 1 + 2. One call settled inline and one collected by wait(): the same keys, one level deep, no result key.
local inline,inline_value=run([==[
const done = await tools.bash({command: 'echo inline'});
return {keys: Object.keys(done).sort(), state: done.state, code: done.code, ok: done.ok,
  out: done.stdout, nested: done.result === undefined ? 'absent' : typeof done.result};
]==],60000)
check(inline.ok==true,'a plain call in code mode runs: '..tostring(inline.error))
check(inline_value and inline_value.out=='inline\n' and inline_value.code==0 and inline_value.ok==true,
 'the inline call answers the command result: '..json.encode(inline_value):sub(1,240))
local collected,collected_value=run([==[
const started = await tools.bash({command: 'sleep 1; echo collected', wait_s: 0});
const first = started.state;
const waited = await wait(started.op, {wait_s: 20});
return {first: first, keys: Object.keys(waited).sort(), state: waited.state, op: waited.op,
  tool: waited.tool, code: waited.code, ok: waited.ok, out: waited.stdout,
  nested: waited.result === undefined ? 'absent' : typeof waited.result};
]==],60000)
check(collected.ok==true,'a script that starts and resumes a call runs: '..tostring(collected.error))
check(collected_value and collected_value.first=='pending','the call answers a handle first')
check(collected_value and collected_value.state=='done','wait(op) settles it')
check(collected_value and collected_value.op==tostring(collected_value.op) and collected_value.tool=='bash',
 'the settled entry still names its handle and tool: '..json.encode(collected_value):sub(1,240))
check(collected_value and collected_value.out=='collected\n' and collected_value.code==0
  and collected_value.ok==true,
 'the resumed call answers the command result at the TOP level, as the inline call did: '
  ..json.encode(collected_value):sub(1,300))
check(collected_value and collected_value.nested=='absent',
 'and nothing is nested under a result key: '..tostring(collected_value and collected_value.nested))
-- The same keys, not merely the same values: the two answers agree on every field a caller reads.
local inline_keys=type(inline_value)=='table' and inline_value.keys or {}
local collected_keys=type(collected_value)=='table' and collected_value.keys or {}
local inline_set,collected_set={},{}
for _,key in ipairs(inline_keys)do inline_set[key]=true end
for _,key in ipairs(collected_keys)do collected_set[key]=true end
local shared={}
for _,key in ipairs({'stdout','stderr','code','ok','output_complete'})do
 if inline_set[key] and collected_set[key] then shared[#shared+1]=key end
end
check(#shared==5,'the inline and the resumed answer expose the same result keys (shared: '
 ..table.concat(shared,',')..')')
check(not inline_set.result and not collected_set.result,'neither answer carries a result key')
local handle_keys={}
for _,key in ipairs(collected_keys)do
 if key=='op' or key=='tool' or key=='state' then handle_keys[#handle_keys+1]=key end
end
check(#handle_keys==3,'and the handle names its own three fields beside the result: '
 ..table.concat(handle_keys,','))

-- A failing command keeps its own code on BOTH paths, so the flattening does not hide a failure.
local failing,failing_value=run([==[
const done = await tools.bash({command: 'exit 3'});
const started = await tools.bash({command: 'sleep 1; exit 4', wait_s: 0});
const waited = await wait(started.op, {wait_s: 20});
return {inline_code: done.code, inline_state: done.state, waited_code: waited.code,
  waited_state: waited.state, waited_ok: waited.ok, nested: waited.result === undefined ? 'absent' : 'present'};
]==],60000)
check(failing.ok==true,'both calls report their own exit codes without failing the script: '..tostring(failing.error))
check(failing_value and failing_value.inline_code==3 and failing_value.waited_code==4,
 'the codes are the commands\' own: '..json.encode(failing_value):sub(1,240))
check(failing_value and failing_value.waited_ok==false and failing_value.nested=='absent',
 'a non-zero exit is a flat answer with ok=false, not a nested one: '..json.encode(failing_value):sub(1,240))

-- 3. A handle that has not settled keeps the pending shape and flattens nothing.
local long,long_value=run([==[
const started = await tools.bash({command: 'sleep 20', wait_s: 0});
const now = await wait(started.op, {wait_s: 0});
const stopped = await cancel(started.op);
return {state: now.state, op: now.op, waited_s: now.waited_s,
  progress: now.progress && now.progress.state,
  has_stdout: now.stdout === undefined ? 'absent' : typeof now.stdout,
  nested: now.result === undefined ? 'absent' : 'present',
  cancelled: stopped.cancelled};
]==],60000)
check(long.ok==true,'a poll answers a pending entry: '..tostring(long.error))
check(long_value and long_value.state=='pending' and long_value.has_stdout=='absent'
  and long_value.nested=='absent' and type(long_value.waited_s)=='number',
 'a still-running handle answers {state=pending, op, waited_s, progress} and nothing else: '
  ..json.encode(long_value or {}):sub(1,240))
check(long_value and tostring(long_value.progress)~='','and says what state the work is in: '
 ..json.encode(long_value or {}):sub(1,200))
check(long_value and long_value.cancelled==true,
 'and the long call is stopped, so this row leaves nothing running: '..json.encode(long_value or {}):sub(1,200))

-- 4. An unknown op is a failed entry with a reason, in the same shape.
local unknown,unknown_value=run('const missing = await wait("op-does-not-exist", {wait_s: 0});'
 ..' return {state: missing.state, reason: missing.reason, nested: missing.result === undefined ? "absent" : "present"};',30000)
check(unknown.ok==true,'a wait on an unknown handle answers instead of throwing: '..tostring(unknown.error))
check(unknown_value and unknown_value.state=='failed' and unknown_value.reason=='unknown_op'
  and unknown_value.nested=='absent',
 'an unknown op is {state=failed, reason=unknown_op}: '..json.encode(unknown_value or {}):sub(1,240))

-- 5. A handle nobody resumed is announced in the same flat shape, with its hash beside it.
local orphan,orphan_value=run([==[
const started = await tools.bash({command: 'sleep 1; echo nobody watched', wait_s: 0});
return {op: started.op};
]==],60000)
check(orphan.ok==true and type(orphan_value and orphan_value.op)=='string','a handle is left behind')
if host.sleep then host.sleep(2500) end
local announced=run('return 1;',30000)
local row=nil
for _,entry in ipairs(type(announced)=='table' and announced.pending_settled or {})do
 if entry.op==(orphan_value and orphan_value.op) then row=entry end
end
check(row~=nil,'the settled handle is announced on the next script: '
 ..json.encode(type(announced)=='table' and announced.pending_settled or {}):sub(1,240))
check(row and row.state=='done' and row.stdout=='nobody watched\n' and row.code==0 and row.ok==true,
 'the announced row is the answer itself, flat, as wait(op) would have answered it: '
  ..json.encode(row or {}):sub(1,300))
check(row and row.result==nil,'the announced row is not nested under a result key')
check(row and type(row.result_sha256)=='string','and keeps its retained hash for results.get(): '
 ..tostring(row and row.result_sha256))

print(string.format('one result shape: %d checks',checks))
