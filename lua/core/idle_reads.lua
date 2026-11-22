-- The fresh reads a chat's idle prompt makes, done in a SUPERVISED CHILD PROCESS
-- (change/chat-start-guard, Victor 22/11).
--
-- WHY A PROCESS. `wa chat` runs a turn synchronously: while this interpreter is inside host.http the
-- whole CLI is gone, and an Enter pressed in that moment waits for the network. The local views the
-- client draws mid-run (local_views.lua: /nodes, /mcp, /login, /help, /keybindings) are exactly that
-- shape, and they are a PREFETCH - they exist so a /nodes typed WHILE A RUN IS IN FLIGHT has a recent
-- snapshot to draw from. Measured on the base in a real pty: the /mcp half alone blocked this
-- interpreter for 122 s on a peer that accepts and never answers (the roster's own probe children wait
-- up to 20 s each), and scripts/test-chat-start-pty.mjs measures the reader's Enter against it.
--
-- The host has one concurrency primitive - supervised operations - and lua/core/nodes.lua already uses
-- it for probe children. This is the same shape: M.tick STARTS `wa idle-reads` (a child that builds the
-- views and prints ONE JSON line) and, on a later tick, reads back a child that has settled and hands
-- its answer to the caller. Nothing here waits: a tick is a start, or a status read of an operation
-- that is already over.
--
-- WHAT IS NOT HERE, AND WHY: the provider's rolling limits (status.lua -> provider.limits, one HTTP
-- call per configured provider, 4-7 s against the real provider) CANNOT ride along. A child of this
-- node is a tool child, and the kernel withholds every provider credential from those by policy
-- (rust/wa-operation/src/lib.rs, DENY_ENV: WASM_AGENT_LLM_API_KEY and every *_API_KEY / *_TOKEN by
-- shape - session isolation finding 5). Measured: a child that asked its own provider answered
-- 'limits unavailable: provider not configured'. So the limits are read where they are ASKED for -
-- /status between runs, which is the reader's own request and the reader's own wait - and the mid-run
-- snapshot draws whatever the last such read left (status.lua M._limits) and says how old it is,
-- instead of this process making every Enter wait for a number nobody asked for yet.
--
-- WHAT THE ANSWER IS: {at, views = {{name, spec}, ...}, problems = {...}}. Each spec is the one
-- balloon.spec produces - the exact shape balloon.publish sends - so the child converts ONCE and the
-- parent only sends (local_views.publish_spec). The specs carry captured_at, so a panel drawn from an
-- old read says its age instead of pretending.
--
-- HOW OFTEN: one child per M.MAX_AGE seconds (60, the age at which a view is allowed to be rebuilt).
-- ABSENT CAPABILITY: no host.operation (an older binary, or a test) means no child: M.tick answers
-- with a named reason and the chat behaves as it did before this file existed.
local json = dofile('lua/vendor/json.lua')
local M = {}

-- Seconds between two prefetches: the age at which local_views is willing to rebuild a view.
M.MAX_AGE = 60
-- The operation this module owns and starts. owner is what keeps two callers' children apart in the
-- operation table (lua/core/nodes.lua sets its own for the same reason).
M.OWNER = "idle-reads"
-- The child's own deadline: a peer or a rendezvous that never answers costs this at most, and never
-- the reader's Enter.
M.DEADLINE_S = 120
-- A /nodes page for a node with 143 capabilities is a few dozen kilobytes of JSON; the cap is where
-- this stops reading a child's stdout rather than growing without a bound.
M.OUTPUT_LIMIT = 262144

-- ---- the child half: the views one prefetch builds, as the JSON the parent applies ----------------

