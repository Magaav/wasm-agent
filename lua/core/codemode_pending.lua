-- One pending-call handle for every code-mode call (docs/CODEMODE.md, "Pending calls").
--
-- A call that can outlive its wait is the general case: a build, `scripts/fast.sh`, a deploy, a
-- download, a remote call, a long `bash`, an outbound message. Until 12/11 every one of them blocked
-- the script that started it, and the model could only choose a timeout and hope. The operator's
-- decision (Victor, 12/11) is one pattern for all of them: the call answers a *handle* when it is
-- still running after its wait, and `wait(op)` resumes it later - in the same script, the next step,
-- the next turn or a resumed session of the same scope.
--
-- This module is that pattern, and it is built on what the node already has rather than beside it:
--
--   * the work itself is a **managed operation** (`rust/wa-operation`, `operation start/status/wait/
--     read/cancel`). An operation already owns a child, an absolute budget, output cursors, a durable
--     per-operation record on disk and a terminal outcome - so a handle here is the operation id, the
--     very id `operation read` and `/operations` already answer. No second registry of running work
--     is invented; this file only remembers *which tool call* an operation is, and for which scope.
--   * settling, reading and cancelling go back through `dispatch('operation', …)`, so the profile,
--     role, workspace and permission checks are the ones every other call gets.
--
-- The three rules that make it safe:
--
--   1. **Starting is an effect; waiting is a read.** `invoke` is only ever called where the loop
--      already dispatches, in the loop's serial order. `wait`/`cancel` dispatch nothing that has an
--      effect of its own: they poll an operation that is already running.
--   2. **Nothing here holds a lock or a lease.** Every wait is a bounded `operation wait` slice
--      (<= 1 s) followed by a status read, looped until the deadline; the node's own settlement
--      condition variable does the blocking. A cancelled run, a stop/steer or a dead peer therefore
--      ends a wait at once and answers `pending`, never a hang and never a false `failed`.
--   3. **A resume never re-runs an effect.** The operation id *is* the handle: `wait` reads a
--      settled operation's retained output, and a second `wait` on the same id answers the same
--      bytes from disk. There is no code path from here back into the tool's dispatch.
--
-- What a handle does NOT do, named rather than hidden: a tool whose work runs *inside* this
-- interpreter cannot be moved off it, so a call can only become pending when the node has a detached
-- executor for it (`M.EXECUTORS`). Today that is `bash` and `operation` - the two the long work in a
-- run actually goes through. A tool with no executor answers exactly as it did before this file
-- existed; it is never turned into a handle that cannot settle.
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local output = dofile("lua/core/tool_output.lua")
local M = {}

-- The wait a call gets when it names none, and the ceiling on any wait. A script's own remaining time
-- is the third bound (`M.effective_ms`): a wait never outlives the script that started it.
M.DEFAULT_WAIT_S = 60
M.MAX_WAIT_S = 300
-- Reserved for the answer itself, the delivery into the guest and the script's return: a wait that
-- spent the script's last millisecond would answer a handle nobody could read.
M.MARGIN_MS = 2000
-- Concurrent handles one session may hold. Refused by name past it (`codemode_pending_limit`), never
-- by silently dropping the oldest - a dropped handle is work nobody can find again.
M.MAX_OPEN = 16
-- Operations one `wait` may ask about at once.
M.MAX_BATCH = 20
-- Bytes of an operation's output kept in `progress`.
M.PROGRESS_BYTES = 400
-- The longest single blocking slice. The node does the blocking natively, so this is not a relay
-- limit; it is what keeps a wait interruptible by a stop/steer without a long call to unwind.
M.SLICE_MS = 1000

-- ---------------------------------------------------------------------------- the record on disk
--
-- One index per scope (`<data>/codemode-pending/<scope>.json`), bounded by MAX_OPEN. It holds the
-- mapping handle -> tool call and nothing else: the work, its output and its outcome stay in the
-- operation's own record. A scope is the same hash the guest store and the results journal use
-- (session x user x role x workspace x profile), so "the same scope" is one meaning in this node.
function M.dir() return paths.data() .. "/codemode-pending" end
local function index_path(scope) return M.dir() .. "/" .. tostring(scope) .. ".json" end

local function now_seconds()
  local clock = host.now and host.now() or nil
  return tonumber(clock) or 0
end

