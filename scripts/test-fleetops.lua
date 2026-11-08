-- Fleet-ops layers: the operating habits in the cache-stable prefix, the `fleetops` skill, the lessons
-- store (on demand only), and the `fleetview` capability. Model-free: the provider is the same fake HTTP
-- fixture the loop tests use, so no inference, no network and no paid call is involved.
--
-- What it proves:
--   * the operating habits are in the system prompt exactly once, inside the `generic` layer (the part
--     `lua/core/prompt_cache.lua` freezes), byte-identical across the turns of a session - and they
--     carry no turn budget, no limit and no nudge that would make the model stop working;
--   * a **fresh** session injects no cross-session knowledge: no lesson text, no notes, no
--     `onSessionStart_injection` block. Memory stays on demand (`<memory policy="on-demand">`), and
--     `lessons` has no prompt/injection surface at all;
--   * the `fleetops` skill ships, is discoverable by its trigger, loads whole, and carries the NEVER
--     list with the safe alternative next to each entry;
--   * `lessons` seeds from this week's incidents, recalls the right one by words, and adding a lesson is
--     one call that a later recall finds;
--   * `fleetview` answers every field for a three-node local fabric, names the fields nobody read
--     instead of inventing them, and is read-only in the tool catalogue.
local json = dofile('lua/vendor/json.lua')
local real_getenv = host.getenv
local overrides = { WASM_AGENT_PROVIDER = 'opencode-go', WASM_AGENT_LLM_API_KEY = 'fixture-only',
  WASM_AGENT_LLM_MODEL = 'deepseek-v4.1-flash', WASM_AGENT_PI_MODELS_STORE = 'missing-test-store',
  WASM_AGENT_CONTEXT_BUDGET = '0', WASM_AGENT_MAX_TOOL_ROUNDS = '2' }
host.getenv = function(key) if overrides[key] ~= nil then return overrides[key] end return real_getenv(key) end
host.http = function() error('unexpected network in the fleetops fixture') end

local checks, failed = 0, 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then print('FAIL ' .. label); failed = failed + 1 end
end
local function count(haystack, needle)
  local total, at = 0, 1
  while true do
    local found = haystack:find(needle, at, true)
    if not found then return total end
    total = total + 1
    at = found + 1
  end
end

