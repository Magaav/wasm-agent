-- A STATUS OF A RUNNING OPERATION WAITS FOR IT (28/11, waiting-costs-no-turns).
--
-- MEASURED before this row: `operation action="status" wait_ms=5000` on a running operation answered in 30 ms and
-- ignored the budget, while `action="wait"` on the same operation blocked 2.75 s until it settled. A session that
-- wanted to know how a long job was doing therefore had to spend one WHOLE MODEL TURN per look - the turn-level cost
-- the mission is named after (ledger, 2 days: 59 of 6,917 rounds were spent asking again; 0.92% of tokens).
--
-- The rule this row pins:
--   * a status of an operation that is STILL RUNNING blocks, up to wait_ms when given, else
--     WA_OPERATION_STATUS_WAIT_MS (default 5000 ms), clamped to the tool's 10 s ceiling;
--   * it answers with the SETTLED record when the operation settles inside that budget, so one turn replaces N polls;
--   * wait_ms=0 restores the plain snapshot on demand, and a status of an already-settled operation never waits.
--
-- Hermetic: its own db, local sleeps only.
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'status waits for a running operation', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)

local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function dispatch(name, args) return tools.dispatch(memory, name, args, 'master', ctx) end
-- THE BUDGET HAS ONE OWNER (law 17, and the operator's rule): lua/core/codemode_pending.lua's DEFAULT_WAIT_S with its
-- MAX_WAIT_S ceiling. This row refuses a second budget in tools.lua and refuses an environment override in product code.
local pending = dofile('lua/core/codemode_pending.lua')
check(pending.clamp_wait_s(nil) == pending.DEFAULT_WAIT_S,
  'a caller that asks for no wait does not get the owner default: ' .. tostring(pending.clamp_wait_s(nil)))
check(pending.clamp_wait_s(1e9) == pending.MAX_WAIT_S,
  'the owner ceiling does not bind: ' .. tostring(pending.clamp_wait_s(1e9)))
check(pending.clamp_wait_s(0) == 0, 'a zero wait is not honoured as zero')
local tools_src = ''
do
  local f = io.open('lua/core/tools.lua', 'r')
  if f then tools_src = f:read('*a') or ''; f:close() end
end
check(tools_src ~= '', 'could not read lua/core/tools.lua to check for a second budget')
check(not tools_src:find('WA_OPERATION_STATUS_WAIT_MS', 1, true),
  'tools.lua reads a wait budget from the environment - product code has no env override')
check(tools_src:find('pending.wait_for_settle', 1, true) ~= nil,
  'tools.lua does not spend the owner budget through pending.wait_for_settle')

local function now_ms() return host.monotonic_ms and host.monotonic_ms() or (os.time() * 1000) end

-- 1) A RUNNING OPERATION IS WAITED FOR: 2 s of sleep, a status with no wait_ms, and the answer is the settled record.
local started = dispatch('operation', { action = 'start', command = 'sleep 2; echo done' })
check(type(started) == 'table' and started.operation_id ~= nil, 'operation start returned no id: ' .. tostring(started and started.error))
local began = now_ms()
local answer = dispatch('operation', { action = 'status', id = started.operation_id })
local waited = now_ms() - began
check(waited >= 1200, 'a status of a RUNNING operation returned in ' .. math.floor(waited) .. ' ms - it did not wait, so a poll still costs a whole turn')
check(type(answer) == 'table' and answer.state ~= 'running', 'the status did not return the settled record: ' .. tostring(type(answer) == 'table' and answer.state))

-- 2) wait_ms=0 IS THE PLAIN SNAPSHOT: a caller that wants a look, not a wait, still gets one.
local long = dispatch('operation', { action = 'start', command = 'sleep 30' })
check(type(long) == 'table' and long.operation_id ~= nil, 'second operation start failed')
local snapshot_began = now_ms()
local snapshot = dispatch('operation', { action = 'status', id = long.operation_id, wait_ms = 0 })
local snapshot_ms = now_ms() - snapshot_began
check(snapshot_ms < 600, 'wait_ms=0 did not return a plain snapshot: ' .. math.floor(snapshot_ms) .. ' ms')
-- A FRESH operation is legitimately `accepted` (spawned, not yet running) before it is `running`: the row asserts
-- UNSETTLED, which is the fact it needs, instead of naming one of the two words the node may use.
local unsettled = type(snapshot) == 'table' and (snapshot.state == 'running' or snapshot.state == 'accepted')
check(unsettled, 'the snapshot lost the unsettled state: ' .. tostring(type(snapshot) == 'table' and snapshot.state))

-- 3) A SETTLED OPERATION NEVER WAITS: the status of a finished operation is immediate.
local settled_began = now_ms()
dispatch('operation', { action = 'status', id = started.operation_id })
local settled_ms = now_ms() - settled_began
check(settled_ms < 600, 'a status of an already settled operation waited ' .. math.floor(settled_ms) .. ' ms')

dispatch('operation', { action = 'cancel', id = long.operation_id })
print(string.format('operation status waits ok (%d checks; a running operation is waited for, wait_ms=0 is a snapshot, a settled one is immediate)', checks))