function M.open(scope)
  local raw = host.read_file(index_path(scope))
  if type(raw) == "string" and raw ~= "" then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == "table" then
      -- `[]` decodes to an empty table, so both spellings of "no handles yet" land here.
      if type(decoded.ops) ~= "table" then decoded.ops = {} end
      local count = 0
      for _ in pairs(decoded.ops) do count = count + 1 end
      decoded.count = count
      return decoded
    end
  end
  return { ops = {}, count = 0 }
end

function M.save(scope, index)
  local count = 0
  for _ in pairs(index.ops or {}) do count = count + 1 end
  index.count = count
  local ok, encoded = pcall(json.encode, { ops = index.ops or {} })
  if not ok then return false end
  -- Best effort: a node that cannot write its index still has the operation's own record, so the
  -- work is never lost - only the name the model was given stops resolving, and `wait` says so.
  local written = host.write_file(index_path(scope), encoded)
  return written and true or false
end

-- ---------------------------------------------------------------------------- time and arguments
-- The one bound every wait obeys: what the call asked for (default 60 s), the ceiling (300 s) and
-- what is left of the script after the answer's own margin.
-- What is left of the script, from the loop's own clock: a function (re-read per call) or a number.
local function remaining_of(opts)
  if type(opts.remaining) == "function" then
    local ok, value = pcall(opts.remaining)
    if ok then return tonumber(value) end
  end
  return tonumber(opts.remaining_ms)
end

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
-- One entry per tool whose work the node can run detached. `start` hands the call to the operation
-- manager and answers `{op=…}` (or `{result=…}` when the call was refused, which is then delivered
-- unchanged); `settle` turns a settled operation into the result the tool would have answered.
local function operation_call(dispatch, action, args)
  local ok, value = pcall(dispatch, "operation", args, json.encode(args))
  if not ok then return nil, tostring(value) end
  if type(value) ~= "table" then return nil, "operation_" .. action .. "_malformed" end
  if value.error and not value.operation_id then return nil, tostring(value.error) end
  return value, nil
end

-- An operation's live state, without waiting: this is what `progress` is built from and what every
-- poll checks. A refusal or an unreachable supervisor is a reason, never a false `failed`.
local function snapshot(dispatch, op)
  local state, reason = operation_call(dispatch, "status", { action = "status", id = op })
  return state, reason
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

-- `progress`: the tail of what the call has printed, or the job's own state, bounded. A pending
-- answer without it is a wait the model cannot judge.
function M.progress(dispatch, op, state)
  state = state or {}
  local entry = { state = tostring(state.state or "running"), elapsed_ms = tonumber(state.elapsed_ms) }
  if state.remaining_ms ~= nil then entry.remaining_ms = tonumber(state.remaining_ms) end
  if state.shell_exited ~= nil then entry.shell_exited = state.shell_exited end
  if state.output_idle_ms ~= nil then entry.output_idle_ms = tonumber(state.output_idle_ms) end
  if state.promoted ~= nil then entry.promoted = state.promoted end
  entry.output_bytes = tonumber(state.output_bytes) or 0
  local line = tail(dispatch, op, state)
  if line then entry.tail = line end
  return entry
end

-- The result a settled operation answers. It is the operation's own state record, which is byte for
-- byte what `bash` already answers for an adopted tree (`operations::foreground` returns the same
-- snapshot): stdout, stderr, `output_complete`, `code`/`ok` and the timing all come from the record,
-- so a call that finished inside its wait reads exactly as it did before handles existed.
local function operation_result(dispatch, op, state)
  local out = {}
  for key, value in pairs(type(state) == "table" and state or {}) do out[key] = value end
  out.operation_id = out.operation_id or op
  -- The partial `operation status` snapshot carries the totals; the text of both streams is a page
  -- read, the same bounded pages the command result uses.
  local stdout = operation_call(dispatch, "read", { action = "read", id = op, stream = "stdout",
    offset = 0, limit = 24576 })
  if type(stdout) == "table" and type(stdout.content) == "string" then
    out.stdout = stdout.content
    out.stdout_truncated = (tonumber(stdout.available_bytes) or 0) > 24576
  end
  local stderr = operation_call(dispatch, "read", { action = "read", id = op, stream = "stderr",
    offset = 0, limit = 8192 })
  if type(stderr) == "table" and type(stderr.content) == "string" then
    out.stderr = stderr.content
    out.stderr_bytes = tonumber(stderr.available_bytes) or 0
    out.stderr_truncated = out.stderr_bytes > 8192
  end
  if out.code == nil then out.code = tonumber(out.process_exit_code) or tonumber(out.command_code) or -1 end
  if out.ok == nil then out.ok = out.code == 0 end
  if out.output_complete == nil then out.output_complete = out.output_streams_closed == true end
  return out
