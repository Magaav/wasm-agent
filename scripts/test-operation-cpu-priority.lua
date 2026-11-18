-- Low CPU priority only for backgrounded work (18/11 round 2, finding 9).
--
-- Round 1 gave EVERY operation a niceness below the node own. That is right for work nobody waits for
-- and wrong for a call the caller is actively waiting on: a foreground build then ran one step below
-- everything else on the node, for no reason. The rule now:
--
--   * a foreground shell (the bash tool, host.exec) runs at the node own priority;
--   * an explicit operation start - the caller gets a receipt and moves on - stays backgrounded and
--     runs at the node niceness (WASM_AGENT_OPERATION_NICE, default +10);
--   * a code-mode call the script is actively awaiting (any wait_s above 0) keeps the node priority;
--   * a code-mode call started with wait_s 0 is backgrounded, so it runs low.
--
-- Every operation records the priority it ran at, so the row reads the fact from the record instead of
-- guessing from timing.
--
-- Hermetic: its own scratch home; the commands are local echoes and short sleeps.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local pending = dofile('lua/core/codemode_pending.lua')
local sid = memory.start_session('', 'operation cpu priority', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function dispatch(name, args, raw) return tools.dispatch(memory, name, args, 'master', ctx, raw) end

-- ---------------------------------------------------------------- a foreground shell keeps it
local foreground = dispatch('bash', { command = 'echo foreground' })
check(type(foreground) == 'table' and foreground.ok == true, 'the foreground shell ran: '
  .. json.encode(foreground or {}):sub(1, 200))
check(tostring(foreground.cpu_priority) == 'default',
  'a call the run waits for keeps the node own priority: ' .. tostring(foreground.cpu_priority))

-- ---------------------------------------------------------------- an explicit start is backgrounded
local started = dispatch('operation', { action = 'start', command = 'sleep 3', timeout_seconds = 60 })
check(type(started.operation_id) == 'string', 'the operation started: ' .. json.encode(started):sub(1, 200))
local state = dispatch('operation', { action = 'status', id = started.operation_id })
check(tostring(state.cpu_priority) ~= 'default' and tostring(state.cpu_priority) ~= 'nil',
  'work nobody waits for runs one step below the node: ' .. tostring(state.cpu_priority))
check(tostring(state.cpu_priority):find('nice%+%d+') ~= nil or tostring(state.cpu_priority) == 'below_normal',
  'and the record names the priority it runs at: ' .. tostring(state.cpu_priority))
pcall(dispatch, 'operation', { action = 'cancel', id = started.operation_id })

-- ---------------------------------------------------------------- code mode: awaited vs backgrounded
local scope = 'priority-scope'
local opts = { ctx = ctx, scope = scope, session = sid, dispatch = dispatch }
-- wait_s above 0: the script is waiting on it inside invoke, so it is a foreground call by fact.
local awaited = pending.invoke(dispatch, opts, 'bash', { command = 'echo awaited' }, '{"command":"echo awaited"}', 30)
check(type(awaited) == 'table' and (awaited.code == 0 or awaited.ok == true),
  'the awaited code-mode call finished inside its wait: ' .. json.encode(awaited or {}):sub(1, 200))
check(tostring(awaited.cpu_priority) == 'default',
  'a code-mode call the script is actively awaiting keeps the node own priority: '
    .. tostring(awaited.cpu_priority))

-- wait_s 0: nobody waits, the script gets a handle and moves on - that one is backgrounded.
local backgrounded = pending.invoke(dispatch, opts, 'bash', { command = 'sleep 2' }, '{"command":"sleep 2"}', 0)
check(type(backgrounded) == 'table' and backgrounded.state == 'pending' and type(backgrounded.op) == 'string',
  'a code-mode call started with wait_s 0 answers a handle: ' .. json.encode(backgrounded or {}):sub(1, 200))
local background_state = dispatch('operation', { action = 'status', id = backgrounded.op })
check(tostring(background_state.cpu_priority) ~= 'default',
  'and that one IS backgrounded, so it runs one step below: ' .. tostring(background_state.cpu_priority))
pcall(dispatch, 'operation', { action = 'cancel', id = backgrounded.op })

print(string.format("ok operation-cpu-priority: %d checks", checks))
