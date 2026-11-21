-- The ONE agent-control implementation: fork, spawn, events, collect, cancel, resume, message, list.
--
-- This module is what wit/agent-control/agent-control.wit describes, expressed over the machinery that
-- already exists rather than beside it:
--
--   fork     memory.fork_session + workspaces.ensure, the same pair POST /fork runs;
--   spawn    subagents.start (admission, depth, budgets) or orchestrator.enqueue (placement on a peer),
--            chosen by one rule - a named node, or placement enabled for this owner;
--   events   the durable ledger, read in bounded pages: a child's first turn is "started", a turn that
--            committed is "commit" with the commits read from its own checkout, and a settled run is
--            "done" with its state. A parent learns what happened WITHOUT a model round asking;
--   collect  a settled run read as data: reply, commits, files, failures, rounds, tokens, usage;
--   cancel   subagents.control("cancel"); the state is cancelling until the run really ended;
--   resume   subagents.control("message"), the one continuation path, key required;
--   message  subagents.control("steer") for a live child, with its delivery word as it came;
--   list     the tree: the spawned runs of a session plus the forks it made.
--
-- Every caller - the model's subagent tool, POST /subagents, the CLI and (in change/fabric-bridge) the
-- bridge - comes through here, so they cannot disagree about what a child is doing. Owner, role and
-- session arrive in ctx, built by the server; nothing in a request body names them.
--
-- WHY THE LEDGER AND NOT A NEW STORE. A child is a session the parent owns, and the facts this API
-- reports are already durable there: the child's own turns, its workspace binding (branch, worktree,
-- ahead/dirty), its native receipt. A second store would be a second truth, and the first to disagree.
-- The one thing added here is the vocabulary the WIT needs and the ledger lacks: which run a fork
-- belongs to (agent_control), so the parent-to-child link survives a restart.
local json = dofile("lua/vendor/json.lua")
local memory = dofile("lua/core/memory.lua")
local workspaces = dofile("lua/core/workspaces.lua")
local M = {}

-- The states wit/agent-control names. A value outside this set is never invented: it reads unknown, and
-- the caller is told which word the node actually used (native_state).
M.STATES = {
  queued = true, running = true, cancelling = true, cancelled = true,
  completed = true, failed = true, unknown = true,
}

local function as_id(value)
  if type(value) == "string" and value ~= "" then return value end
  if type(value) == "number" then return tostring(value) end
  return nil
end

-- The state a native receipt or placement row reports, mapped onto the one allow-list.
function M.state_of(value)
  local word = tostring(value or "")
  if M.STATES[word] then return word end
  if word == "done" then return "completed" end
  if word == "error" then return "failed" end
  return "unknown"
end

local function age_ms(epoch_seconds)
  local at = tonumber(epoch_seconds)
  if not at or at <= 0 then return nil end
  local delta = (tonumber(host.now()) or 0) - at
  if delta < 0 then delta = 0 end
  return math.floor(delta * 1000)
end

function M.age_ms(stamp) return age_ms(stamp) end

--------------------------------------------------------------------------- ledger
local function sql(kind, statement, values)
  local ok, raw = pcall(host[kind], statement, json.encode(values or {}))
  if not ok then return nil, tostring(raw) end
  local decoded = json.decode(raw)
  if type(decoded) ~= "table" then return nil, "ledger_no_result" end
  if decoded.error then return nil, tostring(decoded.error) end
  return decoded
end
local function query(statement, values)
  local result, why = sql("sql_query", statement, values)
  if not result then error(why or "ledger_query_failed", 0) end
  return result
end
local function exec(statement, values)
  local result, why = sql("sql_exec", statement, values)
  if not result then error(why or "ledger_write_failed", 0) end
  return result
end

-- The one row this API adds: which run a fork belongs to. Created lazily, so a ledger written by an
-- older build still answers every other call.
local SCHEMA = "CREATE TABLE IF NOT EXISTS agent_control("
  .. "child_id TEXT PRIMARY KEY, parent_session TEXT, parent_run TEXT, kind TEXT,"
  .. " source_session TEXT, source_seq INTEGER, node TEXT, created_at REAL)"
