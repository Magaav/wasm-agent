-- Low CPU priority only for work nobody is waiting for - and the FACT that decides it is checked
-- where it is decided (18/11 round 2, finding 9; corrected 18/11 round 3, item 5).
--
-- Round 1 gave EVERY operation a niceness below the node's own. Round 2 restricted it to "backgrounded"
-- work, but the only thing knowable at spawn is the wait_s the caller named, so a wait_s:0 call that the
-- script resumes in the same breath was lowered by a guess. The rule now:
--
--   * a foreground shell (the bash tool, host.exec) runs at the node's own priority;
--   * an explicit operation start - the caller gets a receipt and moves on - is backgrounded by
--     definition and runs one step below;
--   * a code-mode call, whatever wait it named, STARTS at the node's own priority, and is lowered when
--     the script stops waiting for it - the end of the script that left the handle behind
--     (lua/core/codemode_pending.lua, M.background, called by lua/core/codemode.lua);
--   * a wait_s:0 call the script awaits at once is therefore never lowered while it is being waited on.
--
-- Every operation records the priority it runs at, so the row reads the fact from the record instead of
-- guessing from timing.
--
-- Hermetic: its own scratch home; the commands are local echoes and short sleeps.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local pending = dofile('lua/core/codemode_pending.lua')
local sid = memory.start_session('', 'operation cpu priority', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function dispatch(name, args, raw) return tools.dispatch(memory, name, args, 'master', ctx, raw) end
local function run(code) return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx) end

-- ---------------------------------------------------------------- a foreground shell keeps it
local foreground = dispatch('bash', { command = 'echo foreground' })
check(type(foreground) == 'table' and foreground.ok == true, 'the foreground shell ran: '
  .. json.encode(foreground or {}):sub(1, 200))
-- The priority is on the OPERATION RECORD, which the answer names (mission slim-tool-results: a command
-- answer keeps what a caller acts on, and the header above already says this row reads the fact from the
-- record). The assertion is unchanged.
local foreground_record = dispatch('operation', { action = 'status', id = foreground.operation_id })
check(tostring(foreground_record.cpu_priority) == 'default',
  'a call the run waits for keeps the node own priority: ' .. tostring(foreground_record.cpu_priority))

-- ---------------------------------------------------------------- an explicit start is backgrounded
local started = dispatch('operation', { action = 'start', command = 'sleep 3', timeout_seconds = 60 })
check(type(started.operation_id) == 'string', 'the operation started: ' .. json.encode(started):sub(1, 200))
local state = dispatch('operation', { action = 'status', id = started.operation_id })
check(tostring(state.cpu_priority) ~= 'default' and tostring(state.cpu_priority) ~= 'nil',
  'work nobody waits for runs one step below the node: ' .. tostring(state.cpu_priority))
check(tostring(state.cpu_priority):find('nice%+%d+') ~= nil or tostring(state.cpu_priority) == 'below_normal',
  'and the record names the priority it runs at: ' .. tostring(state.cpu_priority))
pcall(dispatch, 'operation', { action = 'cancel', id = started.operation_id })

-- ---------------------------------------------------------------- code mode: awaited vs left behind
local scope = 'priority-scope-' .. tostring(math.floor(host.now() * 1000))
local opts = { ctx = ctx, scope = scope, session = sid, dispatch = dispatch }
-- wait_s above 0: the script is waiting on it inside invoke, so it is a foreground call by fact.
local awaited = pending.invoke(dispatch, opts, 'bash', { command = 'echo awaited' }, '{"command":"echo awaited"}', 30)
check(type(awaited) == 'table' and (awaited.code == 0 or awaited.ok == true),
  'the awaited code-mode call finished inside its wait: ' .. json.encode(awaited or {}):sub(1, 200))
check(tostring(awaited.cpu_priority) == 'default',
  'a code-mode call the script is actively awaiting keeps the node own priority: '
    .. tostring(awaited.cpu_priority))

-- wait_s 0, and the script does NOT resume it: it goes pending while the script is still inside it,
-- and the priority is still the node's - the guess at spawn is gone (18/11 round 3, item 5).
local left = pending.invoke(dispatch, opts, 'bash', { command = 'sleep 5', timeout_seconds = 60 },
  '{"command":"sleep 5"}', 0)
check(type(left) == 'table' and left.state == 'pending' and type(left.op) == 'string',
  'a code-mode call started with wait_s 0 answers a handle: ' .. json.encode(left or {}):sub(1, 200))
