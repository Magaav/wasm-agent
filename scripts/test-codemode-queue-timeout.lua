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
-- The six workloads must be OBSERVABLY holding their slots before the ninth call can queue. `start`
-- answers its receipt BEFORE the supervisor takes a slot: Slot::acquire runs in the spawned thread,
-- after admission is recorded (rust/wa-operation/src/lib.rs, `one admission path`). So a returned
-- receipt is not a taken slot, and the six starts above can still be seconds from running. Measured
-- 19/11 on the merged tree: with the slots unwitnessed this row was `accepted` (running) instead of
-- queued and failed inside the loaded fast run, while passing alone and 8-way in parallel.
local function slots_held()
  local held = 0
  for _, id in ipairs(running) do
    local state = dispatch('operation', { action = 'status', id = id })
    if type(state) == 'table' and tostring(state.state) == 'running' then held = held + 1 end
  end
  return held
end
local waited_ms = 0
while slots_held() < #running and waited_ms < 20000 do
  if host.sleep then host.sleep(50) end
  waited_ms = waited_ms + 50
end
check(slots_held() == #running, 'the six workloads hold their slots before the ninth asks for one ('
  .. slots_held() .. ' of ' .. #running .. ' running after ' .. waited_ms .. ' ms)')
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
-- The same receipt-before-slot ordering holds for the ninth call: its handle is answered from the first
-- snapshot, and the supervisor announces `queued` only when it reaches Slot::acquire - after writing the
-- admission record (an fsync). On a loaded disk that snapshot is still `accepted` (measured: a 30 ms
-- fsync turns this row red in 12 runs of 12, with the op then timing out IN THE QUEUE). So the handle must not
-- say running, and the op is watched until its supervisor has decided: it is queued (or already settled
-- as a queue timeout), never running.
local first = tostring(handle.progress and handle.progress.state)
check(first == 'queued' or first == 'accepted',
  'and the handle says it is queued, not running: ' .. json.encode(handle.progress or {}):sub(1, 200))
local decided, decided_ms = first, 0
while decided == 'accepted' and decided_ms < 5000 do
  if host.sleep then host.sleep(20) end
  decided_ms = decided_ms + 20
  local now = dispatch_b('operation', { action = 'status', id = op })
  decided = type(now) == 'table' and (now.queue_state == 'timed_out' and 'queued' or tostring(now.state)) or 'unknown'
end
check(decided == 'queued', 'its supervisor queues it behind the six: ' .. decided .. ' after ' .. decided_ms .. ' ms')

local entry = pending.wait(dispatch_b, opts, op, { wait_s = 10 })
check(type(entry) == 'table' and entry.state == 'failed',
  'the handle SETTLES instead of vanishing: ' .. json.encode(entry or {}):sub(1, 300))
check(tostring(entry.reason) == 'operation_queue_timeout',
  'with the supervisor own name as the reason: ' .. tostring(entry.reason))
check(type(entry) == 'table' and type(entry.result) == 'nil',
  'the wait answers the flat shape: the result is not nested under a result key: ' .. json.encode(entry or {}):sub(1, 300))
local result = entry
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
