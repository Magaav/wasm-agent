-- A wait on one op that never settles ends the script BY NAME - and the count is of WAITS THAT SPENT
-- THEIR WHOLE BUDGET WITH NO PROGRESS, never of pending answers (18/11 round 2, finding 7; corrected
-- 18/11 round 3, item 2).
--
-- The first cut counted every pending ANSWER for an op. That is a wall clock under another name:
--   * a wait_s:0 poll hits the limit at once (20 polls of a healthy build),
--   * a long build awaited with wait_s:60 died at about 20 minutes,
--   * the until:"any" pool loop added one to the long op every time a SHORT op finished.
-- The rule this row pins instead:
--   * only a wait that spent its whole budget (>= M.full_wait_ms(), 30 s in production) counts, so a
--     poll and a wait cut short by a settled sibling count nothing;
--   * any change in the op's own progress fields (bytes written, a counter, a promotion) RESETS the
--     count, so a long build watched for an hour survives;
--   * a silent op re-waited forever still ends by name codemode_wait_never_settles, says it is not a
--     CPU stop and not a wall clock, keeps its handle (pending() lists it, wait(op) resumes it, cancel
--     stops it).
--
-- HOW THE NUMBERS ARE KEPT FAST, and what that does not measure: the row shrinks the two numbers the
-- code reads - the whole-budget threshold and the count - on its OWN copy of the module, and every wait
-- below goes through that copy's M.wait, which is the code under test. The production numbers are
-- asserted as constants (30 s, 20) instead of being waited out: a row that measured 20 x 30 s of real
-- waiting would cost ten minutes and prove nothing more about the RULE.
--
-- Hermetic: its own scratch home; every op is a local sleep or echo.
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
local function dispatch(name, args, raw) return tools.dispatch(memory, name, args, 'master', ctx, raw) end
local function shown(result)
  return json.encode({ ok = result.ok, code = result.code, error = tostring(result.error):sub(1, 300),
    value = result.value }):sub(1, 700)
end
local BOUND = pending.WAIT_BOUND_CODE or 'codemode_wait_never_settles'

-- ---------------------------------------------------------------- the production rule, as numbers
check((pending.FULL_WAIT_MS or 0) >= 30000,
  'the shortest wait that can count is 30 s, not one poll: ' .. tostring(pending.FULL_WAIT_MS))
check((pending.pending_answer_limit and pending.pending_answer_limit() or 0) == 20,
  'and the count is 20 of those waits: ' .. tostring(pending.pending_answer_limit and pending.pending_answer_limit()))

-- ---------------------------------------------------------------- what counts as progress
local clock_a = pending.progress_fingerprint({ state = 'running', output_bytes = 0, elapsed_ms = 1,
  remaining_ms = 900000, output_idle_ms = 5 })
local clock_b = pending.progress_fingerprint({ state = 'running', output_bytes = 0, elapsed_ms = 900000,
  remaining_ms = 1000, output_idle_ms = 900000 })
check(clock_a == clock_b, 'a pending answer whose CLOCK moved is not progress: '
  .. tostring(clock_a) .. ' vs ' .. tostring(clock_b))
check(pending.progress_fingerprint({ state = 'running', output_bytes = 12 }) ~= clock_a,
  'a byte count that moved IS progress')
check(pending.progress_fingerprint({ state = 'running', output_bytes = 0, promoted = true }) ~= clock_a,
  'and so is a state change, like a promotion')

-- ---------------------------------------------------------------- the fast rule, on this row's copy
-- Small numbers, same code path: a 0.4 s wait that spends all of it, three of them, no progress.
local FAST, LIMIT = 300, 3
pending.full_wait_ms = function() return FAST end
pending.pending_answer_limit = function() return LIMIT end
local scope = 'wait-bound-scope-' .. tostring(math.floor(host.now() * 1000))
local function options()
  return { ctx = ctx, scope = scope, session = sid, dispatch = dispatch }
end

-- a) a POLL never counts, however many times it is repeated.
-- One opts table per scenario, because that is where the count lives: lua/core/codemode.lua keeps ONE
-- opts ({ctx, scope, session, dispatch}) for a whole script, and the bound is per script. A fresh table
-- per wait would be a fresh bound, which is a different thing than the one being measured.
local A = options()
local silent = pending.invoke(dispatch, A, 'bash', { command = 'sleep 120' },
  '{"command":"sleep 120"}', 0)
check(type(silent) == 'table' and type(silent.op) == 'string' and silent.state == 'pending',
  'a backgrounded call answered a live handle: ' .. json.encode(silent):sub(1, 200))
