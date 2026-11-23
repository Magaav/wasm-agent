-- CANARY: the code graph (docs/GRAPH.md).
--
-- The graph is OFF by default on every node from G, so on a node that never switched it on this canary
-- answers `off` - the runner's third outcome (lua/core/feature_canary.lua): not a pass, because nothing was
-- proven, and not a failure, because nothing is broken. That is what keeps a dormant feature out of the red
-- list without inventing a success for it.
--
-- Switched on, it exercises what a user does with the graph: index ONE scratch file and read its symbol back
-- through the component. Everything it writes lives in the canary's own scratch directory, which the runner
-- removes whatever the verdict; nothing of the operator's tree is indexed.
local json = dofile('lua/vendor/json.lua')

local M = { mode = 'read' }

function M.run(ctx)
  local answered, entry = pcall(function() return dofile('lua/core/features.lua').resolve('graph') end)
  if not answered or type(entry) ~= 'table' then
    return false, 'resolver_unavailable', 'the feature resolver did not answer: ' .. tostring(entry)
  end
  if entry.enabled ~= true then
    return 'off', 'off (switched off)', string.format(
      'the graph is off by default on this node (%s: %s); switch it on with WA_GRAPH_COMPONENT=1, or "graph": true in the policy features - docs/GRAPH.md',
      tostring(entry.source), tostring(entry.reason))
  end
  if type(host.graph_index) ~= 'function' or type(host.graph_query) ~= 'function' then
    return false, 'capability_missing', 'this host has no graph capabilities, so the switch is on and nothing can answer it'
  end
  local dir = tostring(ctx.scratch or '') .. '/graph-source'
  if not pcall(host.exec, "mkdir -p '" .. dir .. "'", '', 30) then
    return false, 'scratch', 'could not make ' .. dir
  end
  local file = dir .. '/canary.lua'
  if not host.write_file(file, 'local function canary_symbol(value)\n  return value\nend\nreturn canary_symbol\n') then
    return false, 'scratch_write', 'could not write ' .. file
  end
  local options = json.encode({ root = dir, db = tostring(ctx.scratch or '') .. '/graph-store.db' })
  local index_answer = host.graph_index(options)
  local index_ok, index = pcall(json.decode, index_answer or '')
  if not index_ok or type(index) ~= 'table' then return false, 'index_answer', tostring(index_answer) end
  if index.error then return false, 'index', tostring(index.error) .. ' (' .. tostring(index.next or '') .. ')' end
  local query_answer = host.graph_query('canary_symbol', options)
  local query_ok, rows = pcall(json.decode, query_answer or '')
  if not query_ok or type(rows) ~= 'table' then return false, 'query_answer', tostring(query_answer) end
  if rows.error then return false, 'query', tostring(rows.error) end
  if rows[1] == nil then return false, 'query_empty', 'the indexed file did not answer its own symbol' end
  return true, 'readback', 'one scratch file was indexed and its symbol read back through the component'
end

return M

