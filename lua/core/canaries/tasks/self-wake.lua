-- CANARY TASK: the self-wake path, end to end, in this child's own ledger.
--
-- What a user does with a self-wake: a turn asks to be woken, the node lists it, the scheduler claims it
-- when it is due, and the wake is settled with the outcome. Each of those is a real call into
-- lua/core/selfloop.lua - the same functions the CLI, the node tick and a served run use. Nothing of the
-- operator's is touched: this process has its own home and its own memory.db (feature_canary.M.child).
local json = dofile('lua/vendor/json.lua')
local h = dofile('lua/core/canaries/tasks/harness.lua')

h.stage('ledger')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local selfloop = dofile('lua/core/selfloop.lua')
selfloop.setup()

h.stage('session')
local session = memory.start_session('local', 'chat', { id = 'canary-self-wake', user_id = 'master', title = 'canary' })
h.check(type(session) == 'string' and session ~= '', 'session', 'no session was created: ' .. tostring(session))
local ctx = { user_id = 'master', role = 'master', session_id = session }

h.stage('schedule')
local made = selfloop.schedule({ in_seconds = 0, reason = 'canary: prove the self-wake path', prompt = 'canary' }, ctx)
h.check(type(made) == 'table' and made.ok and type(made.wake) == 'table', 'schedule',
  'schedule answered ' .. tostring(json.encode(made)))
local id = made.wake.id

h.stage('list')
local listed = selfloop.list({}, ctx)
h.check(type(listed) == 'table' and type(listed.wakes) == 'table', 'list',
  'list answered ' .. tostring(json.encode(listed)))
local seen = false
for _, wake in ipairs(listed.wakes) do if wake.id == id then seen = true end end
h.check(seen, 'list', 'the wake just scheduled is not in the list')

h.stage('claim')
local claimed = selfloop.claim_due(session, 'master')
h.check(type(claimed) == 'table' and claimed.id == id, 'claim',
  'claim_due answered ' .. tostring(json.encode(claimed)))

h.stage('finish')
local settled = selfloop.finish(claimed, true, 'canary: delivered')
h.check(type(settled) == 'table' and settled.status == 'delivered', 'finish',
  'finish answered ' .. tostring(json.encode(settled)))

h.stage('readback')
local after = selfloop.list({ all = true }, ctx)
local status
for _, wake in ipairs(after.wakes or {}) do if wake.id == id then status = wake.status end end
h.check(status == 'delivered', 'readback', 'the wake reads back as ' .. tostring(status))

