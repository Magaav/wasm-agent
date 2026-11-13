-- Harness evaluator: the engine that GATHERS benchmark data from frozen real tasks.
--
-- What it is. `capture` freezes one task the operator actually gave a session - the prompt, the
-- workspace it started from, the tools/policy in force, the model, and what the session did with it.
-- `run` replays that task against a candidate binary in a scratch home where nothing real is
-- reachable (see lua/core/harness_evaluator_replay.lua). `report` prints ids, categories and metrics.
--
-- What it is not. It does not gate a release, does not decide, and does not change the agent. Until it
-- is proven reliable the numbers it prints are evidence *beside* a human's check of the UX on a real
-- task, never a verdict - `success` for a real task is a `human` check until somebody records one with
-- `wa eval verdict`.
--
-- Privacy is the first design constraint, so it is one rule in one place: a frozen task is somebody's
-- real work (prompts, message text, mail, machine names, paths) and lives only under this node's state
-- directory, `<config>/evaluator`. Nothing here writes a task into a repository, and `wa eval report`
-- prints ids, categories and counts - never a prompt, never a message, never a path from a task.
--
-- KISS: it reuses what the node already has instead of instrumenting a second time. The recorded
-- outcome is the ledger's own transcript (`messages`) and its telemetry spans (`harness_events` kinds
-- `model_call` and `tool`), the same rows `wa model` and the efficiency reports read, so a capture and
-- a replay are measured by one function (M.metrics).
local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")

local M = {}
M.SCHEMA = "harness-evaluator/1"

-- The tools whose call is an *effect*: something outside this node that a replay must not perform.
-- Replay refuses these and records "would have done"; capture counts how many the task attempted. One
-- list, used by both, so an added effect is refused everywhere it is counted.
M.EFFECT_NAMES = {
  "^whatsapp_send", "^whatsapp_download", "^whatsapp_backfill",
  "^mcp_whatsapp_send", "^mcp_whatsapp_download", "^mcp_whatsapp_backfill",
  "^email_send", "^stt_submit", "^fabric_", "^mesh_call", "^relay",
  "^remote$", "^node_update$", "^web_", "^http",
}
-- Connector *reads*: not effects, but during a replay there is no live account to answer them either.
-- They answer from the recording captured with the task.
M.CONNECTOR_NAMES = {
  "^whatsapp_read", "^whatsapp_search", "^whatsapp_reactions", "^whatsapp_message",
  "^whatsapp_media", "^mcp_whatsapp_", "^email_search", "^email_read", "^email_media",
}
-- The hook matcher entries a replay installs: anchored Lua patterns, one JSON entry each, because the
-- hook engine has no alternation (a matcher is a Lua pattern, and `|` is not one). Every name above
-- starts with one of these, so the hook sees it even when this list and a tool catalogue drift.
M.REPLAY_HOOK_MATCHERS = {
  "^whatsapp_", "^mcp_whatsapp", "^email_", "^fabric_", "^mesh_",
  "^stt_", "^web_", "^http", "^remote$", "^relay", "^node_update$",
  -- The one-tool dispatch: a call made inside `tool_call` is nested, and the hook engine fires once per
  -- outermost call by design, so this is the boundary that has to be checked - the sink reads the inner
  -- name out of the arguments (measured 12/11: with this entry missing, the model reached
  -- `whatsapp_read` through `tool_call` and the sink never saw it).
  "^tool_call$",
}
-- A bash tool call and `git push` are handled a step lower: replay puts shims on PATH that refuse the
-- remote commands (`harness-evaluator/replay/sink.sh` explains why the hook cannot do that one).
M.GUARDED_COMMANDS = { "git push", "git fetch", "git pull", "ssh", "scp", "sftp", "rsync", "gh" }

-- The refusal rule, named so a count can be read as the rule that produced it: a tool result that
-- begins with one of these is a refusal ("it refused", not "it failed" and not "it answered").
M.REFUSAL_PREFIXES = { "refused", "denied", "not permitted", "not allowed", "blocked by" }

local function query(statement, params)
  local raw = host.sql_query(statement, json.encode(params or {}))
  local value = raw and json.decode(raw)
  if type(value) ~= "table" then return {} end
  return value
end

