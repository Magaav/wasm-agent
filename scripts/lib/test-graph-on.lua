-- A row that exercises the graph switches it ON in its own home (docs/GRAPH.md, 23/11).
--
-- The graph is OFF by default on every node from G, so a row that drives it must say so explicitly - that is
-- the point of a default: the rows that need a feature ask for it, and the row whose whole job is to prove
-- the default (scripts/test-graph-dormant.lua) stays the one place where nothing is asked for.
--
-- WHY NOT A RUNNER VARIABLE. `WA_GRAPH_COMPONENT=1` exported by the runner would turn the graph on for every
-- row in the run, including the one that proves it is off; and the runner cannot know which rows use the
-- graph without keeping a second list of them. The switch belongs beside the test that needs it.
--
-- WHAT IT WRITES. The node's own policy file (`<state>/policy.json`), `features.graph: true`, merged into
-- whatever that file already says. It then ASKS the resolver until the answer is on, because the resolver
-- re-reads its file about once a second: a row that continued on a stale answer would be the kind of silent
-- wrong setup these tests exist to refuse. It refuses to touch anything when the home is not a scratch one
-- (scripts/lib/test-home-guard.lua): a test never writes a live node's policy.
local M = {}

local function encode(value) return dofile('lua/vendor/json.lua').encode(value) end
local function decode(text) return dofile('lua/vendor/json.lua').decode(text) end

-- The reason this call may not run here, or nil. Shared with every other test that writes state.
function M.refusal(home, scratch)
  local guard = dofile('scripts/lib/test-home-guard.lua')
  return guard.reason({ home = home or os.getenv('WASM_AGENT_HOME') or '', scratch = scratch or os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
end

-- Switch the graph on for this row and prove the switch took. Returns true, or false plus the reason -
-- callers assert on it, so a row can never go green on a graph that was never actually enabled.
function M.enable(opts)
  opts = opts or {}
  local why = M.refusal(opts.home, opts.scratch)
  if why then return false, 'this row writes a policy file and refuses to: ' .. tostring(why) end
  if type(host.features) ~= 'function' then
    return false, 'this binary has no host.features capability, so nothing can switch the graph on'
  end
  local paths = dofile('lua/core/paths.lua')
  local policy = paths.config() .. '/policy.json'
  local document = { version = 1, features = {} }
  local existing = host.read_file and host.read_file(policy)
  if type(existing) == 'string' and existing ~= '' then
    local ok, decoded = pcall(decode, existing)
    if not ok or type(decoded) ~= 'table' then
      return false, 'the policy file this row found is not a JSON object: ' .. policy
    end
    document = decoded
    if type(document.features) ~= 'table' then document.features = {} end
  end
  document.features.graph = true
  local wrote = host.write_file and host.write_file(policy, encode(document) .. '\n')
  if not wrote then return false, 'the policy file could not be written: ' .. policy end
  -- Ask the resolver, not the file: it answers from what the node would actually route on.
  local features = dofile('lua/core/features.lua')
  local deadline = (tonumber(host.now()) or os.time()) + 5
  while (tonumber(host.now()) or os.time()) <= deadline do
    local entry = features.resolve('graph')
    if type(entry) == 'table' and entry.enabled == true then return true end
    host.exec('sleep 0.2', '', 5)
  end
  return false, 'features.graph: true was written to ' .. policy .. ' and the resolver still answers off'
end

return M

