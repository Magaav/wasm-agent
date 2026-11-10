-- A master starts a session on a peer and follows it read-only (lua/core/session_watch.lua,
-- docs/SESSION-WATCH.md), without a second machine and without a deploy.
--
-- What is exercised, and by what:
--   * `start` is the real module: it writes the session row, resolves this node's own binary and asks
--     the operation manager to run it. `host.operation` is the one piece replaced, because the point
--     here is the receipt and the durability, not spawning a process that needs a model to answer.
--     The live run against a real peer is a separate, measured check (docs/SESSION-WATCH.md, "Live").
--   * `watch` is the real module over a real scratch ledger: the transcript, the run, the waiting
--     wake and the operation receipt it projects are the rows the node itself writes.
--   * the gate is the real `wa_node_call`: server.lua is loaded with the enrollment module replaced
--     (a managed node needs a registry on the network to answer), and every refusal below is made by
--     the shipped code.
-- Hermetic: scratch home and ledger (scripts/fast.sh gives each test its own), no network.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local memory = dofile('lua/core/memory.lua')
memory.setup()
local selfloop = dofile('lua/core/selfloop.lua')
selfloop.setup()

local checks = 0
local function ok(value, label)
  checks = checks + 1
  if not value then error('SESSION-WATCH CHECK FAILED: ' .. label .. '\n' .. debug.traceback(), 2) end
end
local function eq(got, want, label)
  ok(got == want, label .. ' (got ' .. tostring(got) .. ', want ' .. tostring(want) .. ')')
end

local session_watch = dofile('lua/core/session_watch.lua')
local identity = json.decode(host.node_identity())
ok(type(identity) == 'table' and identity.node_id and identity.public_key, 'this node has an identity')
local binary = (json.decode(host.runtime_info()) or {}).binary_path