local polled, poll_error = 0, nil
for _ = 1, 60 do
  local ok, problem = pcall(pending.wait, dispatch, A, silent.op, { wait_s = 0 })
  if not ok then poll_error = tostring(problem) break end
  polled = polled + 1
end
check(poll_error == nil and polled == 60,
  'sixty polls of one op do not end anything: ' .. tostring(poll_error) .. ' after ' .. polled)

-- b) a SILENT op, waited on for its whole budget again and again, hits the bound and says what it is
local bound_error
for _ = 1, 60 do
  local ok, problem = pcall(pending.wait, dispatch, A, silent.op, { wait_s = 0.4 })
  if not ok then bound_error = tostring(problem) break end
end
check(bound_error ~= nil, 'a silent op re-waited for its whole budget ends the script: ' .. tostring(bound_error))
check(bound_error:find(BOUND, 1, true) ~= nil, 'by name: ' .. tostring(bound_error):sub(1, 300))
check(bound_error:find('without progress', 1, true) ~= nil,
  'and says what the count is about - WITHOUT PROGRESS: ' .. tostring(bound_error):sub(1, 400))
check(bound_error:find('not a CPU stop', 1, true) ~= nil and bound_error:find('not a wall-clock', 1, true) ~= nil,
  'and that it is neither a CPU stop nor a wall clock: ' .. tostring(bound_error):sub(1, 400))
check(bound_error:find(silent.op, 1, true) ~= nil, 'it names the op: ' .. silent.op)
check(bound_error:find('cancel(' .. silent.op .. ')', 1, true) ~= nil,
  'and the one way to stop it: ' .. tostring(bound_error):sub(1, 400))
-- The handle is not lost: the NEXT script resumes it, which is a fresh opts table (the count is per
-- script, and codemode.lua keeps one opts for one script).
local resumed_ok, alive = pcall(pending.wait, dispatch, options(), silent.op, { wait_s = 0 })
check(resumed_ok and type(alive) == 'table' and alive.state == 'pending',
  'and the handle is untouched and still resumable: ' .. tostring(alive):sub(1, 300))

-- c) a long op with STEADY PROGRESS, waited on for its whole budget forty times, survives
local C = options()
local ticking = pending.invoke(dispatch, C, 'bash',
  { command = 'i=0; while [ $i -lt 400 ]; do echo tick; i=$((i+1)); sleep 0.05; done', timeout_seconds = 120 },
  '{"command":"ticking"}', 0)
check(type(ticking) == 'table' and type(ticking.op) == 'string',
  'the progress op answered a handle: ' .. json.encode(ticking):sub(1, 200))
local survived, progress_error, advanced = 0, nil, false
for _ = 1, 40 do
  local ok, entry = pcall(pending.wait, dispatch, C, ticking.op, { wait_s = 0.4 })
  if not ok then progress_error = tostring(entry) break end
  survived = survived + 1
  if type(entry) == 'table' and type(entry.progress) == 'table' and (tonumber(entry.progress.output_bytes) or 0) > 0 then
    advanced = true
  end
end
check(progress_error == nil and survived == 40,
  'a long op with steady progress awaited 40 times survives: ' .. tostring(progress_error) .. ' after ' .. survived)
check(advanced, 'and the row saw the progress it survived by')

-- d) the POOL: 25 short ops finish beside one long op, which nobody is therefore waiting on for long
local D = options()
local long = pending.invoke(dispatch, D, 'bash', { command = 'sleep 60', timeout_seconds = 120 },
  '{"command":"sleep 60"}', 0)
check(type(long) == 'table' and type(long.op) == 'string', 'the long op answered a handle')
local finished, pool_error = 0, nil
for _ = 1, 25 do
  -- A short call that is short but NOT instantaneous: invoke answers a handle for it (a wait_s:0 call
  -- that settled inside the spawn would answer its result, and then there is no pool to build).
  local short = pending.invoke(dispatch, D, 'bash', { command = 'sleep 0.15', timeout_seconds = 60 }, '{"command":"sleep 0.15"}', 0)
  local list = { long.op }
  if type(short) == 'table' and type(short.op) == 'string' then table.insert(list, 1, short.op) end
  local ok, entries = pcall(pending.wait, dispatch, D, list, { ["until"] = 'any', wait_s = 0.4 })
  if not ok then pool_error = tostring(entries) break end
  for _, entry in ipairs(type(entries) == 'table' and entries or {}) do
    if entry.op ~= long.op and entry.state ~= 'pending' then finished = finished + 1 end
  end
end
check(pool_error == nil, 'the pool loop with 25 short ops finishing does not kill the long one: '
  .. tostring(pool_error))
