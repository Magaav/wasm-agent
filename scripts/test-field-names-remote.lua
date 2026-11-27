-- A WRONG FIELD NAME ANSWERS WITH THE NEAREST REAL NAME AND ITS SHAPE: remote (refusals-that-help (b)).
--
-- The brief names remote too (its schema omits edits and its result shape; notes 215, 228, 63, 64).
-- NAMED GAP: on the peer route the target capability's REQUIRED-field check answers first (path_required), so
-- the caller is told to send path but never that path_str was the wrong name for it. The naming mechanism
-- itself is one owner and works (see the operation row).
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

local nodes = dofile('lua/core/nodes.lua')
local self_name = nodes.node_name()
local wrong = tools.dispatch(memory, 'remote', { node = self_name, capability = 'read', path_str = path }, 'master', ctx)
check(type(wrong) == 'table' and tostring(wrong.error or '') ~= '',
  'a peer call with an unknown field is refused: ' .. json.encode(wrong or {}):sub(1, 240))
check(type(wrong) == 'table' and tostring(wrong.fix or ''):find('path', 1, true) ~= nil,
  'and its fix names path, the field it meant: ' .. tostring(type(wrong) == 'table' and wrong.fix):sub(1, 200))
local right = tools.dispatch(memory, 'remote', { node = self_name, capability = 'read', path = path }, 'master', ctx)
check(type(right) == 'table' and tostring(right.error or ''):find('path_str', 1, true) == nil,
  'and with path the call gets past the naming refusal: ' .. json.encode(right or {}):sub(1, 240))
print(('field names remote: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
