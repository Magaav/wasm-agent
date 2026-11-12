-- One WhatsApp send that ANSWERS (operator decision, 11/11): the message stays a job on the account
-- node's durable queue, and `mcp_whatsapp_send` waits for that job's terminal state and answers it -
-- `done` with the message id, `failed` with the reason, or `pending` with the id and the call that
-- resumes the wait. Model-free and hermetic: a fake account node stands in for the two capabilities
-- and for the worker that settles jobs independently of the wait.
--
-- What is pinned here, one requirement at a time (the mission's a-e and its batch decision):
--   a) the wait holds no lock and no queue lease: it only READS the job's state, and a worker that
--      settles the job while the wait sleeps is what makes it terminal - the loop never writes;
--   b) a routed send never makes one long remote call: the owner queues with `wait_s = 0` and the wait
--      is a series of short state reads with backoff (0.5 s doubling to 5 s), each far under the
--      relay's call limit;
--   c) stop/steer/cancel ends the wait at once, the job stays queued (durable) and the answer is
--      `pending` with its id;
--   d) the job id is the handle: a resume after a timeout, a retried resume and a dropped connection
--      never queue a second message (the send capability is called exactly once);
--   e) an owner that becomes unreachable mid-wait answers `pending` with the id and the reason - not a
--      hang and never a false `failed`;
--   *  the bounds: `wait_s` defaults to 60, is clamped to 0..300 and never outlives the calling
--      script (the codemode deadline minus a margin);
--   *  batches: `{ids:[...]}` waits for 1..20 jobs and answers one entry per id in the order asked,
--      `until:"any"` returns at the first terminal outcome, and an id the owner never allocated is one
--      failed entry, not a lost batch;
--   *  three sends queued with `wait_s:0` and ONE `{ids}` resume answer three outcomes - the pattern
--      the operator asked for;
--   *  the resume form is a READ (it is classified as one, so it joins other calls instead of queueing
--      behind an effect), and `mcp_whatsapp_send_status` is the same call with `wait_s:0`, hidden from
--      every catalogue and guidance.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua')
local wa = dofile('lua/core/whatsapp.lua')

local checks = 0
local function ok(value, label) checks = checks + 1; assert(value, label) end
local function reason(answer) return tostring(type(answer) == 'table' and (answer.error or answer.reason or answer.state) or answer) end