local during = dispatch('operation', { action = 'status', id = left.op })
check(tostring(during.cpu_priority) == 'default',
  'and while a script can still be waiting on it, it runs at the node own priority: '
    .. tostring(during.cpu_priority))

-- The end of the script: codemode.lua calls M.background(scope, dispatch), which lowers every handle
-- this script stopped waiting for. That is the moment the fact is known, and the only one.
local lowered = pending.background(scope, dispatch, opts)
check(type(lowered) == 'table' and (tonumber(lowered.count) or 0) >= 1,
  'the end of the script lowers the handles it left: ' .. json.encode(lowered or {}):sub(1, 200))
local after = dispatch('operation', { action = 'status', id = left.op })
check(tostring(after.cpu_priority) ~= 'default',
  'the handle nobody waits for now runs one step below the node: ' .. tostring(after.cpu_priority))
check(tostring(after.cpu_priority):find('nice%+%d+') ~= nil or tostring(after.cpu_priority) == 'below_normal',
  'and the record says which: ' .. tostring(after.cpu_priority))

-- The same call, resumed: it is work somebody waits for again. The priority is not raised back (a
-- niceness is not a lease), and the row says the one thing that matters - the handle still works.
local resumed = pending.wait(dispatch, opts, left.op, { wait_s = 0 })
check(type(resumed) == 'table' and resumed.state == 'pending',
  'the lowered handle still answers a wait: ' .. json.encode(resumed or {}):sub(1, 300))
pcall(pending.cancel, dispatch, opts, left.op)

-- ---------------------------------------------------------------- a real script leaves it lowered
-- The wiring, from inside a run: a script that starts a call with wait_s 0 and returns leaves a handle
-- the next step can resume, and the run says so (pending_backgrounded) - and the operation's own record
-- names the priority, so this is read from the node and not from this row's belief.
local script = [==[
const h = await tools.bash({command:"sleep 8", wait_s:0});
return {op: h.op, state: h.state};
]==]
local scripted = run(script)
local scripted_value = type(scripted.value) == 'table' and scripted.value
  or (type(scripted.value) == 'string' and json.decode(scripted.value) or {})
check(scripted.ok == true and type(scripted_value.op) == 'string',
  'a script started a call it did not wait for: ' .. json.encode(scripted or {}):sub(1, 400))
local reported = scripted.pending_backgrounded
check(type(reported) == 'table' and (tonumber(reported.count) or 0) >= 1,
  'and the run says which handles it lowered: ' .. json.encode(reported or {}):sub(1, 300))
local scripted_state = dispatch('operation', { action = 'status', id = tostring(scripted_value.op) })
check(tostring(scripted_state.cpu_priority) ~= 'default',
  'the record of that operation names the lower priority: ' .. tostring(scripted_state.cpu_priority))
-- Cancelled from inside a script, so the handle is closed in the pending index too: a handle left
-- running there is work the NEXT script's sweep would lower, which is correct behaviour and would make
-- the check below about this script's own call untrue.
local cancelling = [==[
await cancel("__OP__");
]==]
run(cancelling:gsub('__OP__', tostring(scripted_value.op)))

-- A call the script DOES wait for and finish inside the same script is never lowered, even with
-- wait_s 0: the row reads it from the operation's own record, which the settle wrote.
local inside = run([==[
const quick = await tools.bash({command:"sleep 0.4", wait_s:0});
// A call that settled inside the start answered its result, not a handle: that is a call the script
// waited for from beginning to end, and the row reads it as such instead of inventing an op.
if (!quick.op) { return {state: "done", inline: true}; }
const done = await wait(quick.op, {wait_s: 30});
return {state: done.state, inline: false, op: quick.op};
]==])
local inside_value = type(inside.value) == 'table' and inside.value
  or (type(inside.value) == 'string' and json.decode(inside.value) or {})
check(inside.ok == true and tostring(inside_value.state) == 'done',
  'a wait_s:0 call resumed at once finishes inside the script: ' .. json.encode(inside or {}):sub(1, 400))
local quick_lowered = false
for _, id in ipairs(type(inside.pending_backgrounded) == 'table' and inside.pending_backgrounded.ops or {}) do
  if tostring(id) == tostring(inside_value.op or '') then quick_lowered = true end
end
check(quick_lowered == false, 'and the call THIS script waited for was never lowered: '
  .. json.encode(inside.pending_backgrounded or {}):sub(1, 300))

print(string.format("ok operation-cpu-priority: %d checks", checks))

