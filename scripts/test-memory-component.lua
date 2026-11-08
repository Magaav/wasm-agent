-- The memory seam's parity suite (docs/MEMORY.md "The memory seam"; docs/KERNEL.md "Memory as a
-- component"): the same inputs through the native Lua store and through the `memory` component over a
-- scoped `wa:kernel/sql` grant, compared field for field - remember/recall/forget/list/
-- search_messages/sessions, the FTS ranking order, and the retention decision.
--
-- Self-contained: the runner's own `--db` and a scratch WASM_AGENT_HOME, no node, no network.
-- The runtime half needs a built `memory.wasm` (rust/components/memory). When there is none the
-- parity comparisons are SKIPPED (printed as such, and reported in REPORT.md) and the fallback and
-- refusal checks still run - a skip is never counted as a pass.
local json = dofile('lua/vendor/json.lua')

-- `host.memory` answers with JSON text, like every other capability in this tree; a stub in this file
-- may hand back a table instead, so both are accepted.
local function decode(value)
  if type(value) ~= 'string' then return value end
  local ok, decoded = pcall(json.decode, value)
  return ok and decoded or value
end

local checks, comparisons, skipped = 0, 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then error('MEMORY SEAM CHECK FAILED: ' .. label) end
end
local function skip(what, why)
  skipped = skipped + 1
  print('SKIP memory seam: ' .. what .. ' (' .. why .. ')')
end

local native = dofile('lua/core/memory.lua')
native.setup()

------------------------------------------------------------------ the store, built once
-- Facts through the native path (the store both halves read), and a transcript built by hand: a
-- settled thread, an unfinished one and a failed one, so the derived state and the readable detail
-- are compared for every shape `classify` produces.
local ids = {}
ids.deploy = native.remember('the deploy token lives in the vault', 'global', { 'deploy', 'secrets' })
ids.monday = native.remember('the vault rotates every Monday at noon', 'global', { 'deploy' })
ids.accent = native.remember('configuração do servidor fica em /etc', 'global', {})
ids.guest = native.remember('guest note about vaults', 'user:guest', {})
ids.reserve = native.remember('reserve a standby node for the migration', 'global', { 'ops' })
ids.repeat_text = native.remember('the deploy token lives in the vault', 'global', { 'deploy', 'secrets' })
check(ids.repeat_text == ids.deploy, 'the native store deduplicates the identical fact')

local function sql(statement, params)
  local answer = json.decode(host.sql_exec(statement, json.encode(params or {})))
  if answer.error then error(answer.error) end
  return answer
end
local now = host.now()
for _, session in ipairs({
  { id = 's-settled', user = 'master', title = 'settled thread', last_ok = 1, role = 'assistant', phase = '', calls = '[]' },
  { id = 's-unfinished', user = 'master', title = 'unfinished thread', last_ok = 1, role = 'assistant', phase = '', calls = '[{"id":"c1","function":{"name":"bash","arguments":"{}"}}]' },
  { id = 's-failed', user = 'master', title = 'failed thread', last_ok = 0, role = 'assistant', phase = '', calls = '[]' },
  { id = 's-guest', user = 'guest', title = 'guest thread', last_ok = 1, role = 'assistant', phase = '', calls = '[]' },
}) do
  sql('INSERT INTO sessions(id,route_id,objective,started_at,ended_at,user_id,node_id,title,mode,updated_at) VALUES(?,?,?,?,NULL,?,?,?,?,?)',
    { session.id, '', '', now - 100, session.user, '', session.title, 'default', now - 50 })
  sql('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,ok,created_at,phase,trace) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
    { session.id .. '-m1', session.id, 1, 'user', 'where is the vault token for ' .. session.id, '[]', '', '', 1, now - 90, '', '[]' })
  sql('INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,ok,created_at,phase,trace) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
    { session.id .. '-m2', session.id, 2, session.role, 'the vault token is rotated', session.calls, '', '', session.last_ok, now - 80, session.phase,
      session.last_ok == 0 and '[{"kind":"llm","ok":false,"error":"provider said no"}]' or '[]' })
  sql('INSERT INTO messages_fts(content,session_id,message_id) VALUES(?,?,?)',
    { 'where is the vault token for ' .. session.id, session.id, session.id .. '-m1' })
end

