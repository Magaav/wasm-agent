-- The three counters the next mission is planned from (21/11; docs/CODEMODE.md, "The three counters").
--
-- Telemetry only: nothing here changes a decision. What is asserted is that each counter is counted
-- where the thing it names happens, once per event and never per call:
--
--   * script_cut_at_cap - a script that was told "not yet" (a pending answer) increments once;
--   * handle_mishandled - a script that used a pending answer as if it had settled increments once;
--   * wake_only_round   - the read/write half is held here (an unknown name is refused, a count that
--     was never bumped is 0); the increment itself is in selfloop.run_wake, on the handle-wake turn,
--     which needs a model and is covered there rather than here.
-- Hermetic: its own scratch home, local commands only.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return 'native' end return env(k) end
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local codemode=dofile('lua/core/codemode.lua')
local counters=dofile('lua/core/counters.lua')
local checks=0
local function check(value,label)assert(value,label);checks=checks+1 end
local ready=false
if type(host.quickjs)=='function' then
 local ok,raw=pcall(host.quickjs,'ready','{}')
 if ok then local decoded=json.decode(raw);ready=type(decoded)=='table' and decoded.ok==true end
end
assert(ready,'this node has no embedded code-mode assets, so no script ran and nothing here was measured')
local data=dofile('lua/core/paths.lua').data()
assert(not data:match('/%.wasm%-agent$') or data:find('scratch',1,true) or data:find('/tmp/',1,true),
 'this row needs a scratch HOME (it writes counters); it refused to run in '..tostring(data))
local sid=memory.start_session('','the three counters',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
local catalog=tools.all('master',ctx,memory)
local execution=tools.discovery_execution(memory,ctx)
local function dispatch(name,params,raw) return tools.dispatch(memory,name,params,'master',ctx,raw) end
local function run(code,timeout_ms)
 local args={code=code}
 if timeout_ms then args.timeout_ms=timeout_ms end
 local result=codemode.run(memory,args,'master',ctx,catalog,function()return catalog end,dispatch,execution)
 return result
end

-- Nothing counted before anything happened: a counter nobody bumped is 0, not absent.
local start=counters.read()
check(start.script_cut_at_cap==0 and start.handle_mishandled==0 and start.wake_only_round==0,
 'every counter starts at 0 in a fresh home: '..json.encode(start))
check(counters.bump('not_a_counter')==nil and counters.read().not_a_counter==nil,
 'an unknown counter name is refused instead of creating a key nobody reads')

-- 1. A script told "not yet": one increment, and one only, however many handles it leaves.
local left=run([==[
const first = await tools.bash({command: 'sleep 5', wait_s: 0});
const second = await tools.bash({command: 'sleep 5', wait_s: 0});
return {first: first.state, second: second.state};
]==],60000)
check(left.ok==true,'a script that leaves two handles runs: '..tostring(left.error))
local after_cut=counters.read()
check(after_cut.script_cut_at_cap==1,
 'a script that was told not yet increments script_cut_at_cap ONCE, not once per handle: '
 ..json.encode(after_cut))
check(after_cut.handle_mishandled==0,'and handling the handle properly is not a mishandling')

-- 2. A script that used a pending answer as a result: the pending-value TypeError, counted once.
local misused=run([==[
const started = await tools.bash({command: 'sleep 5', wait_s: 0});
const promise = tools.bash({command: 'sleep 5', wait_s: 0});
return {out: promise.stdout};
]==],60000)
check(misused.ok==false and tostring(misused.error or ''):find('has not resolved yet',1,true)~=nil,
 'using a pending answer as a result still throws the pending-value TypeError: '
 ..tostring(misused.error):sub(1,200))
local after_misuse=counters.read()
check(after_misuse.handle_mishandled==1,
 'and that is counted once as handle_mishandled: '..json.encode(after_misuse))
-- The same script also left a handle behind, and that is its own increment: the two counters answer
-- two different questions about one script.
check(after_misuse.script_cut_at_cap==2,
 'and the handle it left is the same script being cut at its cap once more: '..json.encode(after_misuse))

-- 3. A plain script that waits properly counts nothing.
local clean=run([==[
const done = await tools.bash({command: 'echo fine'});
return {code: done.code};
]==],60000)
check(clean.ok==true,'a plain script runs: '..tostring(clean.error))
local after_clean=counters.read()
check(after_clean.script_cut_at_cap==after_misuse.script_cut_at_cap
  and after_clean.handle_mishandled==after_misuse.handle_mishandled,
 'a script that waits for its calls moves neither counter: '..json.encode(after_clean))

-- 4. The wake-only round's own counter is readable and writable through the same door.
check(counters.bump('wake_only_round')==1 and counters.read().wake_only_round==1,
 'wake_only_round counts the steps whose only input was a settled handle')

-- Leave nothing running.
local pending=dofile('lua/core/codemode_pending.lua')
local opened=pending.list(dispatch,{ctx=ctx})
for _, handle in ipairs(type(opened)=='table' and opened.ops or {}) do
 pcall(function() pending.cancel(dispatch,{ctx=ctx},handle.op) end)
end
print(string.format('codemode counters: %d checks',checks))
