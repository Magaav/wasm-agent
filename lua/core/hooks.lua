-- Hook points, the Claude Code compatible command protocol, Lua plugin hooks, and the mods surface.
--
-- One engine, one config read, one place where a hook's answer is interpreted. The events themselves
-- stay where their boundary is (the agent loop, `tools.dispatch`, the compactor, the subagent
-- launcher, the self-loop, the service registry, `/update`); this file answers only three questions:
-- what is configured for this event, what does each hook say, and what does that mean for the call.
--
-- Contract, and the reason it is written here rather than in each caller:
--
-- * Nothing runs unless the operator configured it. `M.fire` is cheap and inert with no config: one
--   cached lookup, no `host.exec`, no file read.
-- * A hook that fails, times out, exits non-zero or prints unparseable output is RECORDED and never
--   blocks the call. Only an explicit deny/block (`permissionDecision:"deny"`, `decision:"block"`,
--   exit code 2) does - and the reason it carries is what the caller shows.
-- * Every hook has its own timeout and its stdout/stderr are capped, so a wedged or chatty hook
--   cannot hold the run or flood the transcript.
-- * Payloads are built from ids, names and lengths. Text a hook does not need is not handed over,
--   and anything logged passes through the redactor.
--
-- Config sources, in this order (later entries run after earlier ones; a deny wins over an allow):
--   1. `<config>/hooks.json`                     - the node's own hooks and mods (docs/HOOKS.md)
--   2. `<workdir>/.wasm-agent/hooks.json`        - the project's own hooks and mods
--   3. `<home>/.claude/settings.json`            - Claude Code's `hooks` block, opt-in
--   4. `<workdir>/.claude/settings.json`         - Claude Code's project settings, same opt-in
-- The Claude sources are read only when `hooks.claude_compat` is true in (1)/(2) or
-- `WASM_AGENT_CLAUDE_HOOKS=1` is set: the operator's own Claude Code setup is not re-used behind
-- their back, because those hooks were written for a different harness.
local json = dofile('lua/vendor/json.lua')
local redact = dofile('lua/core/redact.lua')
local paths = dofile('lua/core/paths.lua')
local platform = dofile('lua/core/platform.lua')

local M = {}

M.VERSION = 1

-- Bounds. A hook is a user command in the run's path; it gets a small, named allowance.
M.DEFAULT_TIMEOUT_MS = 5000
M.MAX_TIMEOUT_MS = 60000
M.MAX_STDOUT_BYTES = 8192
M.MAX_STDERR_BYTES = 2048
M.MAX_CONTEXT_BYTES = 4000
M.MAX_SYSTEM_MESSAGES = 4
M.MAX_SYSTEM_MESSAGE_BYTES = 500
M.MAX_STOP_CONTINUES = 3
M.STATUSLINE_TTL_MS = 10000
M.STATUSLINE_TIMEOUT_MS = 5000
M.STATUSLINE_MAX = 160
M.LAST_KEPT = 40

-- The catalogue: the one list of events, what each carries, and what it may decide. Documentation,
-- `/hooks` and the tests all read this, so an event cannot exist without saying what it is for.
M.EVENTS = {
  { name = 'SessionStart', matcher = false, may = { 'context', 'systemMessage' },
    when = 'a session begins a run (new, resumed or replayed) and before the first model request',
    fields = { 'session_id', 'run_id', 'cwd', 'source', 'resume' } },
  { name = 'UserPromptSubmit', matcher = false, may = { 'block', 'context', 'systemMessage' },
    when = 'the user message is recorded, before the context is built for the first request',
    fields = { 'session_id', 'run_id', 'prompt', 'prompt_len', 'cwd' } },
  { name = 'PreToolUse', matcher = true, may = { 'allow', 'deny', 'ask', 'updatedInput', 'context', 'systemMessage' },
    when = 'after the arguments are decoded, before the tool runs',
    fields = { 'session_id', 'run_id', 'tool_name', 'tool_input', 'cwd', 'role' } },
  { name = 'PostToolUse', matcher = true, may = { 'context', 'systemMessage' },
    when = 'after a tool returned, before its result is recorded',
    fields = { 'session_id', 'run_id', 'tool_name', 'tool_input', 'tool_response', 'ok', 'cwd' } },
  { name = 'PostToolUseFailure', matcher = true, may = { 'context', 'systemMessage' },
    when = 'after a tool answered with an error or raised, before the failure is recorded',
    fields = { 'session_id', 'run_id', 'tool_name', 'tool_input', 'error', 'cwd' } },
  { name = 'PreCompact', matcher = false, may = { 'block', 'systemMessage' },
    when = 'a compaction is about to rewrite the transcript prefix',
    fields = { 'session_id', 'run_id', 'tokens_before', 'limit', 'keep', 'trigger', 'reason', 'cwd' } },
  { name = 'PostCompact', matcher = false, may = { 'context', 'systemMessage' },
    when = 'a compaction landed: the prefix was rewritten and the summary recorded',
    fields = { 'session_id', 'run_id', 'tokens_before', 'tokens_after', 'through', 'trigger', 'cwd' } },
  { name = 'Stop', matcher = false, may = { 'continue', 'stop', 'context', 'systemMessage' },
    when = 'a completed no-tool candidate is identified as the answer and before it is committed',
    fields = { 'session_id', 'run_id', 'message_id', 'text_len', 'stop_hook_active', 'cwd' } },
  { name = 'SubagentStart', matcher = true, may = { 'context', 'systemMessage' },
    when = 'a child run is admitted and before its first model request',
    fields = { 'session_id', 'run_id', 'subagent_id', 'profile', 'parent_session_id', 'prompt_len', 'cwd' } },
  { name = 'SubagentStop', matcher = true, may = { 'context', 'systemMessage' },
    when = "a child run settled (completed, failed, cancelled or unknown)",
    fields = { 'session_id', 'run_id', 'subagent_id', 'profile', 'state', 'cwd' } },
  { name = 'Notification', matcher = false, may = { 'context', 'systemMessage' },
    when = 'the node has a fact for the reader that is not the answer (a notice, a warning)',
    fields = { 'session_id', 'run_id', 'kind', 'text_len', 'cwd' } },
  { name = 'SelfWake', matcher = false, may = { 'block', 'reschedule', 'systemMessage' },
    when = 'a due self-wake is claimed and before its turn runs',
    fields = { 'session_id', 'run_id', 'wake_id', 'reason', 'due_at', 'attempts', 'cwd' } },
  { name = 'PreDeploy', matcher = false, may = { 'block', 'systemMessage' },
    when = 'a deploy request is about to be written for the sentinel',
    fields = { 'session_id', 'run_id', 'commit', 'reason', 'cwd' } },
  { name = 'PostDeploy', matcher = false, may = { 'context', 'systemMessage' },
    when = 'the sentinel accepted a deploy request (queued, not installed)',
    fields = { 'session_id', 'run_id', 'request', 'commit', 'cwd' } },
  { name = 'ComponentInstall', matcher = true, may = { 'block', 'systemMessage' },
    when = 'a component definition is about to be installed, enabled or upgraded',
    fields = { 'session_id', 'run_id', 'component', 'action', 'artifact', 'cwd' } },
  { name = 'ComponentSwap', matcher = true, may = { 'context', 'systemMessage' },
    when = 'a component upgrade switched to the new instance',
    fields = { 'session_id', 'run_id', 'component', 'state', 'cwd' } },
  { name = 'StatusLine', matcher = false, may = { 'text' },
    when = 'the CLI renders its footer (a mod, not a hook: its stdout is the segment)',
    fields = { 'session_id', 'model', 'cwd', 'runs', 'tokens' } },
}

