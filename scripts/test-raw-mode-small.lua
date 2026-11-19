-- Item 1 (rel review r3), the recorded decision, on the real modules.
--
--   1. there is NO process cache: mode() answers the node's CURRENT row every time it is asked, and a
--      provider row switched mid-process is visible at once - but a THREAD decides once, at its start;
--   2. a NEW thread after the switch gets the new mode; an EXISTING thread keeps its own;
--   3. a record written before raw_mode existed (a legacy thread) acts in only;
--   4. a child takes its PARENT's recorded mode, not the node switch;
--   5. WASM_AGENT_RAW_CODE=bash keeps its a27490af meaning unless the A/B switch names the bash arm.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local raw = dofile('lua/core/raw_code.lua')
local agent = dofile('lua/core/agent.lua')
local provider = dofile('lua/core/provider.lua')
local profile = dofile('lua/core/model_profile.lua')
local pcache = dofile('lua/core/prompt_cache.lua')

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then error(label .. ' (got ' .. tostring(got) .. ', want ' .. tostring(want) .. ')', 0) end
end

local real = host.getenv
local function with(env, fn)
  host.getenv = function(k)
    if env[k] ~= nil then return env[k] end
    return real(k)
  end
  local okc, value = pcall(fn)
  host.getenv = real
  if not okc then error(value, 0) end
  return value
end

-- The provider ROW is the switch, and it is a row (lua/core/model_profile.lua, DEFAULT_TRANSPORTS), so a
-- test flips it by editing that one table and restoring it - no file, no live node state.
local ROW = 'opencode-go'
local saved_row = profile.DEFAULT_TRANSPORTS[ROW]
local function row(value)
  profile.DEFAULT_TRANSPORTS[ROW] = value
  provider.unpin()
end

local function bot(sid, subagent)
  local opts = {}
  if subagent then
    local allowed = {}
    for _, name in ipairs(subagent.allowed or {}) do allowed[name] = true end
    opts.subagent = { id = subagent.id or 'orchestration-worker', allowed = allowed,
      allowed_tools = subagent.allowed or {}, raw_mode = subagent.raw_mode }
  end
  local b = agent.new(sid, function() end, 'master', 'master', '', opts)
  b:build_context()
  return b
end

local function thread(title)
  return memory.start_session('', title, { user_id = 'master', title = title })
end

