-- What code mode costs, before and after (docs/CORE-SPLIT.md, docs/CODEMODE.md).
--
-- The same five scripts on both paths — the native loop in `lua/core/codemode.lua` and the same script
-- routed through the `codemode` component — with, for each run:
--
--   * `ms`            — wall time of one `codemode` tool call, from `host.monotonic_ms` (sub-ms).
--   * `crossings`     — Lua → host capability calls the script cost: on the native path that is
--                       `host.quickjs` (start/admit/deliver/close) plus `host.uuid`/`host.sha256`;
--                       on the component path it is `host.codemode` (open/advance/finish).
--   * `sandbox_calls` — how many times the component crossed into the sandbox for that script (the
--                       component reports it; the native path's number is its `host.quickjs` count).
--
-- `WA_BENCH_PATH=native|component` runs one path per process, because RSS is a property of the
-- process: `scripts/bench-codemode.sh` runs this twice and samples each run's peak.
--
-- **The guest VM is not in these numbers.** `quickjs.wasm`/`prelude.js` are provisioned, not vendored,
-- and a checkout that has not been provisioned cannot run a script on either path. So both paths are
-- driven by the same scripted *protocol peer*: here by patching `host.quickjs` (the native path's only
-- way to reach the guest), on the component path by `WA_CODEMODE_SANDBOX_STUB=1`, which makes the
-- host's `wa:kernel/quickjs` import answer the same five scripts with the same events. The peer is the
-- same work on both sides, so the difference the table shows is the *seam*. `WA_BENCH_VM=real` is not a
-- switch: when the assets are provisioned, drop the patch and the stub and this script measures the
-- real guest (that is a change to this file, and the honest way to make it).
--
-- No node, no network, no model, no `wa serve`: the runner's own `--db` and a scratch WASM_AGENT_HOME.
local json = dofile('lua/vendor/json.lua')
local which = (host.getenv('WA_BENCH_PATH') or 'native')
local out_path = host.getenv('WA_BENCH_OUT') or ''
local runs = tonumber(host.getenv('WA_BENCH_RUNS') or '') or 30
local rows = {}

local function emit(path, scenario, run, ms, crossings, sandbox_calls)
  rows[#rows + 1] = { path = path, scenario = scenario, run = run, ms = ms, crossings = crossings, sandbox_calls = sandbox_calls }
  local line = string.format('%s\t%s\t%d\t%.3f\t%d\t%d', path, scenario, run, ms, crossings, sandbox_calls)
  print(line)
end

-- ---- the protocol peer: the five scripts the host-side stub also knows, and nothing else.
local function calls_of(code)
  if code:find('Promise.all', 1, true) then
    local list = {}
    for i = 1, 10 do list[i] = { name = 'sessions' } end
    return list
  end
  if code:find('tools.sessions', 1, true) then return { { name = 'sessions' } } end
  if code:find('tools.read', 1, true) then return { { name = 'read' } } end
  if code:match('^%s*return 1%s*$') then return {} end
  return nil
end

local function guest_peer()
  local sessions, count = {}, 0
  return function(action, raw)
    if action == 'ready' then
      return json.encode({ ok = true, backend = 'stub', wasm_sha256 = 'stub', prelude_sha256 = 'stub' })
    end
    if action == 'info' then return json.encode({ ok = true, backend = 'stub' }) end
    local args = json.decode(raw)
    if action == 'start' then
      local calls = calls_of(args.code or '')
      if not calls then
        return json.encode({ ok = false, error = 'codemode_sandbox: stub does not know this script', events = {} })
      end
      count = count + 1
      local id = 'stub-' .. count
      local events = {}
      for i, call in ipairs(calls) do
        events[i] = { type = 'call', id = i, target = 'tool', name = call.name, args = '{}' }
      end
      if #calls == 0 then events[#events + 1] = { type = 'done', ok = true, value = '1' } end
      sessions[id] = { calls = calls, delivered = 0 }
      return json.encode({ ok = true, id = id, events = events, backend = 'stub' })
    end
    local session = sessions[args.id]
    if not session then
      return json.encode({ ok = false, error = 'codemode_sandbox: sandbox unavailable', events = {} })
    end
    if action == 'admit' then return json.encode({ ok = true }) end
    if action == 'deliver' then
      session.delivered = session.delivered + 1
      local events = {}
      if session.delivered >= #session.calls then
        events[1] = { type = 'done', ok = true, value = args.payload }
      end
      return json.encode({ ok = true, events = events })
    end
    if action == 'close' then sessions[args.id] = nil; return json.encode({ ok = true }) end
    return json.encode({ ok = false, error = 'codemode_sandbox: unknown action', events = {} })
  end
end

-- ---- the crossings, counted at the one place each path's capability calls go through
local counting = false
local counters = { host = 0, sandbox = 0 }
local peer = guest_peer()
local raw_quickjs, raw_codemode = host.quickjs, host.codemode
host.quickjs = function(action, raw)
  if counting and (action == 'start' or action == 'admit' or action == 'deliver' or action == 'close') then
    counters.host = counters.host + 1
    counters.sandbox = counters.sandbox + 1
  end
  return peer(action, raw)
end
if type(raw_codemode) == 'function' then
  host.codemode = function(request)
    if counting then counters.host = counters.host + 1 end
    local answer = raw_codemode(request)
    if counting and type(answer) == 'string' then
      local ok, decoded = pcall(json.decode, answer)
      if ok and type(decoded) == 'table' then
        counters.sandbox = counters.sandbox + (tonumber(decoded.sandbox_calls) or 0)
      end
    end
    return answer
  end
end

local memory = dofile('lua/core/memory.lua')
memory.setup()
local policy = dofile('lua/core/codemode_policy.lua')
local real_getenv = host.getenv
local function instance(seam)
  host.getenv = function(name)
    if name == 'WA_CODEMODE_COMPONENT' then return seam and '1' or nil end
    return real_getenv(name)
  end
  local module = dofile('lua/core/codemode.lua')
  host.getenv = real_getenv
  return module
end
local codemode = instance(which == 'component')

local session = memory.start_session('local', 'chat', {
  id = 'codemode-bench-' .. which, user_id = 'master', node_id = 'bench', title = 'code mode bench' })
local ctx = { session_id = session, user_id = 'master' }
local function schema(name, description)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = { text = { type = 'string' }, limit = { type = 'integer' } } } } }
end
local catalog = { schema('sessions', 'List sessions'), schema('read', 'Read a file') }
local function current_catalog() return catalog end
local function execution() return { status = 'not_blocked', scope = 'workspace_policy_only', workspace_binding = 'not_applicable' } end
local big = string.rep('x', 200 * 1024)
local function dispatch(name)
  if name == 'read' then return { ok = true, text = big } end
  return { ok = true, name = name }