local schema_ready = false
-- Returns TRUE when the table is there. It wrote no return value once, so every read treated the ledger
-- as absent and a fork never appeared in list - the caller could not tell "no rows" from "not ready".
local function ready()
  if schema_ready then return true end
  local ok = pcall(exec, SCHEMA)
  schema_ready = ok == true
  return schema_ready
end

function M.control_row(id)
  if not ready() then return nil end
  local ok, rows = pcall(query, "SELECT * FROM agent_control WHERE child_id=?", { id })
  if not ok then return nil end
  return rows[1]
end

local function record_control(id, fields)
  if not ready() or not id or id == "" then return end
  pcall(exec, "INSERT INTO agent_control(child_id,parent_session,parent_run,kind,source_session,source_seq,node,created_at)"
    .. " VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(child_id) DO UPDATE SET"
    .. " parent_session=excluded.parent_session, parent_run=excluded.parent_run, kind=excluded.kind,"
    .. " source_session=excluded.source_session, source_seq=excluded.source_seq, node=excluded.node",
    { id, fields.parent_session or "", fields.parent_run or "", fields.kind or "",
      fields.source_session or "", fields.source_seq or 0, fields.node or "",
      tonumber(host.now()) or 0 })
end

--------------------------------------------------------------------------- the owner gate
local function parent_session_of(args, ctx)
  local requested = as_id(args.session or args.parent_session_id or args.thread)
  if not requested or requested == "" then return ctx.session_id end
  return requested
end

-- Is this session one the caller may inspect? A session it owns, or the caller's own. Anything else is
-- refused BY NAME: a session link must never be a way to read someone else's work.
local function readable_session(session_id, ctx)
  if session_id == ctx.session_id then return true end
  local record = memory.session(session_id)
  if not record then return nil, "unknown_session" end
  if record.user_id == ctx.user_id then return true end
  return nil, "forbidden_parent_session"
end
M.readable_session = readable_session

--------------------------------------------------------------------------- children of a session
local function session_ctx(ctx, session_id)
  local copy = {}
  for key, value in pairs(ctx) do copy[key] = value end
  copy.session_id = session_id
  return copy
end

