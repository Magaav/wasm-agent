-- Is the graph component this install ships actually able to answer? A deploy proves it on the
-- candidate binary and the staged component before either replaces what is running
-- (scripts/deploy.sh step 3e), because a core whose `graph` component is missing or was compiled
-- for another engine answers every `host.graph_*` call with `component_unavailable` and the node
-- looks healthy until the agent first navigates its own code.
--
-- Its own home (`WASM_AGENT_HOME`, set by the caller) and its own database: it must not touch the
-- running node's graph. No network, no model, no inference: one index of a two-file fixture and
-- the queries the graph tool itself makes.
local json = dofile('lua/vendor/json.lua')
local paths = dofile('lua/core/paths.lua')
local root = assert(paths.data()) .. '/deploy-graph-check'
local options = json.encode({ root = root, db = root .. '/graph.db' })
local function decode(raw, what)
  local value = json.decode(raw)
  assert(type(value) == 'table' and not value.error, what .. ': ' .. tostring(value and value.error or raw))
  return value
end
assert(host.write_file(root .. '/a.lua', 'local function deploy_probe() end\n'))
assert(host.write_file(root .. '/b.lua', 'local function deploy_caller() deploy_probe() end\n'))
local indexed = decode(host.graph_index(options), 'graph_index')
assert(indexed.ok and (indexed.nodes or 0) > 0, 'graph_index reported no definitions')
local rows = decode(host.graph_query('deploy_probe', options), 'graph_query')
local found = false
for _, row in ipairs(rows) do found = found or row.name == 'deploy_probe' end
assert(found, 'graph_query did not return the definition it just indexed')
local explained = decode(host.graph_explain('deploy_probe', options), 'graph_explain')
local callers = 0
for _, definition in ipairs(explained) do callers = callers + #(definition.incoming or {}) end
assert(callers >= 1, 'graph_explain did not resolve the caller edge')
local status = decode(host.graph_status(options), 'graph_status')
assert(status.ready and status.verified, 'graph_status: the indexed graph does not verify against its tree')
print('graph component ok: ' .. tostring(indexed.nodes) .. ' definition(s), ' .. tostring(#rows) .. ' row(s), 1 caller edge')
