-- One pending-call handle for every code-mode call (docs/CODEMODE.md, "Pending calls").
--
-- A call that can outlive its wait is the general case: a build, `scripts/fast.sh`, a deploy, a
-- download, a remote call, a long `bash`, an outbound message. Until 12/11 every one of them blocked
-- the script that started it, and the model could only choose a timeout and hope. The operator's
-- decision (Victor, 12/11) is one pattern for all of them: the call answers a *handle* when it is
-- still running after its wait, and `wait(op)` resumes it later - in the same script, the next step,
-- the next turn or a resumed session of the same scope. `pending()` lists the handles a scope still
-- holds, so a later step needs no memory of them, and `wait([...], {until:"any"})` answers every op it
-- was asked about, which is what lets a step drop the finished ones and add new calls: a work pool
-- that grows and shrinks.
--
-- This module is that pattern, built on what the node already has rather than beside it. An
-- **executor** (`M.EXECUTORS`) is how one kind of work is started, polled and collected:
--
--   * `operation` - the managed operations (`rust/wa-operation`, `operation start/status/wait/read/
--     cancel`). An operation already owns a child, an absolute budget, output cursors, a durable
--     per-operation record on disk and a terminal outcome, so a handle here *is* the operation id,
--     the very id `operation read` and `/operations` already answer. `bash` and `operation` use it.
--   * `outbox` - a WhatsApp send's durable queue job: the message is queued by the connector and the
--     id it answers is the handle, so a wait reads the queue and a cancel says why it cannot stop a
--     message that is already sent.
--
-- No second registry of running work is invented: this file only remembers *which* call a handle is,
-- for which scope, and how to ask its executor what happened.
--
-- The three rules that make it safe:
--
--   1. **Starting is an effect; waiting is a read.** `invoke` is only ever called where the loop
--      already dispatches, in the loop's serial order. `wait`/`pending`/`cancel` dispatch nothing
--      that has an effect of its own: they poll work that is already running.
--   2. **Nothing here holds a lock or a lease.** Every wait is a bounded slice of the executor's own
--      wait (<= 1 s) followed by a status read, looped until the deadline; the node's settlement
--      does the blocking. A cancelled run, a stop/steer or a dead peer therefore ends a wait at once
--      and answers `pending`, never a hang and never a false `failed`.
--   3. **A resume never re-runs an effect.** The handle *is* the work's id: `wait` reads a settled
--      call's retained answer, and a second `wait` on the same handle answers the same bytes from
--      disk. There is no code path from here back into the tool's dispatch.
--
-- What a handle does NOT do, named rather than hidden: work that runs *inside* this interpreter
-- cannot be moved off it, so a call becomes pending only where the node has a detached executor
-- (`M.EXECUTORS`). A tool with no executor answers exactly as it did before this file existed; it is
-- never turned into a handle that cannot settle. A `remote`/peer call has no executor yet: the call
-- is answered synchronously and cannot be resumed (named in docs/CODEMODE.md).
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local output = dofile("lua/core/pure.lua")("lua/core/tool_output.lua")
local M = {}

-- The wait a call gets when it names none, and the ceiling on any wait. There is no third bound from
-- bound any more (18/11): a script is never killed for waiting, so there is no "remaining
-- script time" for a wait to outlive (the loop sets neither remaining_ms nor remaining). A caller
-- that passes one still gets the old clamp (M.effective_ms); the only other stop is the CPU guard.
M.DEFAULT_WAIT_S = 60
M.MAX_WAIT_S = 300
-- Reserved for the answer itself, the delivery into the guest and the script's return: a wait that
-- spent the script's last millisecond would answer a handle nobody could read.
M.MARGIN_MS = 2000
-- Concurrent pending calls one session may hold. Refused by name past it (`codemode_pending_limit`),
-- never by silently dropping the oldest - a dropped handle is work nobody can find again.
M.MAX_OPEN = 16
-- Operations one `wait` or `cancel` may ask about at once.
M.MAX_BATCH = 20
-- Bytes of an operation's output kept in `progress`, and how many handles `pending()` lists.
M.PROGRESS_BYTES = 400
M.MAX_LIST = 50
-- The page a settled operation's stdout/stderr is read at. One pair of numbers, the same ones
-- rust/wa-capabilities/src/operations.rs reads with (24 * 1024 / 8 * 1024), because a handle and a
-- direct bash answer must clip at the same byte and report the same `stdout_bytes`: two copies of
-- "24 KB" drifting apart is how a result reads complete on one path and truncated on the other
-- (item 4). tools.lua's operation schema and its adopted-tree result read these too.
M.STDOUT_PAGE_BYTES = 24 * 1024
M.STDERR_PAGE_BYTES = 8 * 1024
-- Records kept per scope once they are closed: a settled handle is kept so `results.get(op)` can
-- re-read it, but the index cannot grow without bound in a long session.
M.KEEP_CLOSED = 256
-- The longest single blocking slice. The node does the blocking natively, so this is not a relay
-- limit; it is what keeps a wait interruptible by a stop/steer without a long call to unwind.
M.SLICE_MS = 1000
-- How many times ONE script may be told the same op is still pending WITHOUT PROGRESS before the
-- script ends by name (18/11 round 2, finding 7; narrowed 18/11 round 3, item 2).
--
-- A script that re-waited on an op that never settles used to loop for as long as the op lived and
-- held one of the sandbox's four session slots the whole time: it now ends with a named reason and
-- the slot is released. What counts is narrow on purpose, because the first cut of this bound counted
-- every pending ANSWER and that is a wall clock under another name:
--
--   * only a wait that spent its WHOLE budget (>= M.full_wait_ms()) counts. A poll (wait_s:0, or a
--     wait that returned early because a short op of the same batch settled under until:"any") spends
--     none of the budget the bound is about, so a pool loop that finishes 25 short ops while one long
--     build runs can no longer kill the build, and a wait_s:0 call awaited at once is untouched;
--   * a wait that saw PROGRESS (bytes written, a progress counter that moved, a promotion) resets the
--     count, so a long build with steady output survives however long the script watches it;
--   * the count is per op, so a script that waits on four different calls for five minutes each is
--     untouched.
--
-- This is NOT a wall clock on waiting (the approved rule stands: a script is never killed for waiting,
-- and the CPU guard is the only hard stop for computing). It is the one case where "wait a little
-- longer" and "this handle will never change" are the same thing: an op that shows nothing at all
-- while it is waited on for the whole budget, again and again.
M.PENDING_ANSWER_LIMIT = 20
-- The shortest wait that can count against it: anything under this is a poll, and a poll is not a
-- wait. A caller does not have to know the number; it is the difference between "I asked to wait" and
-- "I glanced".
M.FULL_WAIT_MS = 30000
-- How far short of its budget a wait may return and still be read as having spent it.
M.WHOLE_WAIT_SLACK_MS = 250
-- The name the script's end carries, so the failure layer, the explainer and a test agree on it.
M.WAIT_BOUND_CODE = "codemode_wait_never_settles"
function M.pending_answer_limit()
  local raw = (host.getenv and host.getenv("WASM_AGENT_CODEMODE_WAIT_ANSWERS")) or nil
  local value = tonumber(raw)
  if value and value >= 1 then return math.floor(value) end
  return M.PENDING_ANSWER_LIMIT
end

-- The same for the whole-budget threshold M.FULL_WAIT_MS, so a test can hold the rule with one-second
-- waits instead of fifteen-minute ones. Production default: 30 s.
function M.full_wait_ms()
  local raw = (host.getenv and host.getenv("WASM_AGENT_CODEMODE_WAIT_FULL_MS")) or nil
  local value = tonumber(raw)
  if value and value >= 1 then return math.floor(value) end
  return M.FULL_WAIT_MS
end