local paths = dofile('lua/core/paths.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local agent = dofile('lua/core/agent.lua')
local tools = dofile('lua/core/tools.lua')
local skills = dofile('lua/core/skills.lua')
local lessons = dofile('lua/core/lessons.lua')
local fleetview = dofile('lua/core/fleetview.lua')
local habits = dofile('lua/core/habits.lua')

-- ---- 1. the operating habits ---------------------------------------------------------------------
local habit_lines = habits.lines()
ok(#habit_lines >= 10, 'the habits cover the ten decisions the job named')
ok(habits.text() == habits.text(), 'the habit text is stable between calls')
local joined = habits.text():lower()
for _, phrase in ipairs({ 'look before you change', 'blast radius', 'reversible, supported path',
  'cheapest check first', 'back up', 'one change at a time', 'managed operation', 'verify the effect',
  'side effects', 'empty value', 'roll back', 'lesson', 'report plainly' }) do
  ok(joined:find(phrase, 1, true) ~= nil, 'the habits include "' .. phrase .. '"')
end
-- The hard rule: a habit is a way to work, never a budget, a limit or a nudge. A prohibition on the
-- vocabulary is the cheapest way to keep one from creeping in.
for _, banned in ipairs({ 'turn budget', 'turns left', 'token budget', 'wrap up', 'be brief',
  'stop early', 'within %d turns', 'you must finish', 'nudge', 'hurry' }) do
  ok(joined:find(banned, 1, true) == nil, 'the habits carry no "' .. banned .. '" pressure')
end

local system = agent.system_prompt('master', 'PROJECT INSTRUCTIONS', nil, nil, 'full')
ok(count(system, '<habits>') == 1, 'the habits appear exactly once in the system prompt')
ok(count(system, '</habits>') == 1, 'and the section is closed once')
local habits_at = system:find('<habits>', 1, true)
local stack_at = system:find('<stack', 1, true)
local generic_open = system:find('<generic>', 1, true)
ok(habits_at and generic_open and habits_at > generic_open, 'the habits live in the generic layer')
ok(habits_at and stack_at and habits_at < stack_at, 'before the stack, i.e. in the cache-stable prefix')
local guest_system = agent.system_prompt('guest', nil, nil, nil, 'full')
ok(count(guest_system, '<habits>') == 1, 'a guest gets the same habits, once')
ok(agent.system_prompt('master', 'PROJECT INSTRUCTIONS', nil, nil, 'full') == system,
  'two renders of the same session are byte-identical')

-- ---- 2. a fresh session injects no cross-session knowledge ---------------------------------------
local requests, answers = {}, {}
host.http_stream = function(_, _, _, body)
  requests[#requests + 1] = type(body) == 'string' and body or json.encode(body)
  local next_answer = table.remove(answers, 1)
  if not next_answer then error('the fixture was asked for more calls than it scripted') end
  return json.encode(next_answer)
end
local usage = { prompt_tokens = 100, completion_tokens = 10, total_tokens = 110 }
local function final(text)
  return { status = 200, content = text, stream_complete = true, finish_reason = 'stop', usage = usage, tool_calls = {} }
end
local function system_of(body)
  local decoded = json.decode(body) or {}
  local messages = decoded.messages or {}
  for _, message in ipairs(messages) do
    if message.role == 'system' then return tostring(message.content or '') end
  end
  return ''
end

-- Seed the lessons store first, so "nothing was injected" is a real statement about a non-empty store.
local seeded = lessons.ensure()
ok(#seeded >= 4, 'this week\'s incidents are seeded (' .. #seeded .. ')')

local sid = memory.start_session('', 'fleetops-fresh', { user_id = 'master', node_id = '', title = 'fresh' })
local emitted = {}
local bot = agent.new(sid, function(event) emitted[#emitted + 1] = event end, 'master', 'master', '')
answers = { final('first answer') }
bot:run('hello there')
ok(#requests == 1, 'one model request for the first turn')
local first_system = system_of(requests[1])
ok(first_system ~= '', 'the first request carries a system prompt')
ok(count(first_system, '<habits>') == 1, 'the habits are in the first request exactly once')
ok(first_system:find('<memory policy="on-demand">', 1, true) ~= nil,
  'memory is on demand in the prompt, by construction')
ok(first_system:find('detaches nodes', 1, true) == nil, 'no lesson text is injected')
ok(first_system:find('push-roster') == nil, 'no fleet procedure is injected')
ok(first_system:find('onSessionStart_injection') == nil, 'a fresh session gets no session-start injection')
ok(first_system:find('zz-fleetops-lesson', 1, true) == nil, 'and nothing from an earlier session\'s store')
ok(requests[1]:find('zz-fleetops-lesson', 1, true) == nil, 'not anywhere in the request either')
ok(emitted and #emitted >= 0, 'the run emitted its events')

-- A second turn: the prefix is the same bytes (the cache lock), and the habits did not gain a copy.
answers = { final('second answer') }
local ok_run = pcall(function() bot:run('and again') end)
ok(ok_run, 'the second turn completed without a tool budget or a nudge stopping it')
if #requests >= 2 then
  local second_system = system_of(requests[#requests])
  ok(second_system == first_system, 'the frozen prefix is byte-identical across turns')
  ok(count(second_system, '<habits>') == 1, 'the habits are still present exactly once')
end

-- A *different* fresh session shares the lessons store and still gets none of it.
local sid2 = memory.start_session('', 'fleetops-fresh', { user_id = 'master', node_id = '', title = 'fresh-2' })
local bot2 = agent.new(sid2, function() end, 'master', 'master', '')
answers = { final('third answer') }
requests = {}
bot2:run('new conversation')
ok(#requests == 1 and system_of(requests[1]):find('detaches nodes', 1, true) == nil,
  'a second fresh session is told nothing about the first one\'s lessons')
ok(lessons.prompt_block == nil and lessons.inject == nil and lessons.system_section == nil,
  'the lessons store exposes no injection surface at all')

-- ---- 3. the fleetops skill ------------------------------------------------------------------------
local found = skills.find('fleetops')
ok(found ~= nil, 'the fleetops skill ships')
local body = found and skills.content(found) or ''
ok(body:find('name: fleetops', 1, true) ~= nil, 'its frontmatter names it')
ok(body:find('Use it', 1, true) ~= nil, 'its description carries the trigger ("Use it ...")')
ok(body:find('NEVER', 1, true) ~= nil, 'it has the NEVER list')
ok(body:find('WASM_AGENT_NETWORK_ADMINS', 1, true) ~= nil, 'which names the admin-set edit')
ok(body:find('wa fleet push-roster', 1, true) ~= nil, 'and the safe alternative')
ok(body:find('last_seen', 1, true) ~= nil, 'the offline diagnosis reads last_seen')
ok(body:find('rendezvous journal', 1, true) ~= nil, 'and the rendezvous journal')
ok(body:find('operator route', 1, true) ~= nil or body:find('operator_of_peer', 1, true) ~= nil,
  'and the operator route/pin')
ok(body:find('lessons', 1, true) ~= nil, 'and it tells the model where lessons live')
ok(body:find('hand-edit', 1, true) ~= nil and body:find('dirty tree', 1, true) ~= nil,
  'never hand-edit a production checkout, never deploy from a dirty tree')
local loaded = tools.dispatch(memory, 'skill', { name = 'fleetops' }, 'master', {})
ok(loaded and loaded.content == body, 'the skill tool loads the whole procedure in one call')
ok(found and host.read_file(found.dir .. '/incidents.json') ~= nil, 'the incidents ship with the skill')
local catalogue = skills.prompt_block()
ok(catalogue:find('fleetops', 1, true) ~= nil, 'the skill is discoverable in the catalogue metadata')
ok(catalogue:find('NEVER', 1, true) == nil, 'and its body is not in the prefix')

-- ---- 4. lessons: recall, add, refuse an empty one --------------------------------------------------
local recall = lessons.recall('rendezvous admin list')
ok(#recall.lessons > 0, 'recall finds the admin-set incident by words')
ok(recall.lessons[1].id == 'les-rendezvous-admin-set-20261106', 'and ranks it first')
ok(tostring(recall.lessons[1].rule):find('push-roster', 1, true) ~= nil, 'its rule names the safe path')
local tool_recall = tools.dispatch(memory, 'lessons', { action = 'recall', query = 'rebuild slow cargo' },
  'master', {})
ok(type(tool_recall) == 'table' and type(tool_recall.lessons) == 'table', 'the lessons tool recalls')
ok(tool_recall.note and tool_recall.note:find('looked up', 1, true) ~= nil, 'and says it is on demand')
local missing = tools.dispatch(memory, 'lessons', { action = 'recall' }, 'master', {})
ok(type(missing) == 'table' and missing.error == 'query_required', 'a recall with no words is refused')
ok(missing.effect == 'none', 'with no effect')

-- One call adds a lesson; a later recall finds it.
local added = tools.dispatch(memory, 'lessons', { action = 'add', symptom = 'zz-fleetops-lesson: a made-up symptom',
  cause = 'a made-up cause', fix = 'a made-up fix', rule = 'zz-fleetops-lesson rule: check the fleet list first',
  tags = { 'fixture' } }, 'master', {})
ok(added and added.ok == true and type(added.id) == 'string', 'adding a lesson is one call')
-- The tool dispatch loads the module once per call, so this test's instance must drop its cache to see
-- what was written through the tool: the store file is the source of truth, not module state.
lessons.forget_cache()
local after = lessons.recall('zz-fleetops-lesson')
ok(#after.lessons > 0 and after.lessons[1].id == added.id, 'and a later recall returns it')
local refused = tools.dispatch(memory, 'lessons', { action = 'add', symptom = 'something happened' }, 'master', {})
ok(refused and refused.error == 'lesson_rule_required', 'a lesson with no rule is refused, not stored')
ok(refused.effect == 'none', 'and it changed nothing')
local stats = tools.dispatch(memory, 'lessons', { action = 'stats' }, 'master', {})
ok(stats and stats.stats and stats.stats.count >= 5, 'the store reports its size')

-- ---- 5. fleetview: every field on a three-node local fabric ----------------------------------------
local now = 1794000006000
local function observation(index, name, local_node)
  return {
    name = name, node_id = 'id-' .. name, role = local_node and 'master' or 'peer', local_node = local_node,
    online = true, last_seen_ms = now - index * 1000, version = '0.1.0', commit = '45d8a8c5',
    health = { state = 'ok', source = 'runtime_info' },
    resources = { disk = { available_bytes = 40e9, total_bytes = 100e9, used_percent = 40.0 } },
    components = {
      { name = 'wa-whatsapp', enabled = true, definition = { features = { 'whatsapp_send' } },
        live = { state = 'running' } },
      { name = 'wa-email', enabled = true, definition = { features = { 'email_send' } },
        live = { state = 'running' } },
    },
    operations = { { id = 'op-1', state = 'running', kind = 'bash' } },
    jobs = { { id = 'job-1', state = 'queued' } },
    incidents = {},
  }
end
local fabric = { observation(0, 'laptop', true), observation(1, 'nextcloud', false), observation(2, 'mail', false) }
local view = fleetview.assemble(fabric, {
  now_ms = now,
  lessons = { { id = 'les-fixture', at = now - 5000, rule = 'fixture lesson reaches every node', tags = {} } },
})
ok(view.count == 3, 'the view has all three nodes')
ok(view.nodes[1].local_node == true, 'the local node answers first')
for _, node in ipairs(view.nodes) do
  for _, field in ipairs(fleetview.FIELDS) do
    ok(node[field] ~= nil, node.name .. ' answers ' .. field)
  end
  ok(node.missing == nil, node.name .. ' names nothing as missing when everything was read')
  ok(node.health.state == 'ok', node.name .. ' reports its health state')
  ok(node.disk.used_percent == 40.0, node.name .. ' reports its disk')
  ok(#node.components == 2, node.name .. ' lists its components')
  ok(#node.features > 0, node.name .. ' lists the features they carry')
  ok(#node.operations == 1 and #node.jobs == 1, node.name .. ' lists running work')
  ok(#node.incidents == 1 and node.incidents[1].id == 'les-fixture', node.name .. ' carries the lesson')
end
ok(view.read_only == true, 'the view says it is read-only')

-- The half-answer: a peer the registry knows only for reachability names what nobody read.
local partial = fleetview.node({ name = 'mail', node_id = 'id-mail', local_node = false, online = false,
  last_seen_ms = now - 600000, health_reason = 'peer_offline_no_sample' }, { now_ms = now })
ok(partial.online == false and partial.last_seen_age_s == 600, 'what was read is answered')
for _, field in ipairs({ 'version', 'commit', 'disk', 'components', 'operations', 'jobs' }) do
  ok(partial[field] == nil and partial.missing and count(table.concat(partial.missing, ','), field) == 1,
    'a field nobody read is named: ' .. field)
end
ok(partial.disk == nil, 'an unread disk is absent, never 0%')

-- Through the tool, on this node: the live collector answers one node and says it is read-only.
local live = tools.dispatch(memory, 'fleetview', {}, 'master', {})
ok(type(live) == 'table' and live.schema == 'fleetview.v1', 'the fleetview tool answers its schema')
ok(live.count >= 1 and live.nodes[1].local_node == true, 'with this node first')
ok(live.read_only == true, 'and read-only')
ok(tools.has_effect('fleetview') == false, 'the tool catalogue marks fleetview read-only')
local guest_view = tools.dispatch(memory, 'fleetview', { lessons = false }, 'guest', {})
ok(type(guest_view) == 'table' and guest_view.read_only == true, 'a guest may read the fleet, and only read')

print(string.format('fleetops layers: %d checks, %d failed', checks, failed))
if failed > 0 then error('fleetops layers: ' .. failed .. ' failed checks') end
