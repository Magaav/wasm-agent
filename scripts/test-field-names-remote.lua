-- A WRONG FIELD NAME ANSWERS WITH THE NEAREST REAL NAME AND ITS SHAPE: `remote` (refusals-that-help (b)).
--
-- MEASURED, both routes, after lua/core/json_contract.lua's owner was wired into the argument validator: a peer
-- call (and a self call) with `path_str` answers `unknown_argument:path_str - did you mean path?` with
-- `did_you_mean: path` and `path is string`. Before that wiring the route answered `path_required` first, which
-- named the missing field but never the wrong name - the gap this row used to record, now closed by the same
-- mechanism, so the row pins the answer instead of the gap.
--
-- No tool description changed: zero prompt bytes; the naming lives in a result.
local guard = dofile('scripts/lib/test-home-guard.lua')
local reason = guard.reason({ home = os.getenv('WASM_AGENT_HOME') or '',
  scratch = os.getenv('GATE_ROOT') or os.getenv('TMPDIR') or '' })
if reason then error('this test refuses to run (' .. reason .. ')') end
local json = dofile('lua/vendor/json.lua')
local memory = dofile('lua/core/memory.lua'); memory.setup()
local nodes = dofile('lua/core/nodes.lua')
local tools = dofile('lua/core/tools.lua'); local policy = dofile('lua/core/codemode_policy.lua')
local sid = memory.start_session('', 'field names remote', { user_id = 'master' })
local ctx = { session_id = sid, user_id = 'master' }
policy.pin(memory, 'master', ctx)
local checks, failed = 0, 0
local function check(ok, message)
  if ok then checks = checks + 1 else failed = failed + 1; print('FAIL ' .. message) end
end
local root = os.getenv('HOME') .. '/.wasm-agent/tmp/field-names-remote'
os.execute('mkdir -p ' .. root)
local path = root .. '/a.txt'
assert(host.write_file(path, 'alpha\nbeta\n'))
local self_name = nodes.node_name()

local wrong = tools.dispatch(memory, 'remote', { node = self_name, capability = 'read', path_str = path }, 'master', ctx)
check(type(wrong) == 'table' and tostring(wrong.error):find('unknown_argument:path_str', 1, true) ~= nil,
  'a remote call with an unknown field is refused by name: ' .. json.encode(wrong or {}):sub(1, 240))
check(type(wrong) == 'table' and wrong.did_you_mean == 'path',
  'and names the field it meant: ' .. tostring(type(wrong) == 'table' and wrong.did_you_mean))
check(type(wrong) == 'table' and tostring(wrong.suggested_shape or '') == 'string',
  'and its exact shape: ' .. tostring(type(wrong) == 'table' and wrong.suggested_shape))

-- THE PEER ROUTE: measured with a probe (not asserted here, because this row loads tools.lua before it
-- can hand it a patched nodes table): with nodes.remote_call routed back through the same dispatch, a
-- peer call with path_str answered unknown_argument:path_str - did you mean path?, did=path. Same answer,
-- same owner.

local right = tools.dispatch(memory, 'remote', { node = self_name, capability = 'read', path = path }, 'master', ctx)
check(type(right) == 'table' and tostring(right.error or ''):find('path_str', 1, true) == nil,
  'and with the right field the call gets past the naming refusal: ' .. json.encode(right or {}):sub(1, 240))
print(('field names remote: %d check(s), %d failed'):format(checks, failed))
if failed > 0 then os.exit(1) end
