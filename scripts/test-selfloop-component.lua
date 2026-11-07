-- The self-loop seam's parity suite (docs/CORE-SPLIT.md; docs/KERNEL.md "The self-loop as a
-- component"): the same calls through the native `lua/core/selfloop.lua` and through the `selfloop`
-- component over a scoped `wa:kernel/sql` grant, compared field for field - the refusals, the notes,
-- the wakes, the event subscriptions, the summary, and the tick's counters.
--
-- Self-contained: the runner's own `--db` and a scratch WASM_AGENT_HOME, no node, no network, no
-- model. The component half needs a built `selfloop.wasm` *reachable by this process*, which means
-- `WA_SELFLOOP_COMPONENT_WASM` (the development override the memory seam uses too);
-- `scripts/test-selfloop-component.sh` builds it and sets it. When it is not reachable the parity
-- comparisons are SKIPPED - printed as such, and reported in REPORT.md - and a skip is never counted
-- as a pass.
local json = dofile('lua/vendor/json.lua')

local checks, comparisons, skipped = 0, 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then error('SELFLOOP SEAM CHECK FAILED: ' .. label) end
end
local function skip(what, why)
  skipped = skipped + 1
  print('SKIP selfloop seam: ' .. what .. ' (' .. why .. ')')
end
local function decode(value)
  if type(value) ~= 'string' then return value end
  local ok, decoded = pcall(json.decode, value)
  return ok and decoded or value
end

-- The two interpreters: one native, one routed through the component. The switch is read once, when
-- the module loads, exactly as a node reads it - so the test flips the *host's* answer while each
-- instance loads rather than reaching into the module.
local memory = dofile('lua/core/memory.lua')
memory.setup()
local real_getenv, real_selfloop, real_log = host.getenv, host.selfloop, host.log
local logged = {}