-- The fields of a pending answer that mean the op DID something. The clock fields the same answer
-- carries (elapsed_ms, remaining_ms, output_idle_ms) are deliberately absent: they move on their own,
-- and a fingerprint over them would read the passing of time as progress - which is the bug this
-- bound exists to not have (18/11 round 3, item 2).
M.PROGRESS_FIELDS = { "output_bytes", "bytes", "progress", "promoted", "shell_exited", "state" }
function M.progress_fingerprint(progress)
  if type(progress) ~= "table" then return "" end
  local parts = {}
  for _, key in ipairs(M.PROGRESS_FIELDS) do
    local value = progress[key]
    if value ~= nil then parts[#parts + 1] = key .. "=" .. tostring(value) end
  end
  return table.concat(parts, ";")
end

-- ---------------------------------------------------------------------------- the record on disk
--
-- One index per scope (`<data>/codemode-pending/<scope>.json`), bounded. It holds the mapping
-- handle -> call and nothing else: the work, its output and its outcome stay with its executor. A
-- scope is the same hash the guest store and the results journal use (session x user x role x
-- workspace x profile), so "the same scope" is one meaning in this node.
function M.dir() return paths.data() .. "/codemode-pending" end
local function index_path(scope) return M.dir() .. "/" .. tostring(scope) .. ".json" end

local function now_seconds()
  local clock = host.now and host.now() or nil
  return tonumber(clock) or 0
end

-- Is this record still something a caller can act on: running, of-unknown-outcome, or settled and not
-- yet reported to a script? Only these count against MAX_OPEN.
local function open_record(record)
  return record.state == "running" or record.state == "unknown" or record.state == "pending"
    or (record.reported == false)
end

local function open_count(index)
  local count = 0
  for _, record in pairs(index.ops or {}) do if open_record(record) then count = count + 1 end end
  return count
end

function M.open(scope)
  local raw = host.read_file(index_path(scope))
  if type(raw) == "string" and raw ~= "" then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == "table" then
      -- `[]` decodes to an empty table, so both spellings of "no handles yet" land here.
      if type(decoded.ops) ~= "table" then decoded.ops = {} end
      decoded.count = open_count(decoded)
      return decoded
    end
  end
  return { ops = {}, count = 0 }
end

-- ------------------------------------------------------------------- session_open(session_id)
-- How many handles ONE SESSION still holds, across every scope it can have. A scope is a hash of
-- session x user x role x workspace x profile, and a reader that holds only the session - the idle
-- compaction route - cannot rebuild that hash; the record already carries the session it was started
-- for, so the answer is read out of the records instead of recomputed from the key.
--
-- A read: nothing is opened, polled, waited on or settled, and no index is rewritten.
--
-- Two answers, because a zero must never be read out of a file nobody could see: `unreadable` counts
-- the index files whose contents could not be decoded, and the caller decides (the compaction route
-- refuses rather than compacting on a state it cannot observe). A directory that does not exist yet is
-- the ordinary state of a node that has never left a call running: no handles, nothing unreadable.
--
-- The suffix an index file carries, beside the path builder above.
local INDEX_SUFFIX = ".json"
function M.session_open(session_id)
  session_id = tostring(session_id or "")
  if session_id == "" then return 0, 0 end
  if type(host.list_dir) ~= "function" or type(host.path_kind) ~= "function" then return 0, 1 end
  local dir = M.dir()
  local kind = host.path_kind(dir)
  if kind == "missing" then return 0, 0 end
  if kind ~= "dir" then return 0, 1 end
  local ok, raw = pcall(host.list_dir, dir)
  local decoded = nil
  if ok then
    local dec_ok, value = pcall(json.decode, tostring(raw))
    if dec_ok then decoded = value end
  end
  if type(decoded) ~= "table" or type(decoded.entries) ~= "table" then return 0, 1 end
  local open, unreadable = 0, 0
  for _, entry in ipairs(decoded.entries) do
    local name = tostring(entry.name or "")
    if entry.kind == "file" and name:sub(-#INDEX_SUFFIX) == INDEX_SUFFIX then
      local text = host.read_file(dir .. "/" .. name)
      local index = nil
      if type(text) == "string" and text ~= "" then
        local index_ok, value = pcall(json.decode, text)
        if index_ok and type(value) == "table" and type(value.ops or {}) == "table" then index = value end
      end
      if not index then
        unreadable = unreadable + 1
      else
        for _, record in pairs(index.ops or {}) do
          if type(record) == "table" and open_record(record)
            and tostring(record.session or "") == session_id then
            open = open + 1
          end
        end
      end
    end
  end
  return open, unreadable
end

-- Closed handles are kept so `results.get(op)` keeps working, but the index stays bounded: past
-- KEEP_CLOSED the oldest closed ones are dropped (their retained result bytes stay in the node's
-- tool-results directory; only the name stops resolving, and `results.get` says so).
local function prune(index)
  local closed = {}
  for op, record in pairs(index.ops or {}) do
    if not open_record(record) then closed[#closed + 1] = { op = op, at = tonumber(record.settled_at) or 0 } end
  end
  if #closed <= M.KEEP_CLOSED then return index end
  table.sort(closed, function(a, b) return a.at < b.at end)
  local drop = #closed - M.KEEP_CLOSED
  for position = 1, drop do index.ops[closed[position].op] = nil end
  return index
end

function M.save(scope, index)
  prune(index)
  index.count = open_count(index)
  local ok, encoded = pcall(json.encode, { ops = index.ops or {} })
  if not ok then return false end
  -- Best effort: a node that cannot write its index still has the work's own record, so the work is
  -- never lost - only the name the model was given stops resolving, and `wait` says so.
  return host.write_file(index_path(scope), encoded) and true or false
end

-- ---------------------------------------------------------------------------- time and arguments
-- What is left of the script, from the loop's own clock: a function (re-read per call) or a number.
local function remaining_of(opts)
  if type(opts.remaining) == "function" then
    local ok, value = pcall(opts.remaining)
    if ok then return tonumber(value) end
  end
  return tonumber(opts.remaining_ms)
end

-- The one bound every wait obeys: what the call asked for (default 60 s), the ceiling (300 s) and
-- what is left of the script after the answer's own margin.
function M.effective_ms(wait_s, remaining_ms)
  local seconds = tonumber(wait_s)
  if seconds == nil then seconds = M.DEFAULT_WAIT_S end
  seconds = math.max(0, math.min(M.MAX_WAIT_S, seconds))
  local budget = math.floor(seconds * 1000)
  if type(remaining_ms) == "number" then
    budget = math.min(budget, math.max(0, math.floor(remaining_ms) - M.MARGIN_MS))
  end
  return budget
end

-- `wait_s` on any call. It is a property of the call's *wait*, never an argument of the tool, so it
-- is taken out before the arguments meet the tool's own schema (a strict schema would refuse it).
-- When a call names no `wait_s` this returns the original text unchanged: a script that does not use
-- the knob takes exactly the path it took before this file existed.
function M.strip(raw)
  if type(raw) ~= "string" or raw == "" or raw == "undefined" then return raw, nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" or decoded.wait_s == nil then return raw, nil end
  local wait_s = tonumber(decoded.wait_s)
  decoded.wait_s = nil
  -- A `wait_s` that is not a number is refused by name rather than quietly replaced with the
  -- default: "how long should I wait" answered by a guess is how a call gets abandoned silently.
  if wait_s == nil then return json.encode(decoded), nil, "invalid_wait_s" end
  return json.encode(decoded), wait_s, nil
end

-- ---------------------------------------------------------------------------- the executors
-- One entry per family of work the node can run detached. Each provides:
--   start(dispatch, opts, params, raw) -> {op=…} to register, or {result=…} when the call answered
--                                        at once (a refusal is an answer, never a second attempt);
--   poll(dispatch, opts, record, ms)   -> (state, reason), where `state.settled` is the fact;
--   settle(dispatch, opts, record, state) -> the value the tool would have answered;
--   progress(dispatch, opts, record, state) -> the bounded `progress` a pending answer carries;
--   cancel(dispatch, opts, record)      -> only for kinds whose effect can be stopped.
M.EXECUTORS = {}

local function cancelled()
  local ok, raw = pcall(function() return host.run_cancelled and host.run_cancelled() end)
  if not ok or type(raw) ~= "string" then return false end
  -- Both returns of pcall, or a cancelled run reads as "not cancelled" and the wait runs to its
  -- deadline: that is the bug this line exists to not have (measured 12/11, caught by
  -- scripts/test-codemode-pending.lua's stop/steer check).
  local decoded_ok, decoded = pcall(json.decode, raw)
  return decoded_ok and type(decoded) == "table" and decoded.cancelled == true
end

local function operation_call(dispatch, action, args)
  local ok, value = pcall(dispatch, "operation", args, json.encode(args))
  if not ok then return nil, tostring(value) end
  if type(value) ~= "table" then return nil, "operation_" .. action .. "_malformed" end
  if value.error and not value.operation_id then return nil, tostring(value.error) end
  return value, nil
end

local function snapshot(dispatch, op)
  return operation_call(dispatch, "status", { action = "status", id = op })
end

local function tail(dispatch, op, state)
  local bytes = tonumber(type(state) == "table" and state.output_bytes or nil) or 0
  if bytes <= 0 then return nil end
  local from = math.max(0, bytes - M.PROGRESS_BYTES)
  local page = operation_call(dispatch, "read", { action = "read", id = op, stream = "stdout",
    offset = from, limit = M.PROGRESS_BYTES })
  local content = type(page) == "table" and page.content or nil
  if type(content) ~= "string" or content == "" then return nil end
  return content
end

-- The result a settled operation answers. It is the operation's own state record, which is byte for
-- byte what `bash` already answers for an adopted tree (`operations::foreground` returns the same
-- snapshot): stdout, stderr, `output_complete`, `code`/`ok` and the timing all come from the record,
-- so a call that finished inside its wait reads exactly as it did before handles existed.
local function operation_result(dispatch, op, state)
  local out = {}
  for key, value in pairs(type(state) == "table" and state or {}) do out[key] = value end
  out.operation_id = out.operation_id or op
  local stdout = operation_call(dispatch, "read", { action = "read", id = op, stream = "stdout",
    offset = 0, limit = M.STDOUT_PAGE_BYTES })
  if type(stdout) == "table" and type(stdout.content) == "string" then
    out.stdout = stdout.content
    -- available_bytes is the stream's real size, so the count is the whole output's, not the page's.
    out.stdout_bytes = tonumber(stdout.available_bytes) or #out.stdout
    out.stdout_truncated = out.stdout_bytes > M.STDOUT_PAGE_BYTES
  end
  local stderr = operation_call(dispatch, "read", { action = "read", id = op, stream = "stderr",
    offset = 0, limit = M.STDERR_PAGE_BYTES })
  if type(stderr) == "table" and type(stderr.content) == "string" then
    out.stderr = stderr.content
    out.stderr_bytes = tonumber(stderr.available_bytes) or #out.stderr
    out.stderr_truncated = out.stderr_bytes > M.STDERR_PAGE_BYTES
  end
  if out.code == nil then out.code = tonumber(out.process_exit_code) or tonumber(out.command_code) or -1 end
  if out.ok == nil then out.ok = out.code == 0 end
  if out.output_complete == nil then out.output_complete = out.output_streams_closed == true end
  return out
end

-- Wait for one operation up to `ms`, in bounded slices. Answers the state and, when the wait ended
-- without settlement, the reason (`still_running`, `run_cancelled`, or the supervisor's own words).
local function operation_poll(dispatch, opts, record, ms)
  local op = record.op
  local left = math.max(0, math.floor(tonumber(ms) or 0))
  local state, reason = snapshot(dispatch, op)
  if not state then return nil, reason end
  if state.settled == true then return state, nil end
  while left > 0 do
    if cancelled() then return state, "run_cancelled" end
    local slice = math.min(left, M.SLICE_MS)
    local waited, wait_reason = operation_call(dispatch, "wait",
      { action = "wait", id = op, wait_ms = slice, tool = "operation" })
    if not waited then return state, wait_reason end
    state = waited
    left = left - slice
    if state.settled == true then return state, nil end
    if state.overdue == true then return state, "operation_supervisor_overdue" end
  end
  return state, "still_running"
end

local function operation_progress(dispatch, opts, record, state)
  state = state or {}
  local entry = { state = tostring(state.state or "running"), elapsed_ms = tonumber(state.elapsed_ms) }
  if state.remaining_ms ~= nil then entry.remaining_ms = tonumber(state.remaining_ms) end
  if state.shell_exited ~= nil then entry.shell_exited = state.shell_exited end
  if state.output_idle_ms ~= nil then entry.output_idle_ms = tonumber(state.output_idle_ms) end
  if state.promoted ~= nil then entry.promoted = state.promoted end
  entry.output_bytes = tonumber(state.output_bytes) or 0
  -- WHAT IT IS WAITING ON, when the node knows (item 1, 23/11). The operation's own state carries
  -- `blocked_on` + `blocked_note` when its process tree is parked on a file lock
  -- (rust/wa-operation/src/blocked.rs): the measured case is a mission suite queued behind another
  -- mission's ~/Work/missions/.suite.lock, which answered a bare "running" for 20-50 minutes and sent
  -- workers probing with ps. The facts and the sentence travel together, so a pending answer says what a
  -- human would have to run ps to find out.
  --
  -- Deliberately NOT added to M.PROGRESS_FIELDS: the sentence carries how long the lock has been held,
  -- which changes every second, so fingerprinting it would read a wait that is still parked as progress
  -- and the whole-budget bound (M.PENDING_ANSWER_LIMIT) would never count a parked wait at all.
  if type(state.blocked_on) == "table" then
    local facts = state.blocked_on
    entry.blocked = { kind = tostring(facts.kind or "file_lock") }
    if type(facts.lock_path) == "string" then entry.blocked.lock = facts.lock_path end
    if tonumber(facts.holder_pid) then entry.blocked.holder_pid = math.floor(tonumber(facts.holder_pid)) end
    if type(state.blocked_note) == "string" and state.blocked_note ~= "" then
      entry.blocked_note = state.blocked_note
    end
  end
  local line = tail(dispatch, record.op, state)
  if line then entry.tail = line end
  return entry
end

-- ---- a script's command changed files (chat-view-round-2, item 2) --------------------------------
--
-- The watcher for a shell command lives in the dispatcher's bash branch (lua/core/tools.lua), and a
-- script's bash never reaches the end of it: that branch starts a MANAGED OPERATION and returns
-- (`ctx.parallel_start`), so a command run inside code mode - the one execution path this node has -
-- changed files with no card at all. Measured 23/11 in a scratch work tree through the real
-- dispatcher: `tools.bash({command:"printf C > tracked.txt"})` inside a `run` block emitted NOTHING,
-- while the very same command dispatched directly emitted `bash_changes[1] tracked.txt`.
--
-- So the snapshot is taken HERE, before the operation starts, and compared when it settles - the only
-- moment at which what the command did is a fact. Both halves are lua/core/bash_changes.lua's own
-- functions, the event is the same `bash_changes` the view already draws cards from, and it goes to
-- the run's change queue (lua/core/agent.lua drains it after this call's result row, so the card
-- cannot land inside the code block that is still open). A read-only command takes no snapshot, an
-- operation that never settles claims nothing, and a caller with no listener pays nothing.
local bash_changes = dofile("lua/core/bash_changes.lua")

local function watch_before(opts, params)
  local ctx = type(opts) == "table" and opts.ctx or nil
  if type(ctx) ~= "table" or type(ctx.emit) ~= "function" or not ctx.watch_changes then return nil end
  local command = type(params) == "table" and tostring(params.command or "") or ""
  if command == "" then return nil end
  local cwd = type(params) == "table" and tostring(params.cwd or "") or ""
  local read_only = nil
  if type(ctx.read_only_command) == "function" then read_only = ctx.read_only_command(command) end
  local watched = bash_changes.before(cwd, read_only)
  if type(watched) ~= "table" then return nil end
  watched.command = command
  return watched
end

local function watch_settle(opts, record, state)
  local ctx = type(opts) == "table" and opts.ctx or nil
  local watched = type(record) == "table" and record.watch or nil
  if type(watched) ~= "table" or type(ctx) ~= "table" then return end
  record.watch = nil
  -- Only a settled operation is an answer: an op still running has not finished changing files yet,
  -- and comparing now would report half of what it did.
  if type(state) ~= "table" or state.settled ~= true then return end
  local files, refused = bash_changes.changed(watched)
  if #files == 0 and #refused == 0 then return end
  local event = { type = "bash_changes", command = watched.command, files = files, refused = refused }
  local queue = type(ctx.change_queue) == "table" and ctx.change_queue or nil
  if queue then queue[#queue + 1] = event
  elseif type(ctx.emit) == "function" then ctx.emit(event) end
  -- A file this run wrote that the command then removed (lua/core/tools.lua, announce_gone): the
  -- run's own record still holds its text, so the reader gets a Delete with its real lines.
  if type(ctx.changes) == "table" and type(ctx.emit) == "function" then
    local loaded, tools_module = pcall(dofile, "lua/core/tools.lua")
    local announce = loaded and type(tools_module) == "table" and tools_module.announce_gone or nil
    if type(announce) == "function" then
      local reported = {}
      for _, item in ipairs(files) do reported[item.path] = true end
      for _, item in ipairs(refused) do reported[item.path] = true end
      pcall(announce, ctx, reported)
    end
  end
end

-- The managed-operation family: `bash` starts one through the tool's own serial path, and the
-- `operation` tool's `start` registers the receipt it just answered while `await` becomes a bounded
-- wait on the id the caller already has.
do
  M.EXECUTORS["bash"] = {
    kind = "operation",
    start = function(dispatch, opts, params, raw)
      local copy = {}
      for key, value in pairs(type(params) == "table" and params or {}) do copy[key] = value end
      -- The deadline the synchronous path would have used: the configured default and any active
      -- child budget, so a subagent's remaining time still bounds the operation it starts.
      if copy.timeout_seconds == nil then
        local ok, seconds = pcall(function() return host.exec_timeout and host.exec_timeout() end)
        if ok and tonumber(seconds) then copy.timeout_seconds = math.floor(tonumber(seconds)) end
      end
      -- The path guard is applied by the `operation` branch of the dispatcher, which this path goes
      -- through (`lua/core/tools.lua`): one wall, one wrap, one refusal shape, the same one `bash`
      -- and `host.exec` answer.
      local ctx = opts.ctx or {}
      local saved = ctx.parallel_start
      local saved_background = ctx.background_operation
      -- Before the command runs: the files it may change, for the reader only (watch_settle).
      local watched = watch_before(opts, copy)
      ctx.parallel_start = true
      -- The CPU priority of the operation this starts: low only for a call nobody waits for
      -- (18/11 round 2, finding 9).
      ctx.background_operation = opts.background == true
      local ok, result = pcall(dispatch, "bash", copy, raw)
      ctx.parallel_start = saved
      ctx.background_operation = saved_background
      if not ok then return { result = { error = tostring(result), effect = "unknown", replay_allowed = false } } end
      if type(result) == "table" and type(result.operation_id) == "string" and result.operation_id ~= "" then
        return { op = result.operation_id, watch = watched }
      end
      -- A refusal, a guarded command, a rejected timeout: the call finished, and it answers as it
      -- always did. A refusal is never permission to run the command a second way.
      return { result = result }
    end,
  }
  M.EXECUTORS["operation"] = {
    kind = "operation",
    applies = function(params)
      local action = type(params) == "table" and tostring(params.action or "") or ""
      return action == "await" or action == "start"
    end,
    start = function(dispatch, opts, params, raw)
      if params.action == "start" then
        local ok, result = pcall(dispatch, "operation", params, raw)
        if not ok then return { result = { error = tostring(result) } } end
        if type(result) == "table" and type(result.operation_id) == "string" then
          return { op = result.operation_id, register = true, result = result }
        end
        return { result = result }
      end
      local id = tostring(params.id or "")
      if id == "" then return { result = { error = "id_required" } } end
      -- `wait_for=settled` and the adoption rules are the operation tool's; the wait here only
      -- decides how long this call watches before it hands back a handle.
      return { op = id, attach = true }
    end,
  }
end
for _, name in ipairs({ "bash", "operation" }) do
  M.EXECUTORS[name].poll = operation_poll
  M.EXECUTORS[name].progress = operation_progress
  M.EXECUTORS[name].settle = function(dispatch, opts, record, state)
    return operation_result(dispatch, record.op, state)
  end
  -- One step below the node, after the fact (18/11 round 3, item 5): the operation tool action
  -- "background" re-nices a running operation in its own process group and answers the record with
  -- the priority it now runs at. Best effort by design - a node that cannot renice keeps running the
  -- work at the node's priority and the wait still works - so a refusal is recorded, never thrown.
  M.EXECUTORS[name].demote = function(dispatch, record)
    local answer, why = operation_call(dispatch, "background", { action = "background", id = record.op })
    if not answer then record.demote_error = tostring(why) return nil, why end
    if type(answer) == "table" and answer.cpu_priority ~= nil then
      record.cpu_priority = tostring(answer.cpu_priority)
    end
    return answer
  end
end

-- A script's bash, watched when it settles: the same event a direct bash emits.
do
  local shared = M.EXECUTORS["bash"].settle
  M.EXECUTORS["bash"].settle = function(dispatch, opts, record, state)
    local result = shared(dispatch, opts, record, state)
    watch_settle(opts, record, state)
    return result
  end
end

-- The outbox family: a WhatsApp send is a durable queue job (`lua/core/whatsapp.lua`), so the id the
-- connector answers is the handle. `wait_s:0` queues and answers at once; the id alone resumes. The
-- message is never sent twice, and a cancel says so rather than pretending.
--
-- The same tool answers a DRAFT when operator approval is on for the chat (docs/APPROVE.md): nothing
-- was queued, the handle is the draft, and the three things an op does still hold - `wait` re-reads
-- what the operator decided, `pending` shows the draft's state, and `cancel` is possible HERE,
-- because nothing has been sent yet. That last difference is why this kind's cancel is a function and
-- no longer the fixed `false` it used to be.
do
  local function read_call(dispatch, asked)
    local ok, answer = pcall(dispatch, "mcp_whatsapp_send", asked, json.encode(asked))
    if not ok then return nil, tostring(answer) end
    if type(answer) ~= "table" then return nil, "outbox_answer_malformed" end
    if answer.ok == false and answer.error then return nil, tostring(answer.error) end
    return answer, nil
  end
  local function queue_read(dispatch, record, seconds)
    local asked = record.draft and { draft = record.draft } or { id = record.id }
    if seconds ~= nil then asked.wait_s = seconds end
    return read_call(dispatch, asked)
  end
  M.EXECUTORS["mcp_whatsapp_send"] = {
    kind = "outbox",
    applies = function(params)
      if type(params) ~= "table" then return false end
      return params.chat ~= nil and params.id == nil and params.ids == nil and params.draft == nil
    end,
    start = function(dispatch, opts, params, raw)
      local copy = {}
      for key, value in pairs(params) do copy[key] = value end
      -- Queue and answer at once: the wait is this layer's, the same one every other call gets.
      copy.wait_s = 0
      copy["until"] = nil
      local ok, answer = pcall(dispatch, "mcp_whatsapp_send", copy, raw)
      if not ok then return { result = { error = tostring(answer), effect = "unknown", replay_allowed = false } } end
      if type(answer) ~= "table" or answer.state ~= "pending" then return { result = answer } end
      if type(answer.draft) == "string" and answer.draft ~= "" then
        -- A draft IS the handle: nothing is queued, and the operator's decision settles it.
        return { op = "draft-" .. answer.draft, draft = answer.draft }
      end
      local id = tonumber(answer.id)
      if not id then return { result = answer } end
      return { op = "msg-" .. tostring(id), id = id }
    end,
    poll = function(dispatch, opts, record, ms)
      -- The connector's own bounded wait does the polling, one short call at a time; `seconds` 0 is a
      -- status read. A cancelled run ends it inside the connector (`M.settle`).
      local answer, reason = queue_read(dispatch, record, math.max(0, math.ceil((tonumber(ms) or 0) / 1000)))
      if not answer then return nil, reason end
      answer.settled = answer.state ~= "pending"
      return answer, (answer.settled and nil or (reason or "still_running"))
    end,
    settle = function(dispatch, opts, record, state) return state end,
    -- The one kind whose effect can be stopped: a cancelled DRAFT was never sent, and the operator
    -- never had to decide it. A queued message keeps the old answer, in its own words.
    cancel = function(dispatch, opts, record)
      if not record.draft then
        return { op = record.op, tool = "mcp_whatsapp_send", cancelled = false,
          error = "not_cancellable", why = "a sent message stays sent" }
      end
      local asked = { action = "decide", draft = record.draft, decision = "cancel" }
      local ok, answer = pcall(dispatch, "mcp_whatsapp_approve", asked, json.encode(asked))
      if not ok or type(answer) ~= "table" or answer.ok == false then
        local why = not ok and tostring(answer)
          or tostring(type(answer) == "table" and answer.error or "the account node answered nothing")
        return { op = record.op, tool = "mcp_whatsapp_send", cancelled = false,
          error = "not_cancellable", why = why }
      end
      return { op = record.op, tool = "mcp_whatsapp_send", cancelled = true, draft = record.draft,
        note = "the draft was cancelled: nothing was sent, and nobody had to decide it" }
    end,
    progress = function(dispatch, opts, record, state)
      local entry = { state = tostring(type(state) == "table" and state.state or "pending"), kind = "outbox",
        job = record.id }
      if record.draft then entry.draft = record.draft end
      if type(state) == "table" and state.waited_s ~= nil then entry.waited_s = tonumber(state.waited_s) end
      if type(state) == "table" and state.queue_state ~= nil then entry.queue_state = tostring(state.queue_state) end
      if type(state) == "table" and state.draft_state ~= nil then entry.draft_state = tostring(state.draft_state) end
      return entry
    end,
  }
end

-- The peer family (change/remote-pending, item 1): a remote bash is ADOPTED, not killed.
--
-- The call itself is dispatched first, exactly as it always was, and it now comes back as either the
-- command's own result (it fitted in the peer's budget) or {state:"pending", op, node, ...}: the peer
-- started a managed operation on ITSELF and kept it running. From here on the handle is the peer's
-- operation id plus the node it lives on, and every wait and cancel is a SHORT relayed
-- operation call to that node - never one long relay connection (item 2). The effect already ran
-- once, on the peer, and no path here dispatches it again.
--
-- Only bash is adopted: it is the one effectful capability whose work can outlive the relay's hold.
-- A batch is read-only on the wire and an operation start answers a receipt at once, so neither is
-- turned into work nobody can collect.
do
  -- One slice is a bounded relayed wait (review r1, SHOULD 2). It must stay under BOTH bounds: the
  -- operation tool's own wait_ms maximum (nodes.OPERATION_AWAIT_MAX_MS, 10 s - a larger number is refused
  -- by the peer's schema, so the 15 s this used to name was a slice no call could ask for) and the
  -- relay's hold (nodes.RELAY_PEER_BUDGET_MS). The smaller of the two, in one place, so a change to
  -- either number cannot leave a slice the peer will not accept.
  local nodes_lib = dofile("lua/core/nodes.lua")
  local REMOTE_SLICE_MS = math.min(nodes_lib.OPERATION_AWAIT_MAX_MS, nodes_lib.RELAY_PEER_BUDGET_MS)

  -- One relayed operation call: the peer's own operation tool, reached through the same remote call
  -- everything else uses, so the peer keeps its own admission, its own session and its own answer.
  local function remote_operation(dispatch, record, args)
    local params = { node = record.node, capability = "operation" }
    for key, value in pairs(args) do params[key] = value end
    local ok, answer = pcall(dispatch, "remote", params, json.encode(params))
    if not ok then return nil, tostring(answer) end
    if type(answer) ~= "table" then return nil, "remote_operation_malformed" end
    if answer.error and answer.operation_id == nil then return nil, tostring(answer.error) end
    return answer, nil
  end

  M.EXECUTORS["remote"] = {
    kind = "remote",
    applies = function(params)
      if type(params) ~= "table" then return false end
      if params.capability ~= "bash" then return false end
      return params.node ~= nil and params.node ~= ""
    end,
    start = function(dispatch, opts, params, raw)
      local ok, result = pcall(dispatch, "remote", params, raw)
      if not ok then
        return { result = { error = tostring(result), effect = "unknown", replay_allowed = false } }
      end
      if type(result) ~= "table" then return { result = result } end
      if result.state == "pending" and type(result.op) == "string" and result.op ~= "" then
        -- The peer adopted it: the handle is its operation id, and the node is what routes every later
        -- wait and cancel back to the machine the work is actually on.
        return { op = result.op, node = tostring(result.node or params.node) }
      end
      -- A refusal, a settled command, an unreachable peer: an answer, never a second attempt.
      return { result = result }
    end,
    poll = function(dispatch, opts, record, ms)
      local left = math.max(0, math.floor(tonumber(ms) or 0))
      local last, reason = nil, "still_running"
      local function elapsed_ms() return tonumber(host.monotonic_ms and host.monotonic_ms() or 0) or 0 end
      -- A wait is only asked for when there is a wait to spend: a POLL (wait_s:0, or a batch sibling
      -- that settled early) asks the peer for its STATUS instead of an await with no budget, because a
      -- zero-length await is not a glance - it is a call whose stop condition the peer decides.
      -- A CAP, A MINIMUM CHARGE **AND A PAUSE** (review r2 MUST 3, review r3 item 1).
      --
      -- The charge alone lowered the budget but never waited: a peer that answers AT ONCE without
      -- settling (an overdue supervisor, an interrupted await, an old peer) still got up to
      -- min(40, budget/250) relayed awaits back to back - the burst this fix removes. Two things change:
      --
      --   * every call is followed by a real pause before the next one, whole milliseconds with a
      --     doubling backoff (200 -> 400 -> ... capped at 2 s), so N calls cost N pauses of wall time and
      --     can never be a burst;
      --   * operation_supervisor_overdue STOPS the wait at once and is named, because that answer means
      --     the peer's own supervisor has stopped making progress: asking it again is the hot loop.
      --
      -- host.sleep takes whole MILLISECONDS (rust/wa-capabilities: "Block this interpreter for a bounded
      -- number of milliseconds"), so a fractional value would be 0 ms and this pause would not exist.
      local REMOTE_MAX_CALLS = 40
      local REMOTE_MIN_CHARGE_MS = 250
      local REMOTE_MIN_PAUSE_MS = 200
      local REMOTE_MAX_PAUSE_MS = 2000
      local pause = REMOTE_MIN_PAUSE_MS
      local calls = 0
      while left > 0 and calls < REMOTE_MAX_CALLS do
        calls = calls + 1
        if cancelled() then return last, "run_cancelled" end
        local slice = math.min(left, REMOTE_SLICE_MS)
        local before = elapsed_ms()
        local answer, why = remote_operation(dispatch, record,
          { action = "await", id = record.op, wait_ms = slice, output = true, max_bytes = 24576, tool = "operation" })
        -- Decrement by the time the call ACTUALLY spent, not by the slice asked for (review r1, SHOULD 2):
        -- a peer that answered at once used to be charged the whole slice, so a budget bought fewer
        -- round trips than it paid for.
        left = math.max(0, left - math.max(REMOTE_MIN_CHARGE_MS, elapsed_ms() - before))
        if not answer then
          -- AN UNREACHABLE PEER IS NOT A FAILED COMMAND (review r1, SHOULD 3). A transport error during
          -- one slice says nothing about the operation: it may still be running there, and marking the
          -- local record final would hide work nobody stopped. Report it as PENDING with the reason; the
          -- next wait(op) - or the caller's own next step - asks the peer again.
          if last ~= nil and last.settled == true then return last, nil end
          return last, tostring(why)
        end
        last = answer
        if answer.settled == true then return answer, nil end
        if tostring(answer.error or "") == "operation_supervisor_overdue" then
          -- STOP, and say why: the peer's supervisor has stopped making progress on this operation, so
          -- another await would be the hot retry this loop exists to avoid. The handle stays resumable.
          return answer, "operation_supervisor_overdue"
        end
        if answer.error ~= nil and tostring(answer.error) ~= "await_interrupted" then
          -- The peer answered with an error that is not the harness interrupting its own wait: still not
          -- a settled command. Carry the word, keep the handle alive.
          reason = tostring(answer.error)
        end
        -- THE PAUSE: after every call that did not settle, before the next one. Bounded by what is left
        -- of the caller's own budget, so a pause never overshoots the wait it belongs to.
        if left > 0 and calls < REMOTE_MAX_CALLS then
          local wait = math.min(pause, left)
          if host.sleep then host.sleep(wait) end
          left = math.max(0, left - wait)
          pause = math.min(pause * 2, REMOTE_MAX_PAUSE_MS)
        end
      end
      if last == nil then
        local state, why = remote_operation(dispatch, record, { action = "status", id = record.op })
        if not state then return nil, why end
        last = state
      end
      return last, reason
    end,
    settle = function(dispatch, opts, record, state)
      local out = {}
      for key, value in pairs(type(state) == "table" and state or {}) do out[key] = value end
      out.operation_id = out.operation_id or record.op
      out.node = record.node
      out.adopted = true
      if out.code == nil then out.code = tonumber(out.process_exit_code) or tonumber(out.command_code) or -1 end
      if out.ok == nil then out.ok = out.code == 0 end
      return out
    end,
    progress = function(dispatch, opts, record, state)
      state = state or {}
      local entry = { state = tostring(state.state or "running"), node = record.node,
        op = record.op }
      if state.elapsed_ms ~= nil then entry.elapsed_ms = tonumber(state.elapsed_ms) end
      if state.output_bytes ~= nil then entry.output_bytes = tonumber(state.output_bytes) end
      if type(state.stdout) == "string" and state.stdout ~= "" then
        local tail = state.stdout:sub(-M.PROGRESS_BYTES)
        entry.tail = tail
      end
      return entry
    end,
    cancel = function(dispatch, opts, record)
      -- UNKNOWN IS NOT YES (review r1, MUST 1). The peer's cancel answer has four shapes and only one of
      -- them is a stop it observed: cancelled:true. A refusal and an already-settled operation both come
      -- back carrying the operation_id (operations.rs: the caller's own refusal, and "finished"), so an
      -- answer with an id is NOT proof of a stop - the earlier "answer.cancelled ~= false" read a refusal
      -- as a success and left the command running while the script had been told it was dead.
      local answer, why = remote_operation(dispatch, record, { action = "cancel", id = record.op })
      if not answer then
        return { op = record.op, tool = "remote", node = record.node, cancelled = false,
          error = "not_cancellable", why = tostring(why) }
      end
      if answer.error ~= nil then
        -- "finished" is news (the outcome is retained: wait(op) re-reads it), never a cancel.
        return { op = record.op, tool = "remote", node = record.node, cancelled = false,
          error = tostring(answer.error), state = answer.state,
          note = answer.note or (tostring(answer.error) == "finished"
            and "the call had finished first; wait(op) re-reads its retained result, and nothing was re-run"
            or nil) }
      end
      if answer.cancelled == true then
        return { op = record.op, tool = "remote", node = record.node, cancelled = true,
          state = "cancelled" }
      end
      -- The peer's cancel is a REQUEST: it sets the flag and answers the operation's own snapshot
      -- (rust/wa-operation/src/lib.rs "pub fn cancel" -> self.snapshot(id)), so the snapshot still says
      -- "running" for as long as the supervisor takes to notice. That is not a failure and not a success:
      -- watch it, briefly and by observation, and answer what was SEEN.
      -- OBSERVED, NOT SPUN (review r2, MUST 2). host.sleep takes whole MILLISECONDS (rust/wa-capabilities:
      -- "Block this interpreter for a bounded number of milliseconds"), so 0.2 was 0 ms and the old loop
      -- sent back-to-back relayed status calls for three seconds. Now: whole milliseconds, a doubling
      -- pause between calls, and a HARD CALL CAP, so the observation is a handful of calls by construction.
      local clock = function() return tonumber(host.monotonic_ms and host.monotonic_ms() or 0) or 0 end
      local CALL_CAP = 5
      local stop_by = clock() + 3000
      local pause = 200
      local state = answer
      local calls = 0
      while calls < CALL_CAP and clock() < stop_by do
        calls = calls + 1
        local observed, why_state = remote_operation(dispatch, record, { action = "status", id = record.op })
        if not observed then
          return { op = record.op, tool = "remote", node = record.node, cancelled = false,
            cancel_requested = true, error = "cancel_not_confirmed", state = state.state,
            why = tostring(why_state), calls = calls,
            note = "the stop was requested and the peer could not be asked again; the operation may still "
              .. "be running - check status on that node" }
        end
        state = observed
        local name = tostring(observed.state or "")
        if observed.cancelled == true or name == "cancelled" then
          return { op = record.op, tool = "remote", node = record.node, cancelled = true,
            state = "cancelled", calls = calls }
        end
        if observed.settled == true then
          return { op = record.op, tool = "remote", node = record.node, cancelled = false,
            error = "finished", state = name, calls = calls,
            note = "the call had finished first; wait(op) re-reads its retained result, and nothing was re-run" }
        end
        if clock() >= stop_by then break end
        if host.sleep then host.sleep(pause) end
        pause = math.min(pause * 2, 800)
      end
      return { op = record.op, tool = "remote", node = record.node, cancelled = false,
        cancel_requested = true, error = "cancel_not_confirmed", state = tostring(state.state or "running"),
        note = "the stop was requested and the operation had not settled when this answer was formed; it "
          .. "may still be running - check status on that node, then cancel again" }
    end,
  }
end

local function executor_of(record)
  return M.EXECUTORS[record.tool]
end

local function executor_poll(executor, dispatch, opts, record, ms)
  local poller = executor.poll or operation_poll
  return poller(dispatch, opts, record, ms)
end

local function executor_progress(executor, dispatch, opts, record, state)
  local progress = executor.progress or operation_progress
  local ok, value = pcall(progress, dispatch, opts, record, state)
  if ok and type(value) == "table" then return value end
  return { state = tostring(type(state) == "table" and state.state or "running") }
end

local function executor_settle(executor, dispatch, opts, record, state)
  local settle = executor.settle
  if not settle then return state end
  local ok, value = pcall(settle, dispatch, opts, record, state)
  if ok and value ~= nil then return value end
  return state
end

local function retain(result)
  local ok, encoded = pcall(json.encode, result)
  if not ok then return nil end
  local stored, reference = pcall(output.store, encoded)
  if not stored then return nil end
  return reference.sha256
end

-- Record that this handle settled, exactly once. `reported` is flipped by the waiter that observed
-- the outcome, so an op nobody resumed is announced on the next turn and never twice; a second
-- `wait` reads the retained result instead of writing the row again.
local function settle(executor, dispatch, opts, scope, index, record, state)
  local result = executor_settle(executor, dispatch, opts, record, state)
  record.reason = nil
  local executor_state = tostring(type(state) == "table" and state.state or "")
  if executor_state == "cancelled" then
    -- A cancelled operation is a failed call, never a done one: "it finished" is not what happened.
    record.state = "failed"
    record.error = "cancelled"
  else
    record.state = (type(result) == "table" and result.error) and "failed" or "done"
    record.error = record.state == "failed"
      and (type(result) == "table" and tostring(result.error or result.reason or result.state or "failed") or "failed") or nil
  end
  record.ok = record.state == "done"
  record.settled_at = now_seconds()
  record.result = retain(result)
  if record.result == nil then record.result_error = "result_not_retained" end
  record.reported = false
  record.progress = nil
  M.save(scope, index)
  return result
end

-- The retained result of a settled handle, read from disk: this is what a second `wait` and
-- `results.get(op)` answer. Never re-runs anything.
function M.retained(op, scope)
  local function look(index)
    local record = type(index) == "table" and index.ops and index.ops[op] or nil
    return type(record) == "table" and record or nil
  end
  local record = look(M.open(scope))
  if not record and scope == nil then
    -- No scope named: the handle alone is the question. The index directory is small (one file per
    -- scope, bounded per file); a handle is unique, so one match is the answer and two would be an
    -- error, never a guess.
    -- `host.list_dir` answers a JSON string (`{path, entries}` or `{error, path}`), not a table: a
    -- string put through `ipairs` yields its length, which is exactly the kind of silence that reads
    -- as "found nothing". Decoded once, here, and a directory that does not exist yet is not an error.
    local listing = host.list_dir and host.list_dir(M.dir()) or nil
    if type(listing) == "string" then listing = json.decode(listing) end
    local entries = type(listing) == "table" and (listing.entries or {}) or {}
    local seen = 0
    for _, item in ipairs(entries) do
      local name = tostring(type(item) == "table" and item.name or "")
      if name:match("%.json$") then
        seen = seen + 1
        if seen > 64 then break end
        local found = look(M.open(name:gsub("%.json$", "")))
        if found then
          if record then return nil, "ambiguous_op" end
          record = found
        end
      end
    end
  end
  if not record then return nil, "unknown_op" end
  if not record.result then return nil, record.state == "pending" and "still_running" or "no_retained_result" end
  local text = output.read(record.result, 0, 262144)
  if type(text) ~= "table" or type(text.content) ~= "string" then return nil, "retained_result_unreadable" end
  local ok, value = pcall(json.decode, text.content)
  if not ok then return nil, "retained_result_malformed" end
  return value, nil
end

-- Item #37: a pending call always answers its handle in PLAIN fields - `operation_id`,
-- `stdout_path` and `stderr_path` - not only inside `progress`. A script that must record where the
-- work's output will be cannot be made to reach through a nested table that a running op may not have
-- filled yet, and "which file do I read when this settles" is the first question a detached call
-- raises: stdout for the answer, stderr for why it failed, and both are the operation record's own
-- (absent is nil, never a guess). `op` stays beside `operation_id`: it is the name every existing
-- script and `wait(op)` already use.
-- CAN THIS HANDLE BE STOPPED (22/11). The next step a handle names offers `cancel(op)` only where a
-- cancel can do something: a kind whose effect cannot be stopped says so by name (`executor.cancel ==
-- false` plus its own `cancel_why`), and an outbox handle is stoppable only while it is still a
-- DRAFT - a sent message stays sent (`M.cancel`'s own words, and the reason its cancel is a function).
-- Every other kind answers through the local operation cancel.
local function stoppable(record)
  local executor = M.EXECUTORS[record.tool]
  if type(executor) == "table" then
    if executor.cancel == false then return false end
    if executor.kind == "outbox" then return record.draft ~= nil end
  end
  return true
end

-- HOW THIS CALL IS RESUMED (22/11, Victor). The handle said everything about WHERE the work is and
-- nothing about what to do with it: a real run (session fece6285, 22/11 11:21:04Z) read `stdout_path`
-- on the PEER and spent two round-trips - remote operation list, then await - on a call that
-- `wait(op)` answers in one. So every pending answer - bash, operation, remote, outbox, one shape -
-- carries ONE plain field naming the next step, with its own id in it.
local function next_step(record)
  local op = tostring(record.op)
  if stoppable(record) then
    return string.format('wait("%s") returns this call\'s result; cancel("%s") stops it', op, op)
  end
  return string.format('wait("%s") returns this call\'s result', op)
end

local function handle(record, waited_s, state)
  local out = { state = "pending", op = record.op, operation_id = record.op, tool = record.tool,
    waited_s = waited_s, progress = record.progress, next = next_step(record) }
  -- A remote op names the node it lives on: wait(op) and cancel(op) route there, and a caller that
  -- holds only the handle can always tell WHICH machine is still running its work (item 1).
  if record.node ~= nil then out.node = record.node end
  local source = type(state) == "table" and state or (type(record.progress) == "table" and record.progress or nil)
  if source then
    out.stdout_path = source.stdout_path
    out.stderr_path = source.stderr_path
    out.log_path = source.stdout_path
    out.output_bytes = source.output_bytes
    out.settled = source.settled
    out.state_name = source.state
  end
  return out
end

-- ONE RESULT SHAPE (21/11). A call that settles inside its wait answers the tool's own result - stdout,
-- code, ok - and wait(op) on the very same handle used to answer it one level down, under result. Two
-- shapes for one call is a cost the model paid: it read r.result.stdout on a flat answer, got nothing,
-- and spent three calls working out which shape it was holding. So a settled entry carries the tool's
-- result fields at the TOP LEVEL and the handle's own facts beside them:
--
--   {op, tool, state = "done", ...the tool's result fields...}
--
-- A failed entry is the same shape with state = "failed" and reason; a pending entry has no result to
-- flatten and keeps {op, tool, state = "pending", waited_s, progress}. The handle's own fields win where
-- a tool result uses the same word (an operation result's own state - "completed" - is kept as
-- state_name), so a script never has to guess which state it is reading. A list wait answers a list of
-- exactly these, in the order asked, and a settled handle's row in pending_settled carries the same
-- shape with result_sha256 added for results.get().
function M.flat_entry(op, tool, state, result, reason, retained)
  local entry = {}
  if type(result) == "table" then
    for key, value in pairs(result) do entry[key] = value end
  elseif result ~= nil then
    -- An executor that answers a bare value (nothing in this build does): keep it, under a name that
    -- cannot be mistaken for a handle field.
    entry.value = result
  end
  if state == "done" or state == "failed" then
    if entry.state ~= nil and entry.state ~= state then entry.state_name = entry.state end
    entry.state = state
    if entry.ok == nil then entry.ok = state == "done" end
  end
  entry.op = op
  if entry.tool == nil then entry.tool = tool end
  if retained ~= nil then entry.result_sha256 = retained end
  if reason ~= nil then entry.reason = tostring(reason) end
  return entry
end

-- ---------------------------------------------------------------------------- the call itself
-- Where the loop dispatches a tool, it calls this instead. No executor, or a tool whose executor does
-- not apply to these arguments, takes exactly the old path: `dispatch(name, params, raw)`.
function M.invoke(dispatch, opts, name, params, raw, wait_s)
  local executor = M.EXECUTORS[name]
  if not executor then return dispatch(name, params, raw) end
  if executor.applies and not executor.applies(params) then return dispatch(name, params, raw) end
  local scope = opts.scope
  local index = M.open(scope)
  if index.count >= M.MAX_OPEN then
    return { error = "codemode_pending_limit", limit = M.MAX_OPEN, open = index.count, effect = "none",
      note = "wait for, cancel or collect a handle you already have before starting another (" ..
        M.MAX_OPEN .. " pending calls per session; pending() lists them)" }
  end
  local started_at = now_seconds()
  local budget = M.effective_ms(wait_s, remaining_of(opts))
  -- The call starts at the node's own priority, whatever wait it named (18/11 round 3, item 5). The
  -- priority of work nobody waits for is applied at the ONE boundary where that becomes a fact - the end
  -- of the script that left the handle behind (M.background, called by lua/core/codemode.lua): at spawn
  -- the only knowable thing is the wait the caller asked for, which is a guess, and a wait_s:0 call the
  -- script resumes at once is foreground work from beginning to end.
  local started = executor.start(dispatch, opts, params, raw)
  if type(started) ~= "table" then return dispatch(name, params, raw) end
  if started.result ~= nil then
    -- The call finished as it always did: a refusal, a guarded command, an immediate answer.
    if started.op and started.register then
      index.ops[started.op] = { op = started.op, tool = name, kind = executor.kind, scope = scope,
        started_at = started_at, state = "running", reported = false, node = started.node }
      M.save(scope, index)
    end
    return started.result
  end
  local record = { op = started.op, tool = name, kind = executor.kind or "operation", scope = scope,
    started_at = started_at, state = "running", reported = false, id = started.id,
    -- The shell command's before-snapshot, kept with the handle it belongs to and read once, when
    -- that handle settles (watch_settle). It is this call's own evidence: a map of path -> porcelain
    -- status, never a file's text, and it is dropped at the moment it is compared.
    watch = started.watch,
    session = tostring(opts.session or ""), args = tostring(host.sha256(raw or "{}")),
    node = started.node,
    -- An outbox handle can be a DRAFT, and a draft is the one outbox handle a cancel can stop
    -- (`stoppable`): the executor answers it in `started.draft`, so the record keeps it.
    draft = started.draft }
  index.ops[record.op] = record
  local state, reason = executor_poll(executor, dispatch, opts, record, budget)
  if not state then
    record.state = "unknown"
    record.error = tostring(reason)
    M.save(scope, index)
    local out = handle(record, 0, nil)
    out.progress = { state = "unknown", reason = tostring(reason) }
    out.reason = tostring(reason)
    return out
  end
  if state.settled == true then
    local result = settle(executor, dispatch, opts, scope, index, record, state)
    record.reported = true
    M.save(scope, index)
    return result
  end
  record.progress = executor_progress(executor, dispatch, opts, record, state)
  record.reason = reason
  M.save(scope, index)
  -- The script is being told "not yet": that is the fact the script_cut_at_cap counter counts, once
  -- per script (opts is this script's own table), never once per call (lua/core/counters.lua).
  opts.cut_at_cap = true
  return handle(record, math.floor(budget / 1000), state)
end

-- ---------------------------------------------------------------------------- background(scope)
-- The end of a script's wait. A handle the script leaves behind is work NOBODY is waiting for any more,
-- and that is the one fact that should put it a step below the node (18/11 round 3, item 5). It is
-- applied here, once, at the boundary where the harness stops waiting - not at the spawn (where the only
-- knowable fact is the wait_s the caller asked for, which is a guess) and not on the way to pending (a
-- wait_s:0 call the script resumes at once must keep the node's own priority while it is waited on).
--
-- A read in every other sense: it dispatches no effect of the call, only the re-nice of work that is
-- already running. Best effort, and said: an executor with nothing to lower (the outbox: a queued
-- message is not this process's CPU) is skipped, and a node that refuses the call keeps the priority it
-- had with the refusal on the record, never in the way of the caller.
function M.background(scope, dispatch, opts)
  opts = type(opts) == "table" and opts or {}
  local index = M.open(scope)
  local lowered, failed = {}, {}
  for id, record in pairs(index.ops or {}) do
    local executor = executor_of(record)
    if open_record(record) and record.state == "running" and executor
      and type(executor.demote) == "function" then
      local ok, why = pcall(executor.demote, dispatch, record)
      if ok then
        lowered[#lowered + 1] = tostring(id)
      else
        record.demote_error = tostring(why)
        failed[#failed + 1] = tostring(id)
      end
    end
  end
  if #failed > 0 or #lowered > 0 then M.save(scope, index) end
  if #lowered == 0 and #failed == 0 then return nil end
  local answer = { count = #lowered, ops = lowered }
  if #failed > 0 then answer.failed = failed end
  return answer
end

-- ---------------------------------------------------------------------------- pending(): the pool
-- A READ: the handles this scope still holds, oldest first, so a later step or turn needs no memory
-- of them. It dispatches nothing, changes nothing, and reports progress from what the executor
-- already knows.
function M.list(dispatch, opts)
  local scope = opts and opts.scope
  local index = M.open(scope)
  local rows = {}
  for _, record in pairs(index.ops or {}) do
    if open_record(record) then rows[#rows + 1] = record end
  end
  table.sort(rows, function(a, b) return (tonumber(a.started_at) or 0) < (tonumber(b.started_at) or 0) end)
  local now = now_seconds()
  local ops = {}
  for position = 1, math.min(#rows, M.MAX_LIST) do
    local record = rows[position]
    local executor = executor_of(record) or {}
    local progress = record.progress
    if (not progress) and dispatch then
      local state, reason = executor_poll(executor, dispatch, opts, record, 0)
      if state then
        progress = executor_progress(executor, dispatch, opts, record, state)
        if reason and not progress.reason then progress.reason = reason end
      elseif reason then
        progress = { state = "unknown", reason = tostring(reason) }
      end
    end
    ops[#ops + 1] = { op = record.op, tool = record.tool, state = tostring(record.state or "running"),
      kind = record.kind, age_s = math.floor(now - (tonumber(record.started_at) or now)),
      node = record.node, progress = progress }
  end
  return { ok = true, ops = ops, count = #rows, limit = M.MAX_OPEN, shown = #ops,
    truncated = #rows > #ops }
end

-- ---------------------------------------------------------------------------- resume: wait(op)
-- `wait` is a READ. It dispatches nothing with an effect, takes no lock, and answers one entry per op
-- in the order asked - including every op `until:"any"` did not have to wait for, which is what lets
-- a step drop the finished ones, add new calls and wait again.
function M.wait(dispatch, opts, asked, wait_opts)
  wait_opts = type(wait_opts) == "table" and wait_opts or {}
  local single = type(asked) == "string"
  local list = single and { asked } or (type(asked) == "table" and asked or nil)
  if type(list) ~= "table" or #list == 0 then
    return { error = "wait_requires_an_op_or_a_list", effect = "none" }
  end
  if #list > M.MAX_BATCH then
    return { error = "wait_accepts_at_most_" .. M.MAX_BATCH .. "_ops", asked = #list, effect = "none" }
  end
  if wait_opts.wait_s ~= nil and tonumber(wait_opts.wait_s) == nil then
    return { error = "invalid_wait_s", got = tostring(wait_opts.wait_s), effect = "none" }
  end
  local until_kind = tostring(wait_opts["until"] or "all")
  if until_kind ~= "all" and until_kind ~= "any" then
    return { error = "wait_until_must_be_all_or_any", got = until_kind, effect = "none" }
  end
  local scope = opts.scope
  local index = M.open(scope)
  local budget = M.effective_ms(wait_opts.wait_s, remaining_of(opts))
  local answered = {}
  -- One budget for the whole batch, spent by what the batch waited: five ops in one `wait` do not
  -- buy five waits, they share the one the call asked for.
  local started = now_seconds()
  local function remaining()
    return math.max(0, budget - math.floor((now_seconds() - started) * 1000))
  end
  local stop_waiting = false
  for _, op in ipairs(list) do
    local id = tostring(op)
    local record = index.ops[id]
    local entry
    if type(record) ~= "table" then
      -- `reason`, not `error`: a failed entry is an answer a script branches on, not a refusal that
      -- throws. A refusal (a malformed request, 21 ops) still throws, because that is a bug in the
      -- script rather than news about a call.
      entry = { op = id, state = "failed", reason = "unknown_op",
        note = "no handle with this id in this scope; op ids come from {state:\"pending\", op} or pending()" }
    else
      local executor = executor_of(record)
      if not executor then
        entry = { op = id, tool = record.tool, state = "failed", reason = "no_executor",
          note = "this handle's tool has no detached executor in this build, so it cannot be resumed" }
      else
        -- `until:"any"` stops *waiting* after the first op that settled; the ops after it are still
        -- answered, with the state they have now, so the caller can see its whole pool.
        -- How much of its budget THIS op was given, and how much of it the poll really spent: the
        -- ground of the bound below. A wait that returned early (a short op of the same batch settled)
        -- spent only part of what the call asked for, and a poll was given none of it.
        local allowance = stop_waiting and 0 or remaining()
        local poll_started = now_seconds()
        local state, reason = executor_poll(executor, dispatch, opts, record, allowance)
        local spent_ms = math.max(0, math.floor((now_seconds() - poll_started) * 1000))
        if not state then
          entry = { op = id, tool = record.tool, state = "pending", waited_s = 0,
            progress = { state = "unknown", reason = tostring(reason) } }
        elseif state.settled == true then
          local result = settle(executor, dispatch, opts, scope, index, record, state)
          record.reported = true
          M.save(scope, index)
          -- The same flat shape a direct call answers (M.flat_entry): the tool's result fields at the
          -- top level, the handle's facts beside them.
          entry = M.flat_entry(id, record.tool, record.state, result,
            record.state ~= "done" and record.error or nil)
          if until_kind == "any" then stop_waiting = true end
        else
          record.progress = executor_progress(executor, dispatch, opts, record, state)
          record.reason = reason
          M.save(scope, index)
          opts.cut_at_cap = true
          entry = { op = id, tool = record.tool, state = "pending",
            waited_s = math.floor((budget - remaining()) / 1000), progress = record.progress }
          if reason and reason ~= "still_running" then entry.reason = reason end
          -- One op that never settles is bounded (18/11 round 2, finding 7): after the limit the
          -- script ends BY NAME instead of looping on a handle that will not change, and the sandbox
          -- slot comes back. The handle itself is untouched and still resumable - nothing is lost but
          -- this script's loop.
          --
          -- The count only moves for a wait that SPENT ITS WHOLE BUDGET and saw NO PROGRESS
          -- (18/11 round 3, item 2): a poll spends none of it, a wait cut short by a settled sibling
          -- did not use what it asked for, and any change in the op's own progress fields resets the
          -- count. A long build watched for an hour, and the pool loop that finishes short calls
          -- beside it, therefore survive; a silent op that is re-waited forever still ends here.
          local answers = opts.pending_answers
          if type(answers) ~= "table" then answers = {}; opts.pending_answers = answers end
          local seen = answers[id]
          if type(seen) ~= "table" then seen = { count = 0, progress = nil }; answers[id] = seen end
          local fingerprint = M.progress_fingerprint(record.progress)
          if seen.progress ~= fingerprint then
            seen.count = 0
            seen.progress = fingerprint
          elseif allowance >= M.full_wait_ms() and spent_ms + M.WHOLE_WAIT_SLACK_MS >= allowance then
            seen.count = seen.count + 1
          end
          local limit = M.pending_answer_limit()
          if seen.count >= limit then
            error(string.format("%s: op %s (%s) was waited on %d times in this script for its whole "
              .. "budget without progress: no output, no counter, no state change. The call itself is "
              .. "still running and its handle is kept. This is not a CPU stop and not a wall-clock "
              .. "limit on waiting, and a wait that saw any progress does not count: it is the bound "
              .. "on ONE op that never settles and never moves. Take the handle to a new step "
              .. "(pending() lists it, wait(op) resumes it there) or stop it with cancel(%s).",
              M.WAIT_BOUND_CODE, id, tostring(record.tool or "call"), seen.count, id), 0)
          end
        end
      end
    end
    answered[#answered + 1] = entry
  end
  if single then return answered[1] end
  return answered
end

-- ---------------------------------------------------------------------------- cancel(op)
-- Stopping is the one thing a handle can do to work that is still running. Where the effect cannot be
-- stopped the answer says so by name with the reason - a sent message stays sent, a landed deploy
-- stays landed - and nothing here pretends otherwise.
function M.cancel(dispatch, opts, asked)
  local ids = type(asked) == "string" and { asked } or (type(asked) == "table" and asked or nil)
  if type(ids) ~= "table" or #ids == 0 then
    return { error = "cancel_requires_an_op_or_a_list", effect = "none" }
  end
  if #ids > M.MAX_BATCH then
    return { error = "cancel_accepts_at_most_" .. M.MAX_BATCH .. "_ops", asked = #ids, effect = "none" }
  end
  local scope = opts.scope
  local index = M.open(scope)
  local out = {}
  for _, op in ipairs(ids) do
    local id = tostring(op)
    local record = index.ops[id]
    if type(record) ~= "table" then
      out[#out + 1] = { op = id, cancelled = false, error = "unknown_op" }
    elseif (executor_of(record) or {}).cancel == false then
      -- The kind says its effect cannot be stopped once it started: the answer is the reason, in the
      -- kind's own vocabulary, never a silent success (`a sent message stays sent`).
      local executor = executor_of(record) or {}
      out[#out + 1] = { op = id, tool = record.tool, cancelled = false,
        error = "not_cancellable", why = tostring(executor.cancel_why or
          "this effect cannot be stopped once it has started") }
    elseif type((executor_of(record) or {}).cancel) == "function" then
      local ok, answer = pcall(executor_of(record).cancel, dispatch, opts, record)
      out[#out + 1] = ok and answer or { op = id, tool = record.tool, cancelled = false,
        error = "not_cancellable", why = tostring(answer) }
      if ok and type(answer) == "table" and answer.cancelled then
        record.state = "cancelled"; record.reported = true; record.progress = nil
        M.save(scope, index)
      end
    else
      local state = snapshot(dispatch, id)
      if type(state) == "table" and state.settled == true then
        out[#out + 1] = { op = id, tool = record.tool, cancelled = false, state = record.state,
          error = "finished",
          note = "the call had finished first; the outcome is retained and wait(op) re-reads it" }
      else
        local stopped, reason = operation_call(dispatch, "cancel", { action = "cancel", id = id })
        if not stopped then
          out[#out + 1] = { op = id, tool = record.tool, cancelled = false,
            error = "not_cancellable", why = tostring(reason) }
        else
          record.state = "cancelled"
          record.reported = true
          record.progress = nil
          M.save(scope, index)
          out[#out + 1] = { op = id, tool = record.tool, cancelled = stopped.cancelled ~= false,
            state = "cancelled" }
        end
      end
    end
  end
  return #out == 1 and out[1] or out
end

-- ---------------------------------------------------------------------------- no orphans
-- Handles outlive the script, so something has to notice work that finished while nobody was waiting
-- on it. `begin` settles them (one poll per open handle, no waiting) and `announce` reports each one
-- exactly once, on the next script in that scope. Nothing is ever replayed.
function M.begin(dispatch, opts)
  local scope = opts.scope
  local index = M.open(scope)
  if index.count == 0 then return index end
  local changed = false
  for _, record in pairs(index.ops) do
    if open_record(record) and (record.state == "running" or record.state == "unknown") then
      local executor = executor_of(record)
      local state, reason = executor and executor_poll(executor, dispatch, opts, record, 0) or nil, nil
      if not executor then
        record.state = "unknown"
        record.error = "no_executor"
        changed = true
      elseif state and state.settled == true then
        settle(executor, dispatch, opts, scope, index, record, state)
        changed = true
      elseif state then
        record.state = "running"
        record.progress = executor_progress(executor, dispatch, opts, record, state)
        record.reason = reason
        changed = true
      end
    end
  end
  if changed then M.save(scope, index) end
  return index
end

-- The wake that carried this handle's news, as the store sees it ("pending"/"claimed"/"delivered"/
-- "cancelled"/"failed"/nil). Resolved lazily: this module is loaded BY lua/core/handle_wake.lua, which loads
-- selfloop, so a top-level require would be a cycle; a read that cannot reach the store answers nil, which
-- means "no wake", the same as no wake at all.
function M.handle_wake_state(op)
  local ok, selfloop = pcall(dofile, "lua/core/selfloop.lua")
  if not ok or type(selfloop) ~= "table" or type(selfloop.handle_wake_state) ~= "function" then return nil end
  local called, status = pcall(selfloop.handle_wake_state, op)
  return called and status or nil
end

-- Withdraw the pending wake for a handle this script has just announced (never an error for the caller: a
-- wake that cannot be reached is a wake the runner's own idempotence still protects).
function M.withdraw_wake(op)
  local ok, selfloop = pcall(dofile, "lua/core/selfloop.lua")
  if not ok or type(selfloop) ~= "table" or type(selfloop.withdraw_handle_wake) ~= "function" then return false end
  local called, done = pcall(selfloop.withdraw_handle_wake, op)
  return called and done == true
end

function M.announce(scope)
  local index = M.open(scope)
  if index.count == 0 then return nil end
  local out, changed = {}, false
  for _, record in pairs(index.ops) do
    if record.state ~= "running" and record.state ~= "unknown" and record.reported == false then
      -- THE IN-TURN NOTICE AND THE WAKE ARE ONE NOTICE (G blocker, Fable 24/11). Three orders are possible,
      -- and each must tell the model exactly once:
      --   * the wake was already DELIVERED (or claimed by a turn now running): that turn was the notice, so
      --     this script says nothing and marks it reported;
      --   * a wake is still PENDING: this script is the notice, so the row is withdrawn here and delivers
      --     nothing new - zero extra turns;
      --   * no wake at all: this script is the notice, as it always was.
      local wake = M.handle_wake_state(record.op)
      if wake == "delivered" or wake == "claimed" then
        record.reported = true
        changed = true
      else
        -- The value, not only its hash: an announced handle is read by a model that never called wait() on
        -- it, so the row must be the answer itself (the same flat shape), with the retained hash beside it
        -- for a later results.get(). A handle whose blob cannot be read is announced by name instead of
        -- silently answering an empty object.
        local value, why = M.retained(record.op, scope)
        local entry = M.flat_entry(record.op, record.tool, record.state, value,
          record.state ~= "done" and record.error or nil, record.result)
        if value == nil and why then entry.result_error = tostring(why) end
        out[#out + 1] = entry
        record.reported = true
        changed = true
        if wake == "pending" then M.withdraw_wake(record.op) end
      end
    end
  end
  if changed then M.save(scope, index) end
  if #out == 0 then return nil end
  table.sort(out, function(a, b) return tostring(a.op) < tostring(b.op) end)
  return out
end

-- ---------------------------------------------------------------------------- waking the session
-- A handle settles when its work ends, and the script that started it is usually long gone by then. Until
-- 21/11 that answer reached the model only if it happened to run another script in the same scope
-- (announce); now the node WAKES the session instead (docs/CODEMODE.md, "A settled handle wakes the
-- session"). This function is the settle half, and it is a read: poll every open handle of one scope
-- with NO wait, and hand each one that just settled to on_settled - exactly once, because the record is
-- marked the moment the wake is scheduled durably.
--
-- on_settled(record, value) returns true when the wake exists; the record is then marked woke_at AND
-- reported, so a later script's pending_settled does not say the same thing a second time. A false or a
-- raised callback leaves the record alone, and the next sweep tries again: an unscheduled wake is not a
-- lost answer, it is a retry.
function M.wake_settled(dispatch, opts, scope, on_settled)
  local index = M.open(scope)
  if index.count == 0 then return 0, index end
  local woken, changed = 0, false
  for _, record in pairs(index.ops) do
    if open_record(record) and record.woke_at == nil
      and (record.state == "running" or record.state == "unknown") then
      local executor = executor_of(record)
      if executor then
        local state = executor_poll(executor, dispatch, opts, record, 0)
        if type(state) == "table" and state.settled == true then
          settle(executor, dispatch, opts, scope, index, record, state)
          changed = true
          local value = record.result and select(1, M.retained(record.op, scope)) or nil
          local called, scheduled = pcall(on_settled or function() return false end, record, value)
          if called and scheduled then
            -- SCHEDULING IS NOT DELIVERY (G blocker, Fable 24/11). This used to set both `woke_at` and
            -- `reported`, and `reported` is what silences the in-turn notice (M.announce below). So a wake
            -- that was scheduled and then never delivered - measured on the live node: eight settle wakes
            -- refused `run_resource_refused ... resource_busy` because the session's own turn held the run
            -- claim - took the news away from both routes at once, and the model heard nothing unless it
            -- polled. `woke_at` alone gives exactly-once SCHEDULING (the same sweep, a restart and a second
            -- process all read it), and `reported` now flips only when a path actually reaches the model:
            -- the in-turn announce below, or the wake's own delivered turn.
            record.woke_at = now_seconds()
            woken = woken + 1
          end
        end
      end
    end
  end
  if changed or woken > 0 then M.save(scope, index) end
  return woken, index
end

-- The handles a scope still holds, oldest first, as the wake row lists them: what is still running after
-- a wake, with how long it has been running. A read.
function M.open_handles(scope, index)
  index = index or M.open(scope)
  local now, out = now_seconds(), {}
  for _, record in pairs(index.ops or {}) do
    if open_record(record) and (record.state == "running" or record.state == "unknown") then
      out[#out + 1] = { op = record.op, tool = record.tool, state = record.state,
        age_s = math.max(0, math.floor(now - (tonumber(record.started_at) or now))),
        reason = record.reason, progress = record.progress }
    end
  end
  table.sort(out, function(a, b) return tostring(a.op) < tostring(b.op) end)
  return out
end
-- in one place.
-- `searchTools("select:wait")` (and pending, cancel) answer these: the shape a script should expect,
-- in one place.
M.WAIT_HELP = {
  name = "wait",
  description = "Resume one pending call, or a batch of up to 20, that answered {state:\"pending\", op}. Answers one entry per op in the order asked, in the SAME shape a direct call answers: a settled op answers the call's own fields at the top level (stdout, code, ok, ...) with op, tool and state:\"done\" beside them; a failed one the same with state:\"failed\" and reason; a still-running one {state:\"pending\", op, tool, waited_s, progress}. It answers results, not handles - there is no result key to reach through. It dispatches nothing and never re-runs an effect, so it batches with anything. wait_s defaults to 60 and is capped at 300 (a script has no clock for a wait to outlive). A wait on one op that never settles ends the script by name (codemode_wait_never_settles) after " .. tostring(M.PENDING_ANSWER_LIMIT) .. " waits that each spent their whole budget - 30 s or more - WITHOUT PROGRESS: no change in that op's output, counters or state. A shorter poll does not count, and any progress resets the count. The handle survives, so the next script resumes it. until:\"any\" stops waiting at the first op that settled and still answers every op, finished or not, so a step can drop the finished, add new calls and wait again - a work pool that grows and shrinks, e.g. const open = (await pending()).ops.map(o => o.op); const done = (await Promise.all(open.map(op => wait(op, {wait_s:0})))).filter(e => e.state !== 'pending').map(e => e.op);",
  code = "const first = await tools.bash({command:'bash scripts/fast.sh'});\nif (first.state === 'pending') {\n  const [log, resumed] = await Promise.all([tools.read({path:'fast.log'}), wait(first.op, {wait_s:120})]);\n  return {resumed: resumed.state, tail: first.progress && first.progress.tail};\n}\nreturn {code: first.code};",
}

M.PENDING_HELP = {
  name = "pending",
  description = "The pending calls this session still holds, oldest first: {ok, ops:[{op, tool, state, kind, age_s, progress}], count, limit, shown, truncated}. It dispatches nothing and never re-runs an effect. Use it in a later step or turn instead of remembering handles - then wait(ops) resumes them, or wait(ops, {until:\"any\"}) answers which finished while the rest stay pending.",
  code = "const open = (await pending()).ops.map(o => o.op);\nconst entries = await wait(open, {until:'any'});\nreturn {open: open.length, done: entries.filter(e => e.state !== 'pending').map(e => e.op)};",
}

M.CANCEL_HELP = {
  name = "cancel",
  description = "Stop one pending call, or up to 20, by its op handle. Answers {op, cancelled:true, state:\"cancelled\"} when the work was stopped, {op, cancelled:false, error:\"finished\"} when it had finished first, and {op, cancelled:false, error:\"not_cancellable\", why:…} when the effect cannot be stopped - a sent message stays sent, a landed deploy stays landed. A cancelled call is never re-run.",
  code = "const started = await tools.bash({command:'sleep 300', wait_s:0});\nconst stopped = await cancel(started.op);\nreturn {op: started.op, cancelled: stopped.cancelled};",
}

return M