end

local scenarios = {
  { label = 'a-trivial', code = 'return 1' },
  { label = 'b-one-call', code = 'const r = await tools.sessions({limit:1}); return r;' },
  { label = 'c-ten-parallel', code = 'const rs = await Promise.all([1,2,3,4,5,6,7,8,9,10].map(i=>tools.sessions({limit:i}))); return rs.length;' },
  { label = 'd-200kb', code = 'const big = await tools.read({path:"bench.txt"}); return big.text;' },
}

local first = true
for _, scenario in ipairs(scenarios) do
  for run = 1, runs do
    policy.pin(memory, 'master', ctx)
    counters.host, counters.sandbox = 0, 0
    counting = true
    local started = host.monotonic_ms()
    local result = codemode.run(memory, { code = scenario.code }, 'master', ctx, catalog, current_catalog, dispatch, execution)
    local elapsed = host.monotonic_ms() - started
    counting = false
    if not (type(result) == 'table' and result.ok == true) then
      print('FAIL ' .. scenario.label .. ' did not run: ' .. tostring(result and result.error or result))
      if out_path ~= '' then
        local file = io.open(out_path, 'w')
        if file then file:write(''); file:close() end
      end
      return
    end
    -- The first run of the first scenario in this process pays the cold start (component compile,
    -- instance, first sandbox); it is reported as its own row so the medians are steady-state.
    if first and run == 1 then
      emit(which, 'e-cold', 1, elapsed, counters.host, counters.sandbox)
      first = false
    end
    emit(which, scenario.label, run, elapsed, counters.host, counters.sandbox)
  end
end

if out_path ~= '' then
  local file = assert(io.open(out_path, 'w'))
  for _, row in ipairs(rows) do
    file:write(string.format('%s\t%s\t%d\t%.3f\t%d\t%d\n', row.path, row.scenario, row.run, row.ms, row.crossings, row.sandbox_calls))
  end
  file:close()
end
print(string.format('codemode bench path=%s runs=%d scenarios=%d done', which, runs, #scenarios))
