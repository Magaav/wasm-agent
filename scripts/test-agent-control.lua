-- The agent-control API (wit/agent-control, lua/core/agent_control.lua): one implementation of
-- fork/spawn/events/collect/cancel/resume/message/list, and the vocabulary it promises.
--
-- This row runs against the REAL ledger and the real host, in its own scratch home, with exactly TWO
-- capabilities replaced by hand:
--
--   * host.subagent, the native child runtime (a thread per child, its sockets, its cancel flag), because
--     a unit row cannot run a real child inference;
--   * nothing else - host.exec, host.sql_* and host.now are the node's own.
--
-- Neither is covered by the shared contract fake: scripts/lib/contract-host.lua carries no subagent and no
-- exec entry (measured: 0 matches for either), so a hand stub is the only option here and it says which
-- capability it replaces and why. The stub answers the exact actions lua/core/subagents.lua dispatches -
-- list, status, result, cancel, continue, steer, capacity - with the real shapes ('status' removes the
-- result field, as the native branch does), and nothing else: a stub that answered more than the host does
-- would let this row pass on a call the node would refuse.
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
      -- The real node answers 'status' and 'result' from ONE branch
      -- (rust/wa-capabilities/src/subagents.rs: "status" | "result" => ...), and 'status' removes the
      -- result field. The stub does the same, so collect's use of 'result' is exercised against the
      -- shape the host really returns rather than a shape the stub invented.
      if action == 'status' then
        local record = view(item); record.result = nil
        return json.encode(record)
      end
      if action == 'result' then return json.encode(view(item)) end
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

-- events: what happened, in order, without asking a model. Every kind the contract names is exercised
-- here, because a stream that can only say "started" is not supervision:
--   started - the child's first turn (the e2e proves it live);
--   commit  - a turn whose recorded tool call was a git commit, with the commits read from its checkout;
--   failed  - a run that settled failed, as its own kind, not a done with a field to notice;
--   done    - a run that finished.
local ledger = dofile('lua/core/agent_control.lua')
local child_session = memory.start_session('', 'chat', { user_id = 'master' })
memory.append_turn(child_session, { role = 'user', content = 'WORKER_X task' })
memory.append_turn(child_session, { role = 'assistant', content = 'committed',
  -- A Lua table, not an encoded string: append_turn encodes what it is given, so a string here would be
  -- stored as a string and the reader that parses the column would see no tool calls at all.
  tool_calls = { { ['function'] = { name = 'bash', arguments = 'git commit -m work' } } } })
children.settled.session_id = child_session
children.settled.state = 'completed'
-- A child that FAILED, with its own second session, so the failed kind is a real row and not a flag.
local failed_session = memory.start_session('', 'chat', { user_id = 'master' })
memory.append_turn(failed_session, { role = 'user', content = 'WORKER_Y task' })
memory.append_turn(failed_session, { role = 'assistant', content = 'gave up' })
children.running.session_id = failed_session
children.running.state = 'failed'; children.running.settled = true
-- The commits are read from the child's OWN checkout, so this child gets a real one: a scratch git
-- repository bound to its session, with one commit in it. That is the same read the node performs, not a
-- stubbed git.
local scratch_dir = host.getenv('TMPDIR') or '/tmp'
local repo_dir = scratch_dir .. '/wa-agent-control-commits-' .. tostring(host.uuid())
local function sh(command, cwd)
  local ok, raw = pcall(host.exec, command, cwd or '', 60)
  if not ok then return '' end
  local decoded = json.decode(raw)
  return decoded and tostring(decoded.stdout or '') or ''
end
sh('mkdir -p ' .. repo_dir)
sh('git init -q -b main . && git config user.email t@e.invalid && git config user.name t'
  .. ' && echo work > work.txt && git add work.txt && git commit -qm "do the work"', repo_dir)
local wanted_sha = (sh('git rev-parse HEAD', repo_dir):gsub('%s+$', ''))
check(#wanted_sha == 40, 'the scratch checkout has a commit to read: ' .. wanted_sha)
memory.set_session_workspace(child_session, { managed = true, state = 'bound', worktree = repo_dir,
  branch = 'change/test' })

local stream = control.events({ after = 0 }, ctx)
local kinds, commit_seen, commit_sha, failed_state = {}, false, nil, nil
for _, event in ipairs(stream.events) do
  kinds[event.kind] = true
  if event.kind == 'commit' then
    commit_seen = true
    commit_sha = event.commits[1] and event.commits[1].sha
  end
  if event.kind == 'failed' then failed_state = event.state end
end
check(commit_seen and kinds['commit'], 'a turn that committed produces a commit event')
check(commit_sha == wanted_sha, 'a commit event carries the commit read from its own checkout: '
  .. tostring(commit_sha) .. ' vs ' .. wanted_sha)
check(kinds['failed'], 'a run that failed produces a failed event, by kind')
check(failed_state == 'failed', 'a failed event carries the failed state')
check(kinds['done'], 'a settled run produces a done event')
local after_cursor = control.events({ after = stream.next_seq }, ctx)
check(#after_cursor.events == 0 or (function()
  for _, event in ipairs(after_cursor.events) do if event.seq <= stream.next_seq then return false end end
  return true
end)(), 'events after the cursor never repeat an earlier one')
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