check(finished >= 20, 'and the short ones really did finish beside it: ' .. tostring(finished))
local still = pending.wait(dispatch, D, long.op, { wait_s = 0 })
check(type(still) == 'table' and still.state == 'pending',
  'the long op is still pending after the pool: ' .. json.encode(still):sub(1, 300))

-- ---------------------------------------------------------------- a real script, at real numbers
-- The same two directions inside the sandbox, where the numbers are production's and the waits are
-- polls: sixty polls and a 25-op pool neither end the script nor lose the handle. (What a sandbox
-- cannot afford is 20 x 30 s of deliberate silence, which is why the count itself is proved above.)
local polls_script = [==[
const h = await tools.bash({command:"sleep 40", wait_s:0});
let n = 0;
for (let i = 0; i < 60; i++) { await wait(h.op, {wait_s: 0}); n++; }
const again = await wait(h.op, {wait_s: 0});
await cancel(h.op);
return {answers: n, state: again.state, op: h.op};
]==]
local polls = run(polls_script)
local polls_value = type(polls.value) == 'table' and polls.value
  or (type(polls.value) == 'string' and json.decode(polls.value) or {})
check(polls.ok == true and tonumber(polls_value.answers) == 60,
  'a script may poll one op sixty times and keep running: ' .. shown(polls))
check(tostring(polls_value.state) == 'pending', 'and the handle is still pending afterwards: ' .. shown(polls))
local polls_op = tostring(polls_value.op or '')

local pool_script = [==[
const long = await tools.bash({command:"sleep 60", wait_s:0});
let finished = 0;
for (let i = 0; i < 25; i++) {
  const s = await tools.bash({command:"sleep 0.2", wait_s:0});
  const entries = await wait([s.op, long.op], {until:"any", wait_s: 2});
  for (const e of entries) { if (e.op !== long.op && e.state !== "pending") finished++; }
}
const alive = await wait(long.op, {wait_s: 0});
await cancel(long.op);
return {finished: finished, state: alive.state, op: long.op};
]==]
local pool = run(pool_script)
local pool_value = type(pool.value) == 'table' and pool.value
  or (type(pool.value) == 'string' and json.decode(pool.value) or {})
check(pool.ok == true, 'a script may pool 25 short calls beside a long one: ' .. shown(pool))
check(tonumber(pool_value.finished) == 25, 'and see all 25 finish: ' .. shown(pool))
check(tostring(pool_value.state) == 'pending', 'while the long one is still pending: ' .. shown(pool))

-- Six scripts in a row (six > the sandbox four slots): none of them held its slot, which is only
-- possible if a script that has finished never keeps the sandbox.
local same = 0
for _ = 1, 6 do
  local again = run([==[
const h = await tools.bash({command:"sleep 30", wait_s:0});
await wait(h.op, {wait_s: 0});
await cancel(h.op);
return {op: h.op};
]==])
  if again.ok == true then same = same + 1 end
end
check(same == 6, 'six scripts in a row each got their own sandbox and gave it back: ' .. tostring(same))

-- ---------------------------------------------------------------- the handles are not lost
-- A script that leaves a handle behind: pending() finds it in the next script and cancel(op) stops it.
local left = run([==[
const h = await tools.bash({command:"sleep 30", wait_s:0});
return {op: h.op};
]==])
local left_value = type(left.value) == 'table' and left.value
  or (type(left.value) == 'string' and json.decode(left.value) or {})
local listed = run([==[
const all = await pending();
return {count: all.count, ops: all.ops.map(o => o.op)};
]==])
local listed_value = type(listed.value) == 'table' and listed.value
  or (type(listed.value) == 'string' and json.decode(listed.value) or {})
local found = false
for _, id in ipairs(type(listed_value.ops) == 'table' and listed_value.ops or {}) do
  if tostring(id) == tostring(left_value.op or '') then found = true end
end
check(listed.ok == true and found, 'the handle a finished script was waiting on is still there: ' .. shown(listed))
local cancel_script = [==[
const stopped = await cancel("__OP__");
return {cancelled: stopped.cancelled, state: stopped.state};
]==]
local cancelled = run((cancel_script:gsub('__OP__', tostring(left_value.op or ''))))
local cancelled_value = type(cancelled.value) == 'table' and cancelled.value
  or (type(cancelled.value) == 'string' and json.decode(cancelled.value) or {})
check(cancelled.ok == true and cancelled_value.cancelled == true,
  'and cancel(op) still stops it: ' .. shown(cancelled))

for _, op in ipairs({ silent.op, ticking.op, long.op, tostring(pool_value.op or '') }) do
  if type(op) == 'string' and op ~= '' then pcall(pending.cancel, dispatch, A, op) end
end

print(string.format("ok codemode-wait-bound: %d checks", checks))

