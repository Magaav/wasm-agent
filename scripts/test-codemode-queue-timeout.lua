-- A queued pending call that hits operation_queue_timeout settles with a named result the script sees
-- (18/11 round 2, finding 6).
--
-- Round 1 made the node QUEUE past its 8 running operations instead of refusing them, and the queue
-- wait is bounded by the operation's own deadline. What this row pins is what happens at that bound: the
-- call does not vanish, and it does not become an anonymous failure -
--
--   * the handle settles as failed with reason operation_queue_timeout, the name the supervisor used;
--   * the record says the QUEUE is what ran out (queue_state "timed_out", queue_waited_ms), which is
--     the difference between "the command failed" and "it never started";
--   * the settled result is retained, so a second read of the handle answers the same thing.
--
-- Hermetic: its own scratch home; the commands are local sleeps.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local pending = dofile('lua/core/codemode_pending.lua')
local sid = memory.start_session('', 'queued op times out', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function dispatch(name, args, raw) return tools.dispatch(memory, name, args, 'master', ctx, raw) end

-- ---------------------------------------------------------------- fill the node's workload slots
--
-- The node'S cap is a QUEUE (harness-next-a), and one session may hold only its share of it (session
-- isolation, finding 7: 6 of 8, with two kept for control calls). So the node is filled the way it can
-- be filled: six workloads from this session, and the pending call that must queue comes from a SECOND
-- session - which is exactly the shape this row is about, a caller whose work waits behind somebody
-- else's.
local running = {}
for index = 1, 6 do
  local started = dispatch('operation', { action = 'start', command = 'sleep 20', timeout_seconds = 60 })
  check(type(started.operation_id) == 'string', 'slot ' .. index .. ' was taken: ' .. json.encode(started):sub(1, 160))
  running[#running + 1] = started.operation_id
end
local sid_b = memory.start_session('', 'queued op times out two', { user_id = 'master', id = 'iso-queue-timeout-b' })
local ctx_b = { session_id = sid_b, user_id = 'master' }
local function dispatch_b(name, args, raw) return tools.dispatch(memory, name, args, 'master', ctx_b, raw) end

-- ---------------------------------------------------------------- the ninth call queues, then times out
local scope = 'queue-timeout-scope'
local opts = { ctx = ctx_b, scope = scope, session = sid_b, dispatch = dispatch_b }
-- wait_s 0: the script is handed a handle at once, which is the shape that can lose work.
local handle = pending.invoke(dispatch_b, opts, 'bash', { command = 'echo ninth', timeout_seconds = 1 }, '{}', 0)
check(type(handle) == 'table' and handle.state == 'pending' and type(handle.op) == 'string',
  'a call past the cap answers a handle: ' .. json.encode(handle or {}):sub(1, 240))
local op = handle.op
check(tostring(handle.progress and handle.progress.state) == 'queued',
  'and the handle says it is queued, not running: ' .. json.encode(handle.progress or {}):sub(1, 200))

local entry = pending.wait(dispatch_b, opts, op, { wait_s = 10 })
check(type(entry) == 'table' and entry.state == 'failed',
  'the handle SETTLES instead of vanishing: ' .. json.encode(entry or {}):sub(1, 300))
check(tostring(entry.reason) == 'operation_queue_timeout',
  'with the supervisor own name as the reason: ' .. tostring(entry.reason))
local result = type(entry.result) == 'table' and entry.result or {}
check(tostring(result.error) == 'operation_queue_timeout',
  'and the result carries the same name: ' .. json.encode(result):sub(1, 300))
check(tostring(result.queue_state) == 'timed_out',
  'the record says the QUEUE is what ran out, not the command: ' .. json.encode(result):sub(1, 300))
check(tonumber(result.queue_waited_ms or 0) > 0,
  'with how long it waited for a slot: ' .. tostring(result.queue_waited_ms))
check(result.ok == false and result.settled == true, 'it is a settled failure, not an unknown outcome: '
  .. json.encode({ ok = result.ok, settled = result.settled }):sub(1, 200))

-- The result is retained: reading the handle again answers the same named failure, never "unknown_op".
local retained, why = pending.retained(op, scope)
check(retained ~= nil, 'the settled result is retained for a later read: ' .. tostring(why))
check(type(retained) == 'table' and tostring(retained.error) == 'operation_queue_timeout'
  and tostring(retained.queue_state) == 'timed_out',
  'and a second read answers the same named facts: ' .. json.encode(retained or {}):sub(1, 300))

-- ---------------------------------------------------------------- it is not still "running"
local listed = pending.list(dispatch_b, opts)
local still_running = false
for _, row in ipairs(type(listed.ops) == 'table' and listed.ops or {}) do
  if tostring(row.op) == op and tostring(row.state) == 'running' then still_running = true end
end
check(not still_running, 'and pending() does not report it as running work: ' .. json.encode(listed):sub(1, 300))

for _, id in ipairs(running) do pcall(dispatch, 'operation', { action = 'cancel', id = id }) end
print(string.format("ok codemode-queue-timeout: %d checks", checks))
