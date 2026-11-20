-- Item 1 of review r4: the mode is DECIDED AND PINNED BEFORE the tool context is built.
--
-- The defect this pins, measured: build_context used to build code_ctx from a policy pinned BEFORE the
-- thread's mode was decided, so the declared tool list came from the NODE's mode. Resuming a recorded
-- thread (or a legacy thread) under a different node mode therefore changed the tool list,
-- prompt_cache.enforce reported it changed, and the model was sent a "[session update] ... removed: ..."
-- note about tools it never lost.
--
-- Each case builds the SAME session TWICE with a new agent under a DIFFERENT node mode, and asserts the
-- second build: (1) resolves the tools the first one did, (2) says the frozen prefix did not change, and
-- (3) appends no session-update note.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local agent = dofile('lua/core/agent.lua')
local raw_lib = dofile('lua/core/raw_code.lua')
local pcache = dofile('lua/core/prompt_cache.lua')

local checks = 0
local function ok(v, label) checks = checks + 1; if not v then error(label, 0) end end
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then error(label .. ' (got ' .. tostring(got) .. ', want ' .. tostring(want) .. ')', 0) end
end

local real_getenv = host.getenv
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

local function names(list)
  local out = {}
  for _, item in ipairs(list or {}) do out[#out + 1] = item['function'].name end
  table.sort(out)
  return table.concat(out, ',')
end

local function thread(title)
  return memory.start_session('', title, { user_id = 'master', title = title })
end

-- One build of a session under one node mode, with a FRESH agent each time (a restart, a pool worker,
-- a provider switch - anything that builds the context again).
local function build(sid, node_mode)
  return with({ WASM_AGENT_RAW_CODE = node_mode or false }, function()
    local bot = agent.new(sid, function() end, 'master', 'master', '')
    bot:build_context()
    return { tools = names(bot.tool_list), source = bot.mode_source,
      mode = bot.codemode_policy.raw_mode, report = bot.prefix and bot.prefix.report or {} }
  end)
end

-- The session-update notes delivered since a build: what the MODEL is sent when the prefix changed.
local function note_count(sid)
  local rows = memory.session_messages(sid, { all = true }) or {}
  local n = 0
  for _, row in ipairs(rows) do
    if type(row.content) == 'string' and row.content:find(pcache.NOTE_PREFIX, 1, true) then n = n + 1 end
  end
  return n
end

-- --------------------------------------------------------------- 1. a RECORDED thread, resumed
local recorded = with({ WASM_AGENT_RAW_CODE = 'codemode' }, function()
  local sid = thread('recorded in codemode')
  local first = build(sid, 'codemode')
  ok(first.tools ~= '', 'the recorded thread declares tools in codemode')
  -- codemode is the decision to have NO raw channel, recorded as the word off.
  eq(first.mode, 'off', 'and records the decision to have no raw channel')
  return { sid = sid, tools = first.tools }
end)
-- ...resumed under EVERY other node mode, including native and the block defaults:
for _, node_mode in ipairs({ 'native', 'first', 'only', 'off', 'on', 'stop' }) do
  local before = note_count(recorded.sid)
  local again = build(recorded.sid, node_mode)
  eq(again.source, 'record', node_mode .. ': the resumed thread reads its record')
  eq(again.mode, 'off', node_mode .. ': and keeps the decision it was started in')
  eq(again.tools, recorded.tools, node_mode .. ': so it resolves the SAME declared tools as its first build')
  eq(again.report.changed, false, node_mode .. ': the frozen prefix did not change')
  eq(note_count(recorded.sid) - before, 0, node_mode .. ': and this build delivered no session-update note')
end

-- --------------------------------------------------------------- 2. a LEGACY thread, resumed
local legacy = with({ WASM_AGENT_RAW_CODE = 'codemode' }, function()
  local sid = thread('legacy in codemode')
  local first = build(sid, 'codemode')
  -- Strip the field the way a record written before this release looks.
  local key = pcache.key({ session_id = sid, user_id = 'master', role = 'master' })
  local rows = json.decode(host.sql_query('SELECT value FROM meta WHERE key=?', json.encode({ key })))
  ok(type(rows) == 'table' and rows[1], 'the legacy fixture has a frozen record')
  local value = json.decode(rows[1].value)
  ok(value.raw_mode == 'off', 'and it carries the decision this branch recorded')
  value.raw_mode = nil
  host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key, json.encode(value) }))
  return { sid = sid, tools = first.tools }