-- Runs in the child (wa idle-reads) and in a test, with no view and no socket of its own.
function M.payload(opts)
  opts = opts or {}
  local out = { at = host.now(), views = {}, problems = {} }
  local session_id = tostring(opts.session_id or "")
  local loaded, views = pcall(function() return dofile('lua/core/local_views.lua') end)
  if not loaded or type(views) ~= 'table' then
    out.problems[#out.problems + 1] = 'views: ' .. tostring(views)
    return out
  end
  -- max_age = 0: the child is a fresh process, so every view is due. WHEN a child is worth starting is
  -- the parent's own clock (M.tick), not this one.
  local entries = views.collect({ max_age = 0, live_capabilities = false, session_id = session_id,
    ctx = opts.ctx or { user_id = 'master', role = 'master', session_id = session_id } })
  -- Each stack is converted HERE, once, by the one function that knows the client's shape
  -- (balloon.spec): a page carries Lua the client cannot take (a builder's own closures), and a spec
  -- that crossed a process must not be converted again on the other side (page links are 1-based here
  -- and 0-based there).
  local balloon = dofile('lua/core/balloon.lua')
  for _, entry in ipairs(entries or {}) do
    if entry.problem then out.problems[#out.problems + 1] = entry.problem end
    if type(entry.set) == 'table' then
      local converted, spec = pcall(balloon.spec, entry.name, entry.set.views, entry.set.captured_at)
      if converted and type(spec) == 'table' then out.views[#out.views + 1] = { name = entry.name, spec = spec }
      else out.problems[#out.problems + 1] = entry.name .. ': ' .. tostring(spec) end
    end
  end
  return out
end

-- wa idle-reads --session <id>: the prefetch of one chat, printed as one JSON line on stdout.
-- READ-ONLY: it reads the roster, the fleet cache and its own ledger, and writes nothing but that line
-- (the parent's publishers do the writing).
function M.cli(args)
  local session_id = ""
  for index = 2, #args do
    local word = tostring(args[index])
    if word == '--session' and args[index + 1] then session_id = tostring(args[index + 1])
    elseif word == '--help' or word == '-h' then
      print('usage: wa idle-reads --session <id>')
      print('  the fresh views a chat prompt makes, in a child process: one JSON line on stdout')
      return 0
    end
  end
  print(json.encode(M.payload({ session_id = session_id })))
  return 0
end

-- ---- the parent half: start one, read back one, never wait ------------------------------------

-- In the core's store, not a table here (docs/HOTRELOAD.md): a reload of this file mid-session must not
-- forget an operation this process already started (that would start a second child and leave the first
-- running, unread).
local reload = dofile('lua/core/reload.lua')
local state = reload.state("idle_reads")
if type(state.op) ~= "string" then state.op = nil end
if type(state.started) ~= "number" then state.started = 0 end
M._state = state

local function decode(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, value = pcall(json.decode, raw)
  if ok and type(value) == "table" then return value end
  return nil
end

local function binary_path()
  if type(host.runtime_info) ~= "function" then return "" end
  local ok, raw = pcall(host.runtime_info)
  local info = ok and decode(raw) or nil
  return tostring(info and info.binary_path or "")
end

-- A prefetch that cannot run is a COSMETIC loss (a panel that is older than it could be), never a line
-- in the middle of the conversation: the reason goes to the node's log once, the way local_views'
-- M.report does.
local function log_once(reason)
  reason = tostring(reason or "unknown")
  if state.reported == reason then return end
  state.reported = reason
  if type(host.log) == "function" then pcall(host.log, "idle reads: " .. reason) end
end

local function start(opts)
  if type(host.operation) ~= "function" then return false, "no_operation_host" end
  local program = binary_path()
  if program == "" then return false, "binary_path_unknown" end
  local argv = { "idle-reads", "--session", tostring(opts.session_id or "") }
  -- The ledger this process was TOLD to use, never a default the child would resolve for itself: a CLI
  -- started as `wa --db /scratch/x.db chat` has no WASM_AGENT_DB of its own to inherit, and a child that
  -- fell back to ~/.wasm-agent/memory.db would read the operator's ledger on behalf of a scratch one.
  local db = type(host.getenv) == "function" and tostring(host.getenv("WASM_AGENT_DB") or "") or ""
  if db ~= "" then table.insert(argv, 1, "--db"); table.insert(argv, 2, db) end
  local ok, receipt = pcall(host.operation, "start", json.encode({ program = program, args = argv,
    kind = "command", timeout_seconds = M.DEADLINE_S, owner = M.OWNER }))
  local answer = ok and decode(receipt) or nil
  local id = answer and answer.operation_id
  if not id then
    local why = ok and ("start_refused: " .. json.encode(answer or {})) or ("start_failed: " .. tostring(receipt))
    return false, why
  end
  state.op, state.started, state.reads = tostring(id), host.now(), 0
  return true
end

-- Read back a child that has settled. Answers TRUE when the operation is over (settled, refused or
-- unreadable) and FALSE while it is still running - never blocks on either.
local function settle(opts)
  local id = state.op
  -- owner = M.OWNER on EVERY call, not only on the start: a chat is a SESSIONLESS caller as far as the
  -- kernel is concerned, and a sessionless caller owns the rows that recorded its own owner and nothing
  -- else (rust/wa-capabilities/src/operations.rs, Caller::owns). Measured: without it every read back was
  -- refused 'operation_not_yours' and the prefetch never landed.
  local ok, raw = pcall(host.operation, "status", json.encode({ id = id, owner = M.OWNER }))
  local snapshot = ok and decode(raw) or nil
  if not ok or type(snapshot) ~= "table" then
    state.op = nil
    log_once("status_unreadable: " .. tostring(raw))
    return true
  end
  if snapshot.error and snapshot.settled ~= true then
    -- Another session's id, or one the host no longer knows: forget it rather than ask again every tick.
    state.op = nil
    log_once("status_refused: " .. tostring(snapshot.error))
    return true
  end
  if snapshot.settled ~= true then return false end
  -- NOT CLEARED YET, and the answer is retried: an operation can be settled a moment before its output
  -- is readable (measured 22/11: "idle reads: answer_unreadable: 0" with the child exit code in the
  -- state and its line on disk one tick later). The read below is the honest test, and a retry costs a
  -- tick of a settled operation - nothing is running.
  local read_ok, chunk = pcall(host.operation, "read",
    json.encode({ id = id, stream = "stdout", offset = 0, limit = M.OUTPUT_LIMIT, owner = M.OWNER }))
  local body = ""
  if read_ok then
    local value = decode(chunk)
    body = tostring(value and (value.content or value.data) or "")
  end
  -- The child prints one line; a child that printed more (a test's own value, a note on stdout) must not
  -- turn into a crash here. The answer is the LAST line carrying a views table.
  local payload = nil
  for line in body:gmatch("[^\r\n]+") do
    local one = decode(line)
    if one and type(one.views) == "table" then payload = one end
  end
  if not payload then
    state.reads = (tonumber(state.reads) or 0) + 1
    if state.reads <= 2 then return false end
    state.op, state.reads = nil, nil
    log_once("answer_unreadable: " .. tostring(snapshot.code or snapshot.state or ""))
    return true
  end
  state.op, state.reads = nil, nil
  if type(opts.apply) == "function" then
    local applied, why = pcall(opts.apply, payload)
    if not applied then log_once("apply_failed: " .. tostring(why)) end
  end
  return true
end

-- One idle tick: finish what a previous tick started, and start the next one when it is due. Answers
-- {started, settled, in_flight, reason} and NEVER waits on the network or on the child.
function M.tick(opts)
  opts = opts or {}
  if state.op then
    if not settle(opts) then return { started = false, settled = false, in_flight = true } end
  end
  local now = host.now()
  if now - tonumber(state.started or 0) < (tonumber(opts.max_age) or M.MAX_AGE) then
    return { started = false, settled = true }
  end
  local ok, why = start(opts)
  -- A start that could not happen waits a full interval before it is tried again: a refusal retried at
  -- every idle tick (every two seconds) is a spawn loop, not a prefetch.
  state.started = now
  if not ok then log_once(why) end
  return { started = ok, settled = not ok, reason = why }
end

-- Forget what is in flight and what has been reported. For tests, and for a caller whose session changed.
function M.forget()
  state.op, state.started, state.reported = nil, 0, nil
end

return M
