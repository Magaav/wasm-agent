-- A slow mail query is a HANDLE, not a 2 s deadline (mission email-read-waits-on-a-future).
--
-- Victor, 27/11: a slow answer is not an error. The mail index had the WhatsApp shape - a private
-- `WAIT_MS = 2_000` in `rust/wa-email-index` spent by `rust/wa-capabilities/src/email_query.rs` on every
-- call - so a busy index turned a read into a deadline, and the deadline crossed the seam as a throw.
--
-- The shape this row pins: the crate waits for nobody, the caller's wait is the SHARED one
-- (`lua/core/codemode_pending.lua`: 60 s, 300 s at most), a query that has not settled when that wait ends
-- answers a handle, and `wait` resumes the same job - one number, one handle, for all three mail tools.
--
-- Nothing here touches a mailbox: the dispatcher is replaced, so what is checked is the shape of the
-- answer, never a message.
local failed, checks = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then failed = failed + 1; print('FAIL ' .. label) end
end

local function read(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local text = file:read('a')
  file:close()
  return text
end

-- ---- 1. no crate keeps a private wait --------------------------------------------------
local index = read('rust/wa-email-index/src/lib.rs')
assert(index, 'rust/wa-email-index/src/lib.rs is not readable; this row judges the tree it runs in')
ok(index:find('WAIT_MS', 1, true) == nil, 'the mail index has no WAIT_MS constant of its own')

local query = read('rust/wa-capabilities/src/email_query.rs')
assert(query, 'rust/wa-capabilities/src/email_query.rs is not readable')
ok(query:find('WAIT_MS', 1, true) == nil, 'and the host side says no WAIT_MS either')
ok(query:find('fn wait_ms', 1, true) ~= nil, 'the wait comes from the caller (`fn wait_ms`)')
ok(query:find('args.get("job")', 1, true) ~= nil, 'and a call may name a job id to read its outcome')
ok(query:find('saturating_mul(1000)', 1, true) ~= nil, 'wait_s is seconds, converted in one place')

-- ---- 2. one shared number, read from its owner ------------------------------------------
local pending_text = read('lua/core/codemode_pending.lua')
assert(pending_text, 'lua/core/codemode_pending.lua is not readable')
local default_s = tonumber(pending_text:match('M%.DEFAULT_WAIT_S%s*=%s*(%d+)'))
local max_s = tonumber(pending_text:match('M%.MAX_WAIT_S%s*=%s*(%d+)'))
ok(default_s == 60, 'the shared default is 60 s (it is ' .. tostring(default_s) .. ')')
ok(max_s == 300, 'the ceiling is 300 s (it is ' .. tostring(max_s) .. ')')

-- ---- 3. the three mail tools are ONE family ---------------------------------------------
local memory = dofile('lua/core/memory.lua'); memory.setup()
local pending = dofile('lua/core/codemode_pending.lua')
for _, tool in ipairs({ 'email_search', 'email_read', 'email_media' }) do
  local executor = pending.EXECUTORS[tool]
  ok(type(executor) == 'table', tool .. ' has an executor')
  ok(executor and executor.kind == 'queue_job', tool .. ' is a queue job, the same kind as a WhatsApp send')
end

-- ---- 4. a running query becomes a handle; an answered one stays an answer ---------------
local asked = {}
local dispatch = function(name, params)
  asked[#asked + 1] = { name = name, params = params }
  if params.job then
    return { ok = true, id = params.job, state = 'done', hits = { { subject = 'a synthetic hit' } } }
  end
  return { ok = true, id = 7, state = 'running' }
end
local exec = pending.EXECUTORS.email_search

local started = exec.start(dispatch, {}, { q = 'anything' }, '{}')
ok(started.op == 'email-7', 'a query still running answers a handle named after its job: ' .. tostring(started.op))
ok(started.id == 7 and started.tool == 'email_search', 'carrying the job id and the tool')
ok(started.result == nil, 'and NOT an answer')
ok(asked[1] and asked[1].params.wait_ms == 0, 'the start queues and does not wait (wait_ms=0)')
ok(asked[1] and asked[1].params.job == nil, 'and it asks for a new query, not an old job')

local answered = exec.start(function() return { ok = true, id = 9, state = 'done', hits = {} } end, {}, {}, '{}')
ok(answered.result ~= nil and answered.op == nil, 'a query the connector answered is the answer, not a handle')

-- ---- 5. the poll reads the job, one bounded slice at a time ------------------------------
asked = {}
local slice = {}
local poll = function(dispatch, opts, record, ms)
  local state, reason = exec.poll(function(name, params)
    slice[#slice + 1] = { name = name, params = params }
    if params.wait_ms and params.wait_ms > 0 then return { ok = true, id = params.job, state = 'done' } end
    return { ok = true, id = params.job, state = 'running' }
  end, {}, { id = 7, tool = 'email_search' }, ms)
  return state, reason
end
local state, reason = poll(nil, nil, nil, 0)
ok(state and state.settled == false, 'a job still running polls as pending')
ok(reason == 'still_running', 'with the reason said (it is ' .. tostring(reason) .. ')')
ok(slice[1] and slice[1].params.job == 7, 'the poll names the job') 
ok(slice[1] and slice[1].params.wait_ms == 0, 'and spends only the slice it was given')
state, reason = poll(nil, nil, nil, 800)
ok(state and state.settled == true and reason == nil, 'a job that answered settles, with no reason')
ok(slice[2] and slice[2].params.wait_ms == 800, 'the slice is the caller wait, passed through')

-- ---- 6. a cancel says what it is, and does not pretend ----------------------------------
local cancelled = exec.cancel(dispatch, {}, { op = 'email-7', tool = 'email_search' })
ok(cancelled.cancelled == false, 'a query is not reported as cancelled')
ok(cancelled.error == 'not_cancellable', 'it is refused by name')
ok(type(cancelled.why) == 'string' and #cancelled.why > 0, 'with a reason a reader can act on')

-- ---- 7. the canary reads a handle as pending, never as an empty mailbox ------------------
-- The canary asked `email_search` with no wait before this change, so under it a busy index would have
-- answered a handle and the canary would have said "no message in the index" - a false empty, which is
-- the exact defect the canary was fixed for on 26/11.
local json = dofile('lua/vendor/json.lua')
local canary = dofile('lua/core/canaries/mail.lua')
local native_search = host.email_search
local seen_wait = nil
host.email_search = function(asked)
  local args = json.decode(asked)
  seen_wait = args.wait_s
  return json.encode({ ok = true, id = 31, state = 'running' })
end
local proven, reason, detail = canary.run()
-- This canary says "not proven" with the string 'not_proven' (its own convention), never with false.
ok(proven == 'not_proven', 'a handle is not proof of an index (the canary answered ' .. tostring(proven) .. ')')
ok(reason == 'pending', 'it is reported as pending (got ' .. tostring(reason) .. ')')
ok(reason ~= 'no_data', 'and never as an empty mailbox')
ok(detail and tostring(detail):find('shared wait', 1, true) ~= nil, 'the detail names the wait it spent')
ok(seen_wait == pending.DEFAULT_WAIT_S, 'the canary spends the SHARED wait, read from its owner (' .. tostring(seen_wait) .. ')')
host.email_search = function() return json.encode({ ok = true, hits = { { subject = 'one' } } }) end
proven, reason = canary.run()
ok(proven == true and reason == 'index', 'an answered index still proves the index (got ' .. tostring(proven) .. '/' .. tostring(reason) .. ')')
host.email_search = native_search

print(string.format('ok email-read-waits-on-a-future: %d checks, %d failed', checks, failed))
if failed > 0 then error('email-read-waits-on-a-future failed') end