-- ---------------------------------------------------------------- 1. no cache: the row is read live
ok(raw.reset_mode_cache == nil, 'the process cache is GONE: raw_code has no reset_mode_cache')
local src = host.read_file((host.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/lua/core/raw_code.lua') or ''
ok(src:find('MODE_CACHE', 1, true) == nil, 'and no MODE_CACHE local survives in lua/core/raw_code.lua')
local p_src = host.read_file((host.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/lua/core/provider.lua') or ''
ok(p_src:find('reset_mode_cache', 1, true) == nil,
  'a provider switch no longer invalidates a cache, because there is none (lua/core/provider.lua)')

local counted = 0
local original_default = raw.default_mode
raw.default_mode = function(...) counted = counted + 1; return original_default(...) end
row(profile.TOOL_CALL)
eq(with({}, function() return raw.mode() end), 'native', 'a tool-calling row answers native')
row(nil)
eq(with({}, function() return raw.mode() end), raw.DEFAULT, 'and the same process answers the block default once the row is gone')
ok(counted >= 2, 'mode() measured the row again instead of answering from a cache (got ' .. counted .. ')')
raw.default_mode = original_default

-- ---------------------------------------------------------------- 2/3. the thread decides once
-- Thread A starts while the node is native...
row(profile.TOOL_CALL)
local sid_a = with({}, function()
  local b = bot(thread('recorded native'))
  eq(b.mode_source, 'switch', 'a new thread asks the node')
  eq(b.codemode_policy.raw_mode, 'native', 'and records native with the prefix it freezes')
  return b.session_id
end)
-- ...then the node moves to the block default, mid-process.
row(nil)
local sid_b = with({}, function()
  local b = bot(thread('recorded later'))
  eq(b.codemode_policy.raw_mode, raw.DEFAULT, 'a NEW thread started after the switch gets the NEW mode')
  return b.session_id
end)
ok(sid_a ~= sid_b, 'the two threads are distinct sessions')
local later_a = with({}, function() return bot(sid_a) end)
eq(later_a.mode_source, 'record', 'an existing thread reads its record, not the switch')
eq(later_a.codemode_policy.raw_mode, 'native', 'so the thread started native keeps native after the node moved')
local later_b = with({}, function() return bot(sid_b) end)
eq(later_b.codemode_policy.raw_mode, raw.DEFAULT, 'and the thread started later keeps the mode it recorded')
-- The record is durable, not in-memory: a fresh read of the stored prefix answers the same.
local stored = pcache.read({ session_id = sid_a, user_id = 'master', role = 'master' })
eq(type(stored) == 'table' and stored.raw_mode, 'native', 'the frozen prefix itself carries the mode')

-- A LEGACY record: the same row with raw_mode removed, which is what a thread frozen before this
-- release looks like (its record has system/tools/state and no raw_mode field).
row(profile.TOOL_CALL)
local sid_l = with({}, function() return bot(thread('legacy record')).session_id end)
local key = pcache.key({ session_id = sid_l, user_id = 'master', role = 'master' })
ok(type(key) == 'string' and key ~= '', 'the legacy fixture has a store key')
local rows = json.decode(host.sql_query('SELECT value FROM meta WHERE key=?', json.encode({ key })))
ok(type(rows) == 'table' and rows[1], 'the frozen record is in the store')
local value = json.decode(rows[1].value)
ok(value.raw_mode ~= nil, 'the record written by this branch DOES carry raw_mode (the fixture is built by dropping it)')
value.raw_mode = nil
host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key, json.encode(value) }))
local legacy_read = pcache.read({ session_id = sid_l, user_id = 'master', role = 'master' })
ok(type(legacy_read) == 'table' and legacy_read.raw_mode == nil, 'the legacy record reads back with NO raw_mode')
local legacy_thread = with({}, function() return bot(sid_l) end)
eq(legacy_thread.mode_source, 'legacy', 'a thread without a recorded mode is named legacy')
eq(legacy_thread.codemode_policy.raw_mode, 'only', 'and it keeps only - the mode its prefix was built in')

-- ---------------------------------------------------------------- 4. a child takes the PARENT's mode
row(profile.TOOL_CALL)
local native_parent = with({}, function() return bot(thread('native parent')) end)
eq(native_parent.codemode_policy.raw_mode, 'native', 'the parent is native')
local child_same = with({}, function()
  return bot(thread('child of native'), { id = 'orchestration-worker',
    allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' }, raw_mode = native_parent.codemode_policy.raw_mode })
end)
eq(child_same.mode_source, 'parent', 'a child reads its parent, never the switch')
eq(child_same.codemode_policy.raw_mode, 'native', 'so a child of a native thread is native')
eq(raw.child_mode({ raw_mode = 'native' }, nil), 'native', 'child_mode answers the recorded parent mode')
eq(raw.child_mode({}, { raw_mode = 'first' }), 'first', 'and falls back to the policy when the record has none')
-- The child's declared surface follows that recorded mode: run alone, the same one door a native master
-- gets - while the node's own switch, below, is the block default.
local child_tools = {}
for _, item in ipairs(child_same.tool_list or {}) do child_tools[#child_tools + 1] = item['function'].name end
table.sort(child_tools)
eq(table.concat(child_tools, ','), 'run', 'and a native child declares the run tool alone')
-- Now the node moves while the child runs: the child's decision does not move with it.
row(nil)
local child_after_switch = with({}, function()
  return bot(thread('child after switch'), { id = 'orchestration-worker',
    allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' }, raw_mode = 'native' })
end)
eq(child_after_switch.codemode_policy.raw_mode, 'native',
  'a child admitted native stays native after the node switch moved (its receipt carries it)')

-- ---------------------------------------------------------------- 5. RAW_CODE=bash keeps its meaning
eq(with({ WASM_AGENT_RAW_CODE = 'bash' }, function() return raw.mode() end), nil,
  'RAW_CODE=bash with no A/B arm means NO raw channel, exactly as a27490af read that unknown value')
eq(with({ WASM_AGENT_RAW_CODE = 'bash', WA_AB_ARM = 'bash' }, function() return raw.mode() end), 'bash',
  'and it is the bash transport only when the A/B switch names that arm')
eq(with({ WASM_AGENT_RAW_CODE = 'native' }, function() return raw.mode() end), 'native',
  'native is this branch own transport and is unaffected by the arm switch')

row(saved_row)
print('raw mode small rules ok (' .. checks .. ' checks)')
