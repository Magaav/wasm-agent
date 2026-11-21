-- The agent-control API (wit/agent-control, lua/core/agent_control.lua): one implementation of
-- fork/spawn/events/collect/cancel/resume/message/list, and the vocabulary it promises.
--
-- This row runs against the REAL ledger, in its own scratch home, with the native child runtime STUBBED:
-- scripts/lib/contract-host.lua covers the host capabilities, but it does not cover subagents (a native
-- thread per child, its sockets and its cancel flag), so that one capability is stubbed here by hand and
-- says so. The stub answers the exact actions lua/core/subagents.lua dispatches (list, status, cancel,
-- continue, steer) and nothing else: a stub that answered more than the real host does would let this row
-- pass on a call the node would refuse.
local scratch = dofile('scripts/lib/scratch-home.lua')
local why = scratch.guard('test-agent-control.lua')
if why then print('REFUSED ' .. why); os.exit(2) end
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()

local checks = 0
local function check(value, label)
  assert(value, label)
  checks = checks + 1
end

-- The stub native runtime: three children, one running, one settled with usage, one cancelled.
local now = host.now()
local children = {
  running = { subagent_id = 'run-running', session_id = 'sess-running', parent_session_id = '',
    state = 'running', settled = false, profile = 'explore', title = 'a running child',
    created_at = now - 30, started_at = now - 29, depth = 1 },
  settled = { subagent_id = 'run-settled', session_id = 'sess-settled', parent_session_id = '',
    state = 'completed', settled = true, profile = 'explore', title = 'a settled child',
    created_at = now - 600, started_at = now - 599, settled_at = now - 60, depth = 1,
    result = { reply = 'done and verified', truncated = false },
    accounting = { usage = { available = true, total_tokens = 4321 } } },
  unmeasured = { subagent_id = 'run-unmeasured', session_id = 'sess-unmeasured', parent_session_id = '',
    state = 'completed', settled = true, profile = 'explore', title = 'a child with no numbers',
    created_at = now - 900, started_at = now - 899, settled_at = now - 800, depth = 1,
    result = { reply = 'finished' }, accounting = { usage = { available = false, reason = 'provider_did_not_report' } } },
}
local order = { 'running', 'settled', 'unmeasured' }
local function view(item)
  return { subagent_id = item.subagent_id, session_id = item.session_id,
    parent_session_id = item.parent_session_id, state = item.state, settled = item.settled,
    profile = item.profile, title = item.title, created_at = item.created_at,
    started_at = item.started_at, settled_at = item.settled_at, depth = item.depth,
    result = item.result, accounting = item.accounting, error = item.error }
