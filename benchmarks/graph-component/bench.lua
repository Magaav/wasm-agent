-- Graph latency: run the same calls through whatever host.graph_* this binary has (native
-- wa-graph before stream C, the `graph` component after). Usage:
--   WA_GRAPH_WATCH=0 WA_BENCH_ROOT=<tree> WA_BENCH_DB=<new.db> WA_SCRIPT=benchmarks/graph-component/bench.lua wa --db <tmp.db>
local json = dofile('lua/vendor/json.lua')
local root = assert(os.getenv('WA_BENCH_ROOT'), 'WA_BENCH_ROOT')
local db = assert(os.getenv('WA_BENCH_DB'), 'WA_BENCH_DB')
local opts = json.encode({root = root, db = db})
local function time(label, n, f)
  local samples = {}
  local last
  for i = 1, n do
    local t = host.monotonic_ms(); last = f(); samples[i] = host.monotonic_ms() - t
  end
  table.sort(samples)
  print(string.format('%-14s n=%d median=%.1fms min=%.1fms max=%.1fms', label, n, samples[math.ceil(n / 2)], samples[1], samples[n]))
  return last
end
local index = json.decode(time('index_cold', 1, function() return host.graph_index(opts) end))
assert(index.ok, 'index failed: ' .. tostring(index.error))
local stats = json.decode(host.graph_stats(opts))
print(string.format('tree files=%s nodes=%s edges=%s', tostring(stats.files), tostring(stats.nodes), tostring(stats.edges)))
time('index_noop', 5, function() return host.graph_index(opts) end)
time('query', 10, function() return host.graph_query('append_turn', opts) end)
time('search', 10, function() return host.graph_search('graph component', opts) end)
time('explain', 10, function() return host.graph_explain('locations', opts) end)
time('caps', 5, function() return host.graph_caps(opts) end)
print('bench done')