local EVENT_BY_NAME = {}
for _, event in ipairs(M.EVENTS) do EVENT_BY_NAME[event.name] = event end

function M.event_names()
  local names = {}
  for _, event in ipairs(M.EVENTS) do names[#names + 1] = event.name end
  return names
end

-- ---- small helpers -----------------------------------------------------------------------------

local function quote(value)
  return "'" .. tostring(value or ''):gsub("'", "'\\''") .. "'"
end

local function clip(value, limit)
  value = tostring(value or '')
  if #value <= limit then return value end
  return value:sub(1, limit) .. '…'
end

-- One line: a hook's stdout may be a whole file, and the footer is one row.
local function one_line(value)
  return (tostring(value or ''):gsub('[\r\n]+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function decode_object(text)
  if type(text) ~= 'string' or text == '' then return nil end
  local ok, value = pcall(json.decode, text)
  if ok and type(value) == 'table' then return value end
  return nil
end

local function read_json(path)
  if type(path) ~= 'string' or path == '' or type(host.read_file) ~= 'function' then
    return nil, 'unreadable'
  end
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' then return nil, 'missing' end
  local value = decode_object(text)
  if not value then return nil, 'invalid_json' end
  return value, nil
end

local function is_pattern(matcher)
  return matcher:find('[%^%$%(%)%%%.%[%]%*%+%-%?]') ~= nil
end

-- A matcher is a Lua pattern against the tool name (Claude Code's `matcher` is a regex; the two
-- agree for the shapes people write: `bash`, `^mcp_`, `read|write`, `.*`). A plain word matches
-- case-insensitively anywhere in the name, so `bash` names `bash` and `Bash`.
local function matches(matcher, name)
  if matcher == nil or matcher == '' or matcher == '*' or matcher == '.*' then return true end
  matcher = tostring(matcher)
  name = tostring(name or '')
  if matcher == name then return true end
  local lowered = matcher:lower()
  if not is_pattern(lowered) then
    return name:lower():find(lowered, 1, true) ~= nil
  end
  local ok, found = pcall(string.find, name:lower(), lowered)
  return ok and found ~= nil
end
M.matches = matches

-- A command hook's stdin carries the payload as JSON. `host.exec` takes a command string, not a
-- stdin pipe, so the payload travels as a file and the command's own stdin is redirected from it -
-- exactly what Claude Code's hooks receive on stdin, without a new host capability.
local function payload_file(body)
  local dir = (paths.temp() or '/tmp'):gsub('\\', '/')
  local name = host.uuid and host.uuid() or tostring(math.floor((host.now() or 0) * 1000))
  local path = dir .. '/wa-hook-' .. tostring(name) .. '.json'
  local written = false
  if host.write_file then
    local ok, value = pcall(host.write_file, path, body)
    written = ok and value == true
  end
  if not written then return nil, 'hook_payload_not_written' end
  return path
end

local function remove_file(path)
  if type(path) ~= 'string' then return end
  if type(os) == 'table' and type(os.remove) == 'function' then
    pcall(os.remove, path)
    return
  end
  pcall(host.exec, 'rm -f ' .. quote(path), '', 5)
end

-- ---- config -------------------------------------------------------------------------------------

-- Process-wide state, deliberately in one table every instance of this module shares.
--
-- `dofile` re-executes a module in this interpreter, so `tools.lua`, `agent.lua`, `chat.lua`, `services.lua`
-- and the read surface each hold their own instance of this file. Per-instance caches would mean the
-- config is read once per instance, `/hooks reload` would clear only one of them, a Lua plugin
-- registered by one module would be invisible to the one that fires the event, and `/hooks` would
-- report "no hook has run" about a process in which hooks are running. The state is the node's, not
-- the module's.
local shared = rawget(_G, '__wa_hooks_state')
if type(shared) ~= 'table' then
  shared = { config = { key = nil, value = nil }, statusline = {}, outcomes = {}, plugins = {},
    commands = {}, entries = {} }
  rawset(_G, '__wa_hooks_state', shared)
end

local cache = shared.config
-- The footer's mod segments are cached across redraws; `M.reset` clears it.
local statusline_cache = shared.statusline

local function hooks_disabled()
  local flag = tostring(host.getenv('WASM_AGENT_HOOKS') or ''):lower()
  return flag == 'off' or flag == '0' or flag == 'false'
end

local function claude_env_opt_in()
  local flag = tostring(host.getenv('WASM_AGENT_CLAUDE_HOOKS') or ''):lower()
  return flag == '1' or flag == 'on' or flag == 'true'
end

-- ---------------------------------------------------------------- the hooks seam
--
-- The engine's rules - which sources exist, both config shapes, the matchers, the ordering, the
-- per-hook timeouts, the protocol's interpretation, the bounds and the mods surface - can be served by
-- the `hooks` component (docs/CORE-SPLIT.md, docs/HOOK-EVENTS.md). The two impure acts stay here:
-- **the node reads the config files** (a component has no path to the operator's config directory and
-- no grant to it) and **the node runs each hook** (a command is a process with the node's grants; a Lua
-- plugin is a function in this interpreter). `WA_HOOKS_COMPONENT=1` routes the decisions there;
-- **without it every function below runs exactly the code it always ran**.
--
-- A refusal is not a failure: a hook that denies comes back as a decision and reaches the caller
-- unchanged, field for field. Only "the component could not answer" falls back to the native engine,
-- with one log line per (operation, reason) - a silent fallback would make a broken component look
-- like a working engine, and a log flooded with the same line is not visible either.
--
-- The JSON below is this tree's transport for every capability (`host.selfloop` and `host.memory` do
-- the same); it stops at the host, which turns it into the typed records of `wit/hooks/hooks.wit`
-- before the component sees anything.
-- The switch is the `hooks` feature (docs/FEATURES.md), asked at every route through the one resolver
-- (`lua/core/features.lua`): an operator turns it on in `policy.json` and the next event takes the
-- component path, without a restart. A feature that is on with no component installed answers
-- `component_missing`, and the fallback line below says so instead of the node looking native.
local features = dofile('lua/core/features.lua')
-- The test seam: two instances of this module in one process (native and seam) share one `host.features`
-- table, so the component test sets this on the instance it wants routed. A node never sets it.
M.seam_override = nil
local function seam_component()
  if M.seam_override ~= nil then return M.seam_override() end
  return features.seam('hooks')
end
local fallback_logged = {}

local function note_fallback(op, reason)
  local key = tostring(op) .. '|' .. tostring(reason)
  if fallback_logged[key] then return end
  fallback_logged[key] = true
  pcall(host.log, 'hooks: ' .. tostring(op) .. ' served natively: ' .. tostring(reason))
end

-- One component call. Returns the seam's answer, or nil and the reason there is none.
local function seam(op, args)
  local active, reason = seam_component()
  if not active then return nil, reason end
  if type(host.hooks) ~= 'function' then return nil, 'component_capability_missing' end
  args.op = op
  local ok, answer = pcall(host.hooks, json.encode(args))
  if not ok then return nil, 'component_call_failed' end
  if type(answer) == 'string' then
    local decoded_ok, decoded = pcall(json.decode, answer)
    answer = decoded_ok and decoded or nil
  end
  if type(answer) ~= 'table' then return nil, 'component_no_answer' end
  if not answer.ok then return nil, tostring(answer.error or 'component_failed') end
  if answer.result == nil then return nil, 'component_empty_answer' end
  return answer.result
end

local function routed(op, args)
  local answer, reason = seam(op, args)
  if answer ~= nil then return answer end
  if reason ~= 'seam_disabled' then note_fallback(op, reason) end
  return nil
end

-- One config file's text, or the reason there is none. The *parse* is the component's; the read is
-- the node's, because the operator's files are not a component's to open.
local function read_text(path)
  if type(path) ~= 'string' or path == '' or type(host.read_file) ~= 'function' then
    return nil, 'unreadable'
  end
  local ok, text = pcall(host.read_file, path)
  if not ok or type(text) ~= 'string' then return nil, 'missing' end
  return text, nil
end

local function source_record(name, path, kind)
  local text, problem = read_text(path)
  return { name = name, path = path, kind = kind, text = text, problem = problem }
end

-- The config request: the two native sources always, Claude Code's two only once the operator has
-- opted in (this node's file says `claude_compat`, or the environment does) - the same rule the native
-- read follows, so a node that never opted in never opens those files.
local function configure(workdir, with_claude)
  local sources = {
    source_record('node', paths.config() .. '/hooks.json', 'native'),
    source_record('project', workdir .. '/.wasm-agent/hooks.json', 'native'),
  }
  if with_claude then
    local home = paths.home()
    sources[#sources + 1] = source_record('user-claude', home .. '/.claude/settings.json', 'claude')
    sources[#sources + 1] = source_record('project-claude', workdir .. '/.claude/settings.json', 'claude')
  end
  return routed('configure', {
    workdir = workdir,
    disabled = hooks_disabled(),
    claude_env_opt_in = claude_env_opt_in(),
    sources = sources,
  })
end

-- The component's view, in the shape every reader below (`M.active`, `M.list`, `M.report`,
-- `M.statusline`, `M.commands`) already consumes: the rendering stays here, the facts come from there.
local function view_from(facts)
  local mods = facts.mods or {}
  return {
    version = M.VERSION,
    disabled = facts.disabled == true,
    workdir = tostring(facts.workdir or ''),
    sources = facts.sources or {},
    errors = facts.errors or {},
    hooks = facts.hooks or {},
    mods = {
      statusline = mods.statusline or {},
      commands = mods.commands or {},
      keybindings = mods.keybindings or {},
    },
    compat = facts.compat == true,
    present = facts.present == true,
  }
end

local entries_cache = shared.entries

-- The entries that run for one event, after the component's matchers, cached per (config generation,
-- event, tool) - the same reason the native view is cached: a turn asks for the same tool's entries on
-- every call, and an inert node must not pay a crossing per tool call.
local function seam_match(event, entries, tool)
  local key = tostring(cache.key) .. '|' .. tostring(event) .. '|' .. tostring(tool) .. '|'
    .. tostring(#entries)
  local hit = entries_cache[key]
  if hit then return hit end
  local matched = routed('entries', { event = event, tool = tool, entries = entries })
  if matched == nil then return nil end
  entries_cache[key] = matched
  return matched
end

local function seam_entries(event, view, tool)
  return seam_match(event, view.hooks[event] or {}, tool)
end

local function source(name, path, kind)
  return { name = name, path = path, kind = kind }
end

-- Turn one raw event list into entries. Both shapes are accepted because both exist in the world:
-- the native row (`name`, `command`, `timeout_ms`) and Claude Code's (`matcher` -> `hooks[]`).
local function normalize_entries(event_name, raw, origin, out, errors)
  if raw == nil then return end
  if type(raw) ~= 'table' then
    errors[#errors + 1] = origin.name .. ': ' .. event_name .. ' is not a list'
    return
  end
  for index, item in ipairs(raw) do
    if type(item) ~= 'table' then
      errors[#errors + 1] = origin.name .. ': ' .. event_name .. '[' .. index .. '] is not an object'
    else
      local matcher = item.matcher
      local inner = type(item.hooks) == 'table' and item.hooks or { item }
      for _, hook in ipairs(inner) do
        if type(hook) ~= 'table' then
          errors[#errors + 1] = origin.name .. ': ' .. event_name .. ' hook is not an object'
        else
          local kind = tostring(hook.type or (hook.command and 'command') or 'command')
          local command = hook.command
          if kind ~= 'command' or type(command) ~= 'string' or command:match('^%s*$') then
            errors[#errors + 1] = origin.name .. ': ' .. event_name ..
              ' entry ' .. index .. ' has no command (only `command` hooks are configurable)'
          else
            -- Claude Code counts timeouts in seconds, the native file in milliseconds.
            local timeout = tonumber(hook.timeout_ms)
            if not timeout then
              local seconds = tonumber(hook.timeout)
              timeout = seconds and math.floor(seconds * 1000) or M.DEFAULT_TIMEOUT_MS
            end
            if timeout < 100 then timeout = 100 end
            if timeout > M.MAX_TIMEOUT_MS then timeout = M.MAX_TIMEOUT_MS end
            out[#out + 1] = {
              event = event_name,
              name = tostring(hook.name or item.name or (event_name .. '#' .. index)),
              matcher = matcher ~= nil and tostring(matcher) or (item.matcher and tostring(item.matcher) or nil),
              command = command,
              timeout_ms = timeout,
              on_ask = tostring(hook.on_ask or item.on_ask or 'deny'),
              origin = origin.name,
              path = origin.path,
              order = #out + 1,
            }
          end
        end
      end
    end
  end
end

local function normalize_commands(raw, origin, errors)
  local out = {}
  if raw == nil then return out end
  if type(raw) ~= 'table' then
    errors[#errors + 1] = origin.name .. ': mods.commands is not a list'
    return out
  end
  for index, item in ipairs(raw) do
    local name = type(item) == 'table' and tostring(item.name or '') or ''
    if name:sub(1, 1) ~= '/' or #name > 40 or name:find('%s') then
      errors[#errors + 1] = origin.name .. ': mods.commands[' .. index .. '] needs a name like /hello'
    elseif type(item.command) ~= 'string' or item.command:match('^%s*$') then
      errors[#errors + 1] = origin.name .. ': ' .. name .. ' has no command'
    else
      out[#out + 1] = { name = name, description = tostring(item.description or 'custom command'),
        command = item.command, timeout_ms = tonumber(item.timeout_ms) or M.DEFAULT_TIMEOUT_MS,
        origin = origin.name }
    end
  end
  return out
end

-- Read every source, in the documented order, and answer the merged view. One unreadable or invalid
-- file is reported and skipped: an operator editing a config file must not lose the hooks that were
-- already working.
function M.config(opts)
  opts = opts or {}
  local workdir = tostring(opts.workdir or platform.cwd() or ''):gsub('\\', '/')
  local key = paths.home() .. '|' .. workdir .. '|' .. tostring(opts.reload) .. '|' ..
    tostring((host.getenv('WASM_AGENT_HOOKS') or '') .. '|' .. (host.getenv('WASM_AGENT_CLAUDE_HOOKS') or ''))
  if cache.key == key then return cache.value end
  if seam_component() then
    -- One configure per config generation. A view that says `compat` is asked again with Claude
    -- Code's two sources in the request, because only a native config or the environment can opt in.
    local facts = configure(workdir, false)
    if facts and facts.compat == true then
      local full = configure(workdir, true)
      if full then facts = full end
    end
    if facts then
      cache.key, cache.value = key, view_from(facts)
      return cache.value
    end
  end
  local view = { version = M.VERSION, disabled = hooks_disabled(), workdir = workdir,
    sources = {}, errors = {}, hooks = {}, mods = { statusline = {}, commands = {}, keybindings = {} },
    compat = false, present = false }
  cache.key, cache.value = key, view
  if view.disabled then return view end

  local node = source('node', paths.config() .. '/hooks.json', 'native')
  local project = source('project', workdir .. '/.wasm-agent/hooks.json', 'native')
  local native = { node, project }
  local compat = claude_env_opt_in()
  for _, origin in ipairs(native) do
    local value, problem = read_json(origin.path)
    if problem == 'invalid_json' then
      view.errors[#view.errors + 1] = origin.name .. ': ' .. origin.path .. ' is not valid JSON'
    elseif value then
      origin.present = true
      view.present = true
      view.sources[#view.sources + 1] = { name = origin.name, path = origin.path, kind = origin.kind }
      local hooks = value.hooks or value
      if type(hooks) ~= 'table' then
        view.errors[#view.errors + 1] = origin.name .. ': hooks is not an object'
      else
        for name, list in pairs(hooks) do
          name = tostring(name)
          if EVENT_BY_NAME[name] then
            view.hooks[name] = view.hooks[name] or {}
            normalize_entries(name, list, origin, view.hooks[name], view.errors)
          elseif name:sub(1, 4) == 'bus:' then
            -- A bus topic is a hook source (docs/BUS.md). The topic is data; a hook never decides
            -- anything about the publish, it is told about it.
            view.hooks[name] = view.hooks[name] or {}
            normalize_entries(name, list, origin, view.hooks[name], view.errors)
          elseif name ~= 'version' and name ~= 'claude_compat' then
            view.errors[#view.errors + 1] = origin.name .. ': unknown hook event ' .. name
          end
        end
      end
      local mods = value.mods
      if type(mods) == 'table' then
        for _, item in ipairs(type(mods.statusline) == 'table' and mods.statusline or {}) do
          if type(item) == 'table' and type(item.command) == 'string' then
            view.mods.statusline[#view.mods.statusline + 1] = {
              event = 'StatusLine',
              name = tostring(item.name or ('statusline#' .. #view.mods.statusline + 1)),
              command = item.command, timeout_ms = tonumber(item.timeout_ms) or M.STATUSLINE_TIMEOUT_MS,
              origin = origin.name }
          end
        end
        for _, item in ipairs(normalize_commands(mods.commands, origin, view.errors)) do
          view.mods.commands[#view.mods.commands + 1] = item
        end
        for _, item in ipairs(type(mods.keybindings) == 'table' and mods.keybindings or {}) do
          if type(item) == 'table' and type(item.key) == 'string' and type(item.command) == 'string' then
            view.mods.keybindings[#view.mods.keybindings + 1] = {
              key = item.key, command = item.command, description = tostring(item.description or ''),
              origin = origin.name }
          end
        end
      end
      if value.claude_compat == true or (type(value.hooks) == 'table' and value.hooks.claude_compat == true) then
        compat = true
      end
    end
  end
  view.compat = compat
  if compat then
    local claude = {
      source('user-claude', paths.home() .. '/.claude/settings.json', 'claude'),
      source('project-claude', workdir .. '/.claude/settings.json', 'claude'),
    }
    for _, origin in ipairs(claude) do
      local value, problem = read_json(origin.path)
      if problem == 'invalid_json' then
        view.errors[#view.errors + 1] = origin.name .. ': ' .. origin.path .. ' is not valid JSON'
      elseif value then
        view.present = true
        view.sources[#view.sources + 1] = { name = origin.name, path = origin.path, kind = origin.kind }
        local block = type(value.hooks) == 'table' and value.hooks or {}
        for name, list in pairs(block) do
          name = tostring(name)
          if EVENT_BY_NAME[name] then
            view.hooks[name] = view.hooks[name] or {}
            normalize_entries(name, list, origin, view.hooks[name], view.errors)
          else
            view.errors[#view.errors + 1] = origin.name .. ': unknown hook event ' .. name
          end
        end
      end
    end
  end
  for _, list in pairs(view.hooks) do
    table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end)
  end
  return view
end

-- A new config read and a cleared status-line cache: `/hooks reload`, and the tests.
function M.reset()
  cache.key, cache.value = nil, nil
  for key in pairs(entries_cache) do entries_cache[key] = nil end
  for key in pairs(statusline_cache) do statusline_cache[key] = nil end
  for index = #shared.outcomes, 1, -1 do shared.outcomes[index] = nil end
end

M.last_outcomes = shared.outcomes

-- ---- the Lua plugin surface ---------------------------------------------------------------------

-- Plugin hooks are functions, registered at load time by a module the operator enabled. They take the
-- same payload table a command hook receives and answer the same decision table, so one interpreter
-- covers both. A function hook cannot be configured from JSON (JSON has no functions) - that is the
-- whole difference.
local plugin_hooks = shared.plugins

function M.register(event, fn, opts)
  opts = opts or {}
  if not EVENT_BY_NAME[event] then return nil, 'unknown_hook_event:' .. tostring(event) end
  if type(fn) ~= 'function' then return nil, 'hook_function_required' end
  local handle = { event = event, fn = fn, name = tostring(opts.name or ('lua#' .. (#plugin_hooks + 1))),
    matcher = opts.matcher, origin = 'plugin', order = #plugin_hooks + 1, kind = 'lua' }
  plugin_hooks[#plugin_hooks + 1] = handle
  cache.key = nil
  return handle
end

function M.unregister(handle)
  for index, entry in ipairs(plugin_hooks) do
    if entry == handle then table.remove(plugin_hooks, index); cache.key = nil; return true end
  end
  return false
end

local registered_commands = shared.commands

function M.register_command(name, fn, opts)
  opts = opts or {}
  if type(name) ~= 'string' or name:sub(1, 1) ~= '/' then return nil, 'command_name_must_start_with_slash' end
  if type(fn) ~= 'function' then return nil, 'command_function_required' end
  registered_commands[name] = { name = name, description = tostring(opts.description or 'plugin command'),
    fn = fn, origin = 'plugin' }
  cache.key = nil
  return registered_commands[name]
end

-- The Lua plugin hooks configured for one event, in registration order. They always run after the
-- config sources' entries (the native order), and their matcher is matched here: this interpreter is
-- the only thing that can run one, so it is also the only thing that decides whether it applies.
local function plugin_entries(event, tool)
  local catalogue = EVENT_BY_NAME[event]
  local list = {}
  for _, entry in ipairs(plugin_hooks) do
    if entry.event == event and (not (catalogue and catalogue.matcher) or matches(entry.matcher, tool)) then
      list[#list + 1] = entry
    end
  end
  return list
end

-- One event's whole run order with the seam on: what the component matched and ordered, then the
-- plugin hooks. `nil` means the component could not answer (already logged) and the native filter
-- below must run.
local function seam_plan(event, view, tool, entries)
  local matched = seam_match(event, entries or view.hooks[event] or {}, tool)
  if not matched then return nil end
  local list = {}
  for _, entry in ipairs(matched) do list[#list + 1] = entry end
  if not entries then
    for _, entry in ipairs(plugin_entries(event, tool)) do list[#list + 1] = entry end
  end
  return list
end

-- Every entry for one event, in run order: command hooks from the config sources, then plugin hooks.
-- `opts.tool` filters by matcher (a non-tool event ignores matchers).
function M.entries(event, opts)
  opts = opts or {}
  local view = M.config(opts)
  if view.disabled then return {} end
  if seam_component() then
    local planned = seam_plan(event, view, opts.tool)
    if planned then return planned end
  end
  local list = {}
  local catalogue = EVENT_BY_NAME[event]
  for _, entry in ipairs(view.hooks[event] or {}) do
    if not (catalogue and catalogue.matcher) or matches(entry.matcher, opts.tool) then
      list[#list + 1] = entry
    end
  end
  for _, entry in ipairs(plugin_entries(event, opts.tool)) do list[#list + 1] = entry end
  return list
end

function M.active(opts)
  local view = M.config(opts)
  if view.disabled then return false end
  for _ in pairs(view.hooks) do return true end
  if #plugin_hooks > 0 then return true end
  return false
end

-- ---- running one hook ---------------------------------------------------------------------------

local function outcome(entry, status, extra)
  local row = { name = entry.name, event = entry.event, kind = entry.kind or 'command',
    origin = entry.origin, status = status, timeout_ms = entry.timeout_ms, at = math.floor((host.now() or 0) * 1000) }
  for key, value in pairs(extra or {}) do row[key] = value end
  return row
end

local function record(entry, row)
  local outcomes = shared.outcomes
  outcomes[#outcomes + 1] = row
  while #outcomes > M.LAST_KEPT do table.remove(outcomes, 1) end
  -- A hook's own words can carry a secret it read; the record is redacted at the boundary, like
  -- every other log in the node.
  if row.detail then row.detail = clip(redact.text(row.detail), M.MAX_STDERR_BYTES) end
  if row.system_message then row.system_message = clip(redact.text(row.system_message), M.MAX_SYSTEM_MESSAGE_BYTES) end
  if entry and row.status ~= 'ok' and type(host.log) == 'function' then
    pcall(host.log, 'hook ' .. tostring(entry.name) .. ' (' .. tostring(entry.event) .. '): ' .. row.status
      .. (row.detail and (': ' .. tostring(redact.text(row.detail))) or ''))
  end
  return row
end

local function run_command_hook(entry, payload, ctx)
  local body = json.encode(payload)
  local path, problem = payload_file(body)
  if not path then return outcome(entry, 'error', { error = problem }) end
  local environment = table.concat({
    'WA_HOOK_EVENT=' .. quote(entry.event),
    'WA_HOOK_NAME=' .. quote(entry.name),
    'WA_HOOK_SESSION=' .. quote(ctx.session_id or ''),
    'CLAUDE_PROJECT_DIR=' .. quote(ctx.cwd or ''),
  }, ' ')
  local command = environment .. ' ' .. entry.command .. ' < ' .. quote(path)
  local started = host.monotonic_ms and host.monotonic_ms() or math.floor((host.now() or 0) * 1000)
  local ok, raw = pcall(host.exec, command, ctx.cwd or '', math.max(1, math.ceil(entry.timeout_ms / 1000)))
  remove_file(path)
  local elapsed = (host.monotonic_ms and host.monotonic_ms() or math.floor((host.now() or 0) * 1000)) - started
  if not ok then
    return outcome(entry, 'error', { error = 'hook_exec_failed', detail = tostring(raw), ms = elapsed })
  end
  local result = decode_object(raw) or {}
  if result.error == 'deadline_exceeded' or result.error == 'operation_supervisor_overdue' then
    return outcome(entry, 'timeout', { detail = 'no answer within ' .. entry.timeout_ms .. 'ms', ms = elapsed })
  end
  local stdout = tostring(result.stdout or '')
  local stderr = tostring(result.stderr or '')
  local clipped = false
  if #stdout > M.MAX_STDOUT_BYTES then stdout, clipped = stdout:sub(1, M.MAX_STDOUT_BYTES), true end
  if #stderr > M.MAX_STDERR_BYTES then stderr = stderr:sub(1, M.MAX_STDERR_BYTES) end
  return outcome(entry, 'ok', {
    exit_code = tonumber(result.code), stdout = stdout, stderr = stderr, ms = elapsed,
    stdout_clipped = clipped or nil, detail = stderr ~= '' and stderr or nil,
  })
end

local function run_lua_hook(entry, payload, ctx)
  local ok, answer = pcall(entry.fn, payload, ctx)
  if not ok then return outcome(entry, 'error', { error = 'hook_raised', detail = tostring(answer) }) end
  if type(answer) ~= 'table' then return outcome(entry, 'ok') end
  return outcome(entry, 'ok', { json = answer })
end

-- ---- interpreting what a hook answered ----------------------------------------------------------

-- The protocol is Claude Code's: exit 0 with a JSON object on stdout, exit 2 meaning "block, and
-- here is the reason on stderr", anything else a visible failure that changes nothing. The same
-- fields are read from a Lua hook's returned table, so both kinds of hook are one contract.
local function interpret(entry, row, verdict, payload)
  local answer = row.json or decode_object(row.stdout)
  if row.status == 'timeout' then
    verdict.errors[#verdict.errors + 1] = { name = entry.name, error = 'timeout' }
    return
  elseif row.status == 'error' then
    verdict.errors[#verdict.errors + 1] = { name = entry.name, error = row.error or 'hook_error',
      detail = row.detail }
    return
  end
  local code = tonumber(row.exit_code or 0)
  if code == 2 then
    -- Claude Code's blocking exit. The reason is on stderr, and it is the sentence the model or the
    -- reader is shown.
    verdict.blocked = true
    verdict.blocked_by = entry.name
    verdict.reason = one_line(row.stderr) ~= '' and one_line(row.stderr)
      or (answer and answer.reason) or ('hook ' .. entry.name .. ' exited 2')
    verdict.status = 'blocked'
    return
  elseif code ~= 0 then
    verdict.errors[#verdict.errors + 1] = { name = entry.name, error = 'exit_' .. tostring(code), detail = row.detail }
    return
  end

  if type(answer) ~= 'table' then return end
  row.answered = true

  -- `systemMessage` is the mods surface: a line the reader sees, never a decision.
  local message = answer.systemMessage
  if type(message) == 'string' and one_line(message) ~= '' and #verdict.system_messages < M.MAX_SYSTEM_MESSAGES then
    verdict.system_messages[#verdict.system_messages + 1] = clip(one_line(message), M.MAX_SYSTEM_MESSAGE_BYTES)
    row.system_message = clip(one_line(message), M.MAX_SYSTEM_MESSAGE_BYTES)
  end

  -- `continue:false` stops the run where the event allows it; the reason is the stop reason.
  if answer.continue == false and verdict.event == 'Stop' then
    verdict.stop = true
    verdict.stop_reason = tostring(answer.stopReason or answer.reason or 'stopped by hook ' .. entry.name)
    return
  end

  local specific = type(answer.hookSpecificOutput) == 'table' and answer.hookSpecificOutput or nil
  if specific then
    if specific.hookEventName and specific.hookEventName ~= verdict.event then
      verdict.errors[#verdict.errors + 1] = { name = entry.name, error = 'hook_event_name_mismatch',
        detail = tostring(specific.hookEventName) .. ' != ' .. verdict.event }
    end
    local permission = specific.permissionDecision
    if permission == 'deny' then
      verdict.blocked = true
      verdict.blocked_by = entry.name
      verdict.permission = 'deny'
      verdict.reason = one_line(specific.permissionDecisionReason or answer.reason or '')
      if verdict.reason == '' then verdict.reason = 'denied by hook ' .. entry.name end
      verdict.status = 'denied'
      return
    elseif permission == 'ask' then
      -- This host has no interactive per-call permission prompt, so `ask` is answered by policy:
      -- the entry's `on_ask` (default deny) decides. Fabricating an allow would be worse than a
      -- refusal the reader can change.
      if entry.on_ask == 'allow' then
        verdict.notes[#verdict.notes + 1] = 'hook ' .. entry.name .. ' asked; on_ask=allow'
        verdict.permission = verdict.permission or 'allow'
      else
        verdict.blocked = true
        verdict.blocked_by = entry.name
        verdict.permission = 'ask'
        verdict.reason = 'hook ' .. entry.name .. ' asked to confirm this call'
          .. (one_line(specific.permissionDecisionReason or '') ~= ''
            and (': ' .. one_line(specific.permissionDecisionReason)) or '')
          .. '; no interactive prompt exists for tool calls, so it is refused (set on_ask:"allow" on this hook to allow it)'
        verdict.status = 'ask'
        return
      end
    elseif permission == 'allow' then
      verdict.permission = verdict.permission or 'allow'
      verdict.allowed_by = entry.name
    end
    if type(specific.updatedInput) == 'table' and verdict.event == 'PreToolUse' then
      -- Merged over the call's arguments, so a hook can change one field without restating the
      -- object (Claude Code replaces the whole object; merging is the difference, and it is why a
      -- hook that only narrows a path cannot accidentally drop `requests`). Apply it to the payload
      -- too, so a later hook sees the chain it is part of.
      for key, value in pairs(specific.updatedInput) do
        verdict.updated_input[key] = value
        verdict.input_changes[key] = value
      end
      if type(payload.tool_input) == 'table' then
        for key, value in pairs(specific.updatedInput) do
          if value == json.null then payload.tool_input[key] = nil else payload.tool_input[key] = value end
        end
      end
    end
    if type(specific.additionalContext) == 'string' and specific.additionalContext ~= '' then
      verdict.additional_context = clip(
        (verdict.additional_context and (verdict.additional_context .. '\n') or '') .. specific.additionalContext,
        M.MAX_CONTEXT_BYTES)
    end
  end

  -- The older, flatter shape: `decision: "block"|"approve"` plus `reason`.
  if answer.decision == 'block' or answer.decision == 'deny' then
    verdict.blocked = true
    verdict.blocked_by = entry.name
    verdict.reason = one_line(answer.reason) ~= '' and one_line(answer.reason) or ('blocked by hook ' .. entry.name)
    verdict.status = 'blocked'
  elseif answer.decision == 'approve' or answer.decision == 'allow' then
    verdict.permission = verdict.permission or 'allow'
    verdict.allowed_by = entry.name
  end
  if type(answer.additionalContext) == 'string' and answer.additionalContext ~= '' then
    verdict.additional_context = clip(
      (verdict.additional_context and (verdict.additional_context .. '\n') or '') .. answer.additionalContext,
      M.MAX_CONTEXT_BYTES)
  end
  -- SelfWake's own veto shape: a `decision:"block"` may carry when to try again.
  local reschedule = tonumber(answer.reschedule_seconds or (specific and specific.rescheduleSeconds) or nil)
  if reschedule and reschedule > 0 then verdict.reschedule_seconds = math.floor(reschedule) end
  -- StatusLine: the segment is the hook's stdout, and anything else it says is ignored.
  if verdict.event == 'StatusLine' and one_line(row.stdout) ~= '' then
    verdict.text = clip(one_line(row.stdout), M.STATUSLINE_MAX)
  end
end

local function blank(event)
  return { version = M.VERSION, event = event, ran = 0, outcomes = {}, errors = {}, notes = {},
    system_messages = {}, blocked = false, status = 'no_hooks', additional_context = nil,
    updated_input = {}, input_changes = {}, permission = nil, text = nil }
end

local function envelope(event, payload, ctx)
  local body = {
    hook_event_name = event,
    version = M.VERSION,
    session_id = tostring(ctx.session_id or ''),
    cwd = tostring(ctx.cwd or platform.cwd() or ''),
  }
  if ctx.run_id then body.run_id = tostring(ctx.run_id) end
  if ctx.node_id and ctx.node_id ~= '' then body.node_id = tostring(ctx.node_id) end
  if ctx.user_id and ctx.user_id ~= '' then body.user_id = tostring(ctx.user_id) end
  if ctx.role then body.role = tostring(ctx.role) end
  if ctx.subagent then body.subagent = true end
  for key, value in pairs(payload or {}) do body[key] = value end
  return body
end

-- ---------------------------------------------------------------- the seam's drivers
--
-- The node's hands, the component's rules. One hook at a time: run it here, then ask what its answer
-- means - only a verdict can say whether the next hook still runs, and the native loop breaks on a
-- refusal. One crossing per hook answer, which is what `scripts/bench-hooks.sh` measures.
-- The entry as the wire record. A Lua plugin's `fn` cannot cross (JSON has no functions) and the
-- component needs only the fields the protocol reads, so the function stays in this interpreter.
local function wire_entry(entry)
  return { name = entry.name, event = entry.event, kind = entry.kind, matcher = entry.matcher,
    command = entry.command, timeout_ms = entry.timeout_ms, on_ask = entry.on_ask,
    origin = entry.origin, path = entry.path, order = entry.order }
end

-- The row as the wire record. A Lua hook's answer is a table in this interpreter and a JSON object to
-- the component (`row.json` is what `interpret` reads either way), so it is encoded on the way out.
local WIRE_ROW = { 'name', 'event', 'kind', 'origin', 'status', 'timeout_ms', 'at', 'exit_code',
  'stdout', 'stderr', 'ms', 'error', 'detail', 'stdout_clipped', 'answered', 'system_message' }

local function wire_row(row)
  local out = {}
  for _, key in ipairs(WIRE_ROW) do out[key] = row[key] end
  if type(row.json) == 'table' then out.json = json.encode(row.json) end
  return out
end

-- The other direction: a Lua hook's answer travelled as JSON text and comes back as the table the
-- native verdict carries, so a caller reading `verdict.outcomes[1].json` sees one shape.
local function wire_rows_back(decision)
  for _, row in ipairs(decision and decision.outcomes or {}) do
    if type(row.json) == 'string' then
      local ok, decoded = pcall(json.decode, row.json)
      if ok and type(decoded) == 'table' then row.json = decoded end
    end
  end
  return decision
end

local function seam_row(entry, body, opts)
  local row = entry.kind == 'lua' and run_lua_hook(entry, body, opts) or run_command_hook(entry, body, opts)
  record(entry, row)
  return row
end

-- One event through the component. `nil` means "nothing has run; the native engine should".
local function seam_fire(event, payload, opts, match_opts)
  local view = M.config(match_opts)
  if view.disabled then return blank(event) end
  local entries = seam_plan(event, view, match_opts.tool)
  if not entries then return nil end
  local verdict = blank(event)
  if #entries == 0 then return verdict end
  -- The status a run of hooks starts from is this driver's: `M.fire` answers `ok` when there is
  -- something to run, a bus publish answers `no_hooks` (the native `M.bus` never sets it).
  local prior = blank(event)
  prior.status = 'ok'
  local body = envelope(event, payload, opts)
  local payload_text = json.encode(body)
  for _, entry in ipairs(entries) do
    local row = seam_row(entry, body, opts)
    local answer, reason = seam('decide', {
      event = event, payload = payload_text, prior = prior, entry = wire_entry(entry), row = wire_row(row) })
    if not answer then
      -- Hooks have already run: the native engine must not run them a second time. The verdict so far
      -- is returned with the failure named, and a hook layer never fails a run on its own.
      note_fallback('decide', reason)
      verdict.status = 'engine_error'
      verdict.errors[#verdict.errors + 1] = { error = 'hook_engine_fallback', detail = tostring(reason) }
      return verdict
    end
    prior = wire_rows_back(answer.decision)
    -- The recorded row is the one `/hooks` lists; native keeps one table, so the two fields the
    -- interpretation sets are copied across instead of existing twice.
    local reported = prior.outcomes and prior.outcomes[#prior.outcomes]
    if reported then
      row.answered = reported.answered
      row.system_message = reported.system_message
    end
    if answer.payload then
      payload_text = answer.payload
      local decoded_ok, decoded = pcall(json.decode, payload_text)
      if decoded_ok and type(decoded) == 'table' then body = decoded end
    end
    if answer.stop then break end
  end
  return prior
end

-- One bus publish: `bus:<topic>` then `bus:*`, one shared verdict, the same engine. Both entry lists
-- are fetched before the first hook runs, so an unreachable component means "nothing ran" and the
-- native path is safe.
local function seam_bus(topic, payload, opts)
  local match_opts = { workdir = opts.workdir, cwd = opts.cwd }
  local view = M.config(match_opts)
  if view.disabled then return blank('bus:' .. topic) end
  local events = { 'bus:' .. topic, 'bus:*' }
  local lists = {}
  for _, event in ipairs(events) do
    local entries = seam_plan(event, view, nil)
    if not entries then return nil end
    lists[event] = entries
  end
  local merged = blank('bus:' .. topic)
  local prior = merged
  for _, event in ipairs(events) do
    local body = envelope(event, payload, opts)
    body.topic = topic
    local payload_text = json.encode(body)
    for _, entry in ipairs(lists[event]) do
      local row = seam_row(entry, body, opts)
      local answer, reason = seam('decide', {
        event = 'bus:' .. topic, payload = payload_text, prior = prior, entry = wire_entry(entry), row = wire_row(row) })
      if not answer then
        note_fallback('decide', reason)
        merged.status = 'engine_error'
        merged.errors[#merged.errors + 1] = { error = 'hook_engine_fallback', detail = tostring(reason) }
        return merged
      end
      prior = wire_rows_back(answer.decision)
      merged = prior
      local reported = prior.outcomes and prior.outcomes[#prior.outcomes]
      if reported then
        row.answered = reported.answered
        row.system_message = reported.system_message
      end
      if answer.payload then
        payload_text = answer.payload
        local decoded_ok, decoded = pcall(json.decode, payload_text)
        if decoded_ok and type(decoded) == 'table' then body = decoded end
      end
    end
  end
  return merged
end

-- The footer's segments, in one crossing: the rows are the node's, the line is the component's.
local function seam_statusline(view, opts)
  local entries = seam_match('StatusLine', view.mods.statusline or {}, nil)
  if not entries then return nil end
  if #entries == 0 then return '' end
  local rows = {}
  for _, entry in ipairs(entries) do
    local body = envelope('StatusLine', {
      model = opts.model, runs = opts.runs, tokens = opts.tokens, context = opts.context,
      context_percent = opts.context_percent,
    }, opts)
    rows[#rows + 1] = seam_row(entry, body, opts)
  end
  local text = routed('segment', { entries = entries, rows = rows })
  if text == nil then return nil end
  return tostring(text)
end

-- Fire one event. Never raises: a hook layer that can fail a run is a hook layer the operator turns
-- off. The verdict is a table (see `blank`), and only `blocked`/`stop` change the caller's path.
function M.fire(event, payload, opts)
  opts = opts or {}
  -- A matcher matches the thing the event is about: the tool name for a tool event, the profile for a
  -- child, the component name for an install. Derived from the payload so a caller cannot forget it.
  local match_opts = { workdir = opts.workdir, cwd = opts.cwd, tool = opts.tool }
  if not match_opts.tool and type(payload) == 'table' then
    match_opts.tool = payload.tool_name or payload.profile or payload.component
  end
  if seam_component() then
    local sealed = seam_fire(event, payload, opts, match_opts)
    if sealed then return sealed end
  end
  local verdict = blank(event)
  local ok, problem = pcall(function()
    local entries = M.entries(event, match_opts)
    if #entries == 0 then return end
    verdict.status = 'ok'
    local body = envelope(event, payload, opts)
    for _, entry in ipairs(entries) do
      local row
      if entry.kind == 'lua' then row = run_lua_hook(entry, body, opts) else row = run_command_hook(entry, body, opts) end
      verdict.ran = verdict.ran + 1
      verdict.outcomes[#verdict.outcomes + 1] = record(entry, row)
      interpret(entry, row, verdict, body)
      if verdict.blocked or verdict.stop then break end
    end
  end)
  if not ok then
    verdict.status = 'engine_error'
    verdict.errors[#verdict.errors + 1] = { error = 'engine_error', detail = tostring(problem) }
  end
  return verdict
end

-- A bus topic is a hook source too (docs/BUS.md): `bus:<topic>` names one topic, `bus:*` every
-- topic. This is the read side of `selfloop.publish`, and it is the same engine, so a Lua plugin and
-- a command hook answer a bus fact the same way.
function M.bus(topic, payload, opts)
  topic = tostring(topic or '')
  if topic == '' or topic:find('%s') then return nil, 'bus_topic_required' end
  opts = opts or {}
  if seam_component() then
    local sealed = seam_bus(topic, payload, opts)
    if sealed then return sealed end
  end
  local merged = blank('bus:' .. topic)
  local events = { 'bus:' .. topic, 'bus:*' }
  for _, event in ipairs(events) do
    local body = envelope(event, payload, opts)
    body.topic = topic
    local view = M.config(opts)
    local entries = {}
    for _, entry in ipairs(view.hooks[event] or {}) do entries[#entries + 1] = entry end
    for _, entry in ipairs(plugin_hooks) do if entry.event == event then entries[#entries + 1] = entry end end
    for _, entry in ipairs(entries) do
      local row = entry.kind == 'lua' and run_lua_hook(entry, body, opts) or run_command_hook(entry, body, opts)
      merged.ran = merged.ran + 1
      merged.outcomes[#merged.outcomes + 1] = record(entry, row)
      interpret(entry, row, merged, body)
    end
  end
  return merged
end

-- ---- mods ---------------------------------------------------------------------------------------

M.statusline_cache = statusline_cache

-- The footer's mod segments: each `mods.statusline` command gets the payload on stdin and its
-- stdout becomes a segment. Cached for `STATUSLINE_TTL_MS`, because the footer is redrawn far more
-- often than a shell command can answer, and a stale segment by three seconds is honest where a
-- blocked footer is not.
function M.statusline(opts)
  opts = opts or {}
  local view = M.config(opts)
  if view.disabled or #view.mods.statusline == 0 then return '' end
  local key = tostring(opts.session_id or '') .. '|' .. tostring(opts.model or '') .. '|' .. tostring(opts.cwd or '')
  local now = math.floor((host.now() or 0) * 1000)
  local hit = statusline_cache[key]
  if hit and now - hit.at < M.STATUSLINE_TTL_MS then return hit.text end
  if seam_component() then
    local text = seam_statusline(view, opts)
    if text then
      statusline_cache[key] = { at = now, text = text }
      return text
    end
  end
  local pieces = {}
  for _, entry in ipairs(view.mods.statusline) do
    local body = envelope('StatusLine', {
      model = opts.model, runs = opts.runs, tokens = opts.tokens, context = opts.context,
      context_percent = opts.context_percent,
    }, opts)
    local row = run_command_hook(entry, body, opts)
    record(entry, row)
    local text = one_line(row.stdout or '')
    if text ~= '' then pieces[#pieces + 1] = clip(text, M.STATUSLINE_MAX) end
    -- A segment that failed or exited non-zero is a broken mod, and the footer says which one instead
    -- of silently showing one fact fewer.
    if row.status ~= 'ok' or (tonumber(row.exit_code) or 0) ~= 0 then
      pieces[#pieces + 1] = '!' .. tostring(entry.name)
    end
  end
  local text = table.concat(pieces, ' \194\183 ')
  statusline_cache[key] = { at = now, text = text }
  return text
end

-- Every custom `/` command, config and plugin, in the order the sources were read.
function M.commands(opts)
  local view = M.config(opts)
  local list = {}
  for _, entry in ipairs(view.mods.commands) do list[#list + 1] = entry end
  local names = {}
  for name in pairs(registered_commands) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do list[#list + 1] = registered_commands[name] end
  return list
end

-- Run one custom command. A command is a mod, not a tool: it gets the payload and answers text for
-- the reader. It runs under the node's normal grants (the command is the operator's own), and it is
-- bounded like a hook.
function M.run_command(name, args, opts)
  opts = opts or {}
  name = tostring(name or '')
  for _, entry in ipairs(M.commands(opts)) do
    if entry.name == name then
      if type(entry.fn) == 'function' then
        local ok, answer = pcall(entry.fn, { args = args or '', session_id = opts.session_id, cwd = opts.cwd })
        if not ok then return { ok = false, error = 'command_raised', detail = tostring(answer) } end
        return { ok = true, output = tostring(answer or ''), name = name, origin = entry.origin }
      end
      local body = envelope('Command', { name = name, args = tostring(args or '') }, opts)
      local row = run_command_hook(entry, body, opts)
      record(entry, row)
      if row.status ~= 'ok' then
        return { ok = false, error = row.error or row.status, detail = row.detail, name = name }
      end
      return { ok = true, output = tostring(row.stdout or ''), name = name, origin = entry.origin }
    end
  end
  return { ok = false, error = 'unknown_hook_command', name = name }
end

-- ---- the read surface (`/hooks`, and the window) -------------------------------------------------

-- What is active and what happened last. Ids, names, event names and outcomes - never a payload, a
-- prompt or a hook's full output: this view is shown in a footer and a panel.
function M.list(opts)
  opts = opts or {}
  local view = M.config(opts)
  local events = {}
  for _, event in ipairs(M.EVENTS) do
    local entries = {}
    for _, entry in ipairs(view.hooks[event.name] or {}) do
      entries[#entries + 1] = { name = entry.name, kind = 'command', matcher = entry.matcher,
        timeout_ms = entry.timeout_ms, origin = entry.origin }
    end
    for _, entry in ipairs(plugin_hooks) do
      if entry.event == event.name then
        entries[#entries + 1] = { name = entry.name, kind = 'lua', matcher = entry.matcher, origin = 'plugin' }
      end
    end
    if #entries > 0 then
      events[#events + 1] = { event = event.name, count = #entries, entries = entries }
    end
  end
  local bus = {}
  for name, list in pairs(view.hooks) do
    if name:sub(1, 4) == 'bus:' then bus[#bus + 1] = { event = name, count = #list } end
  end
  local recent = {}
  for index = #shared.outcomes, 1, -1 do
    if #recent >= 8 then break end
    local row = shared.outcomes[index]
    recent[#recent + 1] = { name = row.name, event = row.event, status = row.status,
      exit_code = row.exit_code, ms = row.ms, detail = row.detail and clip(row.detail, 200) or nil }
  end
  local commands = {}
  for _, entry in ipairs(M.commands(opts)) do
    commands[#commands + 1] = { name = entry.name, description = entry.description, origin = entry.origin }
  end
  return {
    version = M.VERSION,
    disabled = view.disabled,
    claude_compat = view.compat == true,
    sources = view.sources,
    errors = view.errors,
    events = events,
    event_count = #events,
    bus = bus,
    statusline = #view.mods.statusline,
    commands = commands,
    keybindings = view.mods.keybindings,
    recent = recent,
    last = recent[1],
  }
end

-- The text `/hooks` prints: the same facts, one line each, for the REPL.
function M.report(opts)
  local view = M.list(opts)
  local lines = {}
  if view.disabled then
    lines[#lines + 1] = 'hooks: disabled (WASM_AGENT_HOOKS is off)'
    return table.concat(lines, '\n')
  end
  if #view.sources == 0 then lines[#lines + 1] = 'hooks: none configured' end
  for _, source_row in ipairs(view.sources) do
    lines[#lines + 1] = string.format('  source %-14s %s', source_row.name, source_row.path)
  end
  if view.claude_compat then
    lines[#lines + 1] = '  claude_compat: reading ~/.claude/settings.json hooks (opt-in)'
  end
  for _, event in ipairs(view.events) do
    local names = {}
    for _, entry in ipairs(event.entries) do
      names[#names + 1] = entry.name .. (entry.matcher and ('[' .. entry.matcher .. ']') or '')
    end
    lines[#lines + 1] = string.format('  %-18s %s', event.event, table.concat(names, ', '))
  end
  for _, entry in ipairs(view.bus) do
    lines[#lines + 1] = string.format('  %-18s %d hook(s)', entry.event, entry.count)
  end
  if view.statusline > 0 then lines[#lines + 1] = string.format('  footer segments: %d', view.statusline) end
  for _, entry in ipairs(view.commands) do
    lines[#lines + 1] = string.format('  command %-12s %s', entry.name, entry.description)
  end
  for _, entry in ipairs(view.keybindings) do
    lines[#lines + 1] = string.format('  keybinding %-12s %s', entry.key, entry.description)
  end
  for _, problem in ipairs(view.errors) do lines[#lines + 1] = '  ! ' .. problem end
  if view.last then
    lines[#lines + 1] = string.format('  last: %s %s (%s%s)', view.last.event, view.last.name, view.last.status,
      view.last.exit_code and (', exit ' .. tostring(view.last.exit_code)) or '')
  else
    lines[#lines + 1] = '  last: no hook has run'
  end
  return table.concat(lines, '\n')
end

return M