end

-- `bash`: the long one. It is started as a managed operation through the tool's own serial path
-- (`ctx.parallel_start`, the branch the model's parallel bash calls already use), so every check bash
-- makes - profile, session cwd, the commit review - runs before the shell does, and the path guard
-- runs here because `operation start` is not behind `host.exec`'s guard (`lua/core/path_guard.lua`).
local function bash_executor()
  return {
    kind = "operation",
    start = function(dispatch, opts, params, raw)
      local guard = dofile("lua/core/path_guard.lua")
      local copy = {}
      for key, value in pairs(type(params) == "table" and params or {}) do copy[key] = value end
      -- The deadline the synchronous path would have used: the configured default and any active
      -- child budget, so a subagent's remaining time still bounds the operation it starts.
      if copy.timeout_seconds == nil then
        local ok, seconds = pcall(function() return host.exec_timeout and host.exec_timeout() end)
        if ok and tonumber(seconds) then copy.timeout_seconds = math.floor(tonumber(seconds)) end
      end
      local allowed, refused = guard.command(copy.command, copy.cwd or "")
      if not allowed then return { result = { error = refused, effect = "none", blocked_by = "path_guard" } } end
      copy.command = guard.wrap(copy.command)
      local ctx = opts.ctx or {}
      local saved = ctx.parallel_start
      ctx.parallel_start = true
      local ok, result = pcall(dispatch, "bash", copy, raw)
      ctx.parallel_start = saved
      if not ok then return { result = { error = tostring(result), effect = "unknown", replay_allowed = false } } end
      if type(result) == "table" and type(result.operation_id) == "string" and result.operation_id ~= "" then
        return { op = result.operation_id }
      end
      -- A refusal, a guarded command, a rejected timeout: the call finished, and it answers as it
      -- always did. A refusal is never permission to run the command a second way.
      return { result = result }
    end,
    settle = function(dispatch, op, state) return operation_result(dispatch, op, state) end,
  }
end

-- `operation`: `await` on an id the caller already has becomes a bounded wait on that same operation
-- (its handle is already the id), and `start` is registered so `wait(op)` works on the receipt the
-- model just got. Neither changes what the tool answers.
local function operation_executor()
  return {
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
    settle = function(dispatch, op, state) return operation_result(dispatch, op, state) end,
  }
end

M.EXECUTORS = { bash = bash_executor(), operation = operation_executor() }

-- ---------------------------------------------------------------------------- polling
local function cancelled()
  local ok, raw = pcall(function() return host.run_cancelled and host.run_cancelled() end)
  if not ok or type(raw) ~= "string" then return false end
  -- Both returns of pcall, or a cancelled run reads as "not cancelled" and the wait runs to its
  -- deadline: that is the bug this line exists to not have (measured 12/11, caught by
  -- scripts/test-codemode-pending.lua's stop/steer check).
  local decoded_ok, decoded = pcall(json.decode, raw)
  return decoded_ok and type(decoded) == "table" and decoded.cancelled == true
end

-- Wait for one operation up to `ms`, in bounded slices. Answers the state and, when the wait ended
-- without settlement, the reason (`still_running`, `run_cancelled`, or the supervisor's own words).
function M.poll(dispatch, op, ms)
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
local function settle(dispatch, scope, index, record, state)
  local entry = M.EXECUTORS[record.tool]
  local result = state
  if entry and entry.settle then
    local ok, settled = pcall(entry.settle, dispatch, record.op, state)
    if ok and settled ~= nil then result = settled end
  end
  record.reason = nil
  -- A cancelled operation is a failed call, never a done one: the record says `failed` with
  -- `cancelled` as the reason, because "it finished" is not what happened to it.
  local operation_state = tostring(type(state) == "table" and state.state or "")
  if operation_state == "cancelled" then
    record.state = "failed"
    record.error = "cancelled"
  else
    record.state = (type(result) == "table" and result.error) and "failed" or "done"
    record.error = record.state == "failed"
      and (type(result) == "table" and tostring(result.error or result.state or "failed") or "failed") or nil
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
    -- No scope named: the handle alone is the question (`results.get(op)` inside a script of the same
    -- scope, a step that resumed a session). The index directory is small and bounded by MAX_OPEN per
    -- scope; a handle is unique, so one match is the answer and two would be an error, never a guess.
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

local function handle(record, waited_s)
  return { state = "pending", op = record.op, tool = record.tool,
    waited_s = waited_s, progress = record.progress }
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
      note = "wait for or cancel a handle you already have before starting another (" .. M.MAX_OPEN ..
        " pending calls per session)" }
  end
  local started_at = now_seconds()
  local started = executor.start(dispatch, opts, params, raw)
  if type(started) ~= "table" then return dispatch(name, params, raw) end
  if started.result ~= nil then
    -- The call finished as it always did: a refusal, a guarded command, an immediate answer.
    if started.op and started.register then
      index.ops[started.op] = { op = started.op, tool = name, kind = executor.kind, scope = scope,
        started_at = started_at, state = "running", reported = false }
      M.save(scope, index)
    end
    return started.result
  end
  local record = { op = started.op, tool = name, kind = executor.kind or "operation", scope = scope,
    started_at = started_at, state = "running", reported = false,
    session = tostring(opts.session or ""), args = tostring(host.sha256(raw or "{}")) }
  index.ops[record.op] = record
  local budget = M.effective_ms(wait_s, remaining_of(opts))
  local state, reason = M.poll(dispatch, record.op, budget)
  if not state then
    record.state = "unknown"
    record.error = tostring(reason)
    M.save(scope, index)
    return { state = "pending", op = record.op, tool = name, waited_s = 0,
      progress = { state = "unknown", reason = tostring(reason) } }
  end
  if state.settled == true then
    local result = settle(dispatch, scope, index, record, state)
    record.reported = true
    M.save(scope, index)
    return result
  end
  record.progress = M.progress(dispatch, record.op, state)
  record.reason = reason
  M.save(scope, index)
  return handle(record, math.floor(budget / 1000))
end

-- ---------------------------------------------------------------------------- resume: wait(op)
-- `wait` is a READ. It dispatches nothing with an effect, takes no lock, and answers one entry per
-- op in the order asked. Because it is a read the guest may batch it with anything:
-- `Promise.all([wait(a), tools.read({path}), wait(b)])`.
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
  -- `until` is a Lua keyword, so the option is read by key.
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
  for _, op in ipairs(list) do
    local id = tostring(op)
    local record = index.ops[id]
    local entry
    if type(record) ~= "table" then
      -- A handle from another scope, or one already collected: an explicit answer, never a guess.
      -- `reason`, not `error`: a failed entry is an answer a script branches on, not a refusal that
      -- throws. A refusal (a malformed request, 21 ops) still throws, because that is a bug in the
      -- script rather than news about a call.
      entry = { op = id, state = "failed", reason = "unknown_op",
        note = "no handle with this id in this scope; op ids come from {state:\"pending\", op}" }
    else
      local state, reason = M.poll(dispatch, id, remaining())
      if not state then
        entry = { op = id, tool = record.tool, state = "pending", waited_s = 0,
          progress = { state = "unknown", reason = tostring(reason) } }
      elseif state.settled == true then
        local result = settle(dispatch, scope, index, record, state)
        record.reported = true
        M.save(scope, index)
        entry = { op = id, tool = record.tool, state = record.state, result = result }
        if record.state ~= "done" then entry.reason = record.error end
      else
        record.progress = M.progress(dispatch, id, state)
        record.reason = reason
        M.save(scope, index)
        entry = { op = id, tool = record.tool, state = "pending",
          waited_s = math.floor((budget - remaining()) / 1000), progress = record.progress }
        if reason and reason ~= "still_running" then entry.reason = reason end
      end
    end
    answered[#answered + 1] = entry
    -- `until:"any"` stops at the first op that settled; the rest are answered nowhere, never
    -- guessed at, because the script asked for one.
    if until_kind == "any" and entry.state ~= "pending" then break end
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
    else
      local executor = M.EXECUTORS[record.tool] or {}
      if executor.cancel == false then
        -- The kind says its effect cannot be stopped once it started: the answer is the reason, in
        -- the recorder's own vocabulary, never a silent success (`a sent message stays sent`).
        out[#out + 1] = { op = id, tool = record.tool, cancelled = false,
          error = "not_cancellable", why = tostring(executor.cancel_why or
            "this effect cannot be stopped once it has started") }
      elseif type(executor.cancel) == "function" then
        local ok, answer = pcall(executor.cancel, dispatch, id, record)
        out[#out + 1] = ok and answer or { op = id, tool = record.tool, cancelled = false,
          error = "not_cancellable", why = tostring(answer) }
        if ok and type(answer) == "table" and answer.cancelled then
          record.state = "cancelled"; record.reported = true; record.progress = nil
          M.save(scope, index)
        end
      else
        local snapshot_state = snapshot(dispatch, id)
        if type(snapshot_state) == "table" and snapshot_state.settled == true then
          out[#out + 1] = { op = id, tool = record.tool, cancelled = false, state = record.state,
            error = "finished",
            note = "the call had already finished; the outcome is retained and wait(op) re-reads it" }
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
  end
  return #out == 1 and out[1] or out
end

-- ---------------------------------------------------------------------------- no orphans
-- Handles outlive the script, so something has to notice an operation that finished while nobody was
-- waiting on it. `begin` settles them (a status read per open handle, no waiting) and `announce`
-- reports each one exactly once, on the next script in that scope. Nothing is ever replayed.
function M.begin(dispatch, opts)
  local scope = opts.scope
  local index = M.open(scope)
  if index.count == 0 then return index end
  local changed = false
  for _, record in pairs(index.ops) do
    if record.state == "running" or record.state == "unknown" then
      local state = snapshot(dispatch, record.op)
      if type(state) == "table" and state.settled == true then
        settle(dispatch, scope, index, record, state)
        changed = true
      elseif type(state) == "table" then
        record.state = "running"
        record.progress = M.progress(dispatch, record.op, state)
        changed = true
      end
    end
  end
  if changed then M.save(scope, index) end
  return index
end

function M.announce(scope)
  local index = M.open(scope)
  if index.count == 0 then return nil end
  local out, changed = {}, false
  for _, record in pairs(index.ops) do
    if record.state ~= "running" and record.state ~= "unknown" and record.reported == false then
      out[#out + 1] = { op = record.op, tool = record.tool, state = record.state, ok = record.ok == true,
        result = record.result, error = record.error }
      record.reported = true
      changed = true
    end
  end
  if changed then M.save(scope, index) end
  if #out == 0 then return nil end
  table.sort(out, function(a, b) return tostring(a.op) < tostring(b.op) end)
  return out
end

-- `searchTools("select:wait")` answers these: the shape a script should expect, in one place.
M.WAIT_HELP = {
  name = "wait",
  description = "Resume one pending call, or a batch of up to 20, that answered {state:\"pending\", op}. Answers one entry per op in the order asked: {state:\"done\", op, tool, result} with the call's normal result, {state:\"failed\", op, error} when it failed, {state:\"pending\", op, progress, waited_s} while it is still running. A read: it dispatches nothing and never re-runs an effect, so it batches with anything - Promise.all([wait(a), tools.read({path}), wait(b)]). wait_s defaults to 60, is capped at 300 and at the script's remaining time; until:\"any\" returns as soon as one op has settled.",
  code = "const first = await tools.bash({command:'bash scripts/fast.sh'});\nif (first.state === 'pending') {\n  const [log, resumed] = await Promise.all([tools.read({path:'fast.log'}), wait(first.op, {wait_s:120})]);\n  return {resumed: resumed.state, tail: first.progress && first.progress.tail};\n}\nreturn {code: first.code};",
}

M.CANCEL_HELP = {
  name = "cancel",
  description = "Stop one pending call, or up to 20, by its op handle. Answers {op, cancelled:true, state:\"cancelled\"} when the work was stopped, {op, cancelled:false, error:\"finished\"} when it had finished first, and {op, cancelled:false, error:\"not_cancellable\", why:…} when the effect cannot be stopped - a sent message stays sent, a landed deploy stays landed. A cancelled call is never re-run.",
  code = "const started = await tools.bash({command:'sleep 300', wait_s:0});\nconst stopped = await cancel(started.op);\nreturn {op: started.op, cancelled: stopped.cancelled};",
}

return M
