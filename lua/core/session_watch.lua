-- Start a session on a peer and follow it, without polling its database.
--
-- Measured 2026-11-10: an orchestrator on `work` had to supervise a session on another node and could
-- not, three times over. `wa call <peer> operation {...}` answered `capability_not_granted` once the
-- peer was bound (the managed allowlist in `lua/core/server.lua` does not name `operation`; it was
-- never named there - the call worked on 2026-11-04 because the peer was not bound yet, and binding
-- is what switches `enrollment.managed()` on). There was no way to start a session on a peer and get
-- its id back, so it took a Windows scheduled task running `wa chat "<prompt>"` with its output in a
-- file. There was no way to follow that session, so it took a python script reading `memory.db`
-- every minute over `wa call ... bash`.
--
-- This module is the two things that were missing, built from what the node already keeps:
--
--   start : one `sessions` row with an id chosen *before* the run starts, then one supervised
--           operation (`rust/wa-operation`, `lua/core/tools.lua`'s `operation`) running
--           `wa chat --session <id> <prompt>` in the requested directory. The receipt returns the
--           session id at once; the run outlives the call because an operation is not the call.
--   watch : a read-only projection of that session's durable events - the transcript the node
--           already writes (`messages`, one row per stored turn), the tail state it already derives
--           (`memory.session_state`), the run in flight it already records (`steering_runs`), the
--           pending wake it already stores (`self_wakes`, which is also where a settle deploy's
--           continuation lives), and the operation receipt. Ordered by the transcript's own `seq`
--           and resumable from that cursor, so a watcher that lost its connection re-reads nothing
--           and misses nothing.
--
-- Watching cannot write. The watch path issues queries only: it never dispatches a tool, never
-- appends a message, never moves a cursor, never schedules a wake and never touches the operation's
-- state. `scripts/test-session-watch.lua` proves it by refusing every `host.sql_exec` during a watch
-- and asserting the ledger is byte-identical afterwards.
--
-- Authority is the node's existing one (`docs/MESH.md`, `lua/core/nodes.lua` `author_of`): both
-- capabilities are master-only, refused here as well as at the peer gate, and neither is classified
-- in `MESH_VERBS`, so a mesh attestation grades them `call` - the strongest grant - rather than
-- inheriting a weaker verb. A guest is refused twice: at admission (`forbidden_role`) and here.
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua')
local users = dofile('lua/core/users.lua')
local nodes = dofile('lua/core/nodes.lua')
local platform = dofile('lua/core/platform.lua')

local M = {}

-- How much of one transcript row a watch page may carry. A single tool result can be megabytes
-- (`read` of a large file); a follow stream is lines of orientation, not the artifact, and the
-- artifact is already addressable (`tool_result`, `session`). Truncation is never silent: every
-- clipped event says `truncated=true` and `bytes=<full length>`.
local TEXT_LIMIT = 4000
local LINE_LIMIT = 300

-- One page per call. A watcher that fell a long way behind gets `has_more=true` and reads on; a
-- bounded page keeps one peer call from becoming a multi-megabyte reply.
local PAGE = 200

-- A run counts as alive without a live witness for this long. `steering_runs.updated_at` moves at
-- every context boundary, so this is a gap between boundaries, not the length of a run.
local LIVE_SECONDS = 90

-- A started run's process is supervised by the node (`host.operation`), and its execution budget is
-- what bounds it here. 1-86400 is the operation manager's own range.
local DEFAULT_RUN_SECONDS = 3600

local function trim(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- A monotonic millisecond clock. `host.monotonic_ms` is the one the host uses for every other
-- duration it reports; the wall clock is only a fallback so a missing capability cannot hang a wait.
local function now_ms()
  if host.monotonic_ms then return host.monotonic_ms() end
  return host.now() * 1000
end

local function decode(raw)
  if type(raw) ~= 'string' or raw == '' then return nil end
  local ok, value = pcall(json.decode, raw)
  return ok and type(value) == 'table' and value or nil
end

local function query(statement, params)
  local ok, raw = pcall(host.sql_query, statement, json.encode(params or {}))
  if not ok then return nil, tostring(raw) end
  local rows = decode(raw)
  if not rows and raw ~= nil then return nil, 'undecodable_result' end
  return rows or {}
end

-- The session row this node already keeps. `nil` means "there is no such session here", which is a
-- different answer from "it exists and has no events yet".
local function session_of(session_id)
  if type(session_id) ~= 'string' or session_id == '' then return nil end
  return memory.session(session_id)
end

local function clip(text, limit)
  text = tostring(text or '')
  if #text <= limit then return text, false, #text end
  return text:sub(1, limit), true, #text
end

-- One line, for a stream a reader follows in a terminal. Newlines become a visible marker rather
-- than splitting one event into several lines a watcher would have to re-join.
local function one_line(text, limit)
  local flat = tostring(text or ''):gsub('\r\n', '\n'):gsub('%s+$', ''):gsub('\n', ' \u{23ce} ')
  return clip(flat, limit)
end

local function first_line(text)
  local flat = tostring(text or ''):gsub('\r\n', '\n'):match('^[^\n]*') or ''
  return trim(flat)
end

-- ---------------------------------------------------------------- authority

-- Both capabilities are masters-only. `verify_peer` already refuses a caller whose role is not
-- master, and `nodes.author_of` refuses one that is not a master *for this node*; this is the third
-- check, in the handler, because a mesh-attested call is admitted by a roster decision that names a
-- verb and sets `role="master"` only after that decision, and a future caller of this module must not
-- inherit the capability by accident.
local function master_ctx(caller)
  if type(caller) ~= 'table' then return nil, { error = 'session_capability_requires_master', effect = 'none' } end
  if not users.is_master(caller.role) then
    return nil, { error = 'session_capability_requires_master', role = tostring(caller.role or ''), effect = 'none' }
  end
  local author = nodes.author_of(caller)
  if not author then return nil, { error = 'forbidden_role', effect = 'none' } end
  return {
    user_id = author,
    role = 'master',
    node_id = (nodes.identity() or {}).node_id or '',
    caller_node = tostring(caller.node_id or ''),
    remote = true,
  }
end

-- ---------------------------------------------------------------- start

-- The durable note that says which operation is running which session. It is a `meta` row, not a new
-- table: the ledger already has one place for a node-local fact that is not a conversation, and a
-- session-to-operation mapping is exactly that. Its absence after a restart is the honest answer
-- "this process did not start that run" - the watcher then says so instead of guessing.
local function run_key(session_id) return 'session.run.v1:' .. tostring(session_id) end

local function remember_run(session_id, record)
  local ok, raw = pcall(host.sql_exec, 'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    json.encode({ run_key(session_id), json.encode(record) }))
  -- Whether this node can still say which operation runs the session is a fact the caller has to be
  -- able to see: a watch that cannot name the process it started answers `unknown`, not `running`.
  return record, ok and (decode(raw) == nil or decode(raw).error == nil) or false
end

local function remembered_run(session_id)
  local rows = query('SELECT value FROM meta WHERE key=?', { run_key(session_id) })
  local row = rows and rows[1]
  return row and decode(row.value) or nil
end

-- The `wa` binary and its command line. `runtime_info().binary_path` is the executable this node is
-- *running*, which is the only answer that keeps a started session on the same build as the node that
-- started it: a PATH lookup could find an older install and run a session with code this node does
-- not have.
local function binary_path()
  local info = decode(host.runtime_info and host.runtime_info() or '') or {}
  local path = tostring(info.binary_path or '')
  if path == '' then return nil, 'node_binary_unknown' end
  return path
end

-- How a prompt becomes a run. `wa chat --session <id> <prompt>` is the same command an operator ran
-- by hand from a scheduled task (the measured workaround), so the shape is not new: what is new is
-- that the node names the session first, hands the id back before the run begins, and supervises the
-- process instead of redirecting its output to a file.
local function launch(spec)
  local ok, raw = pcall(host.operation, 'start', json.encode(spec))
  if not ok then return nil, tostring(raw) end
  local receipt = decode(raw)
  if not receipt then return nil, 'operation_receipt_unreadable' end
  if receipt.error then return nil, tostring(receipt.error) end
  if not receipt.operation_id then return nil, 'operation_receipt_without_id' end
  return receipt
end

function M.start(args, ctx)
  args = args or {}
  local prompt = trim(args.prompt)
  if prompt == '' then return { error = 'session_prompt_required', effect = 'none' } end
  if #prompt > 8000 then return { error = 'session_prompt_too_long', limit = 8000, effect = 'none' } end
  local cwd = tostring(args.cwd or '')
  if cwd ~= '' then
    -- Absolute only: a caller on another node cannot know this node's working directory, so a
    -- relative path here is a mistake that would silently run in the wrong tree. The directory is then
    -- checked before anything is written, because a run started in a directory that is not there does
    -- no work and reports its own failure as the prompt's.
    if not (cwd:match('^/') or cwd:match('^%a:[/\\]') or cwd:match('^\\\\')) then
      return { error = 'session_cwd_must_be_absolute', cwd = cwd, effect = 'none' }
    end
    cwd = (cwd:gsub('\\', '/'))
    if host.path_kind(cwd) ~= 'dir' then return { error = 'session_cwd_not_a_directory', cwd = cwd, effect = 'none' } end
  end
  local requested = tostring(args.session_id or '')
  if requested ~= '' and not requested:match('^[%w%-_]+$') then return { error = 'session_id_invalid', effect = 'none' } end
  if requested ~= '' and memory.session(requested) then return { error = 'session_id_in_use', session_id = requested, effect = 'none' } end

  local program, program_problem = binary_path()
  if not program then return { error = program_problem, effect = 'none' } end
  local seconds = math.floor(tonumber(args.timeout_seconds) or DEFAULT_RUN_SECONDS)
  if seconds < 1 or seconds > 86400 then return { error = 'session_timeout_out_of_range', range = '1-86400', effect = 'none' } end

  local id = requested ~= '' and requested or host.uuid()
  local title = trim(args.title)
  if title == '' then title = first_line(prompt) end
  if #title > 120 then title = title:sub(1, 120) end
  -- `route='remote'` with `objective='remote'`: a session another node started is not this node's
  -- default thread, so `memory.ensure_session` must not hand it to a local `wa chat` that asked for
  -- "the newest open thread" (`lua/core/memory.lua`). The id is chosen here, before the row exists,
  -- so the id the caller holds and the id the ledger stores are the same thing.
  memory.start_session('remote', 'remote', { id = id, user_id = ctx.user_id, node_id = nodes.node_name(), title = title })
  if cwd ~= '' then
    -- The directory the run works in is the session's, not this process's: every tool that resolves a
    -- relative path asks the session (`lua/core/tools.lua` `session_cwd`), and a watcher reads it back
    -- from the same row.
    memory.set_session_worktree(id, cwd)
  end
  local receipt, problem = launch({
    program = program,
    args = { 'chat', '--session', id, prompt },
    cwd = cwd ~= '' and cwd or platform.cwd(),
    timeout_seconds = seconds,
    owner = 'session:' .. id,
  })
  if not receipt then
    -- Nothing is running, so nothing may look like it is: the session exists and is closed with the
    -- reason, and the caller gets the failure rather than an id it cannot follow.
    memory.finish_session(id)
    return { error = 'session_start_failed', reason = tostring(problem), session_id = id, cwd = cwd, effect = 'none',
      note = 'no run was started; the session row is closed with this reason' }
  end
  local record, recorded = remember_run(id, {
    operation_id = tostring(receipt.operation_id or ''),
    program = program,
    cwd = cwd,
    prompt_sha256 = host.sha256(prompt),
    started_at = host.now(),
    started_by = ctx.user_id,
  })
  return {
    ok = true,
    session_id = id,
    node = nodes.node_name(),
    cwd = cwd,
    operation_id = record.operation_id,
    started_at = record.started_at,
    started = true,
    run_recorded = recorded,
    -- A launch receipt, not the run: the process was accepted. `watch` is where the outcome comes
    -- from, and `done` there is the only statement that it ended.
    note = 'a launch receipt, not completion: follow it with session_watch from cursor 0',
    watch = { capability = 'session_watch', session_id = id, cursor = 0 },
  }
end

-- ---------------------------------------------------------------- watch

-- One transcript row as one event. The event kinds are the ones a reader needs to follow work without
-- reading the artifacts: what was asked, what the assistant said, which tool ran and whether it
-- worked, and when the context was compacted.
local function message_event(row)
  local role = tostring(row.role or '')
  local at = tonumber(row.created_at) or nil
  local base = { cursor = tonumber(row.seq) or 0, at = at, seq = tonumber(row.seq) or 0, role = role }
  if role == 'user' then
    local text, truncated, bytes = one_line(row.content, TEXT_LIMIT)
    base.kind = 'prompt'
    base.text = text
    base.truncated, base.bytes = truncated, bytes
    return base
  end
  if role == 'assistant' then
    local content = tostring(row.content or '')
    if trim(content) == '' then
      -- A step that only called tools. It is not a silent gap: the tool events that follow are what
      -- happened, and an empty assistant event would be a line saying nothing.
      return nil
    end
    local text, truncated, bytes = one_line(content, TEXT_LIMIT)
    base.kind = 'assistant'
    base.text = text
    base.truncated, base.bytes = truncated, bytes
    base.ms = tonumber(row.ms) or nil
    return base
  end
  if role == 'tool' then
    base.kind = 'tool'
    base.name = tostring(row.tool_name or '')
    base.ok = (tonumber(row.ok) or 1) ~= 0
    base.ms = tonumber(row.ms) or nil
    if not base.ok then
      -- The failure, as the tool reported it: the `error` field of its own result when it has one,
      -- else the first line. Never the whole result - that is the artifact, not the event.
      local value = decode(row.content)
      local error = type(value) == 'table' and value.error or first_line(row.content)
      local text, truncated, bytes = one_line(error ~= nil and error or first_line(row.content), LINE_LIMIT)
      base.error = text
      base.truncated, base.bytes = truncated, bytes
    end
    return base
  end
  if role == 'summary' then
    local text, truncated, bytes = one_line(row.content, TEXT_LIMIT)
    base.kind = 'compacted'
    base.text = text
    base.truncated, base.bytes = truncated, bytes
    return base
  end
  base.kind = role ~= '' and role or 'message'
  local text, truncated, bytes = one_line(row.content, TEXT_LIMIT)
  base.text = text
  base.truncated, base.bytes = truncated, bytes
  return base
end

-- Is the run this node started still supervised? Answered by the operation manager, which is the one
-- witness that outlives the call that started it *within this process*: after a restart it does not
-- know the id any more, and that is reported as `unknown` rather than as a run that finished.
local function operation_state(record)
  if type(record) ~= 'table' or tostring(record.operation_id or '') == '' then return nil end
  local ok, raw = pcall(host.operation, 'status', json.encode({ id = record.operation_id }))
  if not ok then return nil end
  local state = decode(raw)
  if not state or state.error then return nil end
  state.live = state.state == 'accepted' or state.state == 'running' or state.state == 'draining'
  return state
end

-- The last run this session recorded (`runs`, written by `memory.record_run` at the end of a run).
local function last_run(session_id)
  local rows = query('SELECT id,run_id,status,outcome,reply,started_at,ended_at FROM runs WHERE session_id=? ORDER BY started_at DESC LIMIT 1', { session_id })
  local row = rows and rows[1]
  if not row then return nil end
  return { run_id = tostring(row.run_id or row.id or ''), status = tostring(row.status or ''),
    outcome = tostring(row.outcome or ''), reply_chars = #tostring(row.reply or ''),
    started_at = tonumber(row.started_at) or nil, ended_at = tonumber(row.ended_at) or nil }
end

-- The run in flight, as the node already records it for steering (`steering_runs`, `lua/core/steering.lua`).
-- `boot` is the identity of the process that owns the run, so an `active` row from another process is
-- not proof of life here - only of a run that a process has not settled yet.
local function run_in_flight(session_id)
  local rows = query('SELECT run_id,state,updated_at,boot FROM steering_runs WHERE session_id=?', { session_id })
  local row = rows and rows[1]
  if not row then return nil end
  return { run_id = tostring(row.run_id or ''), state = tostring(row.state or ''),
    updated_at = tonumber(row.updated_at) or nil, boot = tostring(row.boot or '') }
end

-- The event wake or deploy continuation this session is waiting on. `self_wakes` is the durable
-- record of both - a settle deploy queues a wake whose reason names it ("deploy <outcome>: ...",
-- `rust/wa-sentinel/src/deploy_outcome.rs`) - so watching does not read the sentinel's drop-box and
-- cannot be broken by the sentinel changing its file layout.
local function waiting_on(session_id)
  local ok, rows = pcall(function()
    return query("SELECT id,due_at,reason,status,event_json FROM self_wakes WHERE session_id=? AND status IN ('pending','dispatching') ORDER BY due_at IS NULL, due_at LIMIT 1", { session_id })
  end)
  if not ok then return nil end
  local row = rows and rows[1]
  if not row then return nil end
  local reason = tostring(row.reason or '')
  return {
    via = 'wake',
    kind = reason:match('^deploy ') and 'deploy' or 'wake',
    wake_id = tostring(row.id or ''),
    status = tostring(row.status or ''),
    due_at = tonumber(row.due_at) or nil,
    reason = clip(reason, LINE_LIMIT),
  }
end

-- What the session is doing right now, from what this node already knows. Every branch says which
-- witness it is resting on, because "running" from a supervised process and "running" from a steering
-- row updated 80 seconds ago are different strengths of evidence - and after a restart neither exists,
-- which must read as `unknown`, never as a finished run.
local function tail_state(session_id)
  local state = memory.session_state(session_id) or {}
  local record = remembered_run(session_id)
  local operation = operation_state(record)
  local steering = run_in_flight(session_id)
  local wake = waiting_on(session_id)
  local run = last_run(session_id)
  local tail = {
    session_state = state.state or 'unknown',
    detail = tostring(state.detail or ''),
    pending_calls = #(state.pending or {}),
    messages = memory.message_count(session_id),
    run = run,
    operation = operation and { id = tostring(operation.operation_id or ''), state = tostring(operation.state or ''),
      settled = operation.settled == true, process_exit_code = operation.process_exit_code } or nil,
    steering = steering,
    waiting = wake,
  }
  if wake then
    tail.state = 'waiting'
    tail.terminal = false
    tail.witness = 'wake'
    tail.detail = wake.kind == 'deploy' and ('waiting for a deploy to settle: ' .. tostring(wake.reason))
      or ('waiting for a wake: ' .. tostring(wake.reason))
    return tail
  end
  if operation and operation.live then
    tail.state = 'running'
    tail.terminal = false
    tail.witness = 'operation'
    tail.detail = 'the run started for this session is still executing (operation ' .. tostring(operation.state) .. ')'
    return tail
  end
  if state.state == 'answered' then
    tail.state = 'ended'
    tail.terminal = true
    tail.witness = 'transcript'
    tail.outcome = run and (run.status ~= '' and run.status or run.outcome) or 'answered'
    tail.detail = 'the last message is an assistant answer'
    return tail
  end
  if steering and steering.state == 'active' then
    local age = steering.updated_at and (host.now() - steering.updated_at) or nil
    if age and age <= LIVE_SECONDS then
      tail.state = 'running'
      tail.terminal = false
      tail.witness = 'steering'
      tail.age_seconds = math.floor(age)
      tail.detail = 'a run is in flight on this node (last context boundary ' .. math.floor(age) .. 's ago)'
      return tail
    end
    tail.state = 'unknown'
    tail.terminal = true
    tail.witness = 'steering'
    tail.age_seconds = age and math.floor(age) or nil
    tail.detail = 'a run was in flight and has not settled; the process that ran it may have been replaced'
    tail.outcome = 'interrupted'
    return tail
  end
  if operation and operation.settled then
    -- The process finished without leaving an answer: the run ended, and it did not answer. Say what
    -- the process said, not a guess about why.
    tail.state = 'ended'
    tail.terminal = true
    tail.witness = 'operation'
    tail.outcome = 'failed'
    tail.detail = 'the run process settled without an answer' ..
      (operation.process_exit_code and (' (exit ' .. tostring(operation.process_exit_code) .. ')') or '')
    return tail
  end
  tail.state = 'unknown'
  tail.terminal = true
  tail.witness = 'none'
  tail.outcome = 'unknown'
  tail.detail = state.detail ~= '' and state.detail or 'no live witness for this session'
  return tail
end

-- Wait for something new, bounded. A watcher that asks "anything yet?" every second spends a peer
-- call per second; asking the same question and letting the answering node wait briefly is the same
-- latency for a fraction of the calls. The bound is on this interpreter (a request thread), so it is
-- short: ten seconds at most, and it always returns with whatever it has.
local function wait_for_change(session_id, after, wait_ms)
  if wait_ms <= 0 then return end
  local deadline = now_ms() + wait_ms
  local ticks = 0
  while true do
    -- The cheap question every tick: has a row appeared? The tail state costs five queries (a session
    -- classification, the operation, the steering row, the wake and the last run), so it is asked once
    -- a second rather than five times a second on a node that is busy doing the very thing we watch.
    local rows = query('SELECT MAX(seq) AS last FROM messages WHERE session_id=?', { session_id })
    local last = tonumber(rows and rows[1] and rows[1].last) or 0
    if last > after then return end
    ticks = ticks + 1
    if ticks % 5 == 0 and tail_state(session_id).terminal then return end
    if now_ms() >= deadline then return end
    host.sleep('200')
  end
end

function M.watch(args, ctx)
  args = args or {}
  local session_id = tostring(args.session_id or '')
  if session_id == '' then return { error = 'session_id_required', effect = 'none' } end
  local after = args.after
  if after == nil then after = 0 end
  if type(after) == 'string' and after:match('^%d+$') then after = tonumber(after) end
  if type(after) ~= 'number' or after < 0 or after % 1 ~= 0 or after > 9007199254740991 then
    return { error = 'invalid_watch_cursor', effect = 'none' }
  end
  local wait_ms = math.floor(tonumber(args.wait_ms) or 0)
  if wait_ms < 0 or wait_ms > 10000 then return { error = 'invalid_watch_wait', range = '0-10000', effect = 'none' } end
  local session = session_of(session_id)
  if not session then return { error = 'unknown_session', session_id = session_id, effect = 'none' } end
  -- A bound on how far one page may reach, so a long session read from cursor 0 stays one bounded
  -- answer and says `has_more` instead of growing a peer reply without limit.
  local limit = math.floor(tonumber(args.limit) or PAGE)
  if limit < 1 or limit > 1000 then return { error = 'invalid_watch_limit', range = '1-1000', effect = 'none' } end

  if wait_ms > 0 then wait_for_change(session_id, after, wait_ms) end

  local rows, problem = query(
    'SELECT seq,role,content,tool_name,ok,ms,created_at,phase FROM messages WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?',
    { session_id, after, limit + 1 })
  if not rows then
    return { error = 'session_events_unreadable', detail = tostring(problem), session_id = session_id, effect = 'none' }
  end
  local has_more = #rows > limit
  local events, last = {}, after
  for index, row in ipairs(rows) do
    if index > limit then break end
    local event = message_event(row)
    last = tonumber(row.seq) or last
    if event then
      events[#events + 1] = event
    end
  end
  local tail = tail_state(session_id)
  -- Where the session's transcript actually ends. A cursor past it is not an error, and it must not be
  -- echoed back: a client that asked from 999 on a 4-message session would otherwise keep asking from
  -- 999 and never see the fifth message. The answer is the real head, so the next call reads from there.
  local head_rows = query('SELECT COALESCE(MAX(seq),0) AS head FROM messages WHERE session_id=?', { session_id })
  local head = tonumber(head_rows and head_rows[1] and head_rows[1].head) or 0
  -- The tail is an event like any other, and it is always last: a reader that stops at it has seen
  -- everything the transcript holds and knows what the session is doing now. It is a *projection* of
  -- durable state, not a new row, so it does not advance the cursor - re-reading from the same cursor
  -- returns it again, which is what makes a reconnect deterministic.
  local state_event = {
    kind = 'state',
    cursor = last,
    at = host.now(),
    state = tail.state,
    terminal = tail.terminal == true,
    outcome = tail.outcome,
    witness = tail.witness,
    detail = tail.detail,
    waiting = tail.waiting,
    operation = tail.operation and { id = tail.operation.id, state = tail.operation.state } or nil,
    session_state = tail.session_state,
    messages = tail.messages,
    run = tail.run and { run_id = tail.run.run_id, status = tail.run.status, outcome = tail.run.outcome } or nil,
  }
  if not has_more then events[#events + 1] = state_event end
  return {
    ok = true,
    session_id = session_id,
    node = nodes.node_name(),
    schema_version = 1,
    events = events,
    next_cursor = math.min(last, head),
    head = head,
    has_more = has_more,
    done = (not has_more) and tail.terminal == true,
    state = state_event,
    session = {
      id = session_id,
      title = tostring(session.title or ''),
      user_id = tostring(session.user_id or ''),
      node_id = tostring(session.node_id or ''),
      worktree = tostring(session.worktree or ''),
      started_at = tonumber(session.started_at) or nil,
      ended_at = tonumber(session.ended_at) or nil,
      messages = tail.messages,
    },
  }
end

-- ---------------------------------------------------------------- the peer entry point

-- The capability body. `lua/core/server.lua` calls this for `session_start` and `session_watch`, and
-- so does the CLI's own test; the action is named in the arguments so one module answers both halves
-- and their authority is decided in one place.
function M.serve(action, args, caller)
  local ctx, refusal = master_ctx(caller)
  if not ctx then return refusal end
  args = args or {}
  if action == 'start' then return M.start(args, ctx) end
  if action == 'watch' then return M.watch(args, ctx) end
  return { error = 'unknown_session_action', action = tostring(action or ''),
    allowed = { 'start', 'watch' }, effect = 'none' }
end

-- ---------------------------------------------------------------- the CLI half

-- `wa watch <node> <session> [--from <cursor>] [--timeout <seconds>] [--json]`
--
-- Prints one line per event and exits when the run ends. It is the same call a master makes from an
-- agent (`session_watch`), so a human and a model follow a run on another node the same way, and the
-- read-only guarantee is the peer's, not this loop's.
local function event_line(event)
  if event.kind == 'tool' then
    local state = event.ok and 'ok' or ('error ' .. tostring(event.error or 'failed'))
    return string.format('%d tool %s %s%s', event.cursor or 0, tostring(event.name or '?'), state,
      event.ms and string.format(' %dms', event.ms) or '')
  end
  if event.kind == 'state' then
    local text = string.format('%d state %s', event.cursor or 0, tostring(event.state or '?'))
    if event.outcome then text = text .. ' outcome=' .. tostring(event.outcome) end
    if event.waiting then
      local due = event.waiting.due_at and string.format(' at %d', event.waiting.due_at) or ''
      text = text .. string.format(' waiting=%s%s %s', tostring(event.waiting.kind or 'wake'), due, tostring(event.waiting.reason or ''))
    end
    if event.detail and event.detail ~= '' then text = text .. ' - ' .. tostring(event.detail) end
    return text
  end
  return string.format('%d %s %s', event.cursor or 0, tostring(event.kind or '?'), tostring(event.text or ''))
end

function M.cli(argv)
  local node_id, session_id
  local from, timeout, wait_ms, as_json = 0, 1800, 5000, false
  local index = 2
  while argv[index] do
    local arg = argv[index]
    if arg == '--from' then
      local value = argv[index + 1]
      if not value or not value:match('^%d+$') then print('wa watch: --from needs a cursor (a number printed by an earlier watch page)'); return 2 end
      from = tonumber(value); index = index + 2
    elseif arg == '--timeout' then
      timeout = tonumber(argv[index + 1]); if not timeout or timeout < 1 then print('wa watch: --timeout needs seconds'); return 2 end
      index = index + 2
    elseif arg == '--json' then
      as_json = true; index = index + 1
    elseif arg == '--interval' then
      wait_ms = tonumber(argv[index + 1])
      if not wait_ms or wait_ms < 0 or wait_ms > 10000 then print('wa watch: --interval is a wait in milliseconds, 0-10000'); return 2 end
      index = index + 2
    elseif arg == '--help' or arg == '-h' then
      print('usage: wa watch <node> <session> [--from <cursor>] [--timeout <seconds>] [--interval <ms>] [--json]')
      print('  Follow a session on another node, read-only. One line per event; exits when the run ends.')
      return 0
    elseif node_id == nil then node_id = arg; index = index + 1
    elseif session_id == nil then session_id = arg; index = index + 1
    else print('wa watch: unexpected argument ' .. tostring(arg)); return 2 end
  end
  if not node_id or not session_id then
    print('usage: wa watch <node> <session> [--from <cursor>] [--timeout <seconds>] [--interval <ms>] [--json]')
    return 2
  end
  local nodes_cli = dofile('lua/core/nodes.lua')
  local cursor = from
  local deadline = now_ms() + timeout * 1000
  -- The tail state is in every page (that is what makes a resume deterministic), but only a change in
  -- it is an *event*: a reader following a run should not get one identical line per poll while the
  -- model thinks. Transitions are printed, and the final one always is.
  local last_state
  local wait = math.min(tonumber(wait_ms) or 5000, 10000)
  while true do
    local answer = nodes_cli.remote_call(node_id, 'session_watch', {
      action = 'watch', session_id = session_id, after = cursor, wait_ms = wait })
    if type(answer) ~= 'table' then print('wa watch: unreadable answer from ' .. tostring(node_id)); return 1 end
    if answer.error then
      -- The peer's refusals are named, and `capability_not_granted` above all: a peer that has not
      -- been granted this capability answers exactly that, and the operator needs to hear it as a
      -- grant problem rather than as a broken watch.
      print('wa watch: ' .. tostring(answer.error) .. (answer.detail and (' - ' .. tostring(answer.detail)) or ''))
      return 1
    end
    for _, event in ipairs(answer.events or {}) do
      local repeat_of_last = false
      if event.kind == 'state' and answer.done ~= true then
        -- The fingerprint is the state's *identity*, not its wording: `running` names how long since the
        -- last context boundary, and that number changes every poll without the state changing. A
        -- follower reading lines wants transitions, not a clock.
        local fingerprint = table.concat({ tostring(event.state or ''), tostring(event.outcome or ''),
          tostring(event.witness or ''), json.encode(event.waiting or {}) }, '|')
        repeat_of_last = fingerprint == last_state
        last_state = fingerprint
      end
      if not repeat_of_last then
        if as_json then print(json.encode(event)) else print(event_line(event)) end
      end
    end
    cursor = tonumber(answer.next_cursor) or cursor
    if answer.done then
      local state = answer.state or {}
      if not as_json then
        print(string.format('wa watch: %s ended (%s) after %s message(s)',
          tostring(session_id), tostring(state.outcome or state.state or 'ended'), tostring(state.messages or 0)))
      end
      return 0
    end
    if answer.has_more then
      -- A page was full: read on at once rather than waiting for a change that has already happened.
      -- The next page after it is asked without a wait, and the wait returns on the page after that.
      wait = 0
    else
      wait = math.min(tonumber(wait_ms) or 5000, 10000)
    end
    if now_ms() > deadline then
      local state = answer.state or {}
      print(string.format('wa watch: still %s after %ds - re-run with --from %d', tostring(state.state or 'unknown'), timeout, cursor))
      return 3
    end
  end
end

-- `wa session start <node> --prompt <text> [--cwd <dir>] [--timeout <seconds>]`
--
-- The operator's half of `session_start`: the same signed call an agent makes, so the id printed here is
-- the id `wa watch` takes next. It prints the peer's receipt rather than a summary, because the
-- receipt is what says `started=true` is a launch and not a run.
function M.start_cli(argv)
  local node_id, prompt, cwd, timeout
  local index = 3
  while argv[index] do
    local arg = argv[index]
    if arg == '--prompt' then prompt = argv[index + 1]; index = index + 2
    elseif arg == '--cwd' then cwd = argv[index + 1]; index = index + 2
    elseif arg == '--timeout' then timeout = tonumber(argv[index + 1]); index = index + 2
    elseif arg == '--help' or arg == '-h' then
      print('usage: wa session start <node> --prompt <text> [--cwd <dir>] [--timeout <seconds>]')
      print('  Start a session on another node and print its id at once. Follow it with:')
      print('    wa watch <node> <session-id>')
      return 0
    elseif node_id == nil then node_id = arg; index = index + 1
    else print('wa session start: unexpected argument ' .. tostring(arg)); return 2 end
  end
  if not node_id or not prompt or trim(prompt) == '' then
    print('usage: wa session start <node> --prompt <text> [--cwd <dir>] [--timeout <seconds>]')
    return 2
  end
  if timeout and (timeout < 1 or timeout > 86400) then print('wa session start: --timeout is seconds, 1-86400'); return 2 end
  local request = { action = 'start', prompt = prompt }
  if cwd then request.cwd = cwd end
  if timeout then request.timeout_seconds = timeout end
  local answer = dofile('lua/core/nodes.lua').remote_call(node_id, 'session_start', request)
  print(json.encode(answer))
  if type(answer) ~= 'table' or answer.error or answer.ok ~= true then return 1 end
  print('started ' .. tostring(answer.session_id) .. ' on ' .. tostring(answer.node or node_id) .. ' - follow it with: wa watch ' ..
    tostring(node_id) .. ' ' .. tostring(answer.session_id))
  return 0
end

return M
