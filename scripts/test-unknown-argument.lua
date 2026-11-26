-- AN ARGUMENT NAME THE TOOL DOES NOT DECLARE IS REFUSED, BY NAME, WITH THE NAME THAT WAS MEANT (25/11,
-- item 2 of this mission). Measured before this change: 52 of this node's 57 host tools accepted a key
-- their own schema never declared and dropped its value, so the call RAN AS A DIFFERENT CALL and answered
-- as if it had not; the 4 tools that take no arguments at all accepted anything.
--
-- THE RULE IS THE SCHEMA'S, IN ONE PLACE (lua/core/json_contract.lua): an object schema is closed unless
-- it says otherwise - `additionalProperties: true` (or a schema), which is how a tool that FORWARDS its
-- arguments to something with a schema of its own says so. A connector tool is therefore judged by the
-- CONNECTOR's schema, never refused for a key this host does not know; this row proves that too.
--
-- What this row pins:
--   1. a script's call with a key the tool does not declare fails, and the text names the key and the
--      name meant ("unknown_argument:ofsett - did you mean offset?"), and NOTHING RAN (the file the call
--      would have written does not exist);
--   2. the same wrong key through the outer tool door answers the same code and the same suggestion: one
--      rule, two doors, no per-tool copy;
--   3. an OPEN schema (a tool that forwards its arguments) is not refused for a key it does not declare -
--      `remote` carries its capability's own fields that way, and the answer is the node's own answer
--      about the call, never an argument refusal;
--   4. a CLOSED schema is refused even where the handler used to ignore the key (`capabilities`);
--   5. a healthy call is untouched: it answers what it always answered, with no refusal anywhere in it.
--
-- Hermetic: its own scratch home, and it refuses to run against a live one.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end

local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local paths = dofile('lua/core/paths.lua')
local sid = memory.start_session('', 'unknown argument', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }; policy.pin(memory, 'master', ctx)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function run(code) return tools.dispatch(memory, 'codemode', { code = code }, 'master', ctx) end
local function shown(result)
  return json.encode({ ok = result.ok, code = result.code, error = tostring(result.error):sub(1, 300),
    fix = tostring(result.fix):sub(1, 400), value = tostring(result.value):sub(1, 300) }):sub(1, 1100)
end
local home = paths.data()

-- 1. A SCRIPT'S CALL: refused by name, with the name meant, and nothing ran.
local target = home .. '/the-write-that-never-happened.txt'
local code = table.concat({
  'let said = null;',
  -- `conten` is one letter from the `content` this tool declares: the case a suggestion exists for.
  'try { await tools.write({path:' .. json.encode(target) .. ', content:"x", conten:"y"}); }',
  'catch (e) { said = String((e && e.message) || e); }',
  'return said;',
}, '\n')
local refused = run(code)
check(refused.ok == true, 'the script itself ran and caught the refusal: ' .. shown(refused))
local said = tostring(refused.value or '')
check(said:find('unknown_argument:conten', 1, true) ~= nil,
  'the call was refused by the name it sent: ' .. said:sub(1, 400))
check(said:find('did you mean', 1, true) ~= nil and said:find('content', 1, true) ~= nil,
  'and the sentence carries the name that was meant: ' .. said:sub(1, 400))
-- A name that is NOT close to a declared one gets no suggestion: a wrong guess is worse than none.
local far = run(table.concat({
  'let said = null;',
  'try { await tools.write({path:' .. json.encode(target) .. ', content:"x", zzzz:1}); }',
  'catch (e) { said = String((e && e.message) || e); }',
  'return said;',
}, '\n'))
check(tostring(far.value or ''):find('unknown_argument:zzzz', 1, true) ~= nil
    and tostring(far.value or ''):find('did you mean', 1, true) == nil,
  'a name far from every declared one is refused without a misleading suggestion: ' .. tostring(far.value):sub(1, 300))
check(host.read_file(target) == nil, 'nothing ran: the file the call would have written does not exist')
-- The evidence agrees: the call is recorded as never admitted.
local unadmitted = 0
for _, attempt in ipairs(refused.attempts or {}) do
  if attempt.name == 'write' and attempt.admitted ~= true then unadmitted = unadmitted + 1 end
end
check(unadmitted >= 1, 'the run says the call was never admitted: ' .. json.encode(refused.attempts or {}):sub(1, 400))

-- 2. THE SAME CALL THROUGH THE OUTER DOOR: one rule, one wording, both doors.
local outer = tools.dispatch(memory, 'write', { path = target, content = 'x', conten = 'y' }, 'master', ctx)
check(tostring(outer.error):find('unknown_argument:conten', 1, true) ~= nil,
  'the outer door refuses the same name: ' .. json.encode(outer):sub(1, 400))
check(tostring(outer.fix):find('content', 1, true) ~= nil,
  'and names the same argument that was meant: ' .. tostring(outer.fix):sub(1, 300))
check(outer.effect == 'none', 'with no effect: ' .. json.encode(outer):sub(1, 300))
check(host.read_file(target) == nil, 'and still nothing ran')

-- 3. AN OPEN SCHEMA: a tool that forwards its arguments is judged by the schema it forwards to.
local declared_open = (tools.parameters('remote', 'master') or {}).additionalProperties
check(declared_open == true, 'remote declares its arguments open, which is how it forwards them: ' .. tostring(declared_open))
local forwarded = tools.dispatch(memory, 'remote',
  { node = 'no-such-peer-here', capability = 'operation', output = true, max_bytes = 64 }, 'master', ctx)
check(tostring(forwarded.error) ~= 'unknown_argument:output' and tostring(forwarded.error) ~= 'unknown_argument:max_bytes',
  'a field the host does not declare is NOT refused on a forwarding tool: ' .. json.encode(forwarded):sub(1, 400))
check(tostring(forwarded.error):find('unknown_node', 1, true) ~= nil,
  'the answer is the node\'s own answer about the call: ' .. json.encode(forwarded):sub(1, 300))

-- 4. A CLOSED SCHEMA, where the handler used to ignore the key.
local closed = tools.dispatch(memory, 'capabilities', { stats = true }, 'master', ctx)
check(tostring(closed.error):find('unknown_argument:stats', 1, true) ~= nil,
  'capabilities declares itself closed, and refuses a key it does not take: ' .. json.encode(closed):sub(1, 400))
check(closed.capabilities == nil, 'and lists nothing that would read as an answer')

-- 5. A HEALTHY CALL IS UNTOUCHED: the same request answers what it always answered.
local healthy = tools.dispatch(memory, 'capabilities', { names = { 'read' } }, 'master', ctx)
check(healthy.error == nil and json.encode(healthy.capabilities or {}) == json.encode({ 'read' }),
  'a call with only declared names answers normally: ' .. json.encode(healthy):sub(1, 300))
local healthy_script = run('const r = await tools.time({}); return typeof r.epoch;')
check(healthy_script.ok == true and tostring(healthy_script.value):find('number', 1, true) ~= nil,
  'and a script call with its own declared arguments answers normally: ' .. shown(healthy_script))
check(json.encode(healthy_script):find('unknown_argument', 1, true) == nil,
  'with no refusal anywhere in the healthy block: ' .. shown(healthy_script))

print(json.encode({ ok = true, checks = checks }))
