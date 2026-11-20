-- Item 1 (rel review r3), the recorded decision, on the real modules.
--
--   1. there is NO process cache: a read with the switch unset asks the node every time (same work on
--      the second read, never zero), and a RECORDED policy is read without measuring anything;
--   2. a NEW thread gets the mode the node answers at its start; an EXISTING thread keeps its record;
--   3. a record written before raw_mode existed (a legacy thread) acts in only;
--   4. a child takes its PARENT's recorded mode, not the node's answer;
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
local pcache = dofile('lua/core/prompt_cache.lua')

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then error(label .. ' (got ' .. tostring(got) .. ', want ' .. tostring(want) .. ')', 0) end
end

local real_getenv, real_read_file = host.getenv, host.read_file
-- k -> false means UNSET: a caller that exported WASM_AGENT_RAW_CODE (a gate run, an operator shell)
-- must not decide what "the node's own answer" is in a test.
local function with(env, fn)
  host.getenv = function(k)
    if env[k] == false then return nil end
    if env[k] ~= nil then return env[k] end
    return real_getenv(k)
  end
  local okc, value = pcall(fn)
  host.getenv = real_getenv
  if not okc then error(value, 0) end
  return value
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

-- ---------------------------------------------------------------- 1. no cache
ok(raw.reset_mode_cache == nil, 'the process cache is GONE: raw_code has no reset_mode_cache')
local src = host.read_file((host.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/lua/core/raw_code.lua') or ''
ok(src:find('MODE_CACHE', 1, true) == nil, 'and no MODE_CACHE local survives in lua/core/raw_code.lua')
local p_src = host.read_file((host.getenv('WASM_AGENT_LUA_ROOT') or '.') .. '/lua/core/provider.lua') or ''
ok(p_src:find('reset_mode_cache', 1, true) == nil,
  'a provider switch no longer invalidates a cache, because there is none (lua/core/provider.lua)')

-- The node's answer is measured from node state (the provider row and the model profile), and a read
-- with no switch does that work EVERY time: a cached answer would make the second read free.
local work = {}
host.read_file = function(...) work[#work + 1] = 1; return real_read_file(...) end
local firsts = with({ WASM_AGENT_RAW_CODE = false }, function()
  work = {}; local m = raw.mode(); return { mode = m, n = #work }
end)
local seconds = with({ WASM_AGENT_RAW_CODE = false }, function()
  work = {}; local m = raw.mode(); return { mode = m, n = #work }
end)
host.read_file = real_read_file
ok(firsts.n > 0, 'a read with no switch measures the node (got ' .. firsts.n .. ' reads)')
eq(seconds.mode, firsts.mode, 'and the two reads agree')
ok(seconds.n > 0, 'the SECOND read does the work again: nothing is cached (got ' .. seconds.n .. ' reads)')

-- A RECORDED policy is the other half: it is read, never measured.
work = {}
host.read_file = function(...) work[#work + 1] = 1; return real_read_file(...) end
local recorded = { raw_mode = 'native' }
local from_record = raw.mode_of(recorded)
host.read_file = real_read_file
eq(from_record, 'native', 'mode_of(policy) answers the recorded mode')
eq(#work, 0, 'and touches no node state: the decision was made once, at the thread start')

-- ---------------------------------------------------------------- 2/3. the thread decides once
-- Thread A starts while the node answers native (explicit, so the test does not depend on the row)...
local sid_a = with({ WASM_AGENT_RAW_CODE = 'native' }, function()
  local b = bot(thread('recorded native'))
  eq(b.mode_source, 'switch', 'a new thread asks the node')
  eq(b.codemode_policy.raw_mode, 'native', 'and records native with the prefix it freezes')
  return b.session_id
end)
-- ...then the node's answer moves, mid-process.
local sid_b = with({ WASM_AGENT_RAW_CODE = 'first' }, function()
  local b = bot(thread('recorded later'))
  eq(b.codemode_policy.raw_mode, 'first', 'a NEW thread started after the move gets the NEW mode')
  return b.session_id
end)
ok(sid_a ~= sid_b, 'the two threads are distinct sessions')
local later_a = with({ WASM_AGENT_RAW_CODE = 'first' }, function() return bot(sid_a) end)
eq(later_a.mode_source, 'record', 'an existing thread reads its record, not the node')
eq(later_a.codemode_policy.raw_mode, 'native',
  'so the thread started native keeps native after the node moved to first')
local later_b = with({ WASM_AGENT_RAW_CODE = 'only' }, function() return bot(sid_b) end)
eq(later_b.codemode_policy.raw_mode, 'first', 'and the thread started later keeps the mode it recorded')
-- The record is durable, not in-memory: a fresh read of the stored prefix answers the same.
local stored = pcache.read({ session_id = sid_a, user_id = 'master', role = 'master' })
eq(type(stored) == 'table' and stored.raw_mode, 'native', 'the frozen prefix itself carries the mode')

-- A LEGACY record: the same row with raw_mode removed, which is what a thread frozen before this
-- release looks like (its record has system/tools/state and no raw_mode field).
local sid_l = with({ WASM_AGENT_RAW_CODE = 'native' }, function() return bot(thread('legacy record')).session_id end)
local key = pcache.key({ session_id = sid_l, user_id = 'master', role = 'master' })
ok(type(key) == 'string' and key ~= '', 'the legacy fixture has a store key')
local rows = json.decode(host.sql_query('SELECT value FROM meta WHERE key=?', json.encode({ key })))
ok(type(rows) == 'table' and rows[1], 'the frozen record is in the store')
local value = json.decode(rows[1].value)
ok(value.raw_mode ~= nil, 'the record written by this branch DOES carry raw_mode (the fixture drops it)')
-- A PRE-RELEASE record: it has no raw_mode field at all, which is what the absence now means.
value.raw_mode = nil
host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key, json.encode(value) }))
local legacy_read = pcache.read({ session_id = sid_l, user_id = 'master', role = 'master' })
ok(type(legacy_read) == 'table' and legacy_read.raw_mode == nil,
  'the legacy record reads back with NO raw_mode')
-- A legacy record HONOURS an explicit switch (review r4, item 2): that is the mode a27490af froze it in.
local legacy_thread = with({ WASM_AGENT_RAW_CODE = 'native' }, function() return bot(sid_l) end)
eq(legacy_thread.mode_source, 'legacy', 'a thread without a recorded mode is named legacy')
eq(legacy_thread.codemode_policy.raw_mode, 'native', 'and it honours the EXPLICIT switch')
eq(raw.mode_of(legacy_thread.codemode_policy), 'native', 'which every mode reader sees')
-- No switch at all: only, the mode such a record was frozen in.
local saved_explicit = raw.explicit
raw.explicit = function() return raw.UNSET end
local legacy_quiet = with({ WASM_AGENT_RAW_CODE = false }, function() return bot(sid_l) end)
raw.explicit = saved_explicit
eq(legacy_quiet.mode_source, 'legacy', 'with no switch at all it is still a legacy record')
eq(legacy_quiet.codemode_policy.raw_mode, 'only', 'and it keeps only - the mode its prefix was built in')

-- A thread that DECIDED no raw channel keeps that decision (the switch's own word, `off`): it must not
-- start asking the node again, and it must not read as legacy either.
local sid_off = with({ WASM_AGENT_RAW_CODE = 'codemode' }, function() return bot(thread('decided no channel')).session_id end)
local off_thread = with({ WASM_AGENT_RAW_CODE = 'native' }, function() return bot(sid_off) end)
eq(off_thread.mode_source, 'record', 'a decided record is read, never re-measured')
eq(off_thread.codemode_policy.raw_mode, raw.NO_CHANNEL, 'and it carries the word for no raw channel')
eq(raw.mode_of(off_thread.codemode_policy), nil, 'which mode_of answers as no channel at all')

-- ---------------------------------------------------------------- 4. a child takes the PARENT's mode
eq(raw.child_mode({ raw_mode = 'native' }, nil), 'native', 'child_mode answers the recorded parent mode')
eq(raw.child_mode({}, { raw_mode = 'first' }), 'first', 'and falls back to the policy when the record has none')
-- The child declared here is native while the node answers only (the switch): the parent's record wins.
local child = with({ WASM_AGENT_RAW_CODE = 'only' }, function()
  return bot(thread('child of a native parent'), { id = 'orchestration-worker',
    allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' }, raw_mode = 'native' })
end)
eq(child.mode_source, 'parent', 'a child reads its parent, never the node switch')
eq(child.codemode_policy.raw_mode, 'native', 'so a child of a native thread is native')
local names = {}
for _, item in ipairs(child.tool_list or {}) do names[#names + 1] = item['function'].name end
table.sort(names)
eq(table.concat(names, ','), 'run', 'and a native child declares the run tool alone')
-- A child whose parent recorded no mode falls back to its own policy, as before.
local fallback = with({ WASM_AGENT_RAW_CODE = 'codemode' }, function()
  return bot(thread('child without a parent mode'), { id = 'orchestration-worker',
    allowed = { 'read', 'write', 'bash', 'ls', 'run', 'codemode', 'edit' } })
end)
eq(fallback.mode_source, 'switch', 'a child with no parent record still asks the node')

-- ---------------------------------------------------------------- 5. RAW_CODE=bash keeps its meaning
eq(with({ WASM_AGENT_RAW_CODE = 'bash' }, function() return raw.mode() end), nil,
  'RAW_CODE=bash with no A/B arm means NO raw channel, exactly as a27490af read that unknown value')
eq(with({ WASM_AGENT_RAW_CODE = 'bash', WA_AB_ARM = 'bash' }, function() return raw.mode() end), 'bash',
  'and it is the bash transport only when the A/B switch names that arm')
eq(with({ WASM_AGENT_RAW_CODE = 'native' }, function() return raw.mode() end), 'native',
  'native is this branch own transport and is unaffected by the arm switch')

print('raw mode small rules ok (' .. checks .. ' checks)')