local function shquote(text)
  text = tostring(text or "")
  return "'" .. text:gsub("'", "'\\''") .. "'"
end
M.shquote = shquote

-- host.exec answers one JSON object with `code` (the shell's exit status), `stdout` and `stderr`; a
-- call that could not run at all answers `{error=...}`. `status` is carried beside `code` because the
-- rest of this engine reads `status` and the host's own name for it is `code`.
local function exec(command, cwd, timeout)
  local ok, raw = pcall(host.exec, command, cwd or "", timeout or 120)
  if not ok then return { code = -1, status = -1, error = tostring(raw) } end
  local value = type(raw) == "string" and json.decode(raw) or raw
  if type(value) ~= "table" then return { code = -1, status = -1, error = "exec answered nothing" } end
  value.code = tonumber(value.code) or (value.ok and 0 or -1)
  value.status = value.code
  return value
end
M.exec = exec

local function exists(path)
  if type(host.path_kind) == "function" then
    local ok, kind = pcall(host.path_kind, path)
    if ok and kind and kind ~= "missing" and kind ~= "" then return true end
  end
  return host.read_file(path) ~= nil
end

function M.state_dir_override() return host.getenv("WA_EVALUATOR_STATE") end

-- Where the frozen tasks and runs live. `WA_EVALUATOR_STATE` exists for the suites (a scratch home)
-- and for an operator keeping a second range; the default is the node's own state directory.
function M.state_dir()
  local override = host.getenv("WA_EVALUATOR_STATE")
  if override and override ~= "" then return (override:gsub("\\", "/"):gsub("/+$", "")) end
  return paths.config() .. "/evaluator"
end

function M.tasks_dir() return M.state_dir() .. "/tasks" end
function M.runs_dir() return M.state_dir() .. "/runs" end
function M.catalogue_path() return M.state_dir() .. "/tasks.json" end

local function read_json(path)
  local text = host.read_file(path)
  if not text or text == "" then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then return nil end
  return value
end
M.read_json = read_json

local function write_json(path, value)
  return host.write_file(path, json.encode(value)) and true or false
end
M.write_json = write_json

local function entries(path)
  local ok, raw = pcall(host.list_dir, path)
  if not ok or not raw then return {} end
  local decoded = type(raw) == "table" and raw or json.decode(raw)
  if type(decoded) ~= "table" then return {} end
  return decoded.entries or {}
end
M.entries = entries

function M.ensure()
  host.write_file(M.state_dir() .. "/.keep", "")
  host.write_file(M.tasks_dir() .. "/.keep", "")
  host.write_file(M.runs_dir() .. "/.keep", "")
  return M.state_dir()
end

local function safe_id(value)
  return (tostring(value or ""):lower():gsub("[^a-z0-9._-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end
M.safe_id = safe_id

-- ---------------------------------------------------------------- the catalogue
-- `tasks.json` is the range: one row per frozen task with its id, category and check. The task body
-- (prompt, workspace, recording) lives in `tasks/<id>/task.json`; the catalogue is what a report and a
-- `run --all` iterate without reading every body.
function M.tasks()
  local catalogue = read_json(M.catalogue_path()) or { version = 1, tasks = {} }
  local rows = {}
  for _, row in ipairs(catalogue.tasks or {}) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return rows
end

function M.task(id)
  if not id or id == "" then return nil end
  local record = read_json(M.tasks_dir() .. "/" .. safe_id(id) .. "/task.json")
  if not record then return nil end
  local dir = M.tasks_dir() .. "/" .. safe_id(id)
  local patch = host.read_file(dir .. "/workspace.patch")
  if patch and patch ~= "" then record.workspace.patch = patch end
  return record
end

local function save_catalogue(record)
  local catalogue = read_json(M.catalogue_path()) or { version = 1, tasks = {} }
  local rows = {}
  local replaced = false
  for _, row in ipairs(catalogue.tasks or {}) do
    if row.id == record.id then
      rows[#rows + 1] = {
        id = record.id, category = record.category, check = record.check,
        source_session = record.source.session_id, source_turn = record.source.turn,
        created_at = record.created_at, note = record.note,
      }
      replaced = true
    else
      rows[#rows + 1] = row
    end
  end
  if not replaced then
    rows[#rows + 1] = {
      id = record.id, category = record.category, check = record.check,
      source_session = record.source.session_id, source_turn = record.source.turn,
      created_at = record.created_at, note = record.note,
    }
  end
  catalogue.version = 1
  catalogue.tasks = rows
  return write_json(M.catalogue_path(), catalogue)
end

-- ---------------------------------------------------------------- metrics
local function number(value)
  if type(value) == "number" then return value end
  return tonumber(value)
end

local function starts_with_any(text, prefixes)
  local lowered = tostring(text or ""):lower()
  for _, prefix in ipairs(prefixes) do
    if lowered:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function matches_any(name, patterns)
  name = tostring(name or ""):lower()
  for _, pattern in ipairs(patterns) do
    if name:find(pattern) then return true end
  end
  return false
end
M.is_effect = function(name) return matches_any(name, M.EFFECT_NAMES) end
M.is_connector = function(name) return matches_any(name, M.CONNECTOR_NAMES) end

local function decode_field(value)
  if type(value) == "table" then return value end
  if type(value) ~= "string" or value == "" then return nil end
  local ok, decoded = pcall(json.decode, value)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

-- One metrics table from a window of a ledger.
--
-- The same function reads the node's own rows during capture and the replay's dumped rows afterwards,
-- so a captured outcome and a replayed outcome are the same numbers. A field that could not be observed
-- stays nil (and `known` says so) rather than becoming a zero: "no usage recorded" and "zero tokens"
-- are different facts (docs/MEMORY.md, the same rule the efficiency report follows).
function M.metrics(window)
  local messages = window.messages or {}
  local events = window.events or {}
  local out = {
    rounds = nil, model_calls = 0, usage_calls = 0, usage_unknown = 0,
    tokens_in = nil, tokens_out = nil, cache_read = nil, cache_write = nil,
    prompt_tokens = nil, cache_hit = nil, cost_known = false,
    tool_calls = 0, tool_errors = 0, refusals = 0, effects_attempted = 0,
    connector_reads = 0, files_changed = {}, final_answer = nil,
    model = nil, provider = nil, first_at = nil, last_at = nil, wall_ms = nil,
  }
  local input, output, cache_read, cache_write, prompt_tokens = 0, 0, 0, 0, 0
  local saw_input, saw_output, saw_cache, saw_prompt = false, false, false, false
  local effects, connectors = 0, 0
  -- A tool is visible twice in a ledger: as a transcript row and as a telemetry span. Counting both would
  -- double every error and every effect, so one source wins: the spans when the run recorded any (they are
  -- the richer record), the transcript rows otherwise. `source` says which one a number came from.
  local errors_events, effects_events, connectors_events = 0, 0, 0
  local saw_tool_events = false
  local files, seen_file = {}, {}
  local refusals = 0
  local first_at, last_at = nil, nil

  local function touch(at)
    at = number(at)
    if not at then return end
    if not first_at or at < first_at then first_at = at end
    if not last_at or at > last_at then last_at = at end
  end

  for _, row in ipairs(messages) do
    touch(row.created_at)
    local role = tostring(row.role or "")
    if role == "tool" then
      if number(row.ok) == 0 then out.tool_errors = out.tool_errors + 1 end
      if row.content and starts_with_any(row.content, M.REFUSAL_PREFIXES) then refusals = refusals + 1 end
      if row.tool_name and M.is_connector(row.tool_name) then connectors = connectors + 1 end
    elseif role == "assistant" then
      local calls = decode_field(row.tool_calls)
      for _, call in ipairs(calls or {}) do
        local fn = type(call["function"]) == "table" and call["function"] or {}
        local name = tostring(fn.name or "")
        if M.is_effect(name) then effects = effects + 1 end
        if name == "write" or name == "edit" then
          local args = decode_field(fn.arguments) or {}
          local path = args.path or args.file_path or args.file
          if path and not seen_file[path] then
            seen_file[path] = true
            files[#files + 1] = tostring(path)
          end
        end
      end
      if row.content and row.content ~= "" then out.final_answer = row.content end
    end
  end

  for _, row in ipairs(events) do
    touch(row.at)
    local kind = tostring(row.kind or "")
    local payload = decode_field(row.payload) or {}
    if kind == "model_call" then
      out.model_calls = out.model_calls + 1
      if payload.model and not out.model then out.model = tostring(payload.model) end
      if payload.provider and not out.provider then out.provider = tostring(payload.provider) end
      local usage = type(payload.normalized) == "table" and payload.normalized or {}
      if usage.known then
        out.usage_calls = out.usage_calls + 1
        local i, o = number(usage.input), number(usage.output)
        if i then input = input + i; saw_input = true end
        if o then output = output + o; saw_output = true end
        local cr = number(usage.cacheRead)
        if cr then cache_read = cache_read + cr; saw_cache = true end
        local cw = number(usage.cacheWrite)
        if cw then cache_write = cache_write + cw; saw_cache = true end
        local p = number(usage.prompt)
        if p then prompt_tokens = prompt_tokens + p; saw_prompt = true end
        if payload.normalized.cost_known then out.cost_known = true end
      else
        out.usage_unknown = out.usage_unknown + 1
      end
    elseif kind == "tool" then
      saw_tool_events = true
      out.tool_calls = out.tool_calls + 1
      if payload.ok == false then errors_events = errors_events + 1 end
      if M.is_effect(payload.name) then effects_events = effects_events + 1 end
      if M.is_connector(payload.name) then connectors_events = connectors_events + 1 end
    end
  end

  out.rounds = out.model_calls
  if saw_input then out.tokens_in = input end
  if saw_output then out.tokens_out = output end
  if saw_cache then out.cache_read = cache_read; out.cache_write = cache_write end
  if saw_prompt then out.prompt_tokens = prompt_tokens end
  if saw_input and saw_cache and (cache_read + input) > 0 then
    out.cache_hit = cache_read / (cache_read + input)
  end
  out.tool_errors = saw_tool_events and errors_events or out.tool_errors
  out.effects_attempted = saw_tool_events and effects_events or effects
  out.connector_reads = saw_tool_events and connectors_events or connectors
  out.tool_source = saw_tool_events and "telemetry spans" or "transcript rows"
  -- The sink's denials are exact and are added by the replay (M.metrics cannot see them); the prefix
  -- rule is what a capture has. Both are named in the run record's `rules`.
  out.refusals = refusals
  out.files_changed = files
  out.first_at, out.last_at = first_at, last_at
  if first_at and last_at and last_at >= first_at then out.wall_ms = (last_at - first_at) * 1000 end
  return out
end

-- ---------------------------------------------------------------- capture
local function parse_check(text)
  text = tostring(text or "human")
  if text == "" or text == "human" then return { kind = "human" } end
  local kind, rest = text:match("^(%a+):(.*)$")
  if kind == "cmd" or kind == "command" then return { kind = "command", command = rest } end
  if kind == "file" then
    local path, contains = rest:match("^(.-)=(.*)$")
    if path then return { kind = "file", path = path, contains = contains } end
    return { kind = "file", path = rest }
  end
  return nil, "a check is `human`, `cmd:<shell command>` or `file:<path>[=<text it must contain>]`"
end
M.parse_check = parse_check

local function capture_workspace(record, dir, opts)
  local workspace = { kind = "none", path = dir }
  local inside = exec("git rev-parse --is-inside-work-tree", dir, 60)
  if inside.status == 0 and (inside.stdout or ""):match("true") then
    local root = exec("git rev-parse --show-toplevel", dir, 60)
    local head = exec("git rev-parse HEAD", dir, 60)
    local branch = exec("git rev-parse --abbrev-ref HEAD", dir, 60)
    workspace.kind = "git"
    workspace.repo = (root.stdout or ""):gsub("%s+$", "")
    workspace.base_commit = record.source.base_commit ~= "" and record.source.base_commit or (head.stdout or ""):gsub("%s+$", "")
    workspace.head_commit = (head.stdout or ""):gsub("%s+$", "")
    workspace.branch = (branch.stdout or ""):gsub("%s+$", "")
    local status = exec("git status --porcelain", dir, 60)
    workspace.dirty = (status.stdout or "") ~= ""
    local untracked = exec("git ls-files --others --exclude-standard", dir, 60)
    workspace.untracked = {}
    for line in (untracked.stdout or ""):gmatch("[^\r\n]+") do
      workspace.untracked[#workspace.untracked + 1] = line
    end
    local diff = exec("git diff --binary", dir, 120)
    local patch = diff.stdout or ""
    local limit = tonumber(opts.max_patch_bytes) or 4 * 1024 * 1024
    if #patch > limit then
      workspace.patch_skipped = "diff is " .. #patch .. " bytes, over the " .. limit .. " byte capture limit"
      patch = ""
    end
    record.workspace = workspace
    host.write_file(M.tasks_dir() .. "/" .. record.id .. "/workspace.patch", patch)
    workspace.patch_bytes = #patch
    return workspace
  end
  -- Not a git checkout: a small scratch directory travels as a tarball, or not at all - a big one is
  -- named rather than silently half-captured.
  local size = exec("du -sk " .. shquote(dir), "", 120)
  local kilobytes = tonumber((size.stdout or ""):match("^(%d+)"))
  workspace.kind = "dir"
  workspace.kilobytes = kilobytes
  local limit_kb = tonumber(opts.max_dir_kb) or 8192
  if kilobytes and kilobytes <= limit_kb then
    local tarball = M.tasks_dir() .. "/" .. record.id .. "/workspace.tgz"
    local packed = exec("tar czf " .. shquote(tarball) .. " -C " .. shquote(dir .. "/..") .. " " .. shquote(dir:match("([^/]+)$") or "."), "", 300)
    workspace.tarball = packed.status == 0
    if packed.status ~= 0 then workspace.tarball_error = (packed.stderr or ""):gsub("%s+$", "") end
  else
    workspace.skipped = "directory is " .. tostring(kilobytes) .. " KB, over the capture limit"
  end
  record.workspace = workspace
  return workspace
end

-- Freeze one task: `<session-id> [--turn N]`.
function M.capture(session_id, opts)
  opts = opts or {}
  if not session_id or session_id == "" then return nil, "capture needs a session id (wa sessions lists them)" end
  local check, check_error = parse_check(opts.check)
  if not check then return nil, check_error end
  local session = query("SELECT * FROM sessions WHERE id=?", { session_id })[1]
  if not session then return nil, "no such session: " .. session_id end
  local messages = query(
    "SELECT seq,role,content,tool_calls,tool_call_id,tool_name,ok,tokens,ms,trace,created_at FROM messages WHERE session_id=? ORDER BY seq",
    { session_id })
  local events = query("SELECT kind,payload,at FROM harness_events WHERE session_id=? ORDER BY seq", { session_id })
  local turns = {}
  for _, row in ipairs(messages) do
    if row.role == "user" then turns[#turns + 1] = row end
  end
  if #turns == 0 then return nil, "that session has no user message, so there is no task in it" end
  local turn_index = tonumber(opts.turn) or 1
  local prompt = turns[turn_index]
  if not prompt then
    return nil, string.format("that session has %d user message(s); --turn %d does not exist", #turns, turn_index)
  end

  local next_started = turns[turn_index + 1] and number(turns[turn_index + 1].created_at) or nil
  local outcome_messages, window_events = {}, {}
  for _, row in ipairs(messages) do
    local at = number(row.created_at) or 0
    if row.seq > prompt.seq and (not next_started or at < next_started) then
      outcome_messages[#outcome_messages + 1] = row
    end
  end
  for _, row in ipairs(events) do
    local at = number(row.at) or 0
    if at >= (number(prompt.created_at) or 0) and (not next_started or at < next_started) then
      window_events[#window_events + 1] = row
    end
  end
  local metrics = M.metrics({ messages = outcome_messages, events = window_events })

  -- The calls the session made, by name: the recorded evidence of which tools the task needed. The
  -- historical *catalogue* was never recorded by the ledger, so `catalogue_known=false` says that
  -- instead of pretending `tools_used` was the whole of it.
  local tools_used, seen_tool = {}, {}
  local recordings = {}
  local inputs_by_call = {}
  for _, row in ipairs(outcome_messages) do
    if row.role == "assistant" then
      local calls = decode_field(row.tool_calls) or {}
      for _, call in ipairs(calls) do
        local fn = type(call["function"]) == "table" and call["function"] or {}
        local name = tostring(fn.name or "")
        if name ~= "" and not seen_tool[name] then seen_tool[name] = true; tools_used[#tools_used + 1] = name end
        if name ~= "" and call.id then inputs_by_call[tostring(call.id)] = tostring(fn.arguments or "") end
      end
    end
  end
  for _, row in ipairs(outcome_messages) do
    if row.role == "tool" and row.tool_name and M.is_connector(row.tool_name) then
      recordings[#recordings + 1] = {
        tool = tostring(row.tool_name),
        input = inputs_by_call[tostring(row.tool_call_id or "")] or "",
        ok = number(row.ok) ~= 0,
        response = tostring(row.content or ""):sub(1, 8192),
      }
    end
  end

  local id = safe_id(opts.id or (session_id:sub(1, 8) .. "-t" .. turn_index))
  local record = {
    schema = M.SCHEMA,
    id = id,
    category = tostring(opts.category or "uncategorised"),
    check = check,
    note = opts.note and tostring(opts.note) or nil,
    created_at = host.now(),
    source = {
      session_id = session_id,
      turn = turn_index,
      seq = prompt.seq,
      user_messages = #turns,
      mode = session.mode,
      user_id = session.user_id,
      node_id = session.node_id,
      base_commit = tostring(session.workspace_base_commit or ""),
      worktree = tostring(session.worktree or ""),
      branch = tostring(session.workspace_branch or ""),
      started_at = session.started_at,
      ended_at = session.ended_at,
    },
    prompt = tostring(prompt.content or ""),
    policy = {
      mode = session.mode,
      role = session.user_id == "master" and "master" or tostring(session.user_id or ""),
      note = "the role and mode the session ran under; the full historical tool catalogue was not recorded",
    },
    model = { recorded = metrics.model, provider = metrics.provider, known = metrics.model ~= nil },
    catalogue = {
      known = false,
      tools_used = tools_used,
      note = "the ledger records the calls a session made, not the catalogue it was offered; a replay is run by the candidate binary's own catalogue",
    },
    connectors = { recordings = recordings, live_access = false },
    outcome = {
      rounds = metrics.rounds,
      model_calls = metrics.model_calls,
      tool_calls = metrics.tool_calls,
      tool_source = metrics.tool_source,
      tool_errors = metrics.tool_errors,
      refusals = metrics.refusals,
      effects_attempted = metrics.effects_attempted,
      connector_reads = metrics.connector_reads,
      tokens_in = metrics.tokens_in,
      tokens_out = metrics.tokens_out,
      cache_read = metrics.cache_read,
      cache_write = metrics.cache_write,
      cache_hit = metrics.cache_hit,
      usage_unknown = metrics.usage_unknown,
      wall_ms = metrics.wall_ms,
      files_changed = metrics.files_changed,
      final_answer = metrics.final_answer,
    },
    privacy = {
      state_dir = M.state_dir(),
      note = "personal data: this record never leaves the node's evaluator state directory and is never printed whole",
    },
  }

  M.ensure()
  local dir = M.tasks_dir() .. "/" .. id
  local dir_work = opts.dir and tostring(opts.dir) or (record.source.worktree ~= "" and record.source.worktree or nil)
  if not dir_work then
    local platform = dofile("lua/core/platform.lua")
    dir_work = platform.cwd()
  end
  -- The task's own directory exists before the workspace is captured: a tarball is written into it, and
  -- `write_file` makes the parents for a patch but `tar` does not.
  host.write_file(dir .. "/.keep", "")
  capture_workspace(record, dir_work, opts)
  if not write_json(dir .. "/task.json", record) then
    return nil, "the task could not be written to " .. dir .. "/task.json"
  end
  save_catalogue(record)
  return record
end

-- ---------------------------------------------------------------- runs, verdicts, findings
function M.run_ids()
  local ids = {}
  for _, entry in ipairs(entries(M.runs_dir())) do
    if entry.kind == "dir" then ids[#ids + 1] = entry.name end
  end
  table.sort(ids)
  return ids
end

function M.run_record(run_id)
  if not run_id or run_id == "" then return nil end
  return read_json(M.runs_dir() .. "/" .. safe_id(run_id) .. "/run.json")
end

function M.record_run(record)
  M.ensure()
  return write_json(M.runs_dir() .. "/" .. safe_id(record.id) .. "/run.json", record)
end

function M.verdict(run_id, state, note)
  if state ~= "pass" and state ~= "fail" then return nil, "a verdict is `pass` or `fail`" end
  local record = M.run_record(run_id)
  if not record then return nil, "no such run: " .. tostring(run_id) end
  if record.check and record.check.kind ~= "human" then
    return nil, "that task's success is decided by its own check (" .. tostring(record.check.kind) .. "); a hand verdict would contradict it"
  end
  record.verdict = { state = state, note = tostring(note or ""), at = host.now() }
  if not M.record_run(record) then return nil, "the verdict could not be written" end
  return record
end

-- The landing reviewer's shape, storage only: a future reviewer records what it found and what happened
-- later to it. No reviewer runs here, and nothing reads these numbers as a decision.
function M.reviewer_record(run_id, fields)
  local record = M.run_record(run_id)
  if not record then return nil, "no such run: " .. tostring(run_id) end
  local previous = type(record.reviewer) == "table" and record.reviewer or {}
  local function count(key)
    local value = tonumber(fields[key])
    if value == nil then return previous[key] end
    return value
  end
  record.reviewer = {
    findings = count("findings"),
    accepted = count("accepted"),
    misses = count("misses"),
    cost = fields.cost and tostring(fields.cost) or previous.cost,
    at = host.now(),
  }
  if not M.record_run(record) then return nil, "the record could not be written" end
  return record
end

-- ---------------------------------------------------------------- report
local function pad(text, width)
  text = tostring(text or "")
  if #text >= width then return text end
  return text .. string.rep(" ", width - #text)
end

local function fmt(value)
  if value == nil then return "-" end
  if type(value) == "number" then
    if value >= 1000000 then return string.format("%.1fM", value / 1000000) end
    if value >= 1000 then return string.format("%.1fk", value / 1000) end
    if value % 1 ~= 0 then return string.format("%.2f", value) end
    return tostring(math.floor(value))
  end
  return tostring(value)
end

local function fmt_ms(ms)
  if not ms then return "-" end
  if ms >= 1000 then return string.format("%.1fs", ms / 1000) end
  return string.format("%dms", math.floor(ms))
end

M.COLUMNS = function()
  return {
    { key = "task", label = "TASK", width = 22 },
    { key = "category", label = "CATEGORY", width = 16 },
    { key = "check", label = "CHECK", width = 11 },
    { key = "wall", label = "WALL", width = 8 },
    { key = "rounds", label = "ROUNDS", width = 7 },
    { key = "tokens_in", label = "IN", width = 7 },
    { key = "tokens_out", label = "OUT", width = 7 },
    { key = "cache", label = "CACHE", width = 7 },
    { key = "tools", label = "TOOLS", width = 6 },
    { key = "errors", label = "ERR", width = 4 },
    { key = "refusals", label = "REF", width = 4 },
    { key = "effects", label = "EFF", width = 4 },
    { key = "verdict", label = "SUCCESS", width = 12 },
  }
end

local function success_of(record)
  local check = record.check or { kind = "human" }
  if record.error and not record.metrics then return "error" end
  if check.kind == "human" then
    if record.verdict then return record.verdict.state end
    return "needs-human"
  end
  local outcome = type(record.outcome) == "table" and record.outcome or {}
  return outcome.state or "unknown"
end

-- `wa eval report` - ids, categories and metrics. A row never carries a prompt, a message or a path
-- from a task: the ids are enough to find the record, which lives in the state directory.
function M.report(opts)
  opts = opts or {}
  local runs = {}
  for _, id in ipairs(M.run_ids()) do
    local record = M.run_record(id)
    if record then runs[#runs + 1] = record end
  end
  local latest = {}
  for _, record in ipairs(runs) do
    local key = tostring(record.task_id)
    if not latest[key] or (record.started_at or 0) > (latest[key].started_at or 0) then latest[key] = record end
  end
  local rows = {}
  for _, record in ipairs(runs) do
    if opts.all or latest[tostring(record.task_id)] == record then rows[#rows + 1] = record end
  end
  table.sort(rows, function(a, b) return tostring(a.task_id) < tostring(b.task_id) end)
  local lines = {}
  local function row(values)
    local cells = {}
    for index, column in ipairs(M.COLUMNS()) do
      cells[#cells + 1] = pad(values[index] or "", column.width)
    end
    lines[#lines + 1] = table.concat(cells, " "):gsub("%s+$", "")
  end
  local header = {}
  for index, column in ipairs(M.COLUMNS()) do header[index] = column.label end
  row(header)
  for _, record in ipairs(rows) do
    local m = record.metrics or {}
    local check = record.check or { kind = "human" }
    row({
      record.task_id, record.category, check.kind, fmt_ms(record.wall_ms or m.wall_ms),
      fmt(m.rounds), fmt(m.tokens_in), fmt(m.tokens_out),
      m.cache_hit and string.format("%.0f%%", m.cache_hit * 100) or "-",
      fmt(m.tool_calls), fmt(m.tool_errors), fmt(m.refusals), fmt(m.effects_attempted),
      success_of(record),
    })
  end
  if #rows == 0 then lines[#lines + 1] = "(no runs: `wa eval run <task-id|--all> --bin <wa>`)" end
  local reviewer_lines = {}
  for _, record in ipairs(rows) do
    if type(record.reviewer) == "table" then
      reviewer_lines[#reviewer_lines + 1] = string.format("%s: findings %s, accepted %s, misses %s, cost %s",
        tostring(record.task_id), fmt(record.reviewer.findings), fmt(record.reviewer.accepted),
        fmt(record.reviewer.misses), record.reviewer.cost or "-")
    end
  end
  if #reviewer_lines > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "reviewer (storage only - no reviewer decided anything here):"
    for _, line in ipairs(reviewer_lines) do lines[#lines + 1] = "  " .. line end
  end
  -- The landing reviewer's own store (lua/core/harness_evaluator_reviewer.lua): per review a row and
  -- then the totals. It is handed in by the door that has the module, so this file keeps one dependency
  -- and a caller that passes nothing gets the report it had before the reviewer existed.
  if type(opts.reviews) == "table" and type(opts.reviews.report_lines) == "function" then
    local ok, extra = pcall(opts.reviews.report_lines)
    if ok and type(extra) == "table" then
      for _, line in ipairs(extra) do lines[#lines + 1] = line end
    else
      lines[#lines + 1] = "reviews: the review store could not be read (" .. tostring(extra) .. ")"
    end
  end
  return lines
end

-- `wa eval report --compare <run-a> <run-b>`: the same task, two runs, one table of deltas.
function M.compare(run_a, run_b)
  local a, b = M.run_record(run_a), M.run_record(run_b)
  if not a then return nil, "no such run: " .. tostring(run_a) end
  if not b then return nil, "no such run: " .. tostring(run_b) end
  local metrics = {
    { label = "wall", key = "wall_ms", ms = true },
    { label = "rounds", key = "rounds" },
    { label = "tokens_in", key = "tokens_in" },
    { label = "tokens_out", key = "tokens_out" },
    { label = "cache_read", key = "cache_read" },
    { label = "tool_calls", key = "tool_calls" },
    { label = "tool_errors", key = "tool_errors" },
    { label = "refusals", key = "refusals" },
    { label = "effects", key = "effects_attempted" },
  }
  local lines = { string.format("%s (%s) vs %s (%s)", tostring(a.task_id), run_a, tostring(b.task_id), run_b) }
  lines[#lines + 1] = pad("METRIC", 14) .. pad("A", 10) .. pad("B", 10) .. "DELTA"
  for _, metric in ipairs(metrics) do
    local av = (a.metrics or {})[metric.key]
    local bv = (b.metrics or {})[metric.key]
    if metric.key == "wall_ms" then av = a.wall_ms or av; bv = b.wall_ms or bv end
    local function show(value) return metric.ms and fmt_ms(value) or fmt(value) end
    local delta = "-"
    if type(av) == "number" and type(bv) == "number" then
      local d = bv - av
      delta = metric.ms and (string.format("%+.1fs", d / 1000)) or string.format("%+d", d)
    end
    lines[#lines + 1] = pad(metric.label, 14) .. pad(show(av), 10) .. pad(show(bv), 10) .. delta
  end
  lines[#lines + 1] = "success: " .. tostring(success_of(a)) .. " -> " .. tostring(success_of(b))
  return table.concat(lines, "\n")
end

return M
