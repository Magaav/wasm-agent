-- A script is never killed for waiting (18/11, the operator's rule; polish-1811.md item 1).
--
-- Measured 18/11, session 100c54ab: seven TimeoutError endings, one of them at the 300 s maximum,
-- because the harness gave every script a wall-clock budget it had picked itself. The rule:
--
--   1. no wall-clock limit on a script waiting on tools;
--   2. each call keeps its own wait (wait_s, default 60, up to 300) and then answers
--      {state:"pending", op}; wait(op) resumes it;
--   3. the only hard stop is the CPU guard for runaway JS (CPU/instructions, not awaiting);
--   4. the 30 s default and the "pass timeout_ms" hint are gone.
--
-- This row proves (1)-(4) on a real node: two 15 s calls that must come back as RESULTS, one 70 s call
-- that must come back as a HANDLE and then settle when resumed, no TimeoutError anywhere, and
-- while(true){} still stopped by the CPU guard with no budget asked for.
--
-- Hermetic: its own scratch home (the runner gives it one); the calls are local sleeps.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua');local policy=dofile('lua/core/codemode_policy.lua')
local sid=memory.start_session('','never killed for waiting',{user_id='master'})
local ctx={session_id=sid,user_id='master'};policy.pin(memory,'master',ctx)
local checks=0
local function check(ok,message) assert(ok,message);checks=checks+1 end
local function run(code,extra)
  local args={code=code}
  for key,value in pairs(extra or {}) do args[key]=value end
  local started=host.now()
  local result=tools.dispatch(memory,'codemode',args,'master',ctx)
  return result, host.now()-started
end
local function shown(result,elapsed)
  return json.encode({elapsed_s=math.floor(elapsed or 0),ok=result.ok,code=result.code,
    error=tostring(result.error):sub(1,200),value=result.value,summary=result.summary}):sub(1,600)
end

-- ---------------------------------------------------------------- two 15 s calls, results not errors
-- Started with wait_s:0 (queue and answer at once) so the two run *concurrently*, then one batch wait
-- collects both: the point is that a 15 s wait inside a script costs nothing and is never a timeout.
local script = [==[
const a = await tools.bash({command:"sleep 15; echo one", wait_s:0});
const b = await tools.bash({command:"sleep 15; echo two", wait_s:0});
const long = await tools.bash({command:"sleep 70; echo done", wait_s:0});
const pair = await wait([a.op, b.op], {wait_s:40});
const early = await wait(long.op, {wait_s:5});
const resumed = await wait(long.op, {wait_s:200});
return {pair: pair.map(e => ({state: e.state, stdout: e.result && e.result.stdout})),
  early_state: early.state, early_op: early.op,
  resumed_state: resumed.state, resumed_stdout: resumed.result && resumed.result.stdout,
  long_elapsed: resumed.result && resumed.result.elapsed_ms};
]==]
local result,elapsed=run(script)
check(result.ok==true,'a script that waits is not killed: '..shown(result,elapsed))
check(tostring(result.error):find('TimeoutError',1,true)==nil,
  'and never ends in a TimeoutError: '..shown(result,elapsed))
check(elapsed>60,'it ran for '..math.floor(elapsed)..' s - past the old 30 s default it would have died at')
-- The script's own return value arrives as JSON text on this door; decode it so the checks read fields.
local value=type(result.value)=='table' and result.value
  or (type(result.value)=='string' and json.decode(result.value) or {})
local pair=type(value.pair)=='table' and value.pair or {}
check(#pair==2,'both 15 s calls answered: '..shown(result,elapsed))
check(pair[1] and pair[1].state=='done' and tostring(pair[1].stdout):find('one',1,true)~=nil,
  'the first 15 s call returned its own result: '..json.encode(pair[1] or {}))
check(pair[2] and pair[2].state=='done' and tostring(pair[2].stdout):find('two',1,true)~=nil,
  'the second 15 s call returned its own result: '..json.encode(pair[2] or {}))
check(value.early_state=='pending','the 70 s call answered a handle instead of blocking the script: '
  ..json.encode(value.early_state))
check(type(value.early_op)=='string' and value.early_op~='','and the handle is an op id: '
  ..tostring(value.early_op))
check(value.resumed_state=='done','wait(op) resumed it to its result: '..json.encode(value.resumed_state))
check(tostring(value.resumed_stdout):find('done',1,true)~=nil,
  'and the resumed result is the command output: '..tostring(value.resumed_stdout))
check(tonumber(value.long_elapsed or 0)>=70000,'the 70 s command really ran 70 s: '
  ..tostring(value.long_elapsed))

-- ---------------------------------------------------------------- the CPU guard is still the stop
-- No timeout_ms at all: an endless loop must still end, by the instruction guard rather than a clock,
-- and it must not take a minute to notice.
local spin,spin_elapsed=run('while (true) {}')
check(spin.ok==false,'an endless loop is still stopped: '..shown(spin,spin_elapsed))
check(tostring(spin.error):find('^TimeoutError: the script was stopped while computing',1)~=nil,
  'and named as a CPU stop: '..shown(spin,spin_elapsed))
check(tostring(spin.error):find('30000',1,true)==nil,
  'with no invented 30 s budget in the sentence: '..shown(spin,spin_elapsed))
check(tostring(spin.fix):find('pass timeout_ms',1,true)==nil,
  'and no "pass timeout_ms" hint: '..tostring(spin.fix))
check(spin_elapsed<25,'the CPU guard answers in seconds, not at a wall clock: '
  ..string.format('%.1f',spin_elapsed)..' s')

-- ---------------------------------------------------------------- a budget bounds COMPUTING only
-- The knob did not disappear, and it means what it says: a caller that asks for 400 ms of computing can
-- still wait five seconds on a call, because waiting is not computing (the sandbox's clock is paused
-- while the call is out in the host). Under the old flat budget this script died at 400 ms.
local paused,paused_elapsed=run([==[
const started = await tools.bash({command:"sleep 5; echo ok", wait_s:0});
const done = await wait(started.op, {wait_s:20});
return {state: done.state, stdout: done.result && done.result.stdout};
]==], {timeout_ms=400})
check(paused.ok==true,'a computing budget does not stop a script that is waiting: '..shown(paused,paused_elapsed))
local paused_value=type(paused.value)=='table' and paused.value
  or (type(paused.value)=='string' and json.decode(paused.value) or {})
check(paused_value.state=='done','the call it waited on still settled: '..json.encode(paused_value))
check(paused_elapsed>=5,'it really waited: '..math.floor(paused_elapsed)..' s')

print(json.encode({ok=true,checks=checks,elapsed_s=math.floor(elapsed)}))
