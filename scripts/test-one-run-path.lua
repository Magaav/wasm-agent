-- ONE RUN PATH (Victor 21/11): run(code=...) is the only way to act.
--
-- This row judges the three things that keep it one path, on the real modules:
--   1. the SWITCH is refused by name - every value, known or not - and read as nothing else;
--   2. the PROVIDER door is refused by name when it cannot answer with a tool call, so a node is never
--      quietly moved to another path;
--   3. a THREAD frozen in a removed mode moves to the run tool with ONE note that names the mode, and
--      its earlier rows are byte-identical; a thread already frozen on this path gets no note at all,
--      so it pays no cache miss.
--
-- Hermetic: it writes its own scratch home (the guard refuses the real one), starts its own session and
-- touches no provider: nothing here calls a model or a node.
if not host then error('this test runs under the node (WA_SCRIPT), not plain Lua') end
local json = dofile('lua/vendor/json.lua')
local home_guard = dofile('scripts/lib/test-home-guard.lua')
local test_home = os.getenv('WASM_AGENT_HOME') or ''
local scratch_root = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or ''
local guard_reason = home_guard.reason({ home = test_home, scratch = scratch_root })
if guard_reason then error('this test writes a ledger: it refuses to run (' .. guard_reason .. ')') end

local real_getenv = host.getenv
local switch_value = nil
host.getenv = function(key)
  if key == 'WASM_AGENT_RAW_CODE' then return switch_value end
  return real_getenv(key)
end

local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end

local raw_code = dofile('lua/core/raw_code.lua')

-- ---- 1. the switch is gone, and every value says so --------------------------------------------
switch_value = nil
check(raw_code.switch_refusal() == nil, 'an unset switch is the ordinary case and refuses nothing')
for _, value in ipairs({'only', 'first', 'stop', 'on', '1', 'true', 'e2', 'e3', 'bash', 'native',
    'codemode', 'off', '0', 'false', 'no', 'something-nobody-ever-wrote'}) do
  switch_value = value
  local refusal = raw_code.switch_refusal()
  check(refusal and refusal.name == 'run_switch_removed', 'the switch value ' .. value .. ' is refused by name')
  check(refusal.value == value, 'and the refusal names the value it read: ' .. tostring(refusal.value))
  check(refusal.text:find('WASM_AGENT_RAW_CODE=' .. value, 1, true) ~= nil,
    'the sentence names the variable and its value: ' .. value)
  check(refusal.text:find('run(code=...) is the only way to act', 1, true) ~= nil,
    'and says the switch is gone and one path is left: ' .. value)
  check(refusal.text:find('no mode to set', 1, true) ~= nil,
    'it never reads the value as "off": ' .. value)
end
-- A known value also says which door it used to open; an unknown one says no build ever had it.
switch_value = 'only'
check(raw_code.switch_refusal().text:find('the fenced run block as the only way to act', 1, true) ~= nil,
  'a removed value names the door it named')
switch_value = 'something-nobody-ever-wrote'
check(raw_code.switch_refusal().text:find('no build ever had that value', 1, true) ~= nil,
  'an unknown value is refused as unknown, not passed')
switch_value = nil

-- ---- 2. the provider door: native tool calls, or a refusal by name -----------------------------
check(raw_code.transport_refusal('opencode-go', 'deepseek-v4.1-flash') == nil,
  'the fleet provider has a tool-call row, so it is not refused')
local door = raw_code.transport_refusal('a-provider-nobody-measured', 'a-model-nobody-measured')
check(door and door.name == 'provider_cannot_call_tools', 'an unknown provider is refused by name')
check(door.text:find('this provider cannot call tools; add a row or measure it with', 1, true) ~= nil,
  'and says how to open the door')
check(door.text:find('wa conform a-model-nobody-measured', 1, true) ~= nil,
  'naming the measurement of THAT model')
check(door.text:find('moved to another transport', 1, true) ~= nil,
  'and that it is never moved to another path')

-- ---- 3. the action written as text is markup, and nothing runs it ------------------------------
local fenced = 'here it is\n```js run\nreturn await tools.ls({path: "lua"});\n```'
local found = raw_code.text_action(fenced)
check(found and found.marker == '```js run', 'a run block that ends the answer is the action in the wrong form')
check(raw_code.text_action('an example, mid-answer:\n```js run\nreturn 1;\n```\nand that is what it means') == nil,
  'a block the answer goes on from is prose, not an action')
check(raw_code.text_action('```js\nreturn 1;\n```') ~= nil, 'a bare js block that ends the answer is marked the same way')
check(raw_code.text_action('no code here at all') == nil, 'plain prose is an answer')

