-- THE GRAPH IS OFF BY DEFAULT ON EVERY NODE FROM G (docs/GRAPH.md, 23/11), and this is what makes that a
-- fact instead of a comment: with no policy file the `graph` tool is not in the catalogue the model reads,
-- a by-name call is refused with `graph_dormant`, a `write` calls nothing into the graph at all, and no
-- store or index appears; and the moment the policy's features section says `"graph": true`, the same
-- process offers the tool again - and loses it again when the switch goes back off.
--
-- The switch is read through the real resolver (lua/core/features.lua -> host.features), against the policy
-- file in THIS test's own home, which is why the file writes one and waits a watch interval.
--
--   WA_SCRIPT=scripts/test-graph-dormant.lua wa ...   prints "graph dormant ok (N checks)"
if not host then error("this test runs under the node (WA_SCRIPT), not plain Lua") end
-- The rule a test that writes state must pass (scripts/lib/test-home-guard.lua): its home sits under the
-- suite's scratch root and carries none of a live node's own markers.
local home_guard = dofile("scripts/lib/test-home-guard.lua")
local test_home = os.getenv("WASM_AGENT_HOME") or ""
local scratch_root = os.getenv("GATE_ROOT") or os.getenv("TMPDIR") or ""
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error("this test writes state: it refuses to run (" .. guard_reason .. ")") end

local json = dofile("lua/vendor/json.lua")
local paths = dofile("lua/core/paths.lua")
local memory = dofile("lua/core/memory.lua")
memory.setup()
local tools = dofile("lua/core/tools.lua")

local checks = 0
local function check(value, what)
  checks = checks + 1
  if not value then error(what, 2) end
end
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    error(string.format("%s\n  got:  %s\n  want: %s", what, tostring(got), tostring(want)), 2)
  end
end

local config = paths.config()
local policy = config .. '/policy.json'
local function write_policy(graph)
  if graph == nil then
    os.remove(policy)
  else
    assert(host.write_file(policy, json.encode({ version = 1, features = { graph = graph } })))
  end
end
-- The resolver re-stats its file about once a second (WA_FEATURES_WATCH_MS), so a write is not visible
-- before the next tick: the same wait scripts/test-features-defaults.lua makes.
local function after_watch() host.exec('sleep 1.3', '', 30) end

local ctx = { user_id = 'master', role = 'master' }
local function names_of(list)
  local names = {}
  for _, item in ipairs(list) do names[(item['function'] or {}).name] = true end
  return names
end
-- A store is any graph database this node could have made: the configured one, its per-root directory, or a
-- quarantine copy. Anything here after a session means something still reached the graph.
local function stores()
  local answer = host.exec("find '" .. config .. "' -maxdepth 4 -name 'graph.db*' 2>/dev/null", '', 30)
  local ok, decoded = pcall(json.decode, answer or '')
  local text = ok and type(decoded) == 'table' and tostring(decoded.stdout or '') or ''
  local found = {}
  for line in text:gmatch('[^\n]+') do found[#found + 1] = line end
  return found
end

------------------------------------------------------------------- 1. nobody said anything: OFF
write_policy(nil)
after_watch()
local graph_lua = dofile('lua/core/graph.lua')

check(not names_of(tools.catalog('master')).graph,
  'no policy file: the graph is not in the catalogue a role may use')
check(not names_of(tools.all('master', ctx, memory)).graph,
  'and not in the list the prompt declares')
check(not graph_lua.available(), 'and the module says it cannot answer')

local refused = tools.dispatch(memory, 'graph', { action = 'stats' }, 'master', ctx)
eq(refused.error, 'graph_dormant', 'a by-name call is refused by name: ' .. json.encode(refused):sub(1, 200))
eq(refused.effect, 'none', 'and says it did nothing')
check(tostring(refused.next or ''):find('WA_GRAPH_COMPONENT', 1, true) ~= nil,
  'the refusal names the switch: ' .. tostring(refused.next))
check(tostring(refused.next or ''):find('docs/GRAPH.md', 1, true) ~= nil, 'and the document it lives in')

-- The write path is where the indexer used to start (graph-one-store-per-root, item 0): a write must not
-- even send a hint now, and no store may exist after one.
local target = config .. '/written-by-the-test.txt'
local written = tools.dispatch(memory, 'write', { path = target, content = 'off by default\n' }, 'master', ctx)
check(written and written.ok == true, 'the write itself still works: ' .. json.encode(written or {}):sub(1, 200))
eq(written.graph_index, nil, 'and it carries no graph hint at all - nothing was called into the graph')
eq(#stores(), 0, 'and a session that wrote a file created no store: ' .. table.concat(stores(), ', '))

------------------------------------------------------------------- 2. the switch turns it on, live
write_policy(true)
after_watch()
check(names_of(tools.catalog('master')).graph == true, 'graph: true in the policy: the tool is in the catalogue again')
check(names_of(tools.all('master', ctx, memory)).graph == true, 'and in the prompt declaration')
check(graph_lua.available(), 'and the module answers again')
local answered = tools.dispatch(memory, 'graph', { action = 'stats' }, 'master', ctx)
check(type(answered) == 'table' and answered.error ~= 'graph_dormant',
  'a by-name call is no longer refused as dormant (it is answered, or it reports the component): '
    .. json.encode(answered or {}):sub(1, 240))

------------------------------------------------------------------- 3. and off again, same process
write_policy(false)
after_watch()
check(not names_of(tools.catalog('master')).graph, 'features.graph: false: the tool is gone from the catalogue again')
eq(tools.dispatch(memory, 'graph', { action = 'stats' }, 'master', ctx).error, 'graph_dormant',
  'and the by-name call is refused by name again')

print(('graph dormant ok (%d checks)'):format(checks))