end)
-- A legacy thread HONOURS an explicit switch (review r4, item 2), read through a27490af's OWN vocabulary
-- (review r5, item 2): that tree did not know `native`, so it read it as no raw channel - a pre-release
-- thread set to native resumes OFF. codemode is recorded as the word off for the same reason.
local EXPLICIT = { native = 'off', first = 'first', only = 'only', codemode = 'off', stop = 'stop' }
for _, node_mode in ipairs({ 'native', 'first', 'only', 'codemode', 'stop' }) do
  local again = build(legacy.sid, node_mode)
  eq(again.source, 'legacy', node_mode .. ': a record with no mode is named legacy')
  eq(again.mode, EXPLICIT[node_mode], node_mode .. ': and it honours the EXPLICIT switch')
end
-- With NO switch at all it keeps only, the mode a27490af froze a record like this in.
local no_switch = build(legacy.sid, false)
eq(no_switch.source, 'legacy', 'no switch: still a legacy record')
eq(no_switch.mode, 'only', 'no switch: and it keeps only')

-- The no-change property, on a PRISTINE legacy record: frozen in one mode, resumed under that same
-- explicit switch, twice. Nothing about its prefix may move and no session-update note may be owed -
-- this is the case the review names (a resume after a restart must not tell the model its tools changed).
local pristine = with({ WASM_AGENT_RAW_CODE = 'codemode' }, function()
  local sid = thread('legacy, never resumed elsewhere')
  build(sid, 'codemode')
  local key = pcache.key({ session_id = sid, user_id = 'master', role = 'master' })
  local rows = json.decode(host.sql_query('SELECT value FROM meta WHERE key=?', json.encode({ key })))
  local value = json.decode(rows[1].value)
  value.raw_mode = nil
  host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key, json.encode(value) }))
  return sid
end)
local settled = build(pristine, 'codemode')
eq(settled.source, 'legacy', 'the pristine record is legacy')
eq(settled.mode, 'off', 'and honours the switch it froze in')
local resumed = note_count(pristine)
local again_pristine = build(pristine, 'codemode')
eq(again_pristine.tools, settled.tools, 'a legacy record resumed under its own switch keeps its tools')
eq(again_pristine.report.changed, false, 'and its frozen prefix did not change')
eq(note_count(pristine) - resumed, 0, 'and this build owed the model no session-update note')

-- --------------------------------------------------------------- 3. the decision reaches the TOOL LIST
-- The mechanism, stated directly: what the envelope and subagent_tool_list read is the mode on the
-- POLICY they are handed, and build_context must have pinned it BEFORE handing it over. A native node
-- and its thread therefore agree on the surface even when the node says something else.
local native_thread = with({ WASM_AGENT_RAW_CODE = 'native' }, function()
  local sid = thread('native thread')
  return build(sid, 'native')
end)
eq(native_thread.mode, 'native', 'a thread started native records native')
eq(native_thread.tools, 'run', 'and declares the one door')
-- A child inherits the DECISION, including the decision to have no raw channel (review r4, SHOULD): a
-- parent that decided off cannot hand its child a door it closed.
eq(raw_lib.child_mode({ raw_mode = 'native' }, nil), 'native', 'child_mode answers the parent recorded mode')
eq(raw_lib.child_mode({ raw_mode = raw_lib.NO_CHANNEL }, nil), nil, 'and a parent that decided off hands down off')
eq(raw_lib.child_mode({ raw_decided = true }, nil), nil, 'and a decided nil is off too, never a legacy fallthrough')
eq(raw_lib.child_mode({}, { raw_mode = 'first' }), 'first', 'while a parent with no record still falls back to its policy')
local under_block_node = build(thread('native-shaped thread'), 'only')
eq(under_block_node.tools, '', 'while a thread started under only declares none (the surface follows the thread, not the node)')

print('mode decided first ok (' .. checks .. ' checks)')
