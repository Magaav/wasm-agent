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

h.ok()
