-- A WRONG FIELD NAME ANSWERS WITH THE NEAREST REAL NAME AND ITS SHAPE: edit (refusals-that-help (b)).
--
-- MEASURED (notes 8, 128): a model wrote old_string/new_string - and new_str - and learned the real shape
-- only after the call. edit answers this case with its OWN sentence, which names both accepted forms with
-- their full shape. NAMED GAP: it carries none of the shared fields (did_you_mean/suggested_shape).
--
-- Mechanism: lua/core/json_contract.lua owns "what did the caller mean" (nearest name first, then its intent
-- table) and the field's own shape; lua/core/tool_arguments.lua no longer keeps a second copy of the distance
-- rule (law 17/18). No tool description changed - zero prompt bytes; the naming lives in a RESULT.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'field names', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
policy.pin(memory, 'master', ctx)
local checks, failed = 0, 0
local function check(ok, message)
  if ok then checks = checks + 1 else failed = failed + 1; print('FAIL ' .. message) end
end
local root = os.getenv('HOME') .. '/.wasm-agent/tmp/field-names'
os.execute('mkdir -p ' .. root)
local path = root .. '/a.txt'
assert(host.write_file(path, 'alpha\nbeta\ngamma\n'))

local wrong = tools.dispatch(memory, 'edit', { path = path, old_str = 'beta', new_str = 'BETA' }, 'master', ctx)
check(type(wrong) == 'table' and wrong.error ~= nil,
  'an unknown field is refused: ' .. json.encode(wrong or {}):sub(1, 240))
check(type(wrong) == 'table' and tostring(wrong.input or ''):find('new_str', 1, true) ~= nil,
  'the refusal carries the name that was wrong: ' .. tostring(type(wrong) == 'table' and wrong.input))
local fix = tostring(type(wrong) == 'table' and wrong.fix or '')
check(fix:find('edits', 1, true) ~= nil and fix:find('array of', 1, true) ~= nil,
  'the way on names the accepted field that carries old/new text: ' .. fix:sub(1, 300))
check(type(wrong) == 'table' and wrong.did_you_mean == 'edits',
  'and the refusal names the field it meant: ' .. tostring(type(wrong) == 'table' and wrong.did_you_mean))
check(type(wrong) == 'table' and tostring(wrong.suggested_shape or ''):find('old_text', 1, true) ~= nil,
  'and its shape: ' .. tostring(type(wrong) == 'table' and wrong.suggested_shape))
check(host.read_file(path) == 'alpha\nbeta\ngamma\n', 'and nothing ran')
local right = tools.dispatch(memory, 'edit', { path = path, edits = { { old_text = 'beta', new_text = 'BETA' } } }, 'master', ctx)
check(type(right) == 'table' and right.applied == true,
  'the field it named applies the edit: ' .. json.encode(right or {}):sub(1, 200))
check(host.read_file(path):find('BETA', 1, true) ~= nil, 'and it landed')
print(('field names edit: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