-- ---------------------------------------------------------------- the fake account node
-- The clock is the test's, not the machine's: `host.now` is one counter and every recorded sleep moves
-- it, so a 60 s wait costs microseconds and the backoff it used is measurable.
local at = 1700000000
local sleeps, calls = {}, {}
local jobs, next_id, dedupes = {}, 0, 0
local real_now = host.now
host.now = function() return at end
local function tick(seconds) at = at + seconds end
local function clock_sleep(seconds) sleeps[#sleeps + 1] = seconds; tick(seconds) end

-- `settle_on_read` / `fail_on_read` is the WORKER: in production it is the wa-whatsapp component on
-- the account node, taking and settling the job on its own. It is driven by the read count here only
-- so the test can say when, without a second process and without a real sleep.
local function fake_send(request_json)
  calls[#calls + 1] = { name = 'whatsapp_send', request = json.decode(request_json) }
  local request = json.decode(request_json)
  local key = tostring(request.chat) .. '|' .. tostring(request.text) .. '|' .. tostring(request.reply_to)
  for id, job in pairs(jobs) do
    if job.key == key then
      dedupes = dedupes + 1
      return json.encode({ ok = true, id = id, state = job.state, queue = 'whatsapp.outbox', deduped = true })
    end
  end
  next_id = next_id + 1
  jobs[next_id] = { key = key, state = 'queued', reads = 0 }
  return json.encode({ ok = true, id = next_id, state = 'queued', queue = 'whatsapp.outbox' })
end
local function fake_status(request_json)
  calls[#calls + 1] = { name = 'whatsapp_send_status', request = json.decode(request_json) }
  local request = json.decode(request_json)
  local id = tonumber(request.id)
  local job = jobs[id]
  if not job then return json.encode({ ok = false, id = request.id, error = 'whatsapp_send_unknown_id' }) end
  job.reads = job.reads + 1
  if job.settle_on_read and job.reads >= job.settle_on_read then
    job.state, job.message_id = 'done', 'MSG-' .. tostring(id)
  elseif job.fail_on_read and job.reads >= job.fail_on_read then
    job.state, job.reason = 'failed', 'whatsapp_send_refused_by_phone'
  end
  return json.encode({ ok = true, id = id, state = job.state, message_id = job.message_id,
    reason = job.reason, attempts = job.reads, queue = 'whatsapp.outbox' })
end
local real_send, real_status = host.whatsapp_send, host.whatsapp_send_status
host.whatsapp_send, host.whatsapp_send_status = fake_send, fake_status

local ctx = { user_id = 'master', role = 'master', codemode_nested = true }
local function call(name, args, over)
  local scope = {}
  for key, value in pairs(ctx) do scope[key] = value end
  for key, value in pairs(over or {}) do scope[key] = value end
  scope.whatsapp_wait = scope.whatsapp_wait or { sleep = clock_sleep }
  local answer = tools.dispatch(memory, name, args, 'master', scope)
  return type(answer) == 'table' and json.decode(json.encode(answer)) or answer
end
local function calls_of(name)
  local list = {}
  for _, entry in ipairs(calls) do if entry.name == name then list[#list + 1] = entry end end
  return list
end
local function reset()
  calls, sleeps, dedupes = {}, {}, 0
  at = 1700000000
end
-- The job the NEXT send will queue, with the worker's plan, keyed exactly as `fake_send` dedupes it
-- (chat|text|reply_to). `next_id` is moved to it so the send allocates this id, as the queue would.
local CHAT = '5511999999999@lid'
local function fixture(id, text, plan)
  local job = { key = CHAT .. '|' .. text .. '|nil', state = 'queued', reads = 0 }
  for key, value in pairs(plan or {}) do job[key] = value end
  jobs[id], next_id = job, id - 1
  return job
end

-- ---------------------------------------------------------------- 1. the bounds, before any wait
-- Default 60, clamped to 0..300, and never longer than the script that asked has left.
ok(wa.wait_budget(nil, {}) == 60, 'wait_s defaults to 60')
ok(wa.wait_budget(0, {}) == 0, 'wait_s 0 queues and answers at once')
ok(wa.wait_budget(400, {}) == 300, 'wait_s is clamped to 300')
ok(wa.wait_budget(-5, {}) == 0, 'a negative wait_s is 0, not a backwards wait')
local script_left = wa.wait_budget(60, { codemode_deadline = at + 10 })
ok(script_left == 8, 'a wait never outlives the calling script: 10 s left minus the 2 s margin is ' .. tostring(script_left))
ok(wa.wait_budget(60, { codemode_deadline = at + 1 }) == 0, 'a script with less than the margin left waits 0 s')
ok(wa.wait_budget(5, { codemode_deadline = at + 100 }) == 5, 'the script cannot extend a wait the caller asked for')

-- ---------------------------------------------------------------- 2. one send, one answer (a)
reset()
fixture(1, 'oi', { settle_on_read = 3 })
local first = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'oi', wait_s = 60 })
ok(first.state == 'done', 'the send answers what WhatsApp did, not a job id: ' .. json.encode(first))
ok(first.id == 1 and first.message_id == 'MSG-1', 'the answer carries the job id and the message id WhatsApp gave it')
ok(first.served_by == wa.self_name(), 'the answer says which node served it: ' .. tostring(first.served_by))
ok(type(first.waited_s) == 'number' and first.waited_s > 0, 'the answer says how long it waited')
-- a) The wait takes no lock and no queue lease: the ONLY thing it did was read the job's state, and the
-- state became terminal because the worker settled it, never because the loop wrote anything.
ok(#calls_of('whatsapp_send') == 1, 'one send is one queue call')
ok(#calls_of('whatsapp_send_status') == 3, 'the wait read the job state three times')
local only = true
for _, entry in ipairs(calls) do
  if entry.name ~= 'whatsapp_send' and entry.name ~= 'whatsapp_send_status' then only = false end
end
ok(only, 'the wait touched nothing but the send and its state read - no queue take, no lease, no lock')
for _, entry in ipairs(calls_of('whatsapp_send_status')) do
  local keys = 0
  for _ in pairs(entry.request) do keys = keys + 1 end
  ok(keys == 1 and entry.request.id ~= nil, 'a state read asks for the id and nothing else: ' .. json.encode(entry.request))
end
ok(jobs[1].state == 'done', 'the job stayed the queue\'s and the worker\'s: the state moved forward without a write from the wait')

-- ---------------------------------------------------------------- 3. a refusal is a `failed` answer
reset()
fixture(2, 'segunda', { fail_on_read = 2 })
local failed = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'segunda' })
ok(failed.state == 'failed', 'a job the phone refused answers failed: ' .. json.encode(failed))
ok(failed.reason == 'whatsapp_send_refused_by_phone', 'and it carries the reason, not only the word failed')
-- `ok` is about the CALL, `state` is about the MESSAGE: a sandbox turns ok:false into a thrown Error,
-- so an outcome that arrived must be a value the script can read (measured: Promise.all would otherwise
-- lose three answers behind one Error string).
ok(failed.ok == true, 'a failed message is an answer, not a failed call')
ok(call('mcp_whatsapp_send', { id = 999999 }).ok == false,
  'an id this node never allocated IS a failed call: it cannot be waited on at all')

-- ---------------------------------------------------------------- 4. not finished in time is `pending` (c, d)
reset()
fixture(3, 'terceira')
local pending = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'terceira', wait_s = 5 })
ok(pending.state == 'pending' and pending.ok == true, 'a wait that ends first is pending, not an error: ' .. json.encode(pending))
ok(pending.id == 3 and pending.waited_s >= 5, 'pending keeps the id and says how long it waited')
ok(pending.resume == 'mcp_whatsapp_send({id:3, wait_s:60})', 'pending says how to resume: ' .. tostring(pending.resume))
local sent_before = #calls_of('whatsapp_send')
ok(sent_before == 1, 'the message was queued once')
-- The job is durable: the queue still holds it after the wait gave up, and a resume reads it.
reset()
jobs[3].settle_on_read, jobs[3].reads = 1, 0
local resumed = call('mcp_whatsapp_send', { id = 3 })
ok(resumed.state == 'done' and resumed.message_id == 'MSG-3', 'a resume answers the outcome: ' .. json.encode(resumed))
ok(#calls_of('whatsapp_send') == 0, 'a resume never queues anything: the id is the handle')
-- d) repeating the resume is safe, and a retry of the original request is the same job.
call('mcp_whatsapp_send', { id = 3 })
ok(#calls_of('whatsapp_send') == 0, 'a retried resume still queues nothing')
local again = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'terceira', wait_s = 0 })
ok(again.id == 3 and again.state == 'done', 'a repeated send answers the same job: ' .. json.encode(again))
ok(dedupes == 1 and #calls_of('whatsapp_send') == 1,
  'the same chat+text+reply_to is one job, so a retry queues no second message')

