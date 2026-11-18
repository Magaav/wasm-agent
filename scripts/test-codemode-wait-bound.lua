-- A wait on one op that never settles ends the script BY NAME, and gives its sandbox slot back
-- (18/11 round 2, finding 7).
--
-- The rule from round 1 stands and is checked here too: there is no wall-clock cap on a script that is
-- waiting, and the CPU guard is the only hard stop for COMPUTING. What this row pins is the other side
-- of it - a script that re-waits forever on a handle that will not change held one of the sandbox's
-- four session slots for as long as the op lived, with no bound at all:
--
--   * after the limit of pending answers for ONE op, the script ends with the named reason
--     codemode_wait_never_settles, and the sentence says it is not a CPU stop and not a wall clock;
--   * the sandbox is released: six scripts in a row (six > four slots) each get the same named ending,
--     which cannot happen if even one slot leaked;
--   * the handle is not lost: pending() still lists it and cancel(op) still stops it.
--
-- Hermetic: its own scratch home; the op is a local sleep.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local pending = dofile('lua/core/codemode_pending.lua')
local sid = memory.start_session('', 'wait on one op that never settles', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function run(code)
  return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx)
end
local function shown(result)
  return json.encode({ ok = result.ok, code = result.code, error = tostring(result.error):sub(1, 300),
    value = result.value }):sub(1, 700)
end
-- Base-tolerant: a tree without the bound has neither the accessor nor the name, and the row then
-- fails on the behaviour (a script that loops forever) rather than on a missing function.
local BOUND = pending.WAIT_BOUND_CODE or 'codemode_wait_never_settles'
local LIMIT = (pending.pending_answer_limit and pending.pending_answer_limit()) or 0

-- ---------------------------------------------------------------- a live handle, and its id
local started = run([==[
const h = await tools.bash({command:"sleep 120", wait_s:0});
return {op: h.op, state: h.state};
]==])
local started_value = type(started.value) == 'table' and started.value
  or (type(started.value) == 'string' and json.decode(started.value) or {})
local op = tostring(started_value.op or '')
check(started.ok == true and op:sub(1, 3) == 'op-', 'a backgrounded call answered a live handle: '
  ..shown(started))

-- ---------------------------------------------------------------- the bound, and what it says
local loop = [==[
const op = "__OP__";
let n = 0;
for (let i = 0; i < 60; i++) { await wait(op, {wait_s: 0}); n++; }
return {answers: n};
]==]
local looped = run((loop:gsub('__OP__', op)))
check(looped.ok == false, 'a script that only re-waits on one op does not run forever: ' .. shown(looped))
check(tostring(looped.code) == BOUND, 'it ends with the named reason: '
  ..tostring(looped.code) .. ' (' .. shown(looped) .. ')')
local said = tostring(looped.error) .. ' ' .. tostring(looped.message)
check(said:find(BOUND, 1, true) ~= nil, 'the failure carries the name: ' .. said:sub(1, 300))
check(said:find('not a CPU stop', 1, true) ~= nil,
  'and says it is not a CPU kill: ' .. said:sub(1, 300))
check(said:find('not a wall-clock limit', 1, true) ~= nil,
  'and not a wall clock on waiting either: ' .. said:sub(1, 300))
check(said:find('ONE op', 1, true) ~= nil, 'it names the bound as one op never settling: ' .. said:sub(1, 300))
check(said:find(op, 1, true) ~= nil, 'it names the op: ' .. op)
check(tostring(looped.fix):find('pending()', 1, true) ~= nil,
  'the fix says the handle is kept and lists it: ' .. tostring(looped.fix):sub(1, 300))
check((tonumber(LIMIT) or 0) >= 2 and (tonumber(LIMIT) or 0) <= 60,
  'the bound is a count of pending answers, not zero and not a wall clock: ' .. tostring(LIMIT))

-- ---------------------------------------------------------------- the sandbox slot comes back
-- Four sessions fit at once. Six runs in a row each end the same way: a leaked slot would make the
-- fifth answer "sandbox session capacity" instead of the bound.
local same = 0
for _ = 1, 6 do
  local again = run((loop:gsub('__OP__', op)))
  if again.ok == false and tostring(again.code) == BOUND then same = same + 1 end
end
check(same == 6, 'six scripts in a row (six > the four session slots) each end with the bound, '
  .. 'so no sandbox slot is held by the one that ended: ' .. tostring(same))

-- ---------------------------------------------------------------- the handle survives the script
local listed = run([==[
const all = await pending();
return {count: all.count, ops: all.ops.map(o => o.op)};
]==])
local listed_value = type(listed.value) == 'table' and listed.value
  or (type(listed.value) == 'string' and json.decode(listed.value) or {})
local found = false
for _, id in ipairs(type(listed_value.ops) == 'table' and listed_value.ops or {}) do
  if tostring(id) == op then found = true end
end
check(listed.ok == true and found, 'the handle the ended script was waiting on is still there: '
  .. shown(listed))
local cancel_script = [==[
const stopped = await cancel("__OP__");
return {cancelled: stopped.cancelled, state: stopped.state};
]==]
local cancelled = run((cancel_script:gsub('__OP__', op)))
local cancelled_value = type(cancelled.value) == 'table' and cancelled.value
  or (type(cancelled.value) == 'string' and json.decode(cancelled.value) or {})
check(cancelled.ok == true and cancelled_value.cancelled == true,
  'and cancel(op) still stops it: ' .. shown(cancelled))

print(string.format("ok codemode-wait-bound: %d checks", checks))
