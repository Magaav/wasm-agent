-- The hooks seam's cost, measured on one path (docs/CORE-SPLIT.md, "Cost"): the latency of one event
-- fire with 0, 1 and 10 hooks, how many host crossings that costs, and the per-hook part of it.
--
-- `scripts/bench-hooks.sh` runs this twice - once native, once through the component - in one process
-- per path, because peak RSS is a property of the process. Everything here is hermetic: the hook
-- command is a `sh` that prints an empty answer, the config is written into this run's scratch home,
-- and no node, socket or model is involved.
--
-- What it does not measure: the component's hosting under a real node (every call here instantiates
-- its own), and the cost of a *real* hook - on this host a process spawn is milliseconds and the seam
-- is tenths of one, so the end-to-end number is the spawn's. That is why the run also reports the
-- decision alone ("decide", the row handed straight in): that is the seam's own cost.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')

local path = tostring(host.getenv('WA_BENCH_PATH') or 'native')
local out = tostring(host.getenv('WA_BENCH_OUT') or '')
local iterations = tonumber(host.getenv('WA_BENCH_ITERATIONS') or '') or 21
local config = paths.config()

host.exec('mkdir -p ' .. string.format('%q', config), '', 30)
local function write(name, text)
  assert(host.write_file(config .. '/' .. name, text), 'write ' .. name)
end
local stub = config .. '/stub.sh'
write('stub.sh', "#!/bin/sh\nprintf '{}'\n")
host.exec("chmod +x '" .. stub .. "'", '', 30)

local hooks = dofile('lua/core/hooks.lua')

-- Crossings: every `host.hooks` call is one crossing into the runtime. The native path makes none -
-- the engine is the interpreter - which is the number the table in docs/CORE-SPLIT.md compares.
local crossings = 0
local real_hooks = host.hooks
if type(real_hooks) == 'function' then
  host.hooks = function(...) crossings = crossings + 1; return real_hooks(...) end
end

local function percentile(sorted, fraction)
  if #sorted == 0 then return 0 end
  local index = math.max(1, math.ceil(#sorted * fraction))
  return sorted[math.min(index, #sorted)]
end

local function measure(label, fn)
  local samples = {}
  -- One warm-up call, so a first-call cost (compile, instantiate, file cache) is not the median.
  pcall(fn)
  crossings = 0
  local started = host.monotonic_ms()
  for _ = 1, iterations do
    local before = host.monotonic_ms()
    pcall(fn)
    samples[#samples + 1] = host.monotonic_ms() - before
  end
  local elapsed = host.monotonic_ms() - started
  table.sort(samples)
  local p50, p95 = percentile(samples, 0.5), percentile(samples, 0.95)
  local per_fire = crossings / math.max(1, iterations)
  print(string.format('%s\t%s\tp50 %.2f ms\tp95 %.2f ms\t%.2f crossings/fire\t%d runs',
    path, label, p50, p95, per_fire, iterations))
  local row = { label = label, p50 = p50, p95 = p95, crossings = per_fire, total = elapsed,
    runs = iterations }
  crossings = 0
  return row
end

local function config_with(count)
  local entries = {}
  for index = 1, count do
    entries[#entries + 1] = { name = 'h' .. index, matcher = 'bash', command = "sh '" .. stub .. "'" }
  end
  write('hooks.json', json.encode({ hooks = { PreToolUse = entries } }))
  hooks.reset()
end

local results = {}
for _, count in ipairs({ 0, 1, 10 }) do
  config_with(count)
  local payload = { tool_name = 'bash', tool_input = { command = 'true' } }
  results[#results + 1] = measure('fire with ' .. count .. ' hook(s)', function()
    return hooks.fire('PreToolUse', payload, { session_id = 'bench', tool = 'bash' })
  end)
  -- The decision alone: one row handed straight to the engine, no process, no config read. This is
  -- the part the seam actually adds to a hook that runs.
  local verdict = hooks.fire('PreToolUse', payload, { session_id = 'bench', tool = 'bash' })
  local entry = hooks.entries('PreToolUse', { session_id = 'bench', tool = 'bash' })[1] or {
    name = 'synthetic', event = 'PreToolUse', kind = 'command', command = 'true', timeout_ms = 5000,
    on_ask = 'deny', origin = 'node', order = 1 }
  local row = { name = entry.name, event = 'PreToolUse', kind = entry.kind, origin = entry.origin,
    status = 'ok', timeout_ms = entry.timeout_ms, at = 0, exit_code = 0, stdout = '{}', stderr = '' }
  if path ~= 'native' and type(real_hooks) == 'function' then
    results[#results + 1] = measure('decide one row (' .. count .. ' configured)', function()
      return real_hooks(json.encode({ op = 'decide', event = 'PreToolUse',
        payload = json.encode({ hook_event_name = 'PreToolUse', tool_name = 'bash' }),
        entry = entry, row = row }))
    end)
  end
  if verdict and verdict.outcomes and #verdict.outcomes > 0 then
    -- The rows are the node's, so this only proves the loop ran count times.
    assert(verdict.ran == count, 'expected ' .. count .. ' hooks to run, got ' .. tostring(verdict.ran))
  end
end

if out ~= '' then
  local lines = {}
  for _, row in ipairs(results) do
    lines[#lines + 1] = table.concat({ path, row.label, string.format('%.2f', row.p50),
      string.format('%.2f', row.p95), string.format('%.2f', row.crossings), tostring(row.runs) }, '\t')
  end
  assert(host.write_file(out, table.concat(lines, '\n') .. '\n'), 'write ' .. out)
end
print(string.format('%s done: rss sampled by the wrapper', path))