-- ---- 4. an old thread moves here, once ---------------------------------------------------------
local memory = dofile('lua/core/memory.lua'); memory.setup()
local prompt_cache = dofile('lua/core/prompt_cache.lua')
local sid = memory.start_session('', 'one-run-path thread', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master', role = 'master' }
-- The rows this thread already had: they must come through the move untouched.
memory.append_turn(sid, { id = 'before-1', role = 'user', content = 'an earlier message', debug = false })
memory.append_turn(sid, { id = 'before-2', role = 'assistant', content = 'an earlier answer', debug = false })
local function rows()
  local list = {}
  for _, row in ipairs(memory.messages(sid) or {}) do
    if row.id == 'before-1' or row.id == 'before-2' then
      list[#list + 1] = json.encode({ id = row.id, role = row.role, content = row.content })
    end
  end
  return table.concat(list, '|')
end
local earlier = rows()
check(earlier ~= '', 'the thread has earlier rows before the move')

-- The record the BASE writes for a thread frozen in `only`: nothing declared, the block's guidance
-- in parts, and the mode in raw_mode.
local old_system = 'frozen system prompt of an only-mode thread'
local old_tools = json.encode({})
local old_system_sha = host.sha256(old_system)
local old_tools_sha = host.sha256(old_tools)
local record = {
  v = prompt_cache.VERSION, at = host.now(), system = old_system, system_sha256 = old_system_sha,
  tools = old_tools, tools_sha256 = old_tools_sha, parts = { codemode = host.sha256('only guidance') },
  orchestration = false, orchestration_noted = false, raw_mode = 'only',
  state = host.sha256(old_system_sha .. '\0' .. old_tools_sha),
}
record.noted = record.state
local key = prompt_cache.key(ctx)
local wrote = host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',
  json.encode({ key, json.encode(record) }))
check(type(wrote) == 'string' and wrote:find('"ok":true', 1, true) ~= nil, 'the base record is in the store')

-- The new tree resolves the native surface for this thread and enforces the prefix.
local tools = dofile('lua/core/tools.lua')
local native_list = tools.envelope('master', ctx)
local declared = {}
for _, item in ipairs(native_list) do declared[(item['function'] or {}).name] = true end
check(declared.run == true, 'the surface this build resolves has the run tool')
local new_system = 'the same session prompt, resolved by this build'
local frozen, report = prompt_cache.enforce(ctx, {
  system = new_system, tools = native_list,
  parts = { codemode = host.sha256('one-run-path guidance') },
  orchestration = false, facts = {}, catalog = native_list,
  raw_mode = 'native', raw_decided = true,
})
check(report and report.changed == true, 'moving the thread to the run tool is ONE cache miss, and it is reported')
check(report.note_required == true, 'and it owes the note that names the change')
local reasons = {}
for _, reason in ipairs(report.reasons or {}) do reasons[reason] = true end
check(reasons.native == true, 'the reason is named: native')
check(report.removed_mode == 'only', 'the report carries the mode the thread was frozen in')

local delivered = prompt_cache.notes(ctx, frozen, report, {})
check(#delivered == 1, 'exactly one note is appended, not one per reason')
local note = delivered[1]
check(type(note) == 'string' and note:find('[session update]', 1, true) == 1, 'it is the session-update note')
check(note:find('"only"', 1, true) ~= nil, 'it names the mode the thread was started in')
check(note:find('run(code=...) is the only way to act', 1, true) ~= nil, 'and names the one path it moves to')
check(note:find('run tool', 1, true) ~= nil, 'telling the model to call the run tool')
check(note:find('earlier messages are unchanged', 1, true) ~= nil, 'and that its earlier messages are kept')

-- Once: the same resume again owes nothing, so the note is not repeated.
local frozen2, report2 = prompt_cache.enforce(ctx, {
  system = new_system, tools = native_list,
  parts = { codemode = host.sha256('one-run-path guidance') },
  orchestration = false, facts = {}, catalog = native_list,
  raw_mode = 'native', raw_decided = true,
})
check(report2.note_required == false, 'the second resume owes no note: it was delivered once')
check(#prompt_cache.notes(ctx, frozen2, report2, {}) == 0, 'and appends nothing')
check(rows() == earlier, 'the earlier rows of that thread are byte-identical after the move')

-- A thread that ALREADY runs this way is not a move: no reason, no note, no cache miss.
local sid2 = memory.start_session('', 'already native thread', { user_id = 'master' })
local ctx2 = { session_id = sid2, user_id = 'master', role = 'master' }
local native_record = {
  v = prompt_cache.VERSION, at = host.now(), system = new_system, system_sha256 = host.sha256(new_system),
  tools = json.encode(native_list), tools_sha256 = host.sha256(json.encode(native_list)),
  parts = { codemode = host.sha256('one-run-path guidance') },
  orchestration = false, orchestration_noted = false, raw_mode = 'native',
  state = host.sha256(host.sha256(new_system) .. '\0' .. host.sha256(json.encode(native_list))),
}
native_record.noted = native_record.state
local key2 = prompt_cache.key(ctx2)
host.sql_exec('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)', json.encode({ key2, json.encode(native_record) }))
local frozen3, report3 = prompt_cache.enforce(ctx2, {
  system = new_system, tools = native_list,
  parts = { codemode = host.sha256('one-run-path guidance') },
  orchestration = false, facts = {}, catalog = native_list,
  raw_mode = 'native', raw_decided = true,
})
check(report3.changed == false and report3.note_required == false,
  'a thread already on this path keeps its bytes: no cache miss and no note')
check(#prompt_cache.notes(ctx2, frozen3, report3, {}) == 0, 'and nothing is appended')

print('one run path ok (' .. checks .. ' checks)')