------------------------------------------------------------------ the seam instance
-- A second instance of the same module with the `memory` feature (docs/FEATURES.md) routed to the
-- component. The switch is resolved through `lua/core/features.lua` at every call, and two instances of
-- the module share one `host.features` table - so the seam instance carries the module's own test seam
-- (`M.seam_override`) instead of a host stub, and the module's own code decides what to do with it.
local real_getenv, real_memory, real_log = host.getenv, host.memory, host.log
local logged = {}
-- The stubs stay installed until `restore()`: the module reads `host.log` when it falls back, which is
-- after the module was loaded, so a stub removed too early would be invisible to it.
local function seam_instance(memory_capability)
  host.memory = memory_capability or real_memory
  logged = {}
  host.log = function(line) logged[#logged + 1] = tostring(line) end
  local module = dofile('lua/core/memory.lua')
  module.seam_override = function() return true, 'active_component' end
  return module
end
local function restore()
  host.memory, host.log = real_memory, real_log
end

-- Where the built component is. `WA_MEMORY_COMPONENT_WASM` wins (the same development override the
-- agent core has), then a checkout build, then the workspace target dir.
local artifact
for _, candidate in ipairs({
  host.getenv('WA_MEMORY_COMPONENT_WASM') or '',
  'rust/components/memory/target/wasm32-wasip2/release/memory.wasm',
  (host.getenv('CARGO_TARGET_DIR') or '') .. '/wasm32-wasip2/release/memory.wasm',
}) do
  if candidate ~= '' and host.path_kind(candidate) == 'file' then artifact = candidate break end
end

-- Is the component actually reachable from *this process*? `host.memory` reads the artifact named by
-- `WA_MEMORY_COMPONENT_WASM` or the pinned install in the components directory; the Lua stub above
-- cannot influence that, and a "parity" comparison between the native path and a fallback would pass
-- while proving nothing. So the probe decides, and an unreachable component is a reported SKIP.
local seam, seam_log
local reachable = nil
if type(real_memory) ~= 'function' then
  skip('parity', 'this binary has no host.memory capability')
else
  reachable = decode(real_memory(json.encode({ op = 'retention', older_than_seconds = 1 })))
  if type(reachable) ~= 'table' or reachable.ok ~= true then
    skip('parity', 'the memory component did not answer: ' .. tostring(type(reachable) == 'table' and reachable.error or reachable))
    reachable = nil
  end
end

if reachable then
  -- A second instance of the module with the seam on. `host.log` stays stubbed while the component is
  -- exercised, so a silent fallback cannot pass as parity: the log is checked for fallback lines.
  seam = seam_instance(real_memory)
  seam_log = logged
  local written = seam.remember('the component wrote this fact', 'global', { 'seam' })
  check(type(written) == 'string' and #written == 36, 'the component answers remember with an id')
  check(#native.recall('component wrote this fact', 5) == 1, 'a fact written through the seam is readable from the store')
  seam.forget(written)
  check(#seam_log == 0, 'no fallback was logged while the component answered: ' .. tostring(seam_log[1]))
end

------------------------------------------------------------------ parity
local function encode(value) return json.encode(value) end

local function same(label, native_value, seam_value)
  comparisons = comparisons + 1
  local ok_left, left = pcall(encode, native_value)
  local ok_right, right = pcall(encode, seam_value)
  if not ok_left then error('PARITY: ' .. label .. ': the native answer is not encodable: ' .. tostring(left)) end
  if not ok_right then error('PARITY: ' .. label .. ': the component answer is not encodable: ' .. tostring(right)) end
  if left ~= right then
    error(string.format('PARITY: %s differs\n  native:    %s\n  component: %s', label, left, right))
  end
end

-- Remember is compared on the *store*, not on ids the two paths mint independently: the same text
-- stored again through the other path must dedupe onto the row that is already there, which is the
-- one thing that proves both compute `content_sha256` the same way.
if seam then
  local native_id = ids.reserve
  local through_seam = seam.remember('reserve a standby node for the migration', 'global', { 'ops' })
  same('remember deduplicates across paths', { id = native_id }, { id = through_seam })

  -- Recall: an exact term, a conversational query (the any-term pass), a scope, an exclusion, an
  -- accented word, an underscore identifier, and a query with no terms at all.
  for _, case in ipairs({
    { 'recall: exact term', text = 'vault', limit = 10 },
    { 'recall: two terms, AND then OR', text = 'deploy token', limit = 10 },
    { 'recall: conversational question', text = 'what did I ask you to remember about the vault', limit = 5 },
    { 'recall: accented term', text = 'configuração', limit = 5 },
    { 'recall: punctuation splits terms', text = 'configuração_do_servidor', limit = 5 },
    { 'recall: guest scope shared with global', text = 'vault', limit = 10, scope = 'user:guest' },
    { 'recall: guest scope exclusive', text = 'vault', limit = 10, scope = 'user:guest', exclusive = true },
    { 'recall: limit', text = 'vault', limit = 1 },
    { 'recall: no terms', text = '   ...   ', limit = 10 },
    { 'recall: no match', text = 'nothingmatchesthis', limit = 10 },
  }) do
    if case.exclusive then
      same(case[1], native.recall(case.text, case.limit, case.scope, true), seam.recall(case.text, case.limit, case.scope, true))
    elseif case.scope then
      same(case[1], native.recall(case.text, case.limit, case.scope), seam.recall(case.text, case.limit, case.scope))
    else
      same(case[1], native.recall(case.text, case.limit), seam.recall(case.text, case.limit))
    end
  end
  -- The ranking order itself, not just the set: bm25 plus the recency bonus is the component's copy
  -- of the native ORDER BY, and a different order is a different answer to a model.
  local function order(rows)
    local out = {}
    for index, row in ipairs(rows) do out[index] = row.content end
    return out
  end
  same('recall: ranking order', order(native.recall('vault', 10)), order(seam.recall('vault', 10)))

  -- list (memories): all, one scope, and a limit.
  local function without_rank(rows)
    local out = {}
    for index, row in ipairs(rows) do
      out[index] = { id = row.id, scope = row.scope, content = row.content, tags = row.tags,
                     source = row.source, created_at = row.created_at, updated_at = row.updated_at }
    end
    return out
  end
  same('list: all facts', without_rank(native.memories(nil, 50)), without_rank(seam.memories(nil, 50)))
  same('list: one scope', without_rank(native.memories('global', 3)), without_rank(seam.memories('global', 3)))

  -- search_messages: hits, order, the owning account and title.
  local function hits(rows)
    local out = {}
    for index, row in ipairs(rows) do
      out[index] = { id = row.id, session_id = row.session_id, seq = row.seq, role = row.role,
                     content = row.content, tool_name = row.tool_name, ok = row.ok and 1 or 0,
                     created_at = row.created_at, user_id = row.user_id, title = row.title }
    end
    return out
  end
  same('search_messages: hits', hits(native.search_messages('vault token', nil, 10)), hits(seam.search_messages('vault token', nil, 10)))
  same('search_messages: one account', hits(native.search_messages('vault token', 'guest', 10)), hits(seam.search_messages('vault token', 'guest', 10)))
  same('search_messages: no terms', hits(native.search_messages('...', nil, 10)), hits(seam.search_messages('...', nil, 10)))

  -- sessions: the derived state and the readable detail, for a settled, an unfinished and a failed
  -- thread. `state_detail` is built by the same `detail_of` from the same last-message fields, which
  -- is what makes "failed" carry its recorded error and its redaction in both paths.
  local function sessions(rows)
    local out = {}
    for index, row in ipairs(rows) do
      out[index] = { id = row.id, user_id = row.user_id, title = row.title, message_count = row.message_count,
                     state = row.state, state_detail = row.state_detail,
                     started_at = row.started_at, updated_at = row.updated_at }
    end
    return out
  end
  same('sessions: states and details', sessions(native.list_sessions('master', 10, { states = true })), sessions(seam.list_sessions('master', 10, { states = true })))
  same('sessions: without states', sessions(native.list_sessions('master', 10)), sessions(seam.list_sessions('master', 10)))
  same('sessions: one account', sessions(native.list_sessions('guest', 10, { states = true })), sessions(seam.list_sessions('guest', 10, { states = true })))

  -- forget: the same fact, forgotten through each path, leaves the same store.
  local forgotten_native = native.remember('forget me from the native path', 'global', {})
  local forgotten_seam = seam.remember('forget me from the component', 'global', {})
  check(native.forget(forgotten_native) == true, 'native forget retires the row')
  check(seam.forget(forgotten_native) == false, 'a row the native path retired is already gone for the component')
  check(seam.forget(forgotten_seam) == true, 'the component retires its own row')
  check(native.forget(forgotten_seam) == false, 'and the native path agrees it is gone')

  -- retention: the same refusal, and it deletes nothing on either path.
  local native_prune, native_reason = native.prune(30)
  local seam_prune, seam_reason = seam.prune(30)
  same('retention: the refusal', { prune = native_prune, reason = native_reason }, { prune = seam_prune, reason = seam_reason })

  -- Every comparison above ran against the component, not against a quiet fallback.
  check(#seam_log == 0, 'no comparison fell back to the native path: ' .. tostring(seam_log[1]))
  restore()
end

------------------------------------------------------------------ the SQL grant, from the seam's side
-- The host's own tests drive the refusals statement by statement (rust/wa-kernel-runtime/src/
-- sql_host.rs); here the question is what the *caller* sees when the grant says no: a named refusal,
-- never an empty store, and a fallback that still answers.
if type(real_memory) == 'function' then
  local refused = seam_instance(function() return { ok = false, error = 'sql_policy_refused:sql_read_out_of_scope' } end)
  local rows = refused.recall('vault', 5)
  same('a refused component call falls back to the native answer', native.recall('vault', 5), rows)
  local noted = false
  for _, line in ipairs(logged) do
    if tostring(line):find('sql_policy_refused', 1, true) and tostring(line):find('recall', 1, true) then noted = true end
  end
  check(noted, 'the refusal is logged with its reason: ' .. tostring(logged[1]))
  restore()

  -- A wedged component (the host names it `component_wedged`) and a missing capability take the same
  -- path: the native answer, one line of reason.
  local wedged = seam_instance(function() return { ok = false, error = 'component_wedged:recall:interrupt' } end)
  same('a wedged component falls back to the native answer', native.recall('vault token', 3), wedged.recall('vault token', 3))
  check(#logged == 1 and tostring(logged[1]):find('component_wedged', 1, true) ~= nil, 'the wedge is logged once with its reason: ' .. tostring(logged[1]))

  -- One line per (operation, reason), not one per call: a wedged component must be visible, and a
  -- log flooded on every recall is not.
  wedged.recall('vault', 3)
  check(#logged == 1, 'the fallback reason is logged once, not on every call')
  restore()

  local bare = seam_instance(nil)
  host.memory = nil
  local bare_module = dofile('lua/core/memory.lua')
  restore()
  same('a binary without the capability falls back', native.recall('vault', 3), bare_module.recall('vault', 3))
  bare = nil
end

------------------------------------------------------------------ latency
-- What the seam costs. Native: the SQL directly on this interpreter's connection. Component: a
-- component instantiation, a scoped connection, the same statements, and the answer across the
-- boundary. Medians of 15 recalls of the same store, milliseconds.
if seam then
  local function median(values)
    table.sort(values)
    return values[math.floor(#values / 2) + 1]
  end
  local function bench(fn)
    fn() -- warm
    local samples = {}
    for index = 1, 15 do
      local started = host.monotonic_ms()
      fn()
      samples[index] = host.monotonic_ms() - started
    end
    return median(samples)
  end
  for _, case in ipairs({
    { name = 'recall (single term)', native = function() return native.recall('vault', 10) end, seam = function() return seam.recall('vault', 10) end },
    { name = 'recall (conversational)', native = function() return native.recall('what did I ask you to remember about the vault', 5) end,
      seam = function() return seam.recall('what did I ask you to remember about the vault', 5) end },
    { name = 'search_messages', native = function() return native.search_messages('vault token', nil, 10) end,
      seam = function() return seam.search_messages('vault token', nil, 10) end },
    { name = 'sessions (states)', native = function() return native.list_sessions('master', 10, { states = true }) end,
      seam = function() return seam.list_sessions('master', 10, { states = true }) end },
  }) do
    local native_ms, seam_ms = bench(case.native), bench(case.seam)
    print(string.format('bench %-24s native %5.1f ms   component %5.1f ms', case.name, native_ms, seam_ms))
  end
end

local parity = (artifact and seam) and 'ran' or 'SKIPPED'
print(string.format('memory seam: %d checks, %d parity comparisons (%s), %d skipped', checks, comparisons, parity, skipped))
