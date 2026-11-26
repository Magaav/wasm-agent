-- The operator's own door to the service components (docs/SERVICE-COMPONENTS.md).
--
-- WHY THIS EXISTS. `wa services` was "unknown command" while the only way to stop, start, enable or
-- disable a service component was the `services` tool - which needs a turn, and therefore a model. A
-- node declared model-less (`docs/MODEL-LESS.md`) can run no turn at all, so the one thing an operator
-- most needs after a bad component start (stop it) was unreachable without editing the registry store.
-- The decision logic is the registry's (`lua/core/services.lua`): this file is the dispatch and the
-- printing, and every verb goes through `services.control` with the same master gate and the same
-- audit trail the tool path uses. Nothing here runs the host directly, so the two doors can never
-- disagree about what "enable" means.
--
-- The verbs are the operator's: list, status, start, stop, enable, disable. `start`/`stop` operate the
-- instance; `enable`/`disable` decide whether it starts with the node (enable starts it now, disable
-- stops it now). `--json` prints the registry's own answer instead of the one-line form.
local json = dofile('lua/vendor/json.lua')
local services = dofile('lua/core/services.lua')

local M = {}

local VERBS = {
  list = 'every service component this node knows, enabled and live',
  status = 'one service: its stored definition and what the host says it is doing',
  start = 'run it now, without changing whether it starts at boot',
  stop = 'stop the running instance (its claimed queue jobs go back to the queue)',
  enable = 'start it now and at every boot',
  disable = 'stop it now and do not start it at boot',
}

local function usage(stream)
  stream = stream or 'out'
  local function say(line) if stream == 'err' then io.stderr:write(line .. '\n') else print(line) end end
  say('wa services <verb> [name] [--json]')
  for _, verb in ipairs({ 'list', 'status', 'start', 'stop', 'enable', 'disable' }) do
    say(string.format('  %-8s %s', verb, VERBS[verb]))
  end
  say('')
  say('  The registry is this node\'s own (lua/core/services.lua); a master on another node asks for the')
  say('  same verbs through the `services` peer capability, and gets the same answers.')
end

local function fail(code, message)
  io.stderr:write(string.format('services: %s\n', message))
  return code
end

local function text_list(answer)
  local rows = answer.services or {}
  if #rows == 0 then
    print('no service components are stored on this node')
    return 0
  end
  print(string.format('%-24s %-8s %-11s %s', 'name', 'enabled', 'state', 'sha256'))
  for _, row in ipairs(rows) do
    local live = row.live or {}
    print(string.format('%-24s %-8s %-11s %s', row.name, row.enabled and 'yes' or 'no',
      tostring(live.state or 'not_running'), tostring(live.sha256 or ''):sub(1, 12)))
  end
  return 0
end

local function text_status(answer)
  print(string.format('name      %s', tostring(answer.name or '?')))
  print(string.format('enabled   %s', answer.enabled and 'yes' or 'no'))
  local live = answer.live or {}
  print(string.format('state     %s', tostring(live.state or 'not_running')))
  if live.instance then print(string.format('instance  %s', tostring(live.instance))) end
  if live.sha256 then print(string.format('sha256    %s', tostring(live.sha256))) end
  if live.restarts then print(string.format('restarts  %s', tostring(live.restarts))) end
  if live.last_exit and live.last_exit ~= '' then print(string.format('last exit %s', tostring(live.last_exit))) end
  if live.waiting_for and #live.waiting_for > 0 then
    print(string.format('waiting   %s (%s)', table.concat(live.waiting_for, ', '), tostring(live.waiting_reason or '')))
  end
  return 0
end

-- One named verb's answer, printed. A refusal is a refusal: its own error is printed and the exit code
-- is non-zero, so a script that stops a service cannot mistake "it refused" for "it stopped".
local function named(verb, name, want_json)
  if type(name) ~= 'string' or name == '' then
    return fail(2, verb .. ' needs a service name (wa services list)')
  end
  local args = { action = verb, name = name }
  if verb == 'enable' or verb == 'disable' then
    -- The registry's compare-and-set exists for concurrent *definitions*; an operator's one-shot verb
    -- reads the current revision and changes exactly that one. A change that raced another is
    -- reported by the store, not hidden.
    args.expected_revision = services.inventory().revision
  end
  local answer = services.control(args, { role = 'master', user_id = 'cli', session_id = nil })
  if type(answer) ~= 'table' then return fail(1, verb .. ': the registry answered nothing') end
  if want_json then print(json.encode(answer)) end
  if answer.ok == false or answer.error then
    return fail(1, string.format('%s %s: %s', verb, name, tostring(answer.error or answer.status)))
  end
  if verb == 'status' then
    return want_json and 0 or text_status(answer)
  end
  -- start/stop/enable/disable: say what actually happened, from the host's own answer.
  if want_json then return 0 end
  local function show(value)
    if type(value) == 'string' then return value end
    if type(value) == 'table' then return json.encode(value) end
    return nil
  end
  print(string.format('%s %s: %s', verb, name, answer.ok == true and 'ok' or tostring(answer.error)))
  local state = show(answer.state) or show(answer.start and answer.start.state)
  if state then print('  state ' .. state) end
  if verb == 'stop' then
    print(string.format('  was running %s, queue jobs handed back %s',
      tostring(answer.was_running), tostring(answer.queue_handed_over or 0)))
  end
  return 0
end

