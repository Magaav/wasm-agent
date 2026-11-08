-- What the self-loop seam costs, before and after (docs/CORE-SPLIT.md, "Cost").
--
-- The same work on both paths - the native `lua/core/selfloop.lua` and the same module routed through
-- the `selfloop` component - and, for each scenario, one median latency and the crossings the work
-- cost:
--
--   * `host calls`  - Lua -> host capability calls (the native path spends them on `sql_query`/
--                     `sql_exec`; the component path spends them on `host.selfloop`).
--   * `statements`  - SQL statements the work issued. On the native path a statement *is* a host
--                     call; on the component path the statements are the guest's, inside the one host
--                     call, and the host reports the count with every answer (`sql_statements`).
--
-- `WA_BENCH_PATH=native|component` runs one path per process, because RSS is a property of the
-- process: `scripts/bench-selfloop.sh` runs this twice and samples each run's peak.
--
-- No node, no network, no model, no `wa serve`: the runner's own `--db` and a scratch WASM_AGENT_HOME.
local json = dofile('lua/vendor/json.lua')
local which = (host.getenv('WA_BENCH_PATH') or 'both')
local out_path = host.getenv('WA_BENCH_OUT') or ''
local results = {}

local function record(path, scenario, ms, crossings, statements)
  results[#results + 1] = { path = path, scenario = scenario, ms = ms, crossings = crossings, statements = statements }
  local line = string.format('%s\t%s\t%.2f\t%d\t%d', path, scenario, ms, crossings, statements)
  print(line)
end

-- ---- the crossings, counted at the one place every capability call goes through
local counting = false
local counters = { calls = 0, statements = 0 }
local raw_query, raw_exec, raw_selfloop = host.sql_query, host.sql_exec, host.selfloop
host.sql_query = function(...)
  if counting then counters.calls = counters.calls + 1; counters.statements = counters.statements + 1 end
  return raw_query(...)
end
host.sql_exec = function(...)
  if counting then counters.calls = counters.calls + 1; counters.statements = counters.statements + 1 end
  return raw_exec(...)
end
if type(raw_selfloop) == 'function' then
  host.selfloop = function(request)
    if counting then counters.calls = counters.calls + 1 end
    local answer = raw_selfloop(request)
    if counting then
      local decoded = answer
      if type(decoded) == 'string' then
        local ok, value = pcall(json.decode, decoded)
        decoded = ok and value or nil
      end
      if type(decoded) == 'table' then
        counters.statements = counters.statements + (tonumber(decoded.sql_statements) or 0)
      end
    end
    return answer
  end
else
  if which == 'component' then
    print('SKIP the component path: this binary has no host.selfloop capability')
  end
end

local memory = dofile('lua/core/memory.lua')
memory.setup()
local function instance(seam)
  local module = dofile('lua/core/selfloop.lua')
  module.setup()
  -- The seam instance carries the module's test seam: one `host.features` table cannot answer
  -- differently for two instances in one process (docs/FEATURES.md).
  if seam then module.seam_override = function() return true, 'active_component' end end
  return module
end

local T0 = 1700000000
local session_native = memory.start_session('local', 'chat',
  { id = 'bench-native', user_id = 'master', node_id = 'bench', title = 'native' })
local session_seam = memory.start_session('local', 'chat',
  { id = 'bench-seam', user_id = 'master', node_id = 'bench', title = 'seam' })

local function bench(module, ctx, scenario, setup, work)
  setup(module, ctx)
  local function once()
    counters.calls, counters.statements = 0, 0
    counting = true
    work(module, ctx)
    counting = false
  end
  once() -- warm
  local last_calls, last_statements = counters.calls, counters.statements
  local samples = {}
  for index = 1, 21 do
    local started = host.monotonic_ms()
    once()
    samples[index] = host.monotonic_ms() - started
    last_calls, last_statements = counters.calls, counters.statements
  end
  table.sort(samples)
  return samples[math.floor(#samples / 2) + 1], last_calls, last_statements
end

local nothing = function() end
local function one_due_wake(module, ctx)
  module.schedule({ in_seconds = 0, reason = 'bench', now = T0 }, ctx)
end

-- The scenarios, in the order a mission's loop spends its turns.
local scenarios = {
  {
    name = 'read (list+summary)',
    setup = function(module, ctx)
      module.schedule({ in_seconds = 3600, reason = 'a pending wake', now = T0 }, ctx)
      module.notes_write({ text = 'goal: keep going', now = T0 }, ctx)
    end,
    work = function(module, ctx)
      module.list({ now = T0 + 60 }, ctx)
      module.summary(ctx.session_id, { now = T0 + 60 })
    end,
  },
  {
    name = 'notes (write+read)',
    setup = nothing,
    work = function(module, ctx)
      module.notes_write({ text = string.rep('line\n', 40), now = T0 }, ctx)
      module.notes_read({}, ctx)
    end,
  },
  {
    name = 'schedule a wake',
    setup = nothing,
    work = function(module, ctx)
      module.schedule({ in_seconds = 600, reason = 'later', now = T0 }, ctx)
    end,
  },
  {
    name = 'tick (probe unchanged)',
    setup = function(module, ctx)
      module.schedule({ in_seconds = 10, every_seconds = 30, probe = 'return {changed=false}', reason = 'poll', now = T0 }, ctx)
    end,
    work = function(module, ctx)
      module.tick({ now = T0 + 10, dispatch = function() return { accepted = true } end,
        probe = function() return { changed = false } end })
    end,
  },
  {
    name = 'tick (dispatch one wake)',
    setup = function(module, ctx)
      module.schedule({ in_seconds = 0, reason = 'bench', now = T0 }, ctx)
    end,
    work = function(module, ctx)
      module.tick({ now = T0, dispatch = function() return { accepted = true } end })
    end,
  },
  {
    name = 'turn (content+finish)',
    setup = function(module, ctx)
      module.notes_write({ text = 'goal: keep going', now = T0 }, ctx)
      module.schedule({ in_seconds = 0, every_seconds = 30, reason = 'bench', now = T0 }, ctx)
      module.tick({ now = T0, dispatch = function() return { accepted = true } end })
    end,
    work = function(module, ctx)
      local claimed = module.claim_due(ctx.session_id, 'master', { now = T0 + 1, boot = 'b' })
      if not claimed then claimed = { id = 'none', session_id = ctx.session_id, reason = 'bench' } end
      module.turn_content(claimed, { now = T0 + 1 })
      module.finish({ id = claimed.id, every_seconds = 30 }, true, nil, { now = T0 + 2 })
    end,
  },
}

local paths = {}
if which ~= 'component' then paths[#paths + 1] = { name = 'native', module = instance(false), session = session_native } end
if which ~= 'native' and type(raw_selfloop) == 'function' then
  paths[#paths + 1] = { name = 'component', module = instance(true), session = session_seam }
end

for _, path in ipairs(paths) do
  local ctx = { user_id = 'master', role = 'master', session_id = path.session }
  for _, scenario in ipairs(scenarios) do
    local ms, calls, statements = bench(path.module, ctx, scenario.name, scenario.setup, scenario.work)
    record(path.name, scenario.name, ms, calls, statements)
  end
end

if out_path ~= '' then
  local lines = {}
  for _, row in ipairs(results) do
    lines[#lines + 1] = string.format('%s\t%s\t%.2f\t%d\t%d', row.path, row.scenario, row.ms, row.crossings, row.statements)
  end
  host.write_file(out_path, table.concat(lines, '\n') .. '\n')
end