-- A session's spawned children, as the native facade lists them. The context is the CALLER's (owner and
-- role), with the session pointed at the one being listed - never a fabricated master.
local function native_children(session_id, ctx)
  local api = dofile("lua/core/subagents.lua")
  local ok, listed = pcall(api.control, { action = "list", session = session_id }, session_ctx(ctx, session_id))
  if not ok or type(listed) ~= "table" or type(listed.subagents) ~= "table" then return {} end
  local rows = {}
  for _, item in ipairs(listed.subagents) do rows[#rows + 1] = item end
  return rows
end

-- Round and token counts, read from the child's own turns: its own interpreter writes them, so this is
-- the only honest source. Bounded to the aggregate the row needs.
local function usage_of(session_id)
  if not session_id or session_id == "" then return 0, 0 end
  local ok, rows = pcall(query,
    "SELECT COUNT(*) AS rounds, COALESCE(SUM(tokens),0) AS tokens FROM messages"
    .. " WHERE session_id=? AND role='assistant'", { session_id })
  if not ok or not rows or not rows[1] then return 0, 0 end
  return tonumber(rows[1].rounds) or 0, tonumber(rows[1].tokens) or 0
end

local function base_child(fields)
  local child = {
    id = fields.id,
    session = fields.session or "",
    parent_session = fields.parent_session or "",
    parent_run = fields.parent_run or "",
    node = fields.node or "",
    depth = tonumber(fields.depth) or 1,
    state = M.state_of(fields.state),
    profile = fields.profile or (fields.kind == "fork" and "fork" or ""),
    title = fields.title or "",
    created_at_ms = math.floor((tonumber(fields.created_at) or 0) * 1000),
    rounds = tonumber(fields.rounds) or 0,
    tokens = tonumber(fields.tokens) or 0,
    age_ms = age_ms(fields.created_at) or 0,
  }
  if tonumber(fields.started_at) then child.started_at_ms = math.floor(tonumber(fields.started_at) * 1000) end
  if tonumber(fields.settled_at) then child.settled_at_ms = math.floor(tonumber(fields.settled_at) * 1000) end
  if fields.native and fields.native ~= "" and fields.native ~= child.state then child.native_state = fields.native end
  return child
end
M.child_of = base_child

-- A spawned run, as one child.
function M.child_from_run(run, control)
  run = run or {}
  local state = run.state
  if run.settled == true and (state == nil or state == "" or state == "running" or state == "queued") then
    state = (type(run.error) == "string" and run.error ~= "") and "failed" or "completed"
  end
  local rounds, tokens = usage_of(run.session_id or "")
  return base_child({
    id = run.subagent_id or run.id,
    session = run.session_id or "",
    parent_session = run.parent_session_id or (control and control.parent_session),
    parent_run = run.parent_run_id or (control and control.parent_run),
    node = run.node_id or (control and control.node) or "local",
    depth = run.depth,
    state = state, native = tostring(state or ""),
    profile = run.profile, title = run.title,
    created_at = run.created_at, started_at = run.started_at, settled_at = run.settled_at,
    rounds = rounds, tokens = tokens,
  })
end

-- A fork, as one child. A fork is idle by design: it reads running until its own session has ended.
function M.child_from_fork(row)
  if type(row) ~= "table" then return nil end
  local session = memory.session(row.child_id)
  local state, started_at, settled_at = "unknown", nil, nil
  if session then
    state = "running"
    started_at = session.started_at
    if tostring(session.ended_at or "") ~= "" then
      state = "completed"
      settled_at = session.ended_at
    end
  end
  local rounds, tokens = usage_of(row.child_id)
  return base_child({
    id = row.child_id, session = row.child_id, parent_session = row.parent_session,
    parent_run = row.parent_run, node = row.node, depth = 1,
    state = state, profile = "fork",
    title = session and session.title or ("Fork of " .. tostring(row.source_session)),
    created_at = row.created_at, started_at = started_at, settled_at = settled_at,
    rounds = rounds, tokens = tokens,
  })
end

local function children_of(session_id, ctx)
  local children, seen = {}, {}
  for _, run in ipairs(native_children(session_id, ctx)) do
    local child = M.child_from_run(run, M.control_row(run.subagent_id))
    if child.id and not seen[child.id] then seen[child.id] = true; children[#children + 1] = child end
  end
  if ready() then
    local ok, forks = pcall(query, "SELECT * FROM agent_control WHERE parent_session=? AND kind='fork'", { session_id })
    for _, row in ipairs(ok and forks or {}) do
      if not seen[row.child_id] then seen[row.child_id] = true; children[#children + 1] = M.child_from_fork(row) end
    end
  end
  table.sort(children, function(a, b) return (a.created_at_ms or 0) > (b.created_at_ms or 0) end)
  return children
end
M.children_of = children_of

--------------------------------------------------------------------------- list
function M.list(args, ctx)
  args = args or {}
  local session_id = parent_session_of(args, ctx) or ""
  if session_id == "" then return { error = "session_required", children = {} } end
  local ok, why = readable_session(session_id, ctx)
  if not ok then return { error = why, children = {} } end
  local children = children_of(session_id, ctx)
  local summary = #children == 0 and "no children"
    or table.concat((function()
        local parts = {}
        for _, child in ipairs(children) do parts[#parts + 1] = child.title:sub(1, 24) .. " " .. child.state end
        return parts
      end)(), ", ")
  return { session = session_id, children = children, summary = summary }
end

--------------------------------------------------------------------------- fork
function M.fork(args, ctx)
  args = args or {}
  local source = as_id(args.session or args.session_id) or ctx.session_id
  if not source or source == "" then return { error = "session_required", not_started = true } end
  local ok, why = readable_session(source, ctx)
  if not ok then return { error = why, not_started = true } end
  local source_row = memory.session(source)
  if not source_row then return { error = "unknown_session", not_started = true } end
  if source_row.user_id ~= ctx.user_id then return { error = "forbidden", not_started = true } end
  local before = tonumber(args.before_seq or args.beforeSeq)
  if not before then
    local latest = query("SELECT MAX(seq) AS seq FROM messages WHERE session_id=? AND role<>'summary'", { source })[1]
    before = latest and tonumber(latest.seq) or nil
  end
  if not before then return { error = "invalid_boundary", not_started = true } end
  local id, fork_why = memory.fork_session(source, before, ctx.user_id)
  if not id then return { error = fork_why or "fork_failed", not_started = true } end
  local fields = { child_id = id, parent_session = source, parent_run = ctx.run_id or "", kind = "fork",
    source_session = source, source_seq = before, node = ctx.node_id or "" }
  record_control(id, fields)
  local workspace, allocation = workspaces.ensure(memory, id, source)
  local child = M.child_from_fork(M.control_row(id))
    or M.child_from_fork({ child_id = id, parent_session = source, parent_run = ctx.run_id or "",
      source_session = source, created_at = host.now() })
  if not workspace then
    -- The session exists and is the caller's: the refusal keeps the workspace's own word, and the child
    -- is reported so the caller recovers it instead of forking a second time.
    return { error = workspaces.refusal_code(allocation), detail = allocation, child = child }
  end
  return child
end

--------------------------------------------------------------------------- spawn
local function brief_fields(brief, node)
  brief = brief or {}
  local node_value = nil
  if brief.node ~= nil then node_value = tostring(brief.node) end
  if node ~= nil then node_value = tostring(node) end
  return {
    prompt = tostring(brief.prompt or ""),
    profile = brief.profile and tostring(brief.profile) or nil,
    context = brief.context and tostring(brief.context) or nil,
    base = brief.base and tostring(brief.base) or nil,
    model = brief.model and tostring(brief.model) or nil,
    reasoning = brief.reasoning and tostring(brief.reasoning) or nil,
    idempotency_key = brief.idempotency_key and tostring(brief.idempotency_key) or nil,
    timeout_ms = tonumber(brief.timeout_ms),
    max_tokens = tonumber(brief.max_tokens),
    node = node_value,
  }
end

local function run_args(fields)
  local args = { action = "start", prompt = fields.prompt }
  for _, key in ipairs({ "profile", "context", "model", "reasoning", "idempotency_key" }) do
    if fields[key] then args[key] = fields[key] end
  end
  if fields.timeout_ms then args.timeout_ms = fields.timeout_ms end
  if fields.max_tokens then args.max_tokens = fields.max_tokens end
  if fields.base then args.base = fields.base end
  return args
end

function M.spawn(args, ctx)
  args = args or {}
  local fields = brief_fields(args.brief or args, args.node)
  if fields.prompt == "" then return { error = "prompt_required", not_started = true } end
  if ctx.subagent then return { error = "subagent_recursion_forbidden", not_started = true } end

  local orchestrator = dofile("lua/core/orchestrator.lua")
  local placement = false
  if not ctx.remote then placement = orchestrator.enabled(ctx.user_id) end
  if fields.node then
    local users = dofile("lua/core/users.lua")
    local user = users.find(ctx.user_id)
    if not user or not users.is_master(user.role) then return { error = "forbidden", not_started = true } end
    if not dofile("lua/core/nodes.lua").is_master() then return { error = "forbidden", not_started = true } end
    local approved = false
    for _, item in ipairs(orchestrator.policy(ctx.user_id).nodes or {}) do
      if item.node == fields.node and tonumber(item.max_tasks or 0) > 0 then approved = true end
    end
    if not approved then
      -- Named, not guessed: the caller asked for a destination its own policy does not hold, so nothing
      -- ran and nothing will until the policy names it (or the caller spawns locally).
      return { error = "node_not_in_approved_policy", node = fields.node, not_started = true,
        next_action = "Add the node to the owner's placement policy, or spawn on this node." }
    end
    if not dofile("lua/core/nodes.lua").find(fields.node) then
      return { error = "unknown_node", node = fields.node, not_started = true }
    end
    placement = true
  end

  local run = run_args(fields)
  if placement then
    run.placement = true
    local queued = orchestrator.enqueue(run, ctx)
    if queued.error then return queued end
    local dispatch_id = queued.subagent_id or queued.id
    record_control(dispatch_id, { parent_session = ctx.session_id, parent_run = ctx.run_id or "",
      kind = "run", node = fields.node or "placement" })
    local child = M.child_from_run(queued, M.control_row(dispatch_id))
    child.dispatch_state = queued.dispatch_state
    child.note = queued.note
    return child
  end

  local api = dofile("lua/core/subagents.lua")
  local started = api.start(run, ctx)
  if type(started) ~= "table" then return { error = "subagent_runtime_error", not_started = true } end
  if not started.subagent_id then return started end
  record_control(started.subagent_id, { parent_session = ctx.session_id, parent_run = ctx.run_id or "",
    kind = "run", node = "local" })
  return M.child_from_run(started, M.control_row(started.subagent_id))
end

--------------------------------------------------------------------------- collect
local function receipt_of(id, ctx)
  local control = M.control_row(id)
  if control and control.kind == "fork" then return nil, control end
  -- "result", not "status": the native status action deliberately REMOVES the result field (it is the
  -- smaller observation), and collect's whole job is that field. Same record, one key more.
  local ok, raw = pcall(host.subagent, "result", json.encode({
    owner_user = ctx.user_id, session = ctx.session_id, id = id }))
  if not ok then return { error = "subagent_runtime_error" }, control end
  return json.decode(raw), control
end

-- The commits in a child's own checkout, read from git, bounded to three. A child with no managed
-- workspace has none, and that is said rather than reported as an empty history.
local function commits_of(session_id)
  local workspace = session_id and memory.session_workspace(session_id)
  if not workspace or tostring(workspace.worktree or "") == "" then return {}, "no_managed_workspace" end
  local quoted = string.format("%q", tostring(workspace.worktree))
  local ok, raw = pcall(host.exec, "git -C " .. quoted .. " log --format=%H%x09%ct%x09%s -n 3", "", 60)
  if not ok or type(raw) ~= "string" then return {}, "git_unavailable" end
  local decoded_ok, result = pcall(json.decode, raw)
  local text = raw
  if decoded_ok and type(result) == "table" then text = tostring(result.stdout or "") end
  local commits = {}
  for line in text:gmatch("[^\r\n]+") do
    local sha, at, subject = line:match("^(%x+)%s+(%d+)%s+(.+)$")
    if sha then commits[#commits + 1] = { sha = sha, subject = subject:sub(1, 200), at_ms = (tonumber(at) or 0) * 1000 } end
  end
  if #commits == 0 then return {}, "no_commits_read" end
  return commits, nil
end
M.commits_of = commits_of

function M.collect(args, ctx)
  args = args or {}
  local id = as_id(args.id or args.subagent_id)
  if not id then return { error = "id_required" } end
  local receipt, control = receipt_of(id, ctx)
  if control and control.kind == "fork" then
    return { error = "fork_has_no_run", child = M.child_from_fork(control),
      next_action = "A fork answers on its own turns; read its session, or continue it with wa chat --resume." }
  end
  if type(receipt) ~= "table" then return { error = "subagent_runtime_error" } end
  if receipt.error and not receipt.subagent_id then return receipt end
  local state = M.state_of(receipt.state)
  local settled = receipt.settled == true
  if not settled and (state == "running" or state == "queued" or state == "cancelling") then
    return { error = "child_running", state = state, id = id, age_ms = age_ms(receipt.created_at) or 0 }
  end
  local inner = type(receipt.result) == "table" and receipt.result or {}
  local reply = type(inner.reply) == "string" and inner.reply or nil
  local reply_truncated = false
  if reply and #reply > 60000 then reply = reply:sub(1, 60000); reply_truncated = true end
  if inner.truncated == true then reply_truncated = true end
  local accounting = type(receipt.accounting) == "table" and receipt.accounting or {}
  local usage = type(accounting.usage) == "table" and accounting.usage or {}
  local rounds, tokens = usage_of(receipt.session_id)
  local commits, commit_reason = commits_of(receipt.session_id)
  local failures = {}
  if type(receipt.error) == "string" and receipt.error ~= "" then
    failures[#failures + 1] = { kind = "run", detail = receipt.error:sub(1, 2000),
      at_ms = (tonumber(receipt.settled_at) or 0) * 1000 }
  end
  local answer = {
    id = id, state = state, reply = reply, reply_truncated = reply_truncated,
    commits = commits, files = {}, failures = failures,
    rounds = rounds, tokens = tonumber(usage.total_tokens) or tokens,
    usage_available = usage.available == true,
    rc = tonumber(inner.rc),
  }
  if not answer.usage_available then answer.usage_reason = tostring(usage.reason or "not_measured") end
  if commit_reason then answer.commits_reason = commit_reason end
  if state == "unknown" and receipt.state then answer.native_state = tostring(receipt.state) end
  return answer
end

--------------------------------------------------------------------------- cancel
function M.cancel(args, ctx)
  args = args or {}
  local id = as_id(args.id or args.subagent_id)
  if not id then return { error = "id_required" } end
  local control = M.control_row(id)
  if control and control.kind == "fork" then
    local session = memory.session(id)
    if not session then return { error = "unknown_subagent" } end
    if session.user_id ~= ctx.user_id then return { error = "forbidden" } end
    memory.finish_session(id)
    return { id = id, state = "cancelled", settled = true }
  end
  local api = dofile("lua/core/subagents.lua")
  local ok, result = pcall(api.control, { action = "cancel", id = id }, ctx)
  if not ok or type(result) ~= "table" then return { error = "subagent_runtime_error" } end
  if result.error and not result.subagent_id then return result end
  -- Every field the native receipt carries is kept, so a caller that read this shape before the one API
  -- keeps reading it; the API adds its own vocabulary on top rather than replacing the record.
  local out = {}
  for key, value in pairs(result) do out[key] = value end
  out.id = id
  out.native_state = tostring(result.state or "")
  if result.settled == true or M.state_of(result.state) == "cancelled" then
    out.state = "cancelled"
  else
    -- The call is the REQUEST: the run has not ended, so the honest word is cancelling.
    out.state = "cancelling"
    out.detail = "cancel accepted; the run has not ended yet"
  end
  return out
end

--------------------------------------------------------------------------- resume and message
function M.resume(args, ctx)
  args = args or {}
  local id = as_id(args.id or args.subagent_id)
  if not id then return { error = "id_required", not_started = true } end
  local key = tostring(args.idempotency_key or "")
  if key == "" then return { error = "idempotency_key_required", not_started = true } end
  local control = M.control_row(id)
  if control and control.kind == "fork" then
    return { error = "fork_is_not_a_run", not_started = true,
      next_action = "Continue a fork with wa chat --resume <its session>; a fork is a conversation." }
  end
  local api = dofile("lua/core/subagents.lua")
  local ok, result = pcall(api.control, { action = "message", id = id,
    text = tostring(args.message or args.text or ""), idempotency_key = key }, ctx)
  if not ok or type(result) ~= "table" then return { error = "subagent_runtime_error", not_started = true } end
  if result.subagent_id then return M.child_from_run(result, control) end
  return result
end

function M.message(args, ctx)
  args = args or {}
  local id = as_id(args.id or args.subagent_id)
  if not id then return { error = "id_required" } end
  local text = tostring(args.text or args.message or "")
  if text == "" then return { error = "text_required" } end
  -- Steering is idempotent by request key (lua/core/steering.lua refuses one without). A caller that has
  -- its own key passes it and a retry is the same message; a caller that has none gets one per call,
  -- which is what "send this once" means.
  local key = tostring(args.idempotency_key or "")
  if key == "" then key = "agent-control-message:" .. tostring(host.uuid()) end
  local api = dofile("lua/core/subagents.lua")
  local ok, result = pcall(api.control, { action = "steer", id = id, text = text, idempotency_key = key }, ctx)
  if not ok or type(result) ~= "table" then return { error = "subagent_runtime_error" } end
  if result.error then
    -- The refusal keeps the word it came with; nothing here prints delivered over it.
    return { error = tostring(result.error), id = id, effect = "none" }
  end
  local delivery = tostring(result.state or result.delivery or "queued")
  return { id = id, delivery = delivery, queued = delivery == "queued", steering = result }
end

--------------------------------------------------------------------------- events
-- Does this recorded turn say the child committed? Read from the child's own tool call, never guessed
-- from its prose: the commit event carries the commits read from its checkout.
local function committed_in(tool_calls)
  local ok, calls = pcall(json.decode, tostring(tool_calls or "[]"))
  if not ok or type(calls) ~= "table" then return false end
  for _, call in ipairs(calls) do
    local fn = type(call) == "table" and (call["function"] or call) or nil
    local arguments = type(fn) == "table" and tostring(fn.arguments or "") or ""
    if arguments:find("git commit", 1, true) then return true end
  end
  return false
end

local function event_of(child, seq, kind, at, extra)
  local event = { seq = seq, id = child.id, kind = kind, at_ms = (tonumber(at) or 0) * 1000,
    state = child.state, commits = {} }
  for key, value in pairs(extra or {}) do event[key] = value end
  return event
end

function M.events(args, ctx)
  args = args or {}
  local session_id = parent_session_of(args, ctx) or ""
  if session_id == "" then return { error = "session_required", events = {} } end
  local ok, why = readable_session(session_id, ctx)
  if not ok then return { error = why, events = {} } end
  local after = tonumber(args.after or 0) or 0
  if after < 0 or after % 1 ~= 0 then return { error = "invalid_native_event_cursor", events = {} } end
  local children = children_of(session_id, ctx)
  local by_session = {}
  for _, child in ipairs(children) do if child.session ~= "" then by_session[child.session] = child end end
  if next(by_session) == nil then return { session = session_id, events = {}, next_seq = after, children = 0 } end
  local ids = {}
  for session in pairs(by_session) do ids[#ids + 1] = session end
  table.sort(ids)
  local values, holes = {}, {}
  for _, id in ipairs(ids) do values[#values + 1] = id; holes[#holes + 1] = "?" end
  values[#values + 1] = after
  local rows = query("SELECT session_id, seq, role, tool_calls, created_at FROM messages WHERE session_id IN ("
    .. table.concat(holes, ",") .. ") AND seq>? ORDER BY created_at, seq LIMIT 256", values)
  local events, next_seq, commits_cache = {}, after, {}
  for _, row in ipairs(rows) do
    local child = by_session[row.session_id]
    local seq = tonumber(row.seq) or 0
    if child and seq > after then
      if seq > next_seq then next_seq = seq end
      if row.role == "user" and seq == 1 then
        events[#events + 1] = event_of(child, seq, "started", row.created_at, { detail = "admitted" })
      elseif row.role == "assistant" then
        if committed_in(row.tool_calls) then
          local commits = commits_cache[child.session]
          if commits == nil then commits = (commits_of(child.session)); commits_cache[child.session] = commits end
          if #commits > 0 then
            events[#events + 1] = event_of(child, seq, "commit", row.created_at, { commits = commits })
          end
        end
        local settled = child.state == "completed" or child.state == "cancelled" or child.state == "failed"
        if settled then
          local updates = { rounds = child.rounds, tokens = child.tokens }
          if child.state == "failed" then updates.detail = "run_failed" end
          events[#events + 1] = event_of(child, seq, "done", row.created_at, updates)
        end
      end
    elseif child then
      events[#events + 1] = event_of(child, after, child.state == "failed" and "failed" or "started", row.created_at,
        { detail = "state_changed" })
    end
  end
  return { session = session_id, events = events, next_seq = next_seq, children = #children }
end

return M