--- `wa services ...`: dispatch and print. Returns the process exit code.
-- THE CLI IS NOT THE NODE (26/11, Fable item 2a).
--
-- `services.control` asks THIS process kernel registry (rust/wa-kernel-runtime/src/services.rs `status`):
-- that registry is memory plus an OS lock, so a name this process was never told about answers
-- `not_running`. When ANOTHER process serves this node, that answer is the CLI own emptiness - measured
-- 26/11: `wa services status wa-whatsapp` said not_running while the node said running, and the operator
-- was told a component was down.
--
-- So before any live state is printed, the CLI asks who serves this node: an install serve.pid naming a
-- LIVE pid other than this one. Then it says so plainly - a status names the pid, and a verb that would
-- CHANGE the node is refused, because starting a second copy beside the supervisor is worse than saying
-- "ask it". `list` is not gated: its rows are the stored definitions and say what they are.
function M.serve_pid_paths(options)
  if type(options) == 'table' and type(options.paths) == 'table' then return options.paths end
  local env = type(host.getenv) == 'function' and host.getenv or function() return '' end
  local paths = {}
  local explicit = tostring(env('WA_INSTALL_DIR') or '')
  if explicit ~= '' then paths[#paths + 1] = explicit .. '/serve.pid' end
  local home = tostring(env('HOME') or '')
  if home ~= '' then
    paths[#paths + 1] = home .. '/AppData/Local/wasm-agent/serve.pid'
    paths[#paths + 1] = home .. '/.local/share/wasm-agent/serve.pid'
  end
  return paths
end

-- <options> -> { pid, path } | nil. options.read_file/options.pid/options.paths are the row seams.
function M.supervisor(options)
  options = type(options) == 'table' and options or {}
  local read_file = options.read_file or host.read_file
  local mine = tonumber(options.pid or 0) or 0
  if mine == 0 then
    local source = type(host.process_identity) == 'function' and host.process_identity or host.runtime_info
    local ok, raw = pcall(source or function() return '{}' end)
    local info = ok and type(raw) == 'string' and (json.decode(raw) or {}) or {}
    mine = tonumber(info.process_id) or 0
  end
  for _, path in ipairs(M.serve_pid_paths(options)) do
    local ok, text = pcall(read_file, path)
    if ok and type(text) == 'string' then
      local pid = tonumber(text:match('%d+'))
      if pid and pid > 0 and pid ~= mine then
        -- A pid file outlives its process (deploy.sh says so); liveness decides, never the file.
        local alive = options.alive and options.alive(pid) or pcall(read_file, '/proc/' .. tostring(pid) .. '/cmdline')
        if alive then return { pid = pid, path = path } end
      end
    end
  end
  return nil
end

-- <verb>, <options> -> nil, or { pid, path, mutating, line } when another process serves this node.
function M.served(verb, options)
  if tostring(verb) == 'list' then return nil end
  local sup = M.supervisor(options)
  if not sup then return nil end
  sup.mutating = tostring(verb) ~= 'status'
  sup.line = string.format('served by pid %d (%s); ask it - this CLI is not the node supervisor, so it cannot report or change the node components', sup.pid, sup.path)
  return sup
end
function M.run(argv, options)
  argv = type(argv) == 'table' and argv or {}
  local verb = tostring(argv[1] or '')
  local want_json = false
  local rest = {}
  for index = 2, #argv do
    if argv[index] == '--json' then want_json = true else rest[#rest + 1] = argv[index] end
  end
  if verb == '' or verb == 'help' or verb == '--help' or verb == '-h' then
    usage('out')
    return verb == '' and 2 or 0
  end
  if VERBS[verb] == nil then
    io.stderr:write(string.format('services: unknown verb %q\n', verb))
    usage('err')
    return 2
  end
  -- WHO SERVES THIS NODE, asked before any live state (see M.served).
  local served = M.served(verb, options)
  if served then
    if want_json then
      print(json.encode({ ok = false, error = 'cli_is_not_the_node', state = 'served_by', served_by_pid = served.pid,
        serve_pid = served.path, verb = verb, name = rest[1], detail = served.line }))
    else
      io.stderr:write('services: ' .. served.line .. '\n')
    end
    return served.mutating and 1 or 0
  end
  if verb == 'list' then
    local answer = services.control({ action = 'list' }, { role = 'master', user_id = 'cli' })
    if want_json then print(json.encode(answer)) else text_list(answer) end
    return 0
  end
  if verb == 'status' then
    local name = rest[1]
    if type(name) ~= 'string' or name == '' then return fail(2, 'status needs a service name (wa services list)') end
    local answer = services.control({ action = 'status', name = name }, { role = 'master', user_id = 'cli' })
    if type(answer) ~= 'table' then return fail(1, 'status: the host answered nothing') end
    if want_json then print(json.encode(answer)) end
    if answer.error then return fail(1, string.format('status %s: %s', name, tostring(answer.error))) end
    -- `services.control`'s status is the host's live answer; the stored half comes from the inventory.
    local stored
    for _, row in ipairs(services.inventory().services or {}) do
      if row.name == name then stored = row end
    end
    -- A name nobody stored and nobody runs is a typo, not a service: say so instead of printing
    -- `not_running` for it (the host answers "not_running" for any name it was not told about).
    if not stored and (answer.instance == nil or answer.instance == '') and
        (answer.state == nil or answer.state == 'not_running') then
      return fail(1, string.format('status %s: unknown service on this node (wa services list)', name))
    end
    answer.enabled = stored and stored.enabled or false
    answer.live = answer
    if not want_json then text_status(answer) end
    return 0
  end
  return named(verb, rest[1], want_json)
end

return M