-- c) Cancellation ends the wait at once and leaves the job queued.
reset()
fixture(4, 'quarta')
local cancelled_after = 2
local cancelled = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'quarta', wait_s = 300 },
  { whatsapp_wait = { sleep = clock_sleep, cancelled = function() return #calls_of('whatsapp_send_status') >= cancelled_after end } })
ok(cancelled.state == 'pending' and cancelled.ok == true, 'stop/steer answers pending, not an error: ' .. json.encode(cancelled))
ok(cancelled.id == 4 and tostring(cancelled.reason):find('cancel', 1, true) ~= nil,
  'it names why it stopped: ' .. tostring(cancelled.reason))
ok(#calls_of('whatsapp_send_status') <= cancelled_after + 1, 'the wait stopped at the cancellation, it did not run to its bound')
ok(jobs[4].state == 'queued', 'the job is still queued after the wait was cancelled: nothing was lost')

-- ---------------------------------------------------------------- 5. the routed send (b, e)
-- A node that runs no component: the owner queues with wait_s 0 and this node reads the state itself.
local routed_calls = {}
local function routed_remote(node, name, args)
  routed_calls[#routed_calls + 1] = { node = node, name = name, args = args }
  if name == 'mcp_whatsapp_send' then
    ok(args.wait_s == 0, 'the owner is asked to queue and answer at once, never to wait for us')
    jobs[5] = jobs[5] or { key = CHAT .. '|quinta|nil', state = 'queued', reads = 0 }
    next_id = 4
    return { ok = true, id = 5, state = 'queued', queue = 'whatsapp.outbox' }
  end
  local job = jobs[5]
  if not job then return { ok = false, id = args.id, error = 'whatsapp_send_unknown_id' } end
  job.reads = job.reads + 1
  if job.reads >= 3 then job.state, job.message_id = 'done', 'MSG-5' end
  return { ok = true, id = args.id, state = job.state, message_id = job.message_id }
end
reset()
host.whatsapp_send = function() return json.encode({ ok = false, error = 'whatsapp_component_absent', owner = 'acct-node' }) end
host.whatsapp_send_status = function() return json.encode({ ok = false, error = 'whatsapp_component_absent', owner = 'acct-node' }) end
local routed = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'quinta', wait_s = 30 },
  { remote_call = routed_remote })
ok(routed.state == 'done' and routed.message_id == 'MSG-5', 'a routed send answers the outcome too: ' .. json.encode(routed))
ok(routed.served_by == 'acct-node', 'the answer says the account node served it: ' .. tostring(routed.served_by))
ok(#routed_calls >= 4, 'the wait is a loop of short reads, not one long call: ' .. tostring(#routed_calls))
local sends, reads = 0, 0
for _, entry in ipairs(routed_calls) do
  if entry.name == 'mcp_whatsapp_send' then sends = sends + 1 else reads = reads + 1 end
  ok(entry.node == 'acct-node', 'every hop asks the node that holds the account')
  if entry.name == 'mcp_whatsapp_send_status' then
    ok(entry.args.id == 5 and entry.args.wait_s == nil, 'a state read carries the id and no wait')
  end
end
ok(sends == 1, 'one remote send call')
ok(reads >= 3, 'and one short state read per round: ' .. tostring(reads))
-- The backoff doubles from 0.5 s and stops growing at 5 s, so no single hop can reach a relay deadline.
ok(#sleeps >= 2 and sleeps[1] == 0.5 and sleeps[2] == 1, 'the reads back off: ' .. json.encode(sleeps))
local capped = true
for _, seconds in ipairs(sleeps) do if seconds > 5 then capped = false end end
ok(capped, 'no single sleep is longer than 5 s: ' .. json.encode(sleeps))

-- e) The owner becomes unreachable mid-wait: pending with the id and the reason, never a hang or a
-- false failure.
reset()
fixture(6, 'sexta')
local hops = 0
host.whatsapp_send = function() return json.encode({ ok = false, error = 'whatsapp_component_absent', owner = 'acct-node' }) end
host.whatsapp_send_status = function() return json.encode({ ok = false, error = 'whatsapp_component_absent', owner = 'acct-node' }) end
local unreachable = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = 'sexta', wait_s = 120 }, {
  remote_call = function(node, name, args)
    hops = hops + 1
    if name == 'mcp_whatsapp_send' then return { ok = true, id = 6, state = 'queued' } end
    error('relay_busy: the relay did not answer')
  end,
})
ok(unreachable.state == 'pending', 'a lost owner answers pending: ' .. json.encode(unreachable))
ok(unreachable.id == 6 and tostring(unreachable.reason):find('unreachable', 1, true) ~= nil,
  'and it names the reason and keeps the id: ' .. tostring(unreachable.reason))
ok(hops < 6, 'it did not keep hammering an unreachable owner (' .. tostring(hops) .. ' hops)')
host.whatsapp_send, host.whatsapp_send_status = fake_send, fake_status

-- ---------------------------------------------------------------- 6. batches: {ids}, until
reset()
jobs = { [11] = { key = 'b1', state = 'queued', reads = 0, settle_on_read = 2 },
  [12] = { key = 'b2', state = 'queued', reads = 0, settle_on_read = 1 },
  [13] = { key = 'b3', state = 'queued', reads = 0, fail_on_read = 2 } }
local batch = call('mcp_whatsapp_send', { ids = { 11, 12, 13 }, wait_s = 30 })
ok(batch.state == 'settled' and batch.ok == true, 'a batch of ids answers when all are terminal: ' .. json.encode(batch))
ok(#batch.results == 3, 'one entry per id')
ok(batch.results[1].id == 11 and batch.results[2].id == 12 and batch.results[3].id == 13,
  'in the order asked, never the queue\'s order')
ok(batch.results[1].state == 'done' and batch.results[2].state == 'done' and batch.results[3].state == 'failed',
  'each entry carries its own done/failed: ' .. json.encode(batch.results))
ok(batch.results[3].reason == 'whatsapp_send_refused_by_phone', 'and a failed entry keeps its reason')
ok(#calls_of('whatsapp_send') == 0, 'a batch resume queues nothing')

-- until:"any" returns at the first terminal outcome and leaves the rest pending with their ids.
reset()
jobs = { [21] = { key = 'a1', state = 'queued', reads = 0, settle_on_read = 1 },
  [22] = { key = 'a2', state = 'queued', reads = 0 },
  [23] = { key = 'a3', state = 'queued', reads = 0 } }
local any = call('mcp_whatsapp_send', { ids = { 21, 22, 23 }, ['until'] = 'any', wait_s = 60 })
ok(any.state == 'pending' and any.ok == true, 'until:"any" answers as soon as one is terminal: ' .. json.encode(any))
ok(any.results[1].state == 'done' and any.results[2].state == 'pending' and any.results[3].state == 'pending',
  'the settled one is done and the others are pending: ' .. json.encode(any.results))
ok(json.encode(any.pending_ids) == '[22,23]', 'the pending ids are named: ' .. json.encode(any.pending_ids))
ok(tostring(any.resume):find('ids', 1, true) ~= nil, 'the resume for the rest is one call: ' .. tostring(any.resume))

-- An id the owner never allocated is one failed entry, not a lost batch.
reset()
jobs = { [31] = { key = 'u1', state = 'queued', reads = 0, settle_on_read = 1 } }
local mixed = call('mcp_whatsapp_send', { ids = { 31, 999999 }, wait_s = 10 })
ok(mixed.results[1].state == 'done', 'the id that exists still answers: ' .. json.encode(mixed.results[1]))
ok(mixed.results[2].state == 'failed' and mixed.results[2].error == 'whatsapp_send_unknown_id',
  'the id nobody allocated is one failed entry: ' .. json.encode(mixed.results[2]))

-- The bounds of a batch are the operator's: 1..20 ids, and a resume never carries a message.
ok(call('mcp_whatsapp_send', { ids = {} }).error == 'whatsapp_send_bad_ids', 'an empty batch is refused')
local many = {}
for index = 1, 21 do many[index] = index end
ok(call('mcp_whatsapp_send', { ids = many }).error == 'whatsapp_send_bad_ids', 'more than 20 ids is refused')
ok(call('mcp_whatsapp_send', { ids = { 1 }, chat = '5511999999999@lid', text = 'x' }).error == 'whatsapp_send_id_or_message',
  'a call cannot both wait and send')
ok(call('mcp_whatsapp_send', { ids = { 'x' } }).error == 'whatsapp_send_bad_ids', 'an id that is not a number is refused')
ok(call('mcp_whatsapp_send', { id = 1, ['until'] = 'soon' }).error == 'whatsapp_send_bad_until', 'until is all or any')

-- ---------------------------------------------------------------- 7. three sends, one batch resume
-- The pattern the operator asked for: several sends stay serialized (effects), each is queued with
-- wait_s:0, and ONE {ids} resume collects all three outcomes in a later step.
reset()
-- The worker settles each one AFTER the queue call, so `wait_s:0` really answers `pending` and the
-- batch is what collects the three outcomes (settle_on_read 2: the queued read, then done).
fixture(41, 'um', { settle_on_read = 2 })
fixture(42, 'dois', { settle_on_read = 2 })
fixture(43, 'tres', { settle_on_read = 2 })
local queued = {}
for index, text in ipairs({ 'um', 'dois', 'tres' }) do
  local answer = call('mcp_whatsapp_send', { chat = '5511999999999@lid', text = text, wait_s = 0 })
  ok(answer.state == 'pending' and answer.id ~= nil, 'send ' .. text .. ' is queued and answered at once')
  queued[index] = answer.id
end
ok(#calls_of('whatsapp_send') == 3, 'three sends queue three messages, one at a time')
local collected = call('mcp_whatsapp_send', { ids = queued })
ok(collected.state == 'settled' and #collected.results == 3, 'one batched resume answers three outcomes')
ok(#calls_of('whatsapp_send') == 3, 'and it queues nothing: still three sends for three messages')
for index, id in ipairs(queued) do
  ok(collected.results[index].id == id and collected.results[index].state == 'done',
    'the outcome of ' .. tostring(id) .. ' is in the order asked')
end

-- ---------------------------------------------------------------- 8. the resume is a READ
-- `whatsapp.send` policy and serialization belong to the SEND form; a resume only reads the queue.
ok(wa.effect('mcp_whatsapp_send', { chat = 'x@lid', text = 'y' }) == 'write', 'the send form is an effect')
ok(wa.effect('mcp_whatsapp_send', { id = 1 }) == 'read', 'the resume form with one id is a read')
ok(wa.effect('mcp_whatsapp_send', { ids = { 1, 2 } }) == 'read', 'the resume form with ids is a read')
ok(wa.effect('mcp_whatsapp_send', { id = 1, chat = 'x@lid', text = 'y' }) == 'write',
  'a call that carries a message is an effect, whatever else it carries')
ok(tools.has_effect('mcp_whatsapp_send') == true, 'with no arguments the tool is the effect it usually is')
ok(tools.has_effect('mcp_whatsapp_send', { chat = 'x@lid', text = 'y' }) == true, 'a send counts as an effect')
ok(tools.has_effect('mcp_whatsapp_send', { id = 1 }) == false, 'a resume does not count as an effect')
ok(tools.has_effect('mcp_whatsapp_send', { ids = { 1, 2 } }) == false, 'a batched resume does not either')
ok(tools.has_effect('mcp_whatsapp_read', { chat = 'x@lid' }) == false, 'the reads stay reads')

-- ---------------------------------------------------------------- 9. the hidden alias and the catalogue
local status_calls_before = #calls_of('whatsapp_send_status')
local alias = call('mcp_whatsapp_send_status', { id = 43 })
ok(alias.state == 'done' and alias.message_id == 'MSG-43', 'send_status answers like a resume: ' .. json.encode(alias))
ok(#calls_of('whatsapp_send_status') == status_calls_before + 1, 'and it is exactly one state read (wait_s 0)')
ok(wa.hidden('mcp_whatsapp_send_status') == true, 'send_status is a hidden tool of the surface')
ok(wa.hidden('mcp_whatsapp_send') == false, 'the send itself is not hidden')
local offered = {}
for _, schema in ipairs(wa.schemas()) do offered[schema['function'].name] = true end
ok(offered.mcp_whatsapp_send_status == nil, 'no catalogue the model is offered holds send_status')
ok(offered.mcp_whatsapp_send == true, 'and the model is offered the send')
local catalogued = {}
for _, schema in ipairs(tools.catalog('master')) do catalogued[schema['function'].name] = true end
ok(catalogued.mcp_whatsapp_send_status == nil, 'nor does the node\'s own tool catalogue')
ok(tools.snippet('mcp_whatsapp_send_status') == nil, 'and no compaction cue names it')
ok(tools.snippet('mcp_whatsapp_send') ~= nil, 'the send keeps its cue')
local send_schema = nil
for _, schema in ipairs(wa.schemas()) do if schema['function'].name == 'mcp_whatsapp_send' then send_schema = schema['function'] end end
ok(send_schema ~= nil, 'the send is offered')
for _, field in ipairs({ 'chat', 'text', 'reply_to', 'mentions', 'id', 'ids', 'until', 'wait_s' }) do
  ok(send_schema.parameters.properties[field] ~= nil, 'the send schema carries ' .. field)
end
ok(send_schema.parameters.properties.wait_s.maximum == 300 and send_schema.parameters.properties.wait_s.minimum == 0,
  'wait_s is bounded 0..300 in the schema the model reads')
ok(send_schema.parameters.properties.ids.maxItems == 20 and send_schema.parameters.properties.ids.minItems == 1,
  'ids is bounded 1..20 in the schema the model reads')
ok(not send_schema.parameters.required, 'neither shape is required: chat+text sends, id/ids resumes')
ok(send_schema.description:find('state:"done"', 1, true) ~= nil, 'the description names the done answer')
ok(send_schema.description:find('state:"pending"', 1, true) ~= nil, 'and the pending answer with its resume')
ok(send_schema.description:find('mcp_whatsapp_send_status', 1, true) == nil, 'and never sends the model to send_status')
ok(send_schema.description:find('ids', 1, true) ~= nil, 'and says several ids can be resumed in one call')

-- A guest may not resume either: the outbox is the operator's.
local guest = tools.dispatch(memory, 'mcp_whatsapp_send', { id = 1 }, 'guest', { user_id = 'guest', role = 'guest' })
ok(type(guest) == 'table' and guest.error == 'forbidden_for_role:guest', 'a guest may not wait on the outbox')

host.now = real_now
host.whatsapp_send, host.whatsapp_send_status = real_send, real_status
print('whatsapp send waits ok (' .. checks .. ' checks)')
