-- DOES THIS INSTALL ANSWER THROUGH A STAGED COMPONENT, AND DOES A DORMANT FEATURE REFUSE BY NAME?
--
-- The deploy proves both on the candidate binary and the staged component set before either replaces what is
-- running (scripts/deploy.sh step 3e). Two properties, and neither depends on an OPTIONAL feature:
--
--   1. A COMPONENT THAT IS ON BY DEFAULT ANSWERS, through the staged bytes. `memory` is the one this proof
--      calls, and the reason is not taste: its feature is on by default on every node (rust/wa-features
--      FEATURES, `default_enabled: true`), `components.lock` pins it for every install kind (the deploy
--      stages exactly `wa_components_shipped`), and its seam is one capability call with a JSON answer
--      (`host.memory`), so it needs no runtime assets, no model and no network. `codemode` is default-on too,
--      but proving it means proving a JS guest and its assets - a second subject for one question. The call
--      goes through `lua/core/memory.lua`'s own seam, not around it: if the staged component were missing,
--      unpinned or built for another engine, the seam would fall back to the native path and this proof
--      refuses instead of passing.
--   2. A DORMANT FEATURE REFUSES BY NAME. The graph is OFF by default (docs/GRAPH.md, 23/11); the proof does
--      NOT switch it on. It asserts the refusal comes from THIS binary: `graph_dormant`, `effect: none`, and
--      the answer names the switch it would take. That is the state every node ships in, proven on the
--      candidate binary instead of assumed.
--
-- Its own home (`WASM_AGENT_HOME`, set by the caller) and its own database: it must not touch the running
-- node. No env switch, no model, no network.
local json = dofile('lua/vendor/json.lua')
local features = dofile('lua/core/features.lua')

local function decode(raw, what)
  local value = json.decode(raw)
  assert(type(value) == 'table', what .. ': the answer is not JSON: ' .. tostring(raw))
  return value
end

---------------------------------------------------------------- 1. the default-on component answers
local memory = features.resolve('memory')
assert(type(memory) == 'table', 'the feature resolver did not answer for memory')
assert(memory.enabled == true,
  'memory is not enabled on this node (' .. tostring(memory.reason) .. '), so the staged component cannot be proved')
assert(memory.active == 'component',
  'memory is not routed to a component (' .. tostring(memory.reason) .. '): the staged set did not verify, so this proof would prove the native path instead')
assert(type(memory.installed) == 'string' and #memory.installed == 64,
  'the memory component did not verify against its pin: ' .. tostring(memory.installed))

-- Through the seam the node itself uses (lua/core/memory.lua routes every operation through it), so a
-- component that loaded but cannot answer fails here instead of looking healthy.
local store = dofile('lua/core/memory.lua')
store.setup()
local fact = 'the deploy component proof writes exactly this one fact'
-- `M.remember` takes the text and answers the id it stored (`lua/core/memory.lua`); a component that loaded
-- but cannot answer returns nil here, which is the failure this proof is for.
local stored = store.remember(fact, 'global')
assert(type(stored) == 'string' and #stored > 0,
  'the staged memory component did not answer `remember`: ' .. tostring(stored))
local listed = store.memories('global', 5)
assert(type(listed) == 'table', 'the staged memory component did not answer `list`: ' .. tostring(listed))
local found = false
for _, row in ipairs(listed) do
  if tostring(row.content or ''):find(fact, 1, true) then found = true end
end
assert(found, 'the staged memory component answered `list` without the fact it had just stored')

---------------------------------------------------------------- 2. the graph matches its own switch
-- The graph is the ONE feature that is off by default (docs/GRAPH.md, 23/11), and the deploy's proof home is
-- fresh, so in a deploy this is always the dormant branch - the assertion Fable asked for: a dormant feature
-- refuses BY NAME, from THIS binary. The enabled branch is here so the proof does not DEPEND on the graph
-- being dormant: a node whose policy turns it on gets the other honest answer (it answers), and never a
-- refusal read as a broken install.
local graph = features.resolve('graph')
assert(type(graph) == 'table', 'the feature resolver did not answer for the graph')
local verdict
if graph.enabled == false then
  assert(graph.reason == 'default_off',
    'the graph is off for a reason other than its default (' .. tostring(graph.reason) .. '): a policy or an environment value is present in the proof environment')
  local refusal = decode(host.graph_status('{}'), 'graph_status')
  assert(refusal.error == 'graph_dormant',
    'a dormant graph must refuse BY NAME, and it answered: ' .. json.encode(refusal):sub(1, 200))
  assert(refusal.effect == 'none', 'the dormant refusal must report effect: none, got ' .. tostring(refusal.effect))
  assert(tostring(refusal.next or ''):find('WA_GRAPH_COMPONENT', 1, true) ~= nil,
    'the dormant refusal must name the switch that would turn it on: ' .. tostring(refusal.next))
  verdict = 'the dormant graph refused by name (graph_dormant, effect none)'
else
  local status = decode(host.graph_status('{}'), 'graph_status')
  assert(status.error == nil,
    'the graph is enabled on this node and did not answer through the staged component: ' .. json.encode(status):sub(1, 200))
  verdict = 'the enabled graph answered through the staged component'
end

-- THE VERDICT NAMES WHAT IT SAW, both halves, so a deploy log and a reader can tell which answer came back
-- without re-running anything.
print('component proof ok: memory answered through the staged component (' .. memory.installed:sub(1, 12) ..
  '), and ' .. verdict .. ' from this binary')