-- ---- the operation manager, replaced -------------------------------------------------------------
-- `launches` is what `start` asked the host to run; `statuses` is what `watch` is told about it.
local real_operation = host.operation
local launches, statuses = {}, {}
host.operation = function(action, payload)
  local args = json.decode(payload or '{}') or {}
  if action == 'start' then
    launches[#launches + 1] = args
    return json.encode({ operation_id = 'op-fixture-' .. #launches, state = 'accepted', settled = false })
  end
  if action == 'status' then
    return json.encode(statuses[args.id] or { error = 'unknown_operation' })
  end
  if action == 'list' then return json.encode({ operations = {} }) end
  return json.encode({ error = 'unexpected_operation_action:' .. tostring(action) })
end

local master = { role = 'master', node_id = 'peer-work', name = 'work' }
local guest = { role = 'guest', node_id = 'peer-mail', name = 'mail' }
local cwd = paths.data()
-- The directory is stored and reported in the one form the repo uses for paths its own tools join
-- (`lua/core/tools.lua` resolves relative paths against it), so a Windows caller's backslashes arrive
-- as slashes. The test asserts the normalised form on purpose: that is the value the ledger holds.
local cwd_form = (cwd:gsub('\\', '/'))

-- ---- start: an id at once, and a run that outlives the call ---------------------------------------
local receipt = session_watch.serve('start', { prompt = 'say ok', cwd = cwd, title = 'fixture run' }, master)
ok(receipt.ok == true, 'start answers ok: ' .. json.encode(receipt))
ok(type(receipt.session_id) == 'string' and #receipt.session_id > 0, 'start returns a session id at once')
eq(receipt.started, true, 'the receipt says a run was launched')
eq(receipt.operation_id, 'op-fixture-1', 'the receipt names the supervised operation')
eq(receipt.run_recorded, true, 'the node can still say which operation runs this session')
eq(#launches, 1, 'exactly one process was launched')
local spec = launches[1]
eq(spec.program, binary, 'the node runs its own binary, not one found on PATH')
eq(table.concat(spec.args, ' '), 'chat --session ' .. receipt.session_id .. ' say ok', 'the run is the measured workaround, supervised')
eq(spec.cwd, cwd_form, 'the run starts in the directory the caller asked for')
eq(spec.owner, 'session:' .. receipt.session_id, 'the operation is owned by the session')
ok(type(memory.session(receipt.session_id)) == 'table', 'the session is a ledger row before the run starts')
eq(memory.session_worktree(receipt.session_id), cwd_form, 'tools resolve their paths against the requested directory')
eq(memory.message_count(receipt.session_id), 0, 'start does not wait for the run: nothing has run yet')
eq(memory.session(receipt.session_id).objective, 'remote', 'a peer-started session is not this node\'s default thread')

-- A session id the caller chose comes back unchanged: no round trip in which the node could answer
-- "started" and hand back something else.
local named = session_watch.serve('start', { prompt = 'second', session_id = 'chosen-session-id' }, master)
eq(named.session_id, 'chosen-session-id', 'a caller-chosen session id is the id the node stores')
eq(memory.session('chosen-session-id').id, 'chosen-session-id', 'and it is the row the ledger answers with')
-- The exclusion is real: a local `wa chat` asking for the newest open thread does not adopt it.
ok(memory.ensure_session('work', memory.session('chosen-session-id').node_id, 'chat') ~= 'chosen-session-id',
  'a remote-started session is not adopted as the newest local thread')

-- ---- start: refusals before anything is written --------------------------------------------------
local before = #launches
eq(session_watch.serve('start', {}, master).error, 'session_prompt_required', 'a prompt is required')
eq(session_watch.serve('start', { prompt = 'x', cwd = cwd .. '/no-such-directory' }, master).error,
  'session_cwd_not_a_directory', 'a directory that is not there is refused, not guessed')
eq(session_watch.serve('start', { prompt = 'x', cwd = 'relative/dir' }, master).error,
  'session_cwd_must_be_absolute', 'a relative directory is refused: a remote caller cannot mean it')
eq(session_watch.serve('start', { prompt = 'x', session_id = receipt.session_id }, master).error,
  'session_id_in_use', 'an id that already has a session is refused')
eq(session_watch.serve('start', { prompt = 'x', timeout_seconds = 0 }, master).error,
  'session_timeout_out_of_range', 'the execution budget is bounded')
eq(#launches, before, 'a refused start launches nothing')

-- The handler refuses a guest by itself, not only at the gate (a mesh-attested call arrives with a
-- role the roster decided, and this must not inherit it by accident).
local refused = session_watch.serve('start', { prompt = 'x' }, guest)
eq(refused.error, 'session_capability_requires_master', 'a guest cannot start a session')
eq(refused.effect, 'none', 'the refusal names its effect')
eq(session_watch.serve('watch', { session_id = receipt.session_id }, guest).error,
  'session_capability_requires_master', 'a guest cannot watch either')
eq(session_watch.serve('nonsense', {}, master).error, 'unknown_session_action', 'an unknown action is named, not guessed')

-- A launch that the host refuses closes the session instead of leaving it looking live.
host.operation = function(action)
  if action == 'start' then return json.encode({ error = 'program_not_found_on_path' }) end
  return json.encode({ error = 'unknown_operation' })
end
local failed = session_watch.serve('start', { prompt = 'x' }, master)
eq(failed.error, 'session_start_failed', 'a launch the host refuses is reported, not swallowed')
ok(failed.session_id and memory.session(failed.session_id) ~= nil, 'the refused start still names the session it closed')
ok(memory.session(failed.session_id).ended_at ~= nil and memory.session(failed.session_id).ended_at > 0,
  'and that session is closed, so it never reads as running')

-- ---- a finished run: the stream, the cursor and the tail -----------------------------------------
host.operation = function(action, payload)
  local args = json.decode(payload or '{}') or {}
  if action == 'start' then
    launches[#launches + 1] = args
    return json.encode({ operation_id = 'op-fixture-' .. #launches, state = 'accepted', settled = false })
  end
  if action == 'status' then return json.encode(statuses[args.id] or { error = 'unknown_operation' }) end
  if action == 'list' then return json.encode({ operations = {} }) end
  return json.encode({ error = 'unexpected_operation_action:' .. tostring(action) })
end

local session_id = memory.start_session('remote', 'remote', { user_id = 'work', node_id = 'here', title = 'fixture run' })
memory.append_turn(session_id, { role = 'user', content = 'say ok' })
memory.append_turn(session_id, { role = 'tool', tool_name = 'bash', ok = true, ms = 12,
  content = json.encode({ ok = true, stdout = 'ok\n' }) })
memory.append_turn(session_id, { role = 'tool', tool_name = 'read', ok = false, ms = 3,
  content = json.encode({ error = 'file_not_found' }) })
memory.append_turn(session_id, { role = 'assistant', content = 'ok', ms = 1500 })
memory.record_run('run-fixture', session_id, 'completed', 'answered', 'ok')

local full = session_watch.serve('watch', { session_id = session_id, after = 0 }, master)
eq(full.ok, true, 'watch answers ok')
eq(full.schema_version, 1, 'the stream carries its schema version')
local kinds = {}
for _, event in ipairs(full.events) do kinds[#kinds + 1] = event.kind end
eq(table.concat(kinds, ','), 'prompt,tool,tool,assistant,state', 'the stream is ordered: prompt, tools, answer, state')
eq(full.events[1].text, 'say ok', 'the prompt is an event')
eq(full.events[2].name, 'bash', 'a tool event names the tool')
eq(full.events[2].ok, true, 'and says it worked')
eq(full.events[3].name, 'read', 'a failed tool is still a tool event')
eq(full.events[3].ok, false, 'and says it failed')
eq(full.events[3].error, 'file_not_found', 'with the failure the tool itself reported')
eq(full.events[4].text, 'ok', 'the assistant answer is the text a follower reads')
eq(full.events[5].state, 'ended', 'the tail says the run ended')
eq(full.events[5].outcome, 'completed', 'and names the outcome the ledger recorded')
eq(full.done, true, 'done is the one statement that the run ended')
eq(full.next_cursor, full.events[4].cursor, 'the cursor is the transcript position, not the event count')

-- A mid cursor returns the same tail: the suffix of the full stream after that cursor, including the
-- same tail state. Compared without `at`, which is the read-time clock by design.
local function strip(events)
  local out = {}
  for _, event in ipairs(events) do
    local copy = {}
    for key, value in pairs(event) do if key ~= 'at' then copy[key] = value end end
    out[#out + 1] = copy
  end
  return json.encode(out)
end
local mid = full.events[2].cursor
local tail = session_watch.serve('watch', { session_id = session_id, after = mid }, master)
local expected = {}
for _, event in ipairs(full.events) do if (event.cursor or 0) > mid then expected[#expected + 1] = event end end
eq(#tail.events, #expected, 'a mid cursor returns exactly the events after it')
eq(strip(tail.events), strip(expected), 'and it is the same tail, event for event')
eq(tail.next_cursor, full.next_cursor, 'both reach the same cursor')
eq(tail.done, true, 'both say the run ended')

-- Paging: one event at a time reassembles the same stream in the same order, and no page claims the
-- run is over while it is still reading.
local pages, cursor, guard = {}, 0, 0
while true do
  local page = session_watch.serve('watch', { session_id = session_id, after = cursor, limit = 1 }, master)
  guard = guard + 1
  ok(guard < 20, 'paging terminates')
  eq(page.has_more or page.done, true, 'a page either has more or is done')
  if page.has_more then eq(page.events[1].kind == 'state', false, 'a page with more does not append the tail') end
  for _, event in ipairs(page.events) do pages[#pages + 1] = event end
  cursor = page.next_cursor
  if page.done then break end
end
eq(strip(pages), strip(full.events), 'paging from cursor 0 reassembles the same stream')

-- A cursor past the end is not an error: it returns no events and the same tail.
local beyond = session_watch.serve('watch', { session_id = session_id, after = 999 }, master)
eq(#beyond.events, 1, 'a cursor past the end returns the tail alone')
eq(beyond.events[1].kind, 'state', 'and that tail is the state event')
eq(beyond.next_cursor, full.next_cursor, 'and it answers with the session\'s real head, so the next call reads from the data')

-- ---- waiting: a wake, and a deploy continuation, are the same durable row ------------------------
local wake = selfloop.schedule({ reason = 'deploy queued: fixture', in_seconds = 600 },
  { user_id = 'work', session_id = session_id, role = 'master' })
ok(type(wake) == 'table' and wake.ok == true and type(wake.wake) == 'table', 'a wake was scheduled: ' .. json.encode(wake or {}))
local waiting = session_watch.serve('watch', { session_id = session_id, after = full.next_cursor }, master)
eq(waiting.events[#waiting.events].state, 'waiting', 'a session with a pending wake is waiting, not ended')
eq(waiting.events[#waiting.events].waiting.kind, 'deploy', 'the deploy continuation is named from its own reason')
eq(waiting.done, false, 'waiting is not done')
eq(waiting.events[#waiting.events].witness, 'wake', 'and it says which fact it is resting on')
local cancelled = selfloop.cancel({ id = wake.wake.id }, { user_id = 'work', session_id = session_id, role = 'master' })
ok(cancelled.ok == true, 'the fixture wake was cancelled: ' .. json.encode(cancelled or {}))
local settled = session_watch.serve('watch', { session_id = session_id, after = 0 }, master)
eq(settled.done, true, 'cancelling the wake returns the session to its recorded outcome')

-- ---- the replaced node: the same events, an honest outcome --------------------------------------
-- The operation is unknown to this process (a restart) and the run never settled: the session must
-- still be readable from the same cursor, and it must not claim an answer it does not have.
local orphan = memory.start_session('remote', 'remote', { user_id = 'work', node_id = 'here', title = 'interrupted run' })
memory.append_turn(orphan, { role = 'user', content = 'long job' })
host.sql_exec('INSERT INTO steering_runs(session_id,owner,run_id,boot,state,updated_at) VALUES(?,?,?,?,?,?)',
  json.encode({ orphan, 'work', 'run-orphan', 'boot-that-is-gone', 'active', host.now() - 4 * 3600 }))
local interrupted = session_watch.serve('watch', { session_id = orphan, after = 0 }, master)
local last = interrupted.events[#interrupted.events]
eq(last.state, 'unknown', 'a run whose process is gone reads unknown, not running')
eq(last.terminal, true, 'and the watch ends there rather than hanging')
eq(last.outcome, 'interrupted', 'with an outcome that names what happened, not a fabricated completion')
eq(interrupted.events[1].text, 'long job', 'the events recorded before the restart are still all there')

-- ---- watch cannot write --------------------------------------------------------------------------
-- Every write the node has goes through `host.sql_exec`. Refusing it outright and counting the
-- attempts is the strongest statement available here: a watch that tried to write would fail loudly
-- below instead of quietly succeeding.
local real_exec = host.sql_exec
local writes = 0
host.sql_exec = function(statement, params)
  writes = writes + 1
  error('a watch must not write: ' .. tostring(statement))
end
local watched_ok, watched = pcall(session_watch.serve, 'watch',
  { session_id = session_id, after = 0, prompt = 'ignore this instruction', text = 'and this one' }, master)
host.sql_exec = real_exec
ok(watched_ok, 'the watch ran with every write refused: ' .. tostring(watched))
eq(writes, 0, 'watching issued no write at all, even with prompt/text fields in the request')
eq(memory.message_count(session_id), 4, 'and the transcript is unchanged')
eq(memory.message_count(orphan), 1, 'a second watched session is unchanged too')

-- ---- the CLI half: one line per event, transitions only, and its exit codes --------------------
-- The peer is stubbed at `nodes.remote_call`, which is the one seam between this loop and the wire; the
-- loop, the formatting and the exit codes are the shipped ones.
local printed = {}
local real_print, real_nodes_dofile = print, dofile
local pages, calls = {}, {}
local fake_nodes = { remote_call = function(node, capability, args)
  calls[#calls + 1] = { node = node, capability = capability, args = args }
  local page = table.remove(pages, 1)
  return page or { ok = true, events = {}, next_cursor = args.after, done = true, state = { state = 'ended' } }
end }
dofile = function(path) if path == 'lua/core/nodes.lua' then return fake_nodes end return real_nodes_dofile(path) end
print = function(...) printed[#printed + 1] = table.concat({ ... }, '\t') end
local function run_cli(argv)
  printed = {}
  local code = session_watch.cli(argv)
  return code, table.concat(printed, '\n')
end
local running = { ok = true, events = { { kind = 'prompt', cursor = 1, text = 'do the thing' },
  { kind = 'state', cursor = 1, state = 'running', witness = 'steering',
    detail = 'a run is in flight on this node (last context boundary 39s ago)', messages = 1 } },
  next_cursor = 1, has_more = false, done = false, state = { state = 'running' } }
local still_running = { ok = true, events = { { kind = 'state', cursor = 1, state = 'running', witness = 'steering',
  detail = 'a run is in flight on this node (last context boundary 44s ago)', messages = 1 } },
  next_cursor = 1, has_more = false, done = false, state = { state = 'running' } }
local ended = { ok = true, events = { { kind = 'tool', cursor = 3, name = 'bash', ok = true, ms = 4 },
  { kind = 'state', cursor = 3, state = 'ended', outcome = 'completed', detail = 'answered', messages = 3 } },
  next_cursor = 3, has_more = false, done = true, state = { state = 'ended', outcome = 'completed', messages = 3 } }
pages = { running, still_running, ended }
local code, output = run_cli({ 'watch', 'peer', 'sid-1' })
eq(code, 0, 'the CLI exits 0 when the run ends')
ok(output:find('1 prompt do the thing', 1, true) ~= nil, 'the prompt is one line: ' .. output)
ok(output:find('3 tool bash ok 4ms', 1, true) ~= nil, 'the tool line names the tool and its outcome')
ok(output:find('3 state ended outcome=completed', 1, true) ~= nil, 'the end is a line with its outcome')
eq(select(2, output:gsub('state running', '')) , 1, 'a repeated state is printed once, not once per poll, even when its age changes')
ok(output:find('wa watch: sid-1 ended (completed) after 3 message(s)', 1, true) ~= nil, 'the closing line says what ended: ' .. output)
eq(#calls, 3, 'a full run took three pages')
eq(calls[1].capability, 'session_watch', 'the CLI calls the read-only capability')
eq(calls[1].args.action, 'watch', 'and never the start action')
eq(calls[1].args.wait_ms, 5000, 'it long-polls briefly instead of asking every second')
-- A cursor is passed through, which is what makes `--from` resume rather than replay.
printed, pages = {}, { ended }
local resumed = session_watch.cli({ 'watch', 'peer', 'sid-1', '--from', '2' })
eq(resumed, 0, 'a resumed watch exits 0 too')
eq(calls[#calls].args.after, 2, '--from is the cursor the peer is asked from')
-- A refusal is a refusal, not a hang: the peer's own word is printed and the exit code says failed.
pages = { { error = 'capability_not_granted' } }
local refused = run_cli({ 'watch', 'peer', 'sid-1' })
eq(refused, 1, 'a peer refusal exits 1')
ok(refused ~= 0 and printed[1]:find('capability_not_granted', 1, true) ~= nil, 'and names the refusal')
-- Usage is refused before any peer is called.
calls = {}
local before_usage = #calls
eq(run_cli({ 'watch' }), 2, 'a missing node and session is a usage error')
eq(run_cli({ 'watch', 'peer', 'sid', '--from', 'x' }), 2, 'a cursor that is not a number is a usage error')
eq(#calls, before_usage, 'neither usage error reached the network')

-- A watch that has not ended says so, names the cursor to resume from, and exits 3 - distinct from
-- a refusal (1) and from usage (2), so a script can tell "not finished yet" from "failed".
pages = {}
local function never_ending() return { ok = true, events = { { kind = 'state', cursor = 7, state = 'running', witness = 'steering',
  detail = 'still going', messages = 7 } }, next_cursor = 7, has_more = false, done = false, state = { state = 'running' } } end
fake_nodes.remote_call = function(node, capability, args)
  calls[#calls + 1] = { node = node, capability = capability, args = args }
  return never_ending()
end
local timed = run_cli({ 'watch', 'peer', 'sid-1', '--timeout', '1' })
ok(timed == 3, 'a watch still running at its deadline exits 3 (got '..tostring(timed)..': '..table.concat(printed,' | ')..')')
ok(printed[#printed]:find('re-run with --from 7', 1, true) ~= nil, 'and says where to resume: ' .. tostring(printed[#printed]))
print, dofile = real_print, real_nodes_dofile

-- ---- the gate: the managed allowlist and the caller's role ---------------------------------------
-- The real `wa_node_call`, with the one module that needs a registry replaced. A call is signed with
-- this node's own identity, so the gate verifies it exactly as it verifies a peer.
local real_dofile = dofile
local seen = {}
local role_for = {}
local enrollment_stub = {
  managed = function() return true end,
  target = function() return true end,
  caller = function(id, key)
    return { node_id = id, public_key = key, role = role_for[id] or 'guest', name = id }
  end,
  author = function(caller) return caller and caller.node_id or nil end,
  role = function() return 'master' end,
  seen_before = function(id)
    if seen[id] then return true end
    seen[id] = true
    return false
  end,
  audit = function() end,
}
dofile = function(path) if path == 'lua/core/enrollment.lua' then return enrollment_stub end return real_dofile(path) end
real_dofile('lua/core/server.lua')
dofile = real_dofile
ok(type(wa_node_call) == 'function', 'server.lua defines the peer gate')

local nonce = 0
local function call(capability, args)
  nonce = nonce + 1
  args = args or {}
  args.nonce = nonce
  local body = json.encode({ to_node_id = identity.node_id, capability = capability, args = args })
  local ts = math.floor(host.now())
  local signature = json.decode(host.sign('call|' .. identity.node_id .. '|' .. ts .. '|' .. host.sha256(body))).signature
  local signed = json.decode(wa_node_call(body, identity.node_id, identity.public_key, ts, signature))
  -- A refusal before dispatch is answered unsigned (`{error=...}`); a reply that ran is signed. Both
  -- shapes are facts about the gate, so both are returned rather than crashing the test.
  if type(signed) ~= 'table' or signed.reply == nil then return signed end
  return json.decode(signed.reply), signed.reply_sig
end
role_for[identity.node_id] = 'master'
local function gate(capability, args) return (call(capability, args)) end

-- A master reaches both capabilities: the allowlist names them, so the gate admits them and the
-- module answers for them (an unknown session is the module's answer, not the gate's refusal).
local watched_by_peer = gate('session_watch', { session_id = 'no-such-session' })
eq(watched_by_peer.error, 'unknown_session', 'a master\'s watch reaches the module through the managed gate')
local started_by_peer = gate('session_start', { prompt = 'from the peer', cwd = cwd })
eq(started_by_peer.ok, true, 'a master\'s start reaches the module through the managed gate')
ok(type(started_by_peer.session_id) == 'string' and memory.session(started_by_peer.session_id) ~= nil,
  'and the session it names is in the ledger')

-- `operation`, restored: the managed list names it, and the fallthrough dispatches the master-only
-- tool. This is the call that answered `capability_not_granted` on a bound node (2026-11-10).
local operated = gate('operation', { action = 'list' })
ok(operated.error == nil and type(operated.operations) == 'table',
  'a master\'s operation call is admitted by the managed list: ' .. json.encode(operated))
-- Control: a capability the list does not name is still refused, so the two checks above are the
-- list's decision and not a gate that admits everything.
eq(gate('hooks', {}).error, 'capability_not_granted', 'a capability the list does not name is refused')

-- A guest never reaches any of it: the gate refuses the caller before the capability is considered.
role_for[identity.node_id] = 'guest'
eq(gate('session_start', { prompt = 'x' }).error, 'forbidden_role', 'a guest\'s start is refused at the gate')
eq(gate('session_watch', { session_id = session_id }).error, 'forbidden_role', 'a guest\'s watch is refused at the gate')
eq(gate('operation', { action = 'list' }).error, 'forbidden_role', 'a guest\'s operation call is still refused')
role_for[identity.node_id] = 'master'

host.operation = real_operation
print(string.format('session-watch: %d checks passed', checks))