local function instance(seam)
  host.getenv = function(name)
    if name == 'WA_SELFLOOP_COMPONENT' then return seam and '1' or nil end
    return real_getenv(name)
  end
  host.log = function(line) logged[#logged + 1] = tostring(line) end
  local module = dofile('lua/core/selfloop.lua')
  module.setup()
  host.getenv, host.log = real_getenv, real_log
  return module
end

local native = instance(false)

-- Is the component reachable from *this process*? A stub cannot influence that, and a "parity"
-- comparison between the native path and a fallback would pass while proving nothing. So the probe
-- decides, and an unreachable component is a reported SKIP.
local seam, seam_log
local reachable = nil
if type(real_selfloop) ~= 'function' then
  skip('parity', 'this binary has no host.selfloop capability')
else
  -- `summary` of a session that does not exist is a read with no effect on any row.
  reachable = decode(real_selfloop(json.encode({ op = 'summary', session_id = '', now = 0 })))
  if type(reachable) ~= 'table' or reachable.ok ~= true then
    skip('parity', 'the selfloop component did not answer: '
      .. tostring(type(reachable) == 'table' and reachable.error or reachable))
    reachable = nil
  end
end

if reachable then
  logged = {}
  seam = instance(true)
  seam_log = logged
  check(#seam_log == 0, 'no fallback was logged while the component answered: ' .. tostring(seam_log[1]))
end

------------------------------------------------------------------ parity
-- Ids are the one thing the two paths cannot share: each mints its own (the native `host.uuid()`, the
-- component's RandomState+clock mix), so a comparison that kept them would only prove that two calls
-- happen to agree on a random value. Everything else - statuses, refusals, counts, times, the stored
-- text - is compared as it is.
local ID_KEYS = { id = true, cancelled = true, version = true, archived = true }
local function normalize(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, item in pairs(value) do
    if ID_KEYS[key] and type(item) == 'string' and #item > 0 then
      out[key] = '<id>'
    elseif key == 'wake_ids' and type(item) == 'table' then
      local ids = {}
      for index = 1, #item do ids[index] = '<id>' end
      out[key] = ids
    elseif type(item) == 'table' then
      out[key] = normalize(item)
    else
      out[key] = item
    end
  end
  return out
end

local function same(label, native_value, seam_value)
  -- Without a reachable component there is nothing to compare against: the comparison is skipped (the
  -- summary line says so) rather than counted as a pass.
  if not seam then return end
  comparisons = comparisons + 1
  local ok_left, left = pcall(function() return json.encode(normalize(native_value)) end)
  local ok_right, right = pcall(function() return json.encode(normalize(seam_value)) end)
  if not ok_left then error('PARITY: ' .. label .. ': the native answer is not encodable: ' .. tostring(left)) end
  if not ok_right then error('PARITY: ' .. label .. ': the component answer is not encodable: ' .. tostring(right)) end
  if left ~= right then
    error(string.format('PARITY: %s differs\n  native:    %s\n  component: %s', label, left, right))
  end
end

local T0 = 1700000000
native.set_test_clock(function() return T0 end)
if seam then seam.set_test_clock(function() return T0 end) end

local s_native = memory.start_session('local', 'chat',
  { id = 'parity-native', user_id = 'master', node_id = 'test-node', title = 'native' })
local s_seam = memory.start_session('local', 'chat',
  { id = 'parity-seam', user_id = 'master', node_id = 'test-node', title = 'seam' })
local native_ctx = { user_id = 'master', role = 'master', session_id = s_native }
local seam_ctx = { user_id = 'master', role = 'master', session_id = s_seam }

-- Refusals: the names, and the extra fields each one carries. Stateless, so both paths run them in
-- the same order on the same (empty) session state.
for _, case in ipairs({
  { 'a time wake and an event wake together', { reason = 'x', in_seconds = 10, on = { 'deploy.done' } } },
  { 'in_seconds and at together', { reason = 'x', in_seconds = 10, at = T0 + 100 } },
  { 'a time in the past', { reason = 'x', at = T0 - 1 } },
  { 'an empty reason', { reason = '', in_seconds = 10 } },
  { 'neither a time nor an event', { reason = 'x' } },
  { 'an empty event list', { reason = 'x', on = {} } },
  { 'a cadence below the floor', { reason = 'x', in_seconds = 10, every_seconds = 1 } },
  { 'a probe with no cadence', { reason = 'x', in_seconds = 10, probe = 'return {changed=false}' } },
  { 'an event wake with a clock', { reason = 'x', on = { 'deploy.done' }, every_seconds = 30 } },
  { 'a duplicate subscription', { reason = 'x', on = { 'a', 'a' } } },
  { 'an oversized reason', { reason = string.rep('r', 501), in_seconds = 10 } },
  { 'an oversized prompt', { reason = 'x', prompt = string.rep('p', 8001), in_seconds = 10 } },
  { 'an oversized probe', { reason = 'x', in_seconds = 10, every_seconds = 10, probe = string.rep('q', 20001) } },
}) do
  local label, args = case[1], case[2]
  local a = native.schedule({ reason = args.reason, prompt = args.prompt, probe = args.probe,
    in_seconds = args.in_seconds, at = args.at, every_seconds = args.every_seconds, on = args.on, now = T0 }, native_ctx)
  local b
  if seam then
    b = seam.schedule({ reason = args.reason, prompt = args.prompt, probe = args.probe,
      in_seconds = args.in_seconds, at = args.at, every_seconds = args.every_seconds, on = args.on, now = T0 }, seam_ctx)
    same('schedule refuses ' .. label, a, b)
  end
  check(a.error ~= nil, 'the native path refuses ' .. label)
  check(b == nil or b.error ~= nil, 'the component path refuses ' .. label)
end

-- A session that does not exist, and another owner's session: both paths refuse by name.
same('a missing session is refused',
  native.schedule({ reason = 'x', in_seconds = 10, now = T0 }, { user_id = 'master', role = 'master', session_id = 'nope' }),
  seam and seam.schedule({ reason = 'x', in_seconds = 10, now = T0 }, { user_id = 'master', role = 'master', session_id = 'nope' }))

local guest = memory.start_session('local', 'chat',
  { id = 'parity-guest', user_id = 'guest', node_id = 'test-node', title = 'guest' })
same("another owner's session is refused",
  native.list({ now = T0 }, { user_id = 'master', role = 'master', session_id = guest }),
  seam and seam.list({ now = T0 }, { user_id = 'master', role = 'master', session_id = guest }))

-- Notes: the document, the append, the compaction, the archive and the version list.
same('notes_read on a new session', native.notes_read({}, native_ctx), seam and seam.notes_read({}, seam_ctx))
same('notes_write', native.notes_write({ text = 'goal\nstep 1\nstep 2', now = T0 }, native_ctx),
  seam and seam.notes_write({ text = 'goal\nstep 1\nstep 2', now = T0 }, seam_ctx))
same('notes_append', native.notes_append({ text = 'step 3', now = T0 + 1 }, native_ctx),
  seam and seam.notes_append({ text = 'step 3', now = T0 + 1 }, seam_ctx))
same('notes_read after append', native.notes_read({}, native_ctx), seam and seam.notes_read({}, seam_ctx))
same('notes_append past the bound is refused', native.notes_append({ text = string.rep('x', 65536), now = T0 }, native_ctx),
  seam and seam.notes_append({ text = string.rep('x', 65536), now = T0 }, seam_ctx))
same('notes_append of nothing is refused', native.notes_append({ text = '', now = T0 }, native_ctx),
  seam and seam.notes_append({ text = '', now = T0 }, seam_ctx))
local native_compact = native.notes_compact({ keep_lines = 2, now = T0 + 2 }, native_ctx)
local seam_compact = seam and seam.notes_compact({ keep_lines = 2, now = T0 + 2 }, seam_ctx)
same('notes_compact', native_compact, seam_compact)
same('notes_read after compact', native.notes_read({}, native_ctx), seam and seam.notes_read({}, seam_ctx))
same('notes_compact again, unchanged', native.notes_compact({ keep_lines = 2, now = T0 + 3 }, native_ctx),
  seam and seam.notes_compact({ keep_lines = 2, now = T0 + 3 }, seam_ctx))
same('notes_compact with a bad bound', native.notes_compact({ keep_lines = 0, now = T0 }, native_ctx),
  seam and seam.notes_compact({ keep_lines = 0, now = T0 }, seam_ctx))
same('notes_read versions', native.notes_read({ versions = true }, native_ctx), seam and seam.notes_read({ versions = true }, seam_ctx))
same('notes_read an archived version', native.notes_read({ version = native_compact.archived }, native_ctx),
  seam and seam.notes_read({ version = seam_compact and seam_compact.archived }, seam_ctx))
same('notes_read an unknown version', native.notes_read({ version = 'never-written' }, native_ctx),
  seam and seam.notes_read({ version = 'never-written' }, seam_ctx))

-- Wakes: a time wake, an event wake, the list, the summary and the footer.
local native_wake = native.schedule({ in_seconds = 60, reason = 'check the deploy', prompt = 'look again', now = T0 }, native_ctx)
local seam_wake = seam and seam.schedule({ in_seconds = 60, reason = 'check the deploy', prompt = 'look again', now = T0 }, seam_ctx)
same('schedule a time wake', native_wake, seam_wake)
check(native_wake.ok and #native_wake.wake.id == 36, 'the native wake has a uuid-shaped id')
check(seam_wake == nil or (seam_wake.ok and #seam_wake.wake.id == 36), 'the component wake has a uuid-shaped id')
same('list after a time wake', native.list({ now = T0 + 30 }, native_ctx), seam and seam.list({ now = T0 + 30 }, seam_ctx))
same('summary after a time wake', native.summary(s_native, { now = T0 + 30 }), seam and seam.summary(s_seam, { now = T0 + 30 }))
same('footer after a time wake', native.footer_text(s_native, { now = T0 + 30 }), seam and seam.footer_text(s_seam, { now = T0 + 30 }))

local native_event = native.schedule({ on = { 'deploy.done', 'message' }, reason = 'deploy finished', now = T0 }, native_ctx)
local seam_event = seam and seam.schedule({ on = { 'deploy.done', 'message' }, reason = 'deploy finished', now = T0 }, seam_ctx)
same('schedule an event wake', native_event, seam_event)
same('list with both wakes', native.list({ now = T0 + 30 }, native_ctx), seam and seam.list({ now = T0 + 30 }, seam_ctx))

-- Publish is a *global* match: every pending event wake in the store hears a topic. So the two paths
-- are compared in two rounds that start from the same state - one subscription in each session and
-- nothing else pending - because a single shared state would let the native round consume the
-- component round's subscriptions and "0 matched" would prove nothing.
local function clear_pending(module, ctx)
  for _, wake in ipairs(module.list({ now = T0 + 99999 }, ctx).wakes) do
    module.cancel({ id = wake.id, now = T0 + 99999 }, ctx)
  end
end
local function clear_all()
  clear_pending(native, native_ctx)
  if seam then clear_pending(seam, seam_ctx) end
end
local function publish_round(publisher)
  clear_all()
  native.schedule({ on = { 'deploy.done', 'message' }, reason = 'deploy finished', now = T0 }, native_ctx)
  local seam_wake_id
  if seam then
    seam_wake_id = seam.schedule({ on = { 'deploy.done', 'message' }, reason = 'deploy finished', now = T0 }, seam_ctx).wake.id
  end
  local report = publisher('deploy.done', { id = 'evt-1', text = 'PRIVATE PAYLOAD' }, { now = T0 + 5 })
  -- What the store kept about the event: the topic and its identity, never the payload's text.
  local stored
  if seam_wake_id then
    local rows = decode(host.sql_query('SELECT event_json FROM self_wakes WHERE id=?', json.encode({ seam_wake_id })))
    stored = rows and rows[1] and rows[1].event_json or ''
  end
  return report, stored
end
local native_published = publish_round(function(...) return native.publish(...) end)
-- `and` truncates a multiple return, so the second value needs its own branch.
local seam_published, seam_stored
if seam then seam_published, seam_stored = publish_round(function(...) return seam.publish(...) end) end
same('publish a matching topic', native_published, seam_published)
if seam then
  check(seam_stored:find('deploy.done', 1, true) ~= nil, 'the stored event names its topic: ' .. tostring(seam_stored))
  check(seam_stored:find('evt-1', 1, true) ~= nil, 'the stored event keeps its identity: ' .. tostring(seam_stored))
  check(seam_stored:find('PRIVATE PAYLOAD', 1, true) == nil, 'the stored event never keeps the payload text')
end
same('publishing an unmatched topic', native.publish('nobody.listens', { id = 'evt-2' }, { now = T0 + 6 }),
  seam and seam.publish('nobody.listens', { id = 'evt-2' }, { now = T0 + 6 }))
same('publishing no topic is refused', native.publish('', {}, { now = T0 + 6 }), seam and seam.publish('', {}, { now = T0 + 6 }))
same('list after the event', native.list({ now = T0 + 6 }, native_ctx), seam and seam.list({ now = T0 + 6 }, seam_ctx))

-- A message subscription names its session.
local native_message = native.schedule({ on = { 'message' }, reason = 'someone wrote', now = T0 }, native_ctx)
local seam_message = seam and seam.schedule({ on = { 'message' }, reason = 'someone wrote', now = T0 }, seam_ctx)
same('schedule a message wake', native_message, seam_message)
same('a message in another session does not match', native.on_user_message('some-other-session', { now = T0 + 9 }),
  seam and seam.on_user_message('some-other-session', { now = T0 + 9 }))
same('a message in this session matches', native.on_user_message(s_native, { now = T0 + 9, message_id = 'm-1' }),
  seam and seam.on_user_message(s_seam, { now = T0 + 9, message_id = 'm-1' }))

-- Cancel: a pending wake cancels, a second cancel of it is refused, an unknown id is refused.
same('cancel a pending wake', native.cancel({ id = native_wake.wake.id, now = T0 + 10 }, native_ctx),
  seam and seam.cancel({ id = seam_wake and seam_wake.wake.id, now = T0 + 10 }, seam_ctx))
same('cancel it again', native.cancel({ id = native_wake.wake.id, now = T0 + 11 }, native_ctx),
  seam and seam.cancel({ id = seam_wake and seam_wake.wake.id, now = T0 + 11 }, seam_ctx))
same('cancel an unknown id', native.cancel({ id = 'nope', now = T0 + 11 }, native_ctx),
  seam and seam.cancel({ id = 'nope', now = T0 + 11 }, seam_ctx))
same('cancel without an id', native.cancel({}, native_ctx), seam and seam.cancel({}, seam_ctx))
same('list after the cancels', native.list({ all = true, now = T0 + 12 }, native_ctx),
  seam and seam.list({ all = true, now = T0 + 12 }, seam_ctx))

-- The wake turn's shape: the marker, the model's own prompt, its notes, the event identity and the
-- probe result, and the trace.
local shaped = {
  id = 'shaped', session_id = s_native, owner = 'master', reason = 'check tests', prompt = 'run the gate',
  event_json = json.encode({ topic = 'job.ci' }), probe_result = json.encode({ changed = true, seen = 7 }),
}
local native_content, native_trace = native.turn_content(shaped, { now = T0 })
local seam_content, seam_trace
if seam then seam_content, seam_trace = seam.turn_content(shaped, { now = T0 }) end
same('turn_content', { content = native_content, trace = native_trace }, { content = seam_content, trace = seam_trace })
check(type(native_content) == 'string' and native_content:find('[self-wake', 1, true) ~= nil, 'the native turn is marked')

------------------------------------------------------------------ the tick: the counters
-- The tick reads every due row in the store, so one phase at a time runs with the *other* session
-- settled: a phase sets up its own rows in its own session, ticks, and its counters are compared with
-- a second phase that did exactly the same thing on the other path. Without that, the first path's
-- dispatch would consume the second path's rows and "0 dispatched" would prove nothing.
local function settle_all(module, ctx)
  for _, wake in ipairs(module.list({ all = true, now = T0 + 99999 }, ctx).wakes) do
    if wake.status == 'pending' then
      module.cancel({ id = wake.id, now = T0 + 99999 }, ctx)
    end
  end
end

local function settle_both()
  -- Every pending row in the store, including one a previous run in this scratch home left behind:
  -- a phase must start from the same state on both paths or its counters say nothing.
  host.sql_exec("UPDATE self_wakes SET status='cancelled', updated_at=? WHERE status='pending'", json.encode({ T0 + 99999 }))
end

local dispatched = { count = 0 }
local function dispatch(row)
  dispatched.count = dispatched.count + 1
  return { accepted = true, run_id = 1 }
end

-- One phase: a clean slate, the setup's rows, one tick.
local function phase(module, ctx, setup, opts)
  settle_both()
  setup(module, ctx)
  return module.tick(opts)
end

local function due_now(module, ctx)
  module.schedule({ in_seconds = 0, reason = 'due now', now = T0 }, ctx)
end
local function quiet(module, ctx)
  module.schedule({ in_seconds = 10, every_seconds = 30, probe = 'return {changed=false}', reason = 'poll', now = T0 }, ctx)
end
local function probe_wake(module, ctx)
  module.schedule({ in_seconds = 0, every_seconds = 30, probe = 'return {changed=true}', reason = 'poll', now = T0 }, ctx)
end

local native_due = phase(native, native_ctx, due_now, { now = T0, dispatch = dispatch })
check(native_due.dispatched == 1, 'the native tick dispatches a due wake: ' .. json.encode(native_due))
if seam then
  same('tick dispatches a due wake', native_due, phase(seam, seam_ctx, due_now, { now = T0, dispatch = dispatch }))
  -- A claim is a compare-and-set: a second tick finds nothing to hand over.
  same('a claimed wake is not dispatched twice', native.tick({ now = T0 + 1, dispatch = dispatch }),
    seam.tick({ now = T0 + 1, dispatch = dispatch }))

  -- An unchanged probe spends no turn, and re-arms at the cadence the model asked for.
  local unchanged = function() return { changed = false, note = 'nothing new' } end
  local before = dispatched.count
  local function pending(module, ctx, reason)
    for _, wake in ipairs(module.list({ now = T0 + 10 }, ctx).wakes) do
      if wake.reason == reason then return wake end
    end
    return nil
  end
  local native_skip = phase(native, native_ctx, quiet, { now = T0 + 10, dispatch = dispatch, probe = unchanged })
  -- Read before the component phase settles the other session for its own run.
  local native_rearmed = pending(native, native_ctx, 'poll')
  local seam_skip = phase(seam, seam_ctx, quiet, { now = T0 + 10, dispatch = dispatch, probe = unchanged })
  local seam_rearmed = pending(seam, seam_ctx, 'poll')
  same('an unchanged probe skips the turn', native_skip, seam_skip)
  check(native_skip.skipped == 1 and native_skip.dispatched == 0, 'the native tick skipped, not dispatched: ' .. json.encode(native_skip))
  check(seam_skip.skipped == 1 and seam_skip.dispatched == 0, 'the component tick skipped, not dispatched: ' .. json.encode(seam_skip))
  check(dispatched.count == before, 'an unchanged probe spent no model turn on either path')
  same('the re-armed wake', native_rearmed, seam_rearmed)
  check(native_rearmed ~= nil and native_rearmed.in_seconds == 30, 'the native wake re-armed at its cadence')
  check(seam_rearmed ~= nil and seam_rearmed.in_seconds == 30, 'the component wake re-armed at its cadence')

  -- A changed probe dispatches the turn, and the probe's result travels with it.
  local changed = function() return { changed = true, seen = 7 } end
  same('a changed probe wakes the model',
    phase(native, native_ctx, probe_wake, { now = T0, dispatch = dispatch, probe = changed }),
    phase(seam, seam_ctx, probe_wake, { now = T0, dispatch = dispatch, probe = changed }))

  -- A dispatch that did not start is put back with a retry delay: not replayed, not lost.
  local not_started = function() return { not_started = true, error = 'the lane is busy' } end
  same('a dispatch that did not start is deferred',
    phase(native, native_ctx, due_now, { now = T0, dispatch = not_started }),
    phase(seam, seam_ctx, due_now, { now = T0, dispatch = not_started }))
  -- An ambiguous dispatch is reported unknown, and is never dispatched again.
  local ambiguous = function() return { error = 'the scheduler did not answer' } end
  same('an ambiguous dispatch is unknown',
    phase(native, native_ctx, due_now, { now = T0, dispatch = ambiguous }),
    phase(seam, seam_ctx, due_now, { now = T0, dispatch = ambiguous }))

  -- An interrupted dispatch is reported unknown and never replayed. Asserted per path, not compared:
  -- rows a previous phase left in flight are global state, so the two counts are not the same number.
  for _, pair in ipairs({ { native, native_ctx, 'native' }, { seam, seam_ctx, 'component' } }) do
    settle_both()
    local module, ctx, name = pair[1], pair[2], pair[3]
    module.schedule({ in_seconds = 0, reason = 'in flight', now = T0 }, ctx)
    local handed = module.tick({ now = T0, dispatch = dispatch })
    check(handed.dispatched == 1, name .. ': the wake is handed over')
    local reconciled = module.tick({ now = T0 + 4000, dispatch = dispatch, stale_seconds = 60 })
    check(reconciled.reconciled >= 1, name .. ': a stale dispatch is reconciled: ' .. json.encode(reconciled))
    check(reconciled.dispatched == 0, name .. ': an interrupted dispatch is never replayed: '
      .. json.encode(reconciled) .. ' after ' .. json.encode(handed))
  end
  settle_both()
end

------------------------------------------------------------------ a restart, on the component path
if seam then
  settle_all(seam, seam_ctx)
  local survivor = seam.schedule({ in_seconds = 3600, reason = 'survive', now = T0 }, seam_ctx)
  check(survivor.ok, 'the component scheduled the survivor: ' .. json.encode(survivor))
  -- A fresh interpreter with the seam on is what a restarted node has: no module state, no component
  -- state (each call is its own instance), only the row.
  local reloaded = instance(true)
  local after = reloaded.list({ now = T0 + 1 }, seam_ctx)
  local found
  for _, wake in ipairs(after.wakes) do if wake.id == survivor.wake.id then found = wake end end
  check(after.count == 1 and found ~= nil, 'a new interpreter sees the pending wake: ' .. json.encode(after))
  check(found ~= nil and found.status == 'pending', 'the survivor is still pending')
  -- It survives the *store*, not the interpreter: the row is the wake.
  local stored = decode(host.sql_query('SELECT status,due_at FROM self_wakes WHERE id=?', json.encode({ survivor.wake.id })))
  check(type(stored) == 'table' and stored[1] and stored[1].status == 'pending', 'the pending wake is a row in memory.db')
  -- And it is claimed exactly once, by a third instance.
  local claimant = instance(true)
  local claimed = claimant.claim_due(s_seam, 'master', { now = T0 + 3601, boot = 'boot-2' })
  check(claimed ~= nil and claimed.id == survivor.wake.id, 'the wake is claimed once: ' .. json.encode(claimed))
  local again = claimant.claim_due(s_seam, 'master', { now = T0 + 3602, boot = 'boot-2' })
  check(again == nil, 'a claimed wake is not claimed again')
  -- A claim is settled through the component, and a repeating wake re-arms itself.
  local settled = claimant.finish(claimed, true, nil, { now = T0 + 3603 })
  check(settled.status == 'delivered', 'the settled wake is delivered: ' .. json.encode(settled))
  -- The subscription list survives as a set, not as JSON text the seam parses per call.
  local lists = claimant.schedule({ on = { 'a.*', 'message' }, reason = 'sets', now = T0 }, seam_ctx)
  check(lists.ok and #lists.wake.on == 2, 'the subscriptions are a list, not a document: ' .. json.encode(lists))
end

------------------------------------------------------------------ no silent fallback, and a cost
if seam then
  check(#seam_log == 0, 'no fallback line was logged while the component answered: ' .. tostring(seam_log[1]))
  local function median(values)
    table.sort(values)
    return values[math.floor(#values / 2) + 1]
  end
  local function bench(fn)
    fn() -- warm
    local samples = {}
    for index = 1, 15 do
      local started = host.monotonic_ms()
      fn()
      samples[index] = host.monotonic_ms() - started
    end
    return median(samples)
  end
  for _, case in ipairs({
    { name = 'notes_read', native = function() return native.notes_read({}, native_ctx) end, seam = function() return seam.notes_read({}, seam_ctx) end },
    { name = 'summary', native = function() return native.summary(s_native) end, seam = function() return seam.summary(s_seam) end },
    { name = 'list', native = function() return native.list({}, native_ctx) end, seam = function() return seam.list({}, seam_ctx) end },
  }) do
    print(string.format('bench %-16s native %5.1f ms   component %5.1f ms', case.name, bench(case.native), bench(case.seam)))
  end
end

local parity = (reachable and seam) and 'ran' or 'SKIPPED'
print(string.format('selfloop seam: %d checks, %d parity comparisons (%s), %d skipped', checks, comparisons, parity, skipped))