-- A WAKE IS DELIVERED BY THE NODE'S OWN TICK (Fable 24/11). The stages above are the claim-then-finish path a
-- CLI and a one-shot turn take; a SERVED node dispatches through `selfloop.tick`, and on 24/11 that half was
-- dead for two hours on the live node while every stage above would have stayed green. A canary that never
-- calls the tick cannot answer "does a self-wake fire on this node after this install".
--
-- This child has no serve loop and no run scheduler, so the tick is handed the counted scheduler the tick's own
-- rows take (`opts.dispatch`) - the stub is the capability this process does not have - and what is proven is
-- the half that failed: that a due wake REACHES the node's scheduler, within one tick, on a session not held.
h.stage('tick')
local dispatch = { count = 0, ids = {} }
local function counted(row)
  dispatch.count = dispatch.count + 1
  dispatch.ids[#dispatch.ids + 1] = tostring(row.id)
  return { accepted = true, run_id = dispatch.count }
end
local due_now = selfloop.schedule({ in_seconds = 0, reason = 'canary: the node tick dispatches this', prompt = 'canary' }, ctx)
h.check(type(due_now) == 'table' and due_now.ok and type(due_now.wake) == 'table', 'tick',
  'the wake the tick must dispatch could not be scheduled: ' .. tostring(json.encode(due_now)))
local ticked = selfloop.tick({ dispatch = counted })
h.check(type(ticked) == 'table' and ticked.dispatched == 1 and dispatch.ids[1] == due_now.wake.id, 'tick',
  'one tick dispatched ' .. tostring(type(ticked) == 'table' and ticked.dispatched) .. ' wake(s) '
  .. tostring(json.encode(dispatch.ids)) .. ' and the wake due now was ' .. tostring(due_now.wake.id)
  .. ': ' .. tostring(json.encode(ticked)))

-- AND A ROW THE TICK CANNOT DISPATCH NEVER TAKES THE SLOT OF ONE IT CAN (Fable 24/11 12:55Z). Measured on the
-- live node: a parked session's 13 overdue rows filled every page of the plan (8, DUE_LIMIT) and no other wake
-- on the node was dispatched for two hours, while a canary wake of a free session stayed pending an hour past
-- its time. So: one more overdue row than the plan takes, in a PARKED session, all of them EARLIER than one free
-- due wake - and the free wake must be the thing the tick dispatches.
--
-- The free wake has to be later than the held ones and the clock here is the real one, so the stage waits for the
-- second to turn: a clock that does not move is a named failure, never a quiet pass.
h.stage('no-starve')
local DUE_LIMIT = 8
local function next_second()
  -- `host.sleep` is the node's own pause (rust/wa-capabilities/src/host.rs, host.sleep, milliseconds). A
  -- spin over os.time() never turns the second by itself, and a canary that reported success without the
  -- clock moving would be the very thing this stage exists to refuse.
  local start = os.time()
  for _ = 1, 20 do
    if os.time() > start then return true end
    if type(host.sleep) == 'function' then pcall(host.sleep, 120) end
  end
  return false
end
local parked_session = memory.start_session('local', 'chat',
  { id = 'canary-self-wake-parked', user_id = 'master', title = 'canary' })
local parked_ctx = { user_id = 'master', role = 'master', session_id = parked_session }
local parked_ids = {}
for i = 1, DUE_LIMIT + 1 do
  local made_i = selfloop.schedule({ in_seconds = 0, reason = 'canary: held ' .. i, prompt = 'canary' }, parked_ctx)
  h.check(type(made_i) == 'table' and made_i.ok and type(made_i.wake) == 'table', 'no-starve',
    'the parked session could not be given its overdue rows: ' .. tostring(json.encode(made_i)))
  parked_ids[#parked_ids + 1] = made_i.wake.id
end
h.check(selfloop.park(parked_session, 'master', 'canary: parked', {}).ok, 'no-starve',
  'the session was not parked, so the fixture would prove nothing')
h.check(next_second(), 'no-starve',
  'the real clock did not advance within the bound, so the free wake could not be given a LATER time than the held ones')
local free_made = selfloop.schedule({ in_seconds = 0, reason = 'canary: the free wake', prompt = 'canary' }, ctx)
h.check(type(free_made) == 'table' and free_made.ok and type(free_made.wake) == 'table', 'no-starve',
  'the free wake could not be scheduled: ' .. tostring(json.encode(free_made)))
dispatch = { count = 0, ids = {} }
local starved = selfloop.tick({ dispatch = counted })
h.check(type(starved) == 'table' and starved.dispatched == 1 and dispatch.ids[1] == free_made.wake.id, 'no-starve',
  'one tick dispatched ' .. tostring(type(starved) == 'table' and starved.dispatched) .. ' wake(s) '
  .. tostring(json.encode(dispatch.ids)) .. ' behind ' .. tostring(#parked_ids) .. ' overdue rows of a parked session, '
  .. 'and the one free wake was ' .. tostring(free_made.wake.id) .. ': ' .. tostring(json.encode(starved)))
h.check(tonumber(starved.paused) == #parked_ids, 'no-starve',
  'the tick reports ' .. tostring(starved.paused) .. ' held row(s), not ' .. tostring(#parked_ids))
local parked_after = selfloop.list({ all = true }, parked_ctx)
for _, wake in ipairs(parked_after.wakes or {}) do
  h.check(wake.status == 'pending' or wake.status == 'dispatching', 'no-starve',
    'a held wake changed state behind the hold: ' .. tostring(wake.id) .. ' is ' .. tostring(wake.status))
end

h.ok()