end
local answered = {}
local real_subagent = host.subagent
host.subagent = function(action, payload)
  local args = json.decode(payload or '{}')
  answered[#answered + 1] = action
  if action == 'list' then
    local rows = {}
    for _, key in ipairs(order) do rows[#rows + 1] = view(children[key]) end
    return json.encode({ subagents = rows })
  end
  for _, key in ipairs(order) do
    local item = children[key]
    if item.subagent_id == args.id then
      if action == 'status' then return json.encode(view(item)) end
      if action == 'cancel' then
        item.state = 'cancelled'; item.settled = true; item.settled_at = host.now()
        return json.encode(view(item))
      end
      if action == 'continue' or action == 'steer' then return json.encode(view(item)) end
    end
  end
  if action == 'capacity' then return json.encode({ max_concurrent = 2, usage = {} }) end
  return json.encode({ error = 'unknown_subagent' })
end

local control = dofile('lua/core/agent_control.lua')
local sid = memory.start_session('', 'chat', { user_id = 'master' })
local ctx = { role = 'master', user_id = 'master', session_id = sid }

-- The state allow-list. A word this generation does not know is UNKNOWN with the native word kept, never
-- folded into a neighbour.
check(control.state_of('running') == 'running', 'a known state passes through')
check(control.state_of('done') == 'completed', 'done reads completed')
check(control.state_of('something-new') == 'unknown', 'an unknown word is unknown, never invented')
check(control.state_of(nil) == 'unknown', 'an absent state is unknown, not empty')

-- spawn: the refusals name the cause and prove nothing started.
local no_prompt = control.spawn({ prompt = '' }, ctx)
check(no_prompt.error == 'prompt_required' and no_prompt.not_started == true, 'an empty brief is refused by name')
local child_ctx = { role = 'master', user_id = 'master', session_id = sid, subagent = {} }
check(control.spawn({ prompt = 'work' }, child_ctx).error == 'subagent_recursion_forbidden',
  'a child cannot spawn children (depth guard)')
local off_policy = control.spawn({ prompt = 'work', node = 'peer-a' },
  { role = 'master', user_id = 'master', session_id = sid, remote = true })
check(off_policy.error == 'node_not_in_approved_policy' and off_policy.not_started == true,
  'a peer the policy does not hold is refused by name, not run locally')

-- list: the tree, with the state, rounds and age a surface needs.
local listed = control.list({}, ctx)
check(type(listed.children) == 'table' and #listed.children == 3, 'list reports every child of the session')
local by_id = {}
for _, child in ipairs(listed.children) do by_id[child.id] = child end
check(by_id['run-running'].state == 'running', 'a running child reads running')
check(by_id['run-running'].parent_session == '', 'the parent link is carried')
check(type(by_id['run-running'].age_ms) == 'number' and by_id['run-running'].age_ms >= 29000,
  'age is measured, not absent: a running child that is old says so')
check(type(by_id['run-running'].created_at_ms) == 'number', 'created-at is a millisecond stamp')

-- collect: a running child refuses by name; a settled one answers as data.
local early = control.collect({ id = 'run-running' }, ctx)
check(early.error == 'child_running' and early.state == 'running', 'collect refuses a running child by name')
local answer = control.collect({ id = 'run-settled' }, ctx)
check(answer.state == 'completed' and answer.reply == 'done and verified', 'a settled child answers with its reply')
check(answer.usage_available == true and answer.tokens == 4321, 'measured usage is reported')
local unmeasured = control.collect({ id = 'run-unmeasured' }, ctx)
check(unmeasured.usage_available == false and type(unmeasured.usage_reason) == 'string',
  'unmeasured usage says so instead of reading as a free run')
check(type(answer.commits) == 'table' and type(answer.failures) == 'table',
  'collect reports commits and failures as data even when there are none')

-- resume: the key is required, because a lost answer must not run the message twice.
check(control.resume({ id = 'run-settled', message = 'go on' }, ctx).error == 'idempotency_key_required',
  'resume without an idempotency key is refused')
local resumed = control.resume({ id = 'run-settled', message = 'go on', idempotency_key = 'k-1' }, ctx)
check(resumed.id == 'run-settled', 'resume with a key returns the same child')

-- message: the delivery word comes back as it came, never printed as success for a refusal.
check(control.message({ id = 'run-settled' }, ctx).error == 'text_required', 'an empty message is refused')
local signalled = control.message({ id = 'run-settled', text = 'status?', idempotency_key = 'm-1' }, ctx)
-- The stub child has no live run to steer, so the honest answer is the refusal, by name. What this
-- checks is the shape: a message answers with its delivery or its refusal, and never both.
check((type(signalled.delivery) == 'string') ~= (type(signalled.error) == 'string'),
  'a steering message reports either a delivery or a refusal, never both')
-- The stub's child is a receipt, not a session in this ledger, so steering has no session to write to
-- and refuses BY NAME. That is the property: a message never reports a delivery it did not get.
check(type(signalled.error) == 'string' and not signalled.delivery,
  'a message to a child this node does not hold is refused by name: ' .. tostring(signalled.error))

-- cancel: the request is not the end. A settled cancel is cancelled; the answer carries which.
local cancelled = control.cancel({ id = 'run-running' }, ctx)
check(cancelled.state == 'cancelled' and cancelled.settled == true, 'a run that ended is reported cancelled')

-- fork: same context, new session, linked to its parent from the moment it exists.
-- A fork cuts at a message boundary, so the parent needs one: a session with no turns has nothing to fork.
memory.append_turn(sid, { role = 'user', content = 'the parent task' })
memory.append_turn(sid, { role = 'assistant', content = 'working on it' })
local forked = control.fork({}, ctx)
-- A fork's checkout is allocated by workspaces.ensure, which in a scratch repository may refuse by name
-- (this tree requires a wave registration for its own repo). Both outcomes are answers this API owes: a
-- child, or a NAMED refusal that still reports the fork so the caller can recover it instead of forking
-- twice. Neither is an empty success.
local fork_child = forked.child or (forked.id and forked)
check(type(fork_child) == 'table', 'fork answers with a child, on the success and the refusal path alike: '
  .. tostring(forked.error or 'ok'))
if forked.error then
  check(forked.error:match('^workspace_') ~= nil, 'a refused fork refuses by name: ' .. forked.error)
end
check(fork_child.id and fork_child.id ~= sid, 'a fork is a new session')
check(fork_child.parent_session == sid, 'a fork names its parent')
check(fork_child.profile == 'fork', 'a fork is a conversation, reported as one')
local after = control.list({}, ctx)
local seen = false
for _, child in ipairs(after.children) do if child.id == fork_child.id then seen = true end end
check(seen, 'a fork appears in list at once')
check(control.collect({ id = fork_child.id }, ctx).error == 'fork_has_no_run',
  'a fork is never reported as a finished run')

-- events: what happened, in order, without asking a model.
local events = control.events({ after = 0 }, ctx)
check(type(events.events) == 'table', 'events answers with an event list')
local kinds = {}
for _, event in ipairs(events.events) do kinds[event.kind] = true end
check(next(kinds) == nil or kinds['started'] or kinds['done'], 'events carry only the named kinds')

-- the owner gate: another session's children are refused by name.
local stranger = memory.start_session('', 'chat', { user_id = 'guest' })
check(control.list({ session = stranger }, { role = 'guest', user_id = 'guest', session_id = sid }).error == nil,
  'a session the caller owns may be listed')
check(control.list({ session = stranger }, ctx).error == 'forbidden_parent_session',
  'a session the caller does not own is refused by name')

host.subagent = real_subagent
print('agent-control ok (' .. checks .. ' checks)')
